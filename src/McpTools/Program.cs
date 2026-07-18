using McpTools.Downstream;
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
            var serverAppClientId = configuration["MicrosoftEntra:ServerAppClientId"]
                ?? throw new InvalidOperationException("MicrosoftEntra__ServerAppClientId app setting is required.");
            var tenantId = configuration["MicrosoftEntra:TenantId"]
                ?? throw new InvalidOperationException("MicrosoftEntra__TenantId app setting is required.");
            return new ManagedIdentityOboTokenAcquirer(serverAppClientId, tenantId);
        });

        services.AddSingleton<IDownstreamOrdersClient>(sp =>
        {
            var configuration = context.Configuration;
            var baseUrl = configuration["DownstreamOrdersApi:BaseUrl"]
                ?? throw new InvalidOperationException("DownstreamOrdersApi__BaseUrl app setting is required.");
            var scope = configuration["DownstreamOrdersApi:Scope"]
                ?? throw new InvalidOperationException("DownstreamOrdersApi__Scope app setting is required.");
            var tokenAcquirer = sp.GetRequiredService<IOboTokenAcquirer>();
            var httpClient = sp.GetRequiredService<IHttpClientFactory>().CreateClient();
            return new DownstreamOrdersClient(tokenAcquirer, httpClient, new Uri(baseUrl), scope);
        });
    })
    .Build();

host.Run();
