using McpTools.Identity;

namespace McpTools.Downstream;

/// <summary>
/// Fetches order status from the synthetic downstream Orders API through
/// either delegated OBO or the server's trusted-subsystem application identity.
/// Abstracted so <see cref="McpTools.Tools.GetOrderStatus"/> is unit-testable
/// with a fake implementation (see tests/McpTools.Tests/GetOrderStatusTests.cs);
/// <see cref="DownstreamOrdersClient"/> is the real implementation.
/// </summary>
public interface IDownstreamOrdersClient
{
    /// <summary>
    /// Returns the same typed shapes get_order_status has always returned
    /// (contract unchanged): an <c>OrderStatus</c> for a known id, an
    /// <c>OrderNotFound</c> for any other id.
    /// </summary>
    Task<object> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        // Nullable: correlation is audit-only on the delegated path, so a caller
        // without azp/oid still gets served (headers omitted). See GetOrderStatus.
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken);

    Task<object> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken);
}

public enum DownstreamAccessMode
{
    OnBehalfOf,
    Application,
}
