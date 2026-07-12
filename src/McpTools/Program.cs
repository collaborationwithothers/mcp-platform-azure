using Microsoft.Extensions.Hosting;

// .NET isolated-worker host for the Functions MCP server (ADR-002). The MCP
// tool triggers are discovered by the worker SDK from the [McpToolTrigger]
// attributes; the attribute-based programming model needs no MCP-specific
// host-builder call beyond the standard isolated-worker defaults.
var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .Build();

host.Run();
