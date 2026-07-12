using System.Text.Json.Serialization;
using McpTools.Fixtures;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;

namespace McpTools.Tools;

/// <summary>
/// The single synthetic tool exposed by the tracer: get_order_status.
///
/// The tool contract is frozen at v1; only the implementation may change later
/// (the OBO issue reimplements <see cref="Resolve"/> to fetch on behalf of the
/// user, without changing the shapes below). In the tracer the tool is
/// self-contained: it serves from <see cref="SyntheticOrders"/> and calls
/// nothing downstream.
/// </summary>
public sealed class GetOrderStatus
{
    internal const string ToolName = "get_order_status";

    // Acceptance: the description string must state the data is synthetic.
    internal const string ToolDescription =
        "Returns the status of a Contoso order by id. The order data is SYNTHETIC "
        + "demo data (ids CONTOSO-1001 to CONTOSO-1005) and is not sourced from any "
        + "real system.";

    /// <summary>
    /// MCP tool trigger entry point. This is the only Azure-Functions-aware code
    /// path; it delegates immediately to the host-independent <see cref="Resolve"/>
    /// so the tool logic can be unit-tested in process with no Functions host.
    /// </summary>
    [Function(nameof(GetOrderStatus))]
    public object Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context,
        [McpToolProperty("orderId", "The order id to look up, for example CONTOSO-1001.", isRequired: true)]
            string orderId)
        => Resolve(orderId);

    /// <summary>
    /// Pure tool logic. Returns the typed success shape for a known id and the
    /// typed not-found shape (found:false) for any other id. The not-found case
    /// is a typed result, never a thrown or unhandled error.
    /// </summary>
    public static object Resolve(string orderId)
    {
        if (SyntheticOrders.All.TryGetValue(orderId, out var order))
        {
            return new OrderStatus(orderId, order.Status, order.UpdatedUtc);
        }

        return new OrderNotFound(
            orderId,
            Found: false,
            Message: $"No order was found for id '{orderId}'. Order data is synthetic "
                + "(known ids are CONTOSO-1001 to CONTOSO-1005).");
    }
}

/// <summary>Typed success result: a known order id.</summary>
public sealed record OrderStatus(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("updatedUtc")] string UpdatedUtc);

/// <summary>Typed not-found result: any id not in the fixture. Found is always false.</summary>
public sealed record OrderNotFound(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("found")] bool Found,
    [property: JsonPropertyName("message")] string Message);
