using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text.Json;
using McpTools.Downstream;
using Microsoft.AspNetCore.Mvc.Testing;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;
using Xunit;

namespace McpTools.AspNetCore.Tests;

public sealed class ToolSurfaceTests
{
    private const string ScopeClaimUri =
        "http://schemas.microsoft.com/identity/claims/scope";
    private const string RoleClaimUri =
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/role";
    private const string TenantClaimUri =
        "http://schemas.microsoft.com/identity/claims/tenantid";

    [Theory]
    [InlineData("get_order_status", "Orders.Read")]
    [InlineData("get_service_info", "ServiceInfo.Read")]
    [InlineData("get_access_guidance", null)]
    public async Task ApplicationModeCanCallEveryAuthorizedTool(
        string toolName,
        string? toolRole)
    {
        var claims = new List<Claim>
        {
            new("roles", "Orders.Invoke.All"),
            new("azp", "application-client-id"),
            new("oid", "application-object-id"),
        };
        if (toolRole is not null)
        {
            claims.Add(new Claim("roles", toolRole));
        }

        var (result, downstream) = await CallToolAsync(claims, toolName);

        Assert.NotEqual(true, result.IsError);
        if (toolName == "get_order_status")
        {
            Assert.Equal(DownstreamAccessMode.Application, downstream.LastAccessMode);
            Assert.Null(downstream.LastInboundUserAssertion);
        }
    }

    [Theory]
    [InlineData("get_order_status")]
    [InlineData("get_service_info")]
    [InlineData("get_access_guidance")]
    public async Task DelegatedModeCanCallEveryAuthorizedTool(string toolName)
    {
        var scopes = toolName == "get_order_status"
            ? "Orders.Invoke Orders.Read.AsUser"
            : "Orders.Invoke";
        var claims = new List<Claim>
        {
            new("scp", scopes),
            new("tid", "guest-tenant-id"),
            new("azp", "interactive-client-id"),
            new("oid", "user-object-id"),
        };
        if (toolName == "get_service_info")
        {
            claims.Add(new Claim("roles", "ServiceInfo.Read"));
        }

        var (result, downstream) = await CallToolAsync(claims, toolName);

        Assert.NotEqual(true, result.IsError);
        if (toolName == "get_order_status")
        {
            Assert.Equal(DownstreamAccessMode.OnBehalfOf, downstream.LastAccessMode);
            Assert.False(string.IsNullOrWhiteSpace(downstream.LastInboundUserAssertion));
            Assert.Equal("guest-tenant-id", downstream.LastTenantId);
        }
    }

    [Theory]
    [InlineData("get_order_status", "Orders.Read")]
    [InlineData("get_service_info", "ServiceInfo.Read")]
    public async Task ApplicationModeDeniesMissingPerToolRole(
        string toolName,
        string requiredRole)
    {
        var claims = new[]
        {
            new Claim("roles", "Orders.Invoke.All"),
            new Claim("azp", "application-client-id"),
            new Claim("oid", "application-object-id"),
        };

        var (result, downstream) = await CallToolAsync(claims, toolName);

        Assert.True(result.IsError);
        Assert.Contains(requiredRole, Text(result), StringComparison.Ordinal);
        Assert.Null(downstream.LastAccessMode);
    }

    [Theory]
    [InlineData("get_order_status", "Orders.Read.AsUser")]
    [InlineData("get_service_info", "ServiceInfo.Read")]
    public async Task DelegatedModeDeniesMissingPerToolEntitlement(
        string toolName,
        string requiredEntitlement)
    {
        var claims = new[]
        {
            new Claim("scp", "Orders.Invoke"),
            new Claim("tid", "guest-tenant-id"),
            new Claim("azp", "interactive-client-id"),
            new Claim("oid", "user-object-id"),
        };

        var (result, downstream) = await CallToolAsync(claims, toolName);

        Assert.True(result.IsError);
        Assert.Contains(requiredEntitlement, Text(result), StringComparison.Ordinal);
        Assert.Null(downstream.LastAccessMode);
    }

