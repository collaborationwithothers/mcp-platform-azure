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
builder.Services.AddSingleton<IDownstreamOrdersClient, TracerOnlyDownstreamOrdersClient>();
builder.Services.AddSingleton<McpToolApplication>();
builder.Services.AddMcpServer()
    .WithHttpTransport(options =>
    {
        options.SessionMode = HttpServerSessionMode.Stateless;
    })
    .WithTools<ServiceInfoTool>();

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
