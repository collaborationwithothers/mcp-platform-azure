using System.Net;
using System.Net.Http.Headers;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using Xunit;

namespace McpTools.AspNetCore.Tests;

public sealed class AuthenticationTests
{
    private static readonly Uri PrivateHost =
        new("https://mcp.internal.consultwithcloud.com");

    [Fact]
    public void JwtValidationUsesV1TenantMetadataAndIssuer()
    {
        using var factory = new TestMcpHostFactory();
        var options = factory.Services
            .GetRequiredService<IOptionsMonitor<JwtBearerOptions>>()
            .Get(JwtBearerDefaults.AuthenticationScheme);

        Assert.Equal(
            $"https://login.microsoftonline.com/{TestMcpHostFactory.TenantId}/"
                + ".well-known/openid-configuration",
            options.MetadataAddress);
        Assert.Equal(
            TestMcpHostFactory.Issuer,
            options.TokenValidationParameters.ValidIssuer);
    }

    [Fact]
    public async Task UnauthenticatedMcpRequestReturnsPrivateResourceChallenge()
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });

        using var response = await client.PostAsync("/mcp", McpPostBody());

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var challenge = Assert.Single(response.Headers.WwwAuthenticate);
        Assert.Equal("Bearer", challenge.Scheme);
        Assert.Equal(
            "resource_metadata=\"https://mcp.internal.consultwithcloud.com/"
                + ".well-known/oauth-protected-resource/mcp\"",
            challenge.Parameter);
    }

    [Fact]
    public async Task UnauthenticatedHealthProbeReturnsOnlyHealthStatus()
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });

        using var response = await client.GetAsync("/healthz");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("Healthy", await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task ForwardedHttpsSchemeServesPrivateMetadataBehindProxy()
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("http://mcp.internal.consultwithcloud.com"),
        });
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            "/.well-known/oauth-protected-resource/mcp");
        request.Headers.Add("X-Forwarded-Proto", "https");

        using var response = await client.SendAsync(request);
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(
            "https://mcp.internal.consultwithcloud.com/mcp",
            document.RootElement.GetProperty("resource").GetString());
    }

    [Fact]
    public async Task ValidTokenWithoutServerEntitlementIsForbidden()
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            factory.CreateToken([new Claim("roles", "ServiceInfo.Read")]));

        using var response = await client.PostAsync("/mcp", McpPostBody());

        Assert.Equal(HttpStatusCode.Forbidden, response.StatusCode);
    }

    [Theory]
    [InlineData("scp", "Orders.Invoke")]
    [InlineData("scp", "Catalog.Invoke")]
    [InlineData("roles", "Orders.Invoke.All")]
    [InlineData("roles", "Catalog.Invoke.All")]
    public async Task EveryExistingServerEntitlementAllowsToolListing(
        string claimType,
        string claimValue)
    {
        await using var factory = new TestMcpHostFactory();
        using var httpClient = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            factory.CreateToken([new Claim(claimType, claimValue)]));
        var transportOptions = new HttpClientTransportOptions
        {
            Endpoint = new Uri(PrivateHost, "/mcp"),
            Name = $"Issue 146 {claimValue} server-entry client",
            TransportMode = HttpTransportMode.StreamableHttp,
        };
        await using var mcpClient = await McpClient.CreateAsync(
            new HttpClientTransport(transportOptions, httpClient));

        var tools = await mcpClient.ListToolsAsync();

        Assert.Equal(
            ["get_access_guidance", "get_order_status", "get_service_info"],
            tools.Select(tool => tool.Name).Order(StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public async Task ProtectedResourceMetadataUsesPrivateResourceAndScopeUnion()
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });

        using var response = await client.GetAsync(
            "/.well-known/oauth-protected-resource/mcp");
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        response.EnsureSuccessStatusCode();
        Assert.Equal(
            "https://mcp.internal.consultwithcloud.com/mcp",
            document.RootElement.GetProperty("resource").GetString());
        Assert.Equal(
            [
                "api://mcp-server-app-id/Orders.Invoke",
                "api://mcp-server-app-id/Catalog.Invoke",
            ],
            document.RootElement.GetProperty("scopes_supported")
                .EnumerateArray()
                .Select(scope => scope.GetString()
                    ?? throw new InvalidOperationException("A scope value was null."))
                .ToArray());
        Assert.Equal(
            [TestMcpHostFactory.AuthorizationServer],
            document.RootElement.GetProperty("authorization_servers")
                .EnumerateArray()
                .Select(server => server.GetString()
                    ?? throw new InvalidOperationException(
                        "An authorization server value was null."))
                .ToArray());
    }

    [Theory]
    [InlineData(InvalidTokenKind.Signature)]
    [InlineData(InvalidTokenKind.Audience)]
    [InlineData(InvalidTokenKind.Expired)]
    public async Task InvalidTokenIsRejectedBeforeMcpDispatch(InvalidTokenKind kind)
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        using var untrustedRsa = RSA.Create(2048);
        var now = DateTime.UtcNow;
        var token = kind switch
        {
            InvalidTokenKind.Signature => factory.CreateToken(
                ServerEntitlementClaims(),
                signingKey: new RsaSecurityKey(untrustedRsa)),
            InvalidTokenKind.Audience => factory.CreateToken(
                ServerEntitlementClaims(),
                audience: "api://wrong-audience"),
            InvalidTokenKind.Expired => factory.CreateToken(
                ServerEntitlementClaims(),
                notBefore: now.AddMinutes(-20),
                expires: now.AddMinutes(-10)),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        client.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", token);

        using var response = await client.PostAsync("/mcp", McpPostBody());

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var challenge = Assert.Single(response.Headers.WwwAuthenticate);
        Assert.Equal("Bearer", challenge.Scheme);
    }

    [Theory]
    [InlineData("GET")]
    [InlineData("DELETE")]
    public async Task StatelessMcpEndpointDoesNotRegisterSessionMethods(string method)
    {
        await using var factory = new TestMcpHostFactory();
        using var client = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        using var request = new HttpRequestMessage(new HttpMethod(method), "/mcp");

        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.MethodNotAllowed, response.StatusCode);
    }

    [Fact]
    public async Task AuthorizedCallerListsAndCallsGetServiceInfo()
    {
        await using var factory = new TestMcpHostFactory();
        using var httpClient = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            factory.CreateToken(
            [
                new Claim("roles", "Orders.Invoke.All"),
                new Claim("roles", "ServiceInfo.Read"),
            ]));
        var transportOptions = new HttpClientTransportOptions
        {
            Endpoint = new Uri(PrivateHost, "/mcp"),
            Name = "Issue 146 in-process client",
            TransportMode = HttpTransportMode.StreamableHttp,
        };
        await using var mcpClient = await McpClient.CreateAsync(
            new HttpClientTransport(transportOptions, httpClient));

        var tools = await mcpClient.ListToolsAsync();
        Assert.Contains(tools, tool => tool.Name == "get_service_info");

        var result = await mcpClient.CallToolAsync("get_service_info");

        Assert.NotEqual(true, result.IsError);
        var content = Assert.IsType<TextContentBlock>(Assert.Single(result.Content));
        using var payload = JsonDocument.Parse(content.Text);
        Assert.Equal("contoso-orders-mcp", payload.RootElement.GetProperty("serverName").GetString());
        Assert.Equal("streamable-http", payload.RootElement.GetProperty("transport").GetString());
        Assert.Contains("SYNTHETIC", payload.RootElement.GetProperty("dataDisclaimer").GetString());
    }

    [Fact]
    public async Task ServerEntitlementDoesNotBypassGetServiceInfoRole()
    {
        await using var factory = new TestMcpHostFactory();
        using var httpClient = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = PrivateHost,
        });
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            factory.CreateToken([new Claim("roles", "Orders.Invoke.All")]));
        var transportOptions = new HttpClientTransportOptions
        {
            Endpoint = new Uri(PrivateHost, "/mcp"),
            Name = "Issue 146 per-tool authorization client",
            TransportMode = HttpTransportMode.StreamableHttp,
        };
        await using var mcpClient = await McpClient.CreateAsync(
            new HttpClientTransport(transportOptions, httpClient));

        var result = await mcpClient.CallToolAsync("get_service_info");

        Assert.True(result.IsError);
        var content = Assert.IsType<TextContentBlock>(Assert.Single(result.Content));
        Assert.Equal(
            "403 Forbidden: get_service_info requires the application role "
                + "'ServiceInfo.Read'.",
            content.Text);
    }

    private static Claim[] ServerEntitlementClaims() =>
        [new Claim("roles", "Orders.Invoke.All")];

    private static StringContent McpPostBody() =>
        new("{}", Encoding.UTF8, "application/json");

    public enum InvalidTokenKind
    {
        Signature,
        Audience,
        Expired,
    }
}
