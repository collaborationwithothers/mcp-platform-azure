namespace McpTools.Downstream;

/// <summary>
/// Fetches order status from the synthetic downstream Orders API via OBO.
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
    Task<object> GetOrderStatusAsync(
        string orderId, string inboundUserAssertion, CancellationToken cancellationToken);
}
