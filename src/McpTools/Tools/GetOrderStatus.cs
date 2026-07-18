using System.Diagnostics.CodeAnalysis;
using System.Text.Json.Serialization;
using McpTools.Downstream;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;

namespace McpTools.Tools;

/// <summary>
/// The single synthetic tool exposed by the tracer: get_order_status.
///
/// The tool contract is frozen at v1 (see <see cref="OrderStatus"/> /
/// <see cref="OrderNotFound"/>); only the implementation changed with issue
/// 10 (OBO thickening), from an in-memory fixture to a live call through
/// <see cref="IDownstreamOrdersClient"/> to the synthetic downstream Orders
/// API (src/DownstreamOrdersApi), authorized via the Entra On-Behalf-Of
/// exchange.
///
/// The caller's inbound bearer token reaches this function via
/// <c>ToolInvocationContext.TryGetHttpTransport</c> -&gt;
/// <c>HttpTransport.Headers</c>. An earlier pass of this ticket concluded
/// (wrongly) that McpToolTrigger had no path to the inbound token at all;
/// that was corrected after review pointed at
/// <c>ToolInvocationContextExtensions.TryGetHttpTransport</c>, confirmed
/// present (via direct assembly reflection, then re-verified against
/// Microsoft Learn and the official Azure-Samples/remote-mcp-functions-dotnet
/// sample) in the pinned Microsoft.Azure.Functions.Worker.Extensions.Mcp
/// 1.5.1. See docs/decisions/ADR-006, "OBO exchange: confused deputy,
/// audience validation, and the inbound-token gap," for the full chronology,
/// and COMPATIBILITY.md for the verification evidence. This mechanism is
/// confirmed only for the Streamable HTTP transport
/// (/runtime/webhooks/mcp); the SSE transport
/// (/runtime/webhooks/mcp/sse, deprecated) routes session state through a
/// storage-queue-backed backplane whose effect on header availability is
/// unconfirmed at runtime, so this repo's tracer targets Streamable HTTP
/// only (matches apim-mcp-server's mcpProperties.transportType = streamable
/// on the gateway side).
/// </summary>
public sealed class GetOrderStatus
{
    internal const string ToolName = "get_order_status";

    // Acceptance: the description string must state the data is synthetic.
    internal const string ToolDescription =
        "Returns the status of a Contoso order by id. The order data is SYNTHETIC "
        + "demo data (ids CONTOSO-1001 to CONTOSO-1005) and is not sourced from any "
        + "real system.";

    // Order: the token-store header wins when present (requires the
    // token store explicitly enabled, per COMPATIBILITY.md); the raw
    // Authorization header is the fallback MCP clients that send a Bearer
    // token directly rely on. Matches the header order and names in
    // Microsoft's own OBO sample (Azure-Samples/remote-mcp-functions-dotnet,
    // HelloToolWithAuth.cs, GetUserToken), which is sample-derived
    // behaviour, not a documented platform guarantee (COMPATIBILITY.md).
    private static readonly string[] InboundTokenHeaderNames =
        ["X-MS-TOKEN-AAD-ACCESS-TOKEN", "Authorization"];

    private readonly IDownstreamOrdersClient _downstreamOrdersClient;

    public GetOrderStatus(IDownstreamOrdersClient downstreamOrdersClient)
    {
        _downstreamOrdersClient = downstreamOrdersClient;
    }

    [Function(nameof(GetOrderStatus))]
    public async Task<object> Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context,
        [McpToolProperty("orderId", "The order id to look up, for example CONTOSO-1001.", isRequired: true)]
            string orderId,
        CancellationToken cancellationToken)
    {
        // TryGetHttpTransport's out parameter is not nullable-annotated in the
        // extension package, but the method's own contract guarantees it is
        // non-null when it returns true (confirmed by reflection against the
        // installed 1.5.1 assembly): the null-forgiving operator just silences
        // a warning the third-party signature can't express, not an unchecked
        // assumption of our own.
        if (!context.TryGetHttpTransport(out var transport)
            || !TryExtractInboundAccessToken(transport!.Headers, out var inboundToken))
        {
            throw new InvalidOperationException(
                "get_order_status: no inbound Entra access token was found on the request "
                + "(checked X-MS-TOKEN-AAD-ACCESS-TOKEN and Authorization). Easy Auth requires "
                + "authentication to reach this function, so this indicates either a transport "
                + "this repo has not verified header availability for (see GetOrderStatus's doc "
                + "comment on the Streamable HTTP constraint) or a token-store misconfiguration.");
        }

        return await _downstreamOrdersClient.GetOrderStatusAsync(orderId, inboundToken, cancellationToken);
    }

    /// <summary>
    /// Pure header-extraction logic, unit-tested with plain dictionaries and
    /// no Functions/MCP-extension dependency (spec: Testing Decisions, "unit
    /// seam"). Strips a leading "Bearer " scheme from the Authorization
    /// header (X-MS-TOKEN-AAD-ACCESS-TOKEN is already a bare token).
    /// </summary>
    public static bool TryExtractInboundAccessToken(
        IReadOnlyDictionary<string, string> headers, [NotNullWhen(true)] out string? token)
    {
        foreach (var headerName in InboundTokenHeaderNames)
        {
            if (!headers.TryGetValue(headerName, out var value) || string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            token = value.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
                ? value["Bearer ".Length..]
                : value;
            return true;
        }

        token = null;
        return false;
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
