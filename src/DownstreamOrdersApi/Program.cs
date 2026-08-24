using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using DownstreamOrdersApi;
using DownstreamOrdersApi.Endpoints;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);
var authority = RequiredConfiguration(builder.Configuration, "Authentication:Authority");
var audience = RequiredConfiguration(builder.Configuration, "Authentication:Audience");
var metadataAddress = builder.Environment.IsDevelopment()
    ? builder.Configuration["DevelopmentAuthentication:MetadataAddress"]
        ?? $"{authority.TrimEnd('/')}/.well-known/openid-configuration"
    : $"{authority.TrimEnd('/')}/.well-known/openid-configuration";
var issuer = builder.Environment.IsDevelopment()
    ? builder.Configuration["DevelopmentAuthentication:ValidIssuer"] ?? authority
    : authority;
var requireHttpsMetadata = builder.Configuration.GetValue(
    "Authentication:RequireHttpsMetadata",
    true);
if (!requireHttpsMetadata && !builder.Environment.IsDevelopment())
{
    throw new InvalidOperationException(
        "Authentication:RequireHttpsMetadata may be false only in Development.");
}

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.MetadataAddress = metadataAddress;
        options.Audience = audience;
        options.RequireHttpsMetadata = requireHttpsMetadata;
        options.MapInboundClaims = false;
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateAudience = true,
            ValidateIssuer = true,
            ValidateIssuerSigningKey = true,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.Zero,
            ValidAudience = audience,
            ValidIssuer = issuer,
        };
    });
builder.Services.AddAuthorization();

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

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();
app.MapGet("/api/orders/{orderId}", OrderStatusEndpoint.Handle)
    .RequireAuthorization();

app.Run();

static string RequiredConfiguration(IConfiguration configuration, string key) =>
    configuration[key]
    ?? throw new InvalidOperationException($"Required configuration '{key}' is missing.");

public partial class Program;
