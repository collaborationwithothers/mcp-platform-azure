using System.Net;
using System.IdentityModel.Tokens.Jwt;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using DownstreamOrdersApi.Endpoints;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace DownstreamOrdersApi.Tests;

/// <summary>
/// In-process tests for the synthetic Orders API. Unit tests call Resolve
/// with an order ID and assert its status code and typed response. HTTP tests
/// use a test host with a deterministic signing key.
/// </summary>
public sealed class OrderStatusEndpointTests : IClassFixture<TestOrdersApiFactory>
{
    private readonly TestOrdersApiFactory _factory;
    private readonly HttpClient _client;

    public OrderStatusEndpointTests(TestOrdersApiFactory factory)
    {
        _factory = factory;
        _client = factory.CreateClient();
    }

    public static readonly TheoryData<string, string, string> KnownOrders = new()
    {
        { "CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z" },
        { "CONTOSO-1002", "Shipped", "2026-06-03T09:30:00Z" },
        { "CONTOSO-1003", "Processing", "2026-06-05T17:45:00Z" },
        { "CONTOSO-1004", "Cancelled", "2026-06-02T11:15:00Z" },
        { "CONTOSO-1005", "BackOrdered", "2026-06-04T08:20:00Z" },
    };

    [Theory]
    [MemberData(nameof(KnownOrders))]
    public void Resolve_KnownId_Returns200WithTypedBody(
        string orderId, string expectedStatus, string expectedUpdatedUtc)
    {
        var (statusCode, body) = OrderStatusEndpoint.Resolve(orderId);

        Assert.Equal(HttpStatusCode.OK, statusCode);
        var response = Assert.IsType<OrderStatusResponse>(body);
        Assert.Equal(orderId, response.OrderId);
        Assert.Equal(expectedStatus, response.Status);
        Assert.Equal(expectedUpdatedUtc, response.UpdatedUtc);
    }

    [Theory]
    [InlineData("CONTOSO-9999")]
    [InlineData("UNKNOWN")]
    [InlineData("contoso-1001")] // case-sensitive: not the canonical id
    public void Resolve_UnknownId_Returns404WithTypedBody(string orderId)
    {
        var (statusCode, body) = OrderStatusEndpoint.Resolve(orderId);

        Assert.Equal(HttpStatusCode.NotFound, statusCode);
        var response = Assert.IsType<OrderNotFoundResponse>(body);
        Assert.Equal(orderId, response.OrderId);
        Assert.False(string.IsNullOrWhiteSpace(response.Message));
    }

    [Fact]
    public void Fixture_ContainsExactlyTheFiveContosoIds()
    {
        Assert.Equal(5, Fixtures.SyntheticOrders.All.Count);
        for (int n = 1001; n <= 1005; n++)
        {
            Assert.True(Fixtures.SyntheticOrders.All.ContainsKey($"CONTOSO-{n}"));
        }
    }

    [Fact]
    public async Task GetOrder_WithoutBearerToken_Returns401()
    {
        var response = await _client.GetAsync("/api/orders/CONTOSO-1001");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task GetOrder_WithMcpAudienceToken_Returns401()
    {
        var response = await GetOrderAsync(
            "CONTOSO-1001",
            _factory.CreateToken(TestOrdersApiFactory.McpServerAudience));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task GetOrder_WithUnknownSigningKey_Returns401()
    {
        using var unknownRsa = RSA.Create(2048);
        var response = await GetOrderAsync(
            "CONTOSO-1001",
            _factory.CreateToken(
                TestOrdersApiFactory.OrdersAudience,
                new RsaSecurityKey(unknownRsa)));

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task GetKnownOrder_WithOrdersAudienceToken_Preserves200JsonContract()
    {
        var response = await GetOrderAsync(
            "CONTOSO-1001",
            _factory.CreateToken(TestOrdersApiFactory.OrdersAudience));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<OrderStatusResponse>();
        Assert.NotNull(body);
        Assert.Equal("CONTOSO-1001", body.OrderId);
        Assert.Equal("Delivered", body.Status);
        Assert.Equal("2026-06-01T14:05:00Z", body.UpdatedUtc);
    }

    [Fact]
    public async Task GetUnknownOrder_WithOrdersAudienceToken_Preserves404JsonContract()
    {
        var response = await GetOrderAsync(
            "CONTOSO-9999",
            _factory.CreateToken(TestOrdersApiFactory.OrdersAudience));

        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<OrderNotFoundResponse>();
        Assert.NotNull(body);
        Assert.Equal("CONTOSO-9999", body.OrderId);
        Assert.False(string.IsNullOrWhiteSpace(body.Message));
    }

    [Fact]
    public void OrdersAndMcpServerAudiences_AreDistinct()
    {
        Assert.NotEqual(
            TestOrdersApiFactory.McpServerAudience,
            TestOrdersApiFactory.OrdersAudience);
    }

    [Fact]
    public void ProductionHost_WithoutLiveTelemetryConnectionString_FailsFast()
    {
        using var productionFactory = _factory.WithWebHostBuilder(builder =>
            builder.UseSetting(WebHostDefaults.EnvironmentKey, "Production"));

        var exception = Assert.Throws<InvalidOperationException>(
            () => productionFactory.CreateClient());

        Assert.Contains("APPLICATIONINSIGHTS_CONNECTION_STRING", exception.Message);
    }

    private async Task<HttpResponseMessage> GetOrderAsync(string orderId, string token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"/api/orders/{orderId}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return await _client.SendAsync(request);
    }
}

public sealed class TestOrdersApiFactory : WebApplicationFactory<Program>
{
    internal const string OrdersAudience = "api://orders-api-app-id";
    internal const string McpServerAudience = "api://mcp-server-app-id";
    private const string Authority = "https://login.example.test/orders-tenant/v2.0";
    private const string Issuer = "https://issuer.example.test/orders-tenant/v2.0";

    private readonly RSA _rsa = RSA.Create(2048);
    private readonly RsaSecurityKey _signingKey;

    public TestOrdersApiFactory()
    {
        _signingKey = new RsaSecurityKey(_rsa) { KeyId = "orders-test-signing-key" };
    }

    internal string CreateToken(string audience, SecurityKey? signingKey = null)
    {
        var now = DateTime.UtcNow;
        var token = new JwtSecurityToken(
            issuer: Issuer,
            audience: audience,
            claims: [new Claim("sub", "test-caller")],
            notBefore: now.AddMinutes(-1),
            expires: now.AddMinutes(5),
            signingCredentials: new SigningCredentials(
                signingKey ?? _signingKey,
                SecurityAlgorithms.RsaSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting(WebHostDefaults.EnvironmentKey, "Development");
        builder.UseSetting("Authentication:Authority", Authority);
        builder.UseSetting("Authentication:Audience", OrdersAudience);
        builder.UseSetting("DevelopmentAuthentication:ValidIssuer", Issuer);
        builder.ConfigureTestServices(services =>
        {
            services.PostConfigure<JwtBearerOptions>(
                JwtBearerDefaults.AuthenticationScheme,
                options =>
                {
                    var configuration = new OpenIdConnectConfiguration { Issuer = Issuer };
                    configuration.SigningKeys.Add(_signingKey);
                    options.ConfigurationManager =
                        new StaticConfigurationManager<OpenIdConnectConfiguration>(configuration);
                });
        });
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing)
        {
            _rsa.Dispose();
        }
    }
}
