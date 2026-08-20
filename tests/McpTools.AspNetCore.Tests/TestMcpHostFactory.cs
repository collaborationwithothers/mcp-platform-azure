using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace McpTools.AspNetCore.Tests;

internal sealed class TestMcpHostFactory : WebApplicationFactory<Program>
{
    internal const string Issuer = "https://issuer.example.test";
    internal const string Audience = "api://mcp-server-app-id";

    private readonly RSA _rsa = RSA.Create(2048);
    private readonly RsaSecurityKey _signingKey;

    internal RecordingDownstreamOrdersClient Downstream { get; } = new();

    internal TestMcpHostFactory()
    {
        _signingKey = new RsaSecurityKey(_rsa) { KeyId = "test-signing-key" };
    }

    internal string CreateToken(
        IEnumerable<Claim>? claims = null,
        string? audience = null,
        DateTime? notBefore = null,
        DateTime? expires = null,
        SecurityKey? signingKey = null)
    {
        var now = DateTime.UtcNow;
        var token = new JwtSecurityToken(
            issuer: Issuer,
            audience: audience ?? Audience,
            claims: claims,
            notBefore: notBefore ?? now.AddMinutes(-1),
            expires: expires ?? now.AddMinutes(5),
            signingCredentials: new SigningCredentials(
                signingKey ?? _signingKey,
                SecurityAlgorithms.RsaSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting(WebHostDefaults.EnvironmentKey, "Development");
        builder.UseSetting("Authentication:Authority", Issuer);
        builder.UseSetting("Authentication:Audience", Audience);
        builder.UseSetting("ReverseProxy:TrustAnyForwarder", "true");
        builder.UseSetting("MicrosoftEntra:ServerAppClientId", "mcp-server-app-id");
        builder.UseSetting("MicrosoftEntra:TenantId", "server-tenant-id");
        builder.UseSetting("DownstreamOrdersApi:BaseUrl", "https://orders.example.test");
        builder.UseSetting(
            "DownstreamOrdersApi:Scope",
            "api://orders-api/user_impersonation");
        builder.UseSetting(
            "DownstreamOrdersApi:ApplicationScope",
            "api://orders-api/.default");
        builder.ConfigureTestServices(services =>
        {
            services.PostConfigure<JwtBearerOptions>(
                JwtBearerDefaults.AuthenticationScheme,
                options =>
                {
                    var configuration = new OpenIdConnectConfiguration
                    {
                        Issuer = Issuer,
                    };
                    configuration.SigningKeys.Add(_signingKey);
                    options.ConfigurationManager =
                        new StaticConfigurationManager<OpenIdConnectConfiguration>(configuration);
                });
            services.RemoveAll<IDownstreamOrdersClient>();
            services.AddSingleton<IDownstreamOrdersClient>(Downstream);
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

internal sealed class RecordingDownstreamOrdersClient : IDownstreamOrdersClient
{
    internal DownstreamAccessMode? LastAccessMode { get; private set; }
    internal string? LastInboundUserAssertion { get; private set; }
    internal string? LastTenantId { get; private set; }

    public Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        string tenantId,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken)
    {
        LastAccessMode = DownstreamAccessMode.OnBehalfOf;
        LastInboundUserAssertion = inboundUserAssertion;
        LastTenantId = tenantId;
        return Task.FromResult(McpTools.Core.McpToolApplication.GetOrderStatusFromFixture(orderId));
    }

    public Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken)
    {
        LastAccessMode = DownstreamAccessMode.Application;
        LastInboundUserAssertion = null;
        LastTenantId = null;
        return Task.FromResult(McpTools.Core.McpToolApplication.GetOrderStatusFromFixture(orderId));
    }
}