    [Fact]
    public async Task OrderStatusReturnsFrozenKnownAndUnknownShapes()
    {
        var claims = new[]
        {
            new Claim("roles", "Orders.Invoke.All"),
            new Claim("roles", "Orders.Read"),
            new Claim("azp", "application-client-id"),
            new Claim("oid", "application-object-id"),
        };

        var (known, _) = await CallToolAsync(claims, "get_order_status", "CONTOSO-1001");
        var (unknown, _) = await CallToolAsync(claims, "get_order_status", "CONTOSO-9999");

        using var knownPayload = JsonDocument.Parse(Text(known));
        Assert.Equal("CONTOSO-1001", knownPayload.RootElement.GetProperty("orderId").GetString());
        Assert.Equal("Delivered", knownPayload.RootElement.GetProperty("status").GetString());
        Assert.Equal(
            "2026-06-01T14:05:00Z",
            knownPayload.RootElement.GetProperty("updatedUtc").GetString());

        using var unknownPayload = JsonDocument.Parse(Text(unknown));
        Assert.Equal("CONTOSO-9999", unknownPayload.RootElement.GetProperty("orderId").GetString());
        Assert.False(unknownPayload.RootElement.GetProperty("found").GetBoolean());
        Assert.Equal(
            "No order was found for id 'CONTOSO-9999'. Order data is synthetic "
                + "(known ids are CONTOSO-1001 to CONTOSO-1005).",
            unknownPayload.RootElement.GetProperty("message").GetString());
    }

    [Fact]
    public async Task AccessGuidanceReturnsTheSameTotalEntitlementContract()
    {
        var claims = new[]
        {
            new Claim("roles", "Orders.Invoke.All"),
            new Claim("azp", "application-client-id"),
            new Claim("oid", "application-object-id"),
        };

        var (result, _) = await CallToolAsync(claims, "get_access_guidance");

        using var payload = JsonDocument.Parse(Text(result));
        var entitlements = payload.RootElement.GetProperty("requiredEntitlements");
        Assert.Equal(6, entitlements.GetArrayLength());
        Assert.Equal(
            ["get_access_guidance", "get_order_status", "get_service_info"],
            entitlements.EnumerateArray()
                .Select(entry => entry.GetProperty("tool").GetString()
                    ?? throw new InvalidOperationException("An entitlement tool was null."))
                .Distinct(StringComparer.Ordinal)
                .Order(StringComparer.Ordinal)
                .ToArray());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RawAndMappedClaimsAuthorizeTheSameDelegatedTool(bool mapped)
    {
        var claims = new[]
        {
            new Claim(mapped ? ScopeClaimUri : "scp", "Orders.Invoke Orders.Read.AsUser"),
            new Claim(mapped ? TenantClaimUri : "tid", "guest-tenant-id"),
            new Claim("azp", "interactive-client-id"),
            new Claim("oid", "user-object-id"),
        };

        var (result, downstream) = await CallToolAsync(claims, "get_order_status");

        Assert.NotEqual(true, result.IsError);
        Assert.Equal("guest-tenant-id", downstream.LastTenantId);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RawAndMappedRoleClaimsAuthorizeTheSameApplicationTool(bool mapped)
    {
        var roleType = mapped ? RoleClaimUri : "roles";
        var claims = new[]
        {
            new Claim(roleType, "Orders.Invoke.All"),
            new Claim(roleType, "ServiceInfo.Read"),
            new Claim("azp", "application-client-id"),
            new Claim("oid", "application-object-id"),
        };

        var (result, _) = await CallToolAsync(claims, "get_service_info");

        Assert.NotEqual(true, result.IsError);
    }

    private static async Task<(CallToolResult Result, RecordingDownstreamOrdersClient Downstream)>
        CallToolAsync(
            IEnumerable<Claim> claims,
            string toolName,
            string orderId = "CONTOSO-1001")
    {
        await using var factory = new TestMcpHostFactory();
        using var httpClient = factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("https://mcp.internal.consultwithcloud.com"),
        });
        httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            factory.CreateToken(claims));
        var transportOptions = new HttpClientTransportOptions
        {
            Endpoint = new Uri("https://mcp.internal.consultwithcloud.com/mcp"),
            Name = $"Issue 147 {toolName} test client",
            TransportMode = HttpTransportMode.StreamableHttp,
        };
        await using var mcpClient = await McpClient.CreateAsync(
            new HttpClientTransport(transportOptions, httpClient));

        var arguments = toolName == "get_order_status"
            ? new Dictionary<string, object?> { ["orderId"] = orderId }
            : null;
        var result = arguments is null
            ? await mcpClient.CallToolAsync(toolName)
            : await mcpClient.CallToolAsync(toolName, arguments);

        return (result, factory.Downstream);
    }

    private static string Text(CallToolResult result) =>
        Assert.IsType<TextContentBlock>(Assert.Single(result.Content)).Text;
}
