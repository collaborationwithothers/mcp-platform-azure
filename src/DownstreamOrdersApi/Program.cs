using Microsoft.Extensions.Hosting;

// .NET isolated-worker host for the synthetic downstream Orders API (issue
// 10: OBO thickening). A plain HTTP-triggered service; no MCP extension.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .Build();

host.Run();
