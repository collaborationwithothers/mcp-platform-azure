using McpTools.AspNetCore;
using McpTools.Core;
using McpTools.Downstream;
using McpTools.Identity;
using Microsoft.AspNetCore.Authentication.JwtBearer;
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
var scopePrefix = audience.TrimEnd('/');

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

app.UseAuthentication();
app.UseAuthorization();
app.MapMcp("/mcp")
    .RequireAuthorization(McpHostContract.ServerEntryPolicy);

app.Run();

static string RequiredConfiguration(IConfiguration configuration, string key) =>
    configuration[key]
    ?? throw new InvalidOperationException($"Required configuration '{key}' is missing.");

public partial class Program;
