using System.Diagnostics.CodeAnalysis;
using System.Text.Json.Serialization;
using McpTools.Downstream;
using McpTools.Fixtures;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Protocol;

namespace McpTools.Tools;

/// <summary>
/// The single synthetic tool exposed by the tracer: get_order_status.
///
/// The tool contract is frozen at v1 (see <see cref="OrderStatus"/> /
/// <see cref="OrderNotFound"/>); only the data source varies, and it varies by
/// caller identity mode (issue 10, OBO thickening):
///
/// <list type="bullet">
///   <item><b>Delegated</b> (the validated principal carries an <c>scp</c>
///   claim): a user-context caller, sourced from the synthetic downstream
///   Orders API (src/DownstreamOrdersApi) via the Entra On-Behalf-Of exchange
///   (<see cref="IDownstreamOrdersClient"/>). The caller's inbound token is the
///   OBO user assertion.</item>
///   <item><b>App-context</b> (the principal has an app id and no <c>scp</c>;
///   an authorized principal also carries <c>roles</c>): requires the
///   <c>Orders.Read</c> application role, then
///   calls the downstream as the MCP server's own application identity. The
///   original caller's azp/appid and oid are logged and propagated only as
///   audit correlation; the downstream authorizes the server identity.</item>
/// </list>
///
/// The mode decision itself lives in <see cref="IdentityModeResolver"/>, not
/// inline here, so it is unit-testable in isolation.
///
/// The inbound bearer token reaches this function via
/// <c>ToolInvocationContext.TryGetHttpTransport</c> -&gt;
/// <c>HttpTransport.Headers</c>. An earlier pass of this ticket concluded
/// (wrongly) that McpToolTrigger had no path to the inbound token; that was
/// corrected after review pointed at
/// <c>ToolInvocationContextExtensions.TryGetHttpTransport</c>, confirmed
/// present (via direct assembly reflection, then re-verified against Microsoft
/// Learn and the official Azure-Samples/remote-mcp-functions-dotnet sample) in
/// the pinned Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1. See
/// docs/decisions/ADR-006 for the full chronology and COMPATIBILITY.md for the
/// verification evidence. This mechanism is confirmed only for the Streamable
/// HTTP transport (/runtime/webhooks/mcp); the SSE transport
/// (/runtime/webhooks/mcp/sse, deprecated) is unconfirmed at runtime, so this
/// repo's tracer targets Streamable HTTP only (matches apim-mcp-server's
/// mcpProperties.transportType = streamable on the gateway side).
/// </summary>
public sealed class GetOrderStatus
{
    internal const string ToolName = "get_order_status";

    // Acceptance: the description string must state the data is synthetic.
    internal const string ToolDescription =
        "Returns the status of a Contoso order by id. The order data is SYNTHETIC "
        + "demo data (ids CONTOSO-1001 to CONTOSO-1005) and is not sourced from any "
        + "real system.";

    // The user assertion for the OBO exchange. The token-store header
    // (X-MS-TOKEN-AAD-ACCESS-TOKEN) is expected ABSENT in this topology: APIM
    // forwards a bearer and Easy Auth validates it without brokering a
    // sign-in, and no token store is enabled -- the token-store header is what
    // requires the token store (verified; COMPATIBILITY.md). So the raw
    // Authorization header is the OPERATIVE source here. The token-store header
    // is still checked first (harmless, and matches Microsoft's own OBO sample
    // Azure-Samples/remote-mcp-functions-dotnet, HelloToolWithAuth.cs) so the
    // code is correct if a future topology enables the token store.
    private static readonly string[] InboundTokenHeaderNames =
        ["X-MS-TOKEN-AAD-ACCESS-TOKEN", "Authorization"];

    private readonly IDownstreamOrdersClient _downstreamOrdersClient;
    private readonly ILogger<GetOrderStatus> _logger;

