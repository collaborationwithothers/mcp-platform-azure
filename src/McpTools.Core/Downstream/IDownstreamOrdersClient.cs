using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Downstream;

/// <summary>
/// Fetches an order through either delegated OBO or the server application
/// identity. Token acquisition and transport remain host concerns.
/// </summary>
public interface IDownstreamOrdersClient
{
    Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        string tenantId,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken);

    Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken);
}

public enum DownstreamAccessMode
{
    OnBehalfOf,
    Application,
}
