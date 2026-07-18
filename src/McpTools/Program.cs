using McpTools.Downstream;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

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

        services.AddSingleton<IOboTokenAcquirer>(_ =>
        {
            var configuration = context.Configuration;
            return new ManagedIdentityOboTokenAcquirer(
                RequireSetting(configuration, "MicrosoftEntra:ServerAppClientId", "MicrosoftEntra__ServerAppClientId"),
                RequireSetting(configuration, "MicrosoftEntra:TenantId", "MicrosoftEntra__TenantId"));
        });

        services.AddSingleton<IDownstreamOrdersClient>(sp =>
        {
            var configuration = context.Configuration;
            var baseUrl = RequireSetting(configuration, "DownstreamOrdersApi:BaseUrl", "DownstreamOrdersApi__BaseUrl");
            var scope = RequireSetting(configuration, "DownstreamOrdersApi:Scope", "DownstreamOrdersApi__Scope");
            var tokenAcquirer = sp.GetRequiredService<IOboTokenAcquirer>();
            var httpClient = sp.GetRequiredService<IHttpClientFactory>().CreateClient();
            return new DownstreamOrdersClient(tokenAcquirer, httpClient, new Uri(baseUrl), scope);
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
