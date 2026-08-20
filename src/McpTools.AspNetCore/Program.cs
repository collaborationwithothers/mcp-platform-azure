using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using McpTools.AspNetCore;
using McpTools.Core;
using McpTools.Downstream;
using McpTools.Identity;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.IdentityModel.Tokens;
using ModelContextProtocol.AspNetCore;
using ModelContextProtocol.AspNetCore.Authentication;
using ModelContextProtocol.Authentication;

var builder = WebApplication.CreateBuilder(args);
var authority = RequiredConfiguration(builder.Configuration, "Authentication:Authority");
var audience = RequiredConfiguration(builder.Configuration, "Authentication:Audience");
var serverAppClientId = RequiredConfiguration(
    builder.Configuration,
    "MicrosoftEntra:ServerAppClientId");
var serverTenantId = RequiredConfiguration(
    builder.Configuration,
    "MicrosoftEntra:TenantId");
var accessTokenMetadataAddress =
    $"https://login.microsoftonline.com/{serverTenantId}/"
    + ".well-known/openid-configuration";
var accessTokenIssuer = $"https://sts.windows.net/{serverTenantId}/";
var downstreamBaseUrl = RequiredConfiguration(
    builder.Configuration,
    "DownstreamOrdersApi:BaseUrl");
var downstreamScope = RequiredConfiguration(
    builder.Configuration,
    "DownstreamOrdersApi:Scope");
var downstreamApplicationScope = RequiredConfiguration(
    builder.Configuration,
    "DownstreamOrdersApi:ApplicationScope");
var requireHttpsMetadata = builder.Configuration.GetValue(
    "Authentication:RequireHttpsMetadata",
    true);
if (!requireHttpsMetadata && !builder.Environment.IsDevelopment())
{
    throw new InvalidOperationException(
        "Authentication:RequireHttpsMetadata may be false only in Development.");
}
var trustAnyForwarder = builder.Configuration.GetValue(
    "ReverseProxy:TrustAnyForwarder",
    false);
if (trustAnyForwarder && !builder.Environment.IsDevelopment())
{
    throw new InvalidOperationException(
        "ReverseProxy:TrustAnyForwarder may be true only in Development.");
}
var scopePrefix = audience.TrimEnd('/');

builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedProto;
    if (trustAnyForwarder)
    {
        options.KnownIPNetworks.Clear();
        options.KnownProxies.Clear();
    }
});

builder.Services
    .AddAuthentication(options =>
    {
        options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
        options.DefaultChallengeScheme = McpAuthenticationDefaults.AuthenticationScheme;
    })
    .AddJwtBearer(options =>
    {
        options.MetadataAddress = accessTokenMetadataAddress;
        options.Audience = audience;
        options.RequireHttpsMetadata = requireHttpsMetadata;
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateAudience = true,
            ValidateIssuer = true,
            ValidateIssuerSigningKey = true,
            ValidateLifetime = true,
            ValidAudience = audience,
            ValidIssuer = accessTokenIssuer,
            RoleClaimType = "roles",
        };
    })
    .AddMcp(options =>
    {
        options.ResourceMetadataUri = new Uri(McpHostContract.ResourceMetadataUri);
        options.ResourceMetadata = new ProtectedResourceMetadata
        {
            Resource = McpHostContract.Resource,
            AuthorizationServers = { authority },
            ScopesSupported =
            [
                $"{scopePrefix}/{McpHostContract.DelegatedServerScopes[0]}",
                $"{scopePrefix}/{McpHostContract.DelegatedServerScopes[1]}",
            ],
        };
    });

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy(McpHostContract.ServerEntryPolicy, policy =>
    {
        policy.RequireAuthenticatedUser();
        policy.RequireAssertion(context =>
            ServerEntitlementAuthorization.HasExistingServerEntitlement(
                CallerIdentityResolver.Resolve(context.User)));
    });
});

builder.Services.AddHttpContextAccessor();
builder.Services.AddHttpClient();
builder.Services.AddHealthChecks();
if (!builder.Environment.IsDevelopment())
{
    var telemetryCredential = new DefaultAzureCredential();
    var connectionString = RequiredConfiguration(
        builder.Configuration,
        "APPLICATIONINSIGHTS_CONNECTION_STRING");

    builder.Services.AddOpenTelemetry().UseAzureMonitor(options =>
    {
        options.ConnectionString = connectionString;
        options.Credential = telemetryCredential;
    });
}
builder.Services.AddSingleton(
    new KubernetesTokenAcquirer(serverAppClientId, serverTenantId));
builder.Services.AddSingleton<IOboTokenAcquirer>(services =>
    services.GetRequiredService<KubernetesTokenAcquirer>());
builder.Services.AddSingleton<IAppTokenAcquirer>(services =>
    services.GetRequiredService<KubernetesTokenAcquirer>());
builder.Services.AddSingleton<IDownstreamOrdersClient>(services =>
    new DownstreamOrdersClient(
        services.GetRequiredService<IOboTokenAcquirer>(),
        services.GetRequiredService<IAppTokenAcquirer>(),
        services.GetRequiredService<IHttpClientFactory>().CreateClient(),
        new Uri(downstreamBaseUrl),
        downstreamScope,
        downstreamApplicationScope));
builder.Services.AddSingleton<McpToolApplication>();
builder.Services.AddMcpServer()
    .WithHttpTransport(options =>
    {
        options.SessionMode = HttpServerSessionMode.Stateless;
    })
    .WithTools<OrderStatusTool>()
    .WithTools<ServiceInfoTool>()
    .WithTools<AccessGuidanceTool>();

var app = builder.Build();

app.UseForwardedHeaders();
app.Use(async (context, next) =>
{
    await next(context);

    var isProtectedResourceMetadataRequest = context.Request.Path
        == "/.well-known/oauth-protected-resource/mcp";
    if (context.Request.Path.StartsWithSegments("/mcp")
        || isProtectedResourceMetadataRequest)
    {
        var requestVerificationId = context.Request.Headers[
            "X-Private-Mcp-Verification"].ToString();
        var verificationId = isProtectedResourceMetadataRequest
            && requestVerificationId.Length == 32
            && requestVerificationId.All(static character =>
                character is >= '0' and <= '9' or >= 'a' and <= 'f')
            ? requestVerificationId
            : "none";
        app.Logger.LogInformation(
            "Private MCP request context {Route} {Scheme} {RemoteIpAddress} {VerificationId}",
            isProtectedResourceMetadataRequest
                ? "/.well-known/oauth-protected-resource/mcp"
                : "/mcp",
            context.Request.Scheme,
            context.Connection.RemoteIpAddress?.ToString(),
            verificationId);
    }
});
app.UseAuthentication();
app.UseAuthorization();
app.MapHealthChecks("/healthz");
app.MapMcp("/mcp")
    .RequireAuthorization(McpHostContract.ServerEntryPolicy);

app.Run();

static string RequiredConfiguration(IConfiguration configuration, string key) =>
    configuration[key]
    ?? throw new InvalidOperationException($"Required configuration '{key}' is missing.");

public partial class Program;
