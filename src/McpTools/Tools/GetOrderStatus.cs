using System.Text.Json.Serialization;
using McpTools.Fixtures;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;

namespace McpTools.Tools;

/// <summary>
/// The single synthetic tool exposed by the tracer: get_order_status.
///
/// The tool contract is frozen at v1; only the implementation may change
/// later. <see cref="Resolve"/> still serves from <see cref="SyntheticOrders"/>
/// and calls nothing downstream, NOT because OBO thickening (issue 10) is
/// undone, but because it hit a verified platform gap: the Azure Functions
/// MCP extension's McpToolTrigger binding (<see cref="ToolInvocationContext"/>)
/// has no Microsoft-Learn-documented path to the caller's inbound bearer
/// token, and MSAL's on-behalf-of exchange needs that token as its user
/// assertion. azure-docs-verifier confirmed this three ways on 2026-07-18
/// (McpToolTrigger exposes no headers; a function cannot bind both
/// McpToolTrigger and HttpTrigger; the ASP.NET Core integration hosting
/// model does not expose its middleware pipeline to non-HttpTrigger
/// bindings) -- see docs/decisions/ADR-006, "OBO exchange: the inbound-token
/// gap", and COMPATIBILITY.md. The OBO exchange itself is fully implemented
/// and unit-tested (<see cref="McpTools.Downstream.DownstreamOrdersClient"/>),
/// ready to wire in here once the gap is resolved (e.g. a redesigned tool
/// hosting model). Per CLAUDE.md ("if the ticket cannot be verified or
/// completed as written, say so ... instead of improvising"), this is
/// recorded rather than papered over with an unverifiable workaround.
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
