using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Azure.ResourceManager;
using Azure.ResourceManager.ApplicationInsights;
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
        options.Authority = authority;
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
    var componentResourceId = RequiredConfiguration(
        builder.Configuration,
        "AzureMonitor:ApplicationInsightsComponentResourceId");
    var component = await new ArmClient(telemetryCredential)
        .GetApplicationInsightsComponentResource(new ResourceIdentifier(componentResourceId))
        .GetAsync();
    var connectionString = component.Value.Data.ConnectionString
        ?? throw new InvalidOperationException(
            "Application Insights returned no connection string.");

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

    if (context.Request.Path.StartsWithSegments("/mcp")
        || context.Request.Path.StartsWithSegments(
            "/.well-known/oauth-protected-resource/mcp"))
    {
        app.Logger.LogInformation(
            "Private MCP request context {Scheme} {RemoteIpAddress}",
            context.Request.Scheme,
            context.Connection.RemoteIpAddress?.ToString());
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
