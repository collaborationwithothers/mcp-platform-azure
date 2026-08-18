using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Tests;

/// <summary>Fails if a tool that should be fixed-data-only reaches downstream.</summary>
internal sealed class UnusedDownstreamOrdersClient : IDownstreamOrdersClient
{
    public Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken) =>
        throw new InvalidOperationException("This tool must not call the downstream Orders API.");

    public Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken) =>
        throw new InvalidOperationException("This tool must not call the downstream Orders API.");
}
