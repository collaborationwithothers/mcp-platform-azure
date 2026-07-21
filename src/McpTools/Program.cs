using McpTools.Downstream;
using McpTools.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

// Fail-closed startup check (issue 10): in a production-like environment,
// refuse to start unless built-in auth (Easy Auth) is enabled. get_order_status
// trusts the Easy-Auth-injected X-MS-CLIENT-PRINCIPAL header for its
// identity-mode and authorization decisions and does NOT re-validate the token
// signature itself, so the host must never serve tools with Easy Auth off (a
// caller could otherwise forge that header). Read the platform-injected env
// vars directly -- they are process environment variables, not app settings
// behind a config provider. A throw here crashes startup with a clear message
// on stderr before any tool is reachable (docs/security.md, "trust chain").
try
{
    BuiltInAuthGuard.EnsureBuiltInAuthEnabled(
        Environment.GetEnvironmentVariable("AZURE_FUNCTIONS_ENVIRONMENT"),
        Environment.GetEnvironmentVariable(BuiltInAuthGuard.WebsiteAuthEnabledVar),
        Environment.GetEnvironmentVariable(BuiltInAuthGuard.AuthV2ConfigJsonVar));
}
catch (InvalidOperationException ex)
{
    Console.Error.WriteLine(ex.Message);
    throw;
}

// .NET isolated-worker host for the Functions MCP server (ADR-002). The MCP
// tool triggers are discovered by the worker SDK from the [McpToolTrigger]
// attributes; the attribute-based programming model needs no MCP-specific
// host-builder call beyond the standard isolated-worker defaults.
//
// DI registrations below back GetOrderStatus's OBO exchange (issue 10):
// MicrosoftEntra__ServerAppClientId/TenantId and DownstreamOrdersApi__* are
// app settings wired by infra/terraform/scenarios/s1-entra-mcp-server/main.tf.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .ConfigureServices((context, services) =>
    {
        services.AddHttpClient();

        services.AddSingleton<ManagedIdentityOboTokenAcquirer>(_ =>
        {
            var configuration = context.Configuration;
            return new ManagedIdentityOboTokenAcquirer(
                RequireSetting(configuration, "MicrosoftEntra:ServerAppClientId", "MicrosoftEntra__ServerAppClientId"),
                RequireSetting(configuration, "MicrosoftEntra:TenantId", "MicrosoftEntra__TenantId"));
        });
        services.AddSingleton<IOboTokenAcquirer>(sp =>
            sp.GetRequiredService<ManagedIdentityOboTokenAcquirer>());
        services.AddSingleton<IAppTokenAcquirer>(sp =>
            sp.GetRequiredService<ManagedIdentityOboTokenAcquirer>());

        services.AddSingleton<IDownstreamOrdersClient>(sp =>
        {
            var configuration = context.Configuration;
            var baseUrl = RequireSetting(configuration, "DownstreamOrdersApi:BaseUrl", "DownstreamOrdersApi__BaseUrl");
            var scope = RequireSetting(configuration, "DownstreamOrdersApi:Scope", "DownstreamOrdersApi__Scope");
            var applicationScope = RequireSetting(
                configuration,
                "DownstreamOrdersApi:ApplicationScope",
                "DownstreamOrdersApi__ApplicationScope");
            var tokenAcquirer = sp.GetRequiredService<IOboTokenAcquirer>();
            var appTokenAcquirer = sp.GetRequiredService<IAppTokenAcquirer>();
            var httpClient = sp.GetRequiredService<IHttpClientFactory>().CreateClient();
            return new DownstreamOrdersClient(
                tokenAcquirer,
                appTokenAcquirer,
                httpClient,
                new Uri(baseUrl),
                scope,
                applicationScope);
        });
    })
    .Build();

host.Run();

// key is the IConfiguration lookup key (colon-separated); appSettingName is
// the same value's actual Function App setting name (double-underscore-
// separated) for the error message, since that is what the runbook/README
// document and what an operator would search for.
static string RequireSetting(IConfiguration configuration, string key, string appSettingName) =>
    configuration[key] ?? throw new InvalidOperationException($"{appSettingName} app setting is required.");
