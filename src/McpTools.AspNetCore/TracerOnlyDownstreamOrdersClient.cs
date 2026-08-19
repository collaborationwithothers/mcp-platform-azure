using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.AspNetCore;

internal sealed class TracerOnlyDownstreamOrdersClient : IDownstreamOrdersClient
{
    public Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException(
            "The ASP.NET Core tracer host exposes only get_service_info in issue 146.");

    public Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken) =>
        throw new NotSupportedException(
            "The ASP.NET Core tracer host exposes only get_service_info in issue 146.");
}