    public GetOrderStatus(
        IDownstreamOrdersClient downstreamOrdersClient,
        ILogger<GetOrderStatus> logger)
    {
        _downstreamOrdersClient = downstreamOrdersClient;
        _logger = logger;
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
        // installed 1.5.1 assembly).
        if (!context.TryGetHttpTransport(out var transport))
        {
            throw new InvalidOperationException(
                "get_order_status: no HTTP transport is available on this invocation. This repo's "
                + "tracer targets the Streamable HTTP transport only (see the doc comment on the "
                + "SSE-transport constraint); headers, and therefore the caller identity and inbound "
                + "token, are unavailable otherwise.");
        }

        var headers = transport!.Headers;

        // Per-request fail-closed check plus mode decision, in one place. The
        // rejection of a missing/malformed/unsupported principal IS the
        // "established error shape" (a thrown tool error, distinct from the
        // typed not-found RESULT, which is reserved for a genuinely unknown
        // order id). This is only a sound security boundary in production
        // because the startup BuiltInAuthGuard asserts Easy Auth is enabled,
        // and enabled Easy Auth strips client-supplied X-MS-* headers before
        // injecting its own (docs/security.md, "trust chain").
        var resolution = IdentityModeResolver.ResolveWithPrincipal(headers);
        return resolution.Mode switch
        {
            IdentityMode.Delegated => await ServeFromDownstreamViaObo(
                orderId, headers, resolution.Principal!, cancellationToken),
            IdentityMode.AppContext => await ServeFromDownstreamAsApplication(
                orderId, resolution.Principal!, cancellationToken),
            IdentityMode.MissingPrincipal => throw new InvalidOperationException(
                $"get_order_status: the {ClientPrincipal.HeaderName} header is missing. In production "
                + "this is a fail-closed rejection: Easy Auth injects that header on every request it "
                + "validates, and the startup auth guard guarantees Easy Auth is enabled, so a missing "
                + "header means the request did not traverse the authenticated path."),
            IdentityMode.MalformedPrincipal => throw new InvalidOperationException(
                $"get_order_status: the {ClientPrincipal.HeaderName} header was present but could not be "
                + "decoded as the Base64 JSON client principal Easy Auth emits."),
            _ => throw new InvalidOperationException(
                "get_order_status: the caller principal carried neither an scp (delegated) claim nor "
                + "an azp/appid application identity, so no data-source mode applies."),
        };
    }

    private async Task<object> ServeFromDownstreamViaObo(
        string orderId,
        IReadOnlyDictionary<string, string> headers,
        ClientPrincipal principal,
        CancellationToken cancellationToken)
    {
        if (!TryExtractInboundAccessToken(headers, out var inboundToken))
        {
            throw new InvalidOperationException(
                "get_order_status: a delegated (scp) principal was present but no inbound Entra access "
                + "token was found on the request (checked X-MS-TOKEN-AAD-ACCESS-TOKEN and Authorization). "
                + "The Authorization bearer is the operative OBO user assertion in this topology; its "
                + "absence indicates an unverified transport or a token-store misconfiguration.");
        }

        var caller = CallerIdentityCorrelation.FromPrincipal(principal);
        LogCaller(caller, IdentityMode.Delegated);
        return await _downstreamOrdersClient.GetOrderStatusOnBehalfOfAsync(
            orderId, inboundToken, caller, cancellationToken);
    }

    private async Task<object> ServeFromDownstreamAsApplication(
        string orderId,
        ClientPrincipal principal,
        CancellationToken cancellationToken)
    {
        if (!AppRoleAuthorization.HasOrdersRead(principal))
        {
            return new CallToolResult
            {
                IsError = true,
                Content =
                [
                    new TextContentBlock
                    {
                        Text = "403 Forbidden: get_order_status requires the application role "
                            + $"'{AppRoleAuthorization.RequiredRole}'.",
                    },
                ],
            };
        }

        var caller = CallerIdentityCorrelation.FromPrincipal(principal);
        LogCaller(caller, IdentityMode.AppContext);
        return await _downstreamOrdersClient.GetOrderStatusAsApplicationAsync(
            orderId, caller, cancellationToken);
    }

    private void LogCaller(CallerIdentityCorrelation caller, IdentityMode mode) =>
        _logger.LogInformation(
            "get_order_status authorized caller. CallerApplicationId={CallerApplicationId} "
            + "CallerObjectId={CallerObjectId} IdentityMode={IdentityMode}",
            caller.ApplicationId,
            caller.ObjectId,
            mode);

    /// <summary>
    /// Maps the fixed in-memory <see cref="SyntheticOrders"/> fixture onto
    /// get_order_status's frozen contract. This is a pure test seam, not a live
    /// request path. Pure and
    /// host-independent (spec: Testing Decisions, "unit seam"). Returns the
    /// typed success shape for a known id and the typed not-found shape
    /// (found:false) for any other id; the not-found case is a typed RESULT,
    /// never a thrown error.
    /// </summary>
    public static object ServeFromFixture(string orderId)
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
            // Case-insensitive, via the same helper the resolver uses: HTTP/2
            // lowercases header names and the transport dictionary's comparer
            // is not guaranteed case-insensitive.
            if (!HeaderLookup.TryGet(headers, headerName, out var value) || string.IsNullOrWhiteSpace(value))
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
