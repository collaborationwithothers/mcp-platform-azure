using System.Diagnostics.CodeAnalysis;
using McpTools.Core;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;

namespace McpTools.Tools;

/// <summary>
/// Azure Functions adapter for get_order_status. The shared application core
/// owns authorization, branch selection, and typed results. This adapter owns
/// the Functions trigger, HTTP headers, and built-in auth parsing.
/// </summary>
public sealed class GetOrderStatus
{
    internal const string ToolName = McpToolContracts.GetOrderStatusName;
    internal const string ToolDescription = McpToolContracts.GetOrderStatusDescription;

    // The user assertion for the OBO exchange. The token-store header
    // (X-MS-TOKEN-AAD-ACCESS-TOKEN) is expected ABSENT in this topology: APIM
    // forwards a bearer and built-in auth validates it without brokering a
    // sign-in, and no token store is enabled. The token-store header is what
    // requires the token store (verified; COMPATIBILITY.md). The raw
    // Authorization header is therefore the OPERATIVE source here. The
    // token-store header is still checked first. This matches Microsoft's OBO
    // sample Azure-Samples/remote-mcp-functions-dotnet, HelloToolWithAuth.cs,
    // and remains correct if a future topology enables the token store.
    private static readonly string[] InboundTokenHeaderNames =
        ["X-MS-TOKEN-AAD-ACCESS-TOKEN", "Authorization"];

    private readonly McpToolApplication _application;

    public GetOrderStatus(McpToolApplication application)
    {
        _application = application;
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
        // non-null when it returns true. This was confirmed by reflection
        // against the installed 1.5.1 assembly.
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
        // rejection of a missing, malformed, or unsupported principal is the
        // established thrown tool-error shape. It is distinct from the typed
        // not-found result, which is reserved for a genuinely unknown order id.
        // This is a sound production boundary only because BuiltInAuthGuard
        // asserts built-in auth is enabled and the platform strips client-
        // supplied X-MS-* headers before injecting its own. See
        // docs/security.md, "trust chain".
        var resolution = IdentityModeResolver.ResolveWithPrincipal(headers);
        var caller = resolution.Mode switch
        {
            IdentityMode.Delegated or IdentityMode.AppContext => resolution.Caller!,
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

        TryExtractInboundAccessToken(headers, out var inboundToken);
        ToolOutcome<OrderLookupResult> outcome;
        try
        {
            outcome = await _application.GetOrderStatusAsync(
                orderId, caller, inboundToken, cancellationToken);
        }
        catch (InboundAccessTokenRequiredException)
        {
            throw new InvalidOperationException(
                "get_order_status: a delegated (scp) principal was present but no inbound Entra access "
                + "token was found on the request (checked X-MS-TOKEN-AAD-ACCESS-TOKEN and Authorization). "
                + "The Authorization bearer is the operative OBO user assertion in this topology; its "
                + "absence indicates an unverified transport or a token-store misconfiguration.");
        }

        return ToolOutcomeMapper.ToFunctionResult(outcome);
    }

    /// <summary>
    /// Reads the inbound OBO assertion from the Functions HTTP transport. The
    /// token-store header wins when both supported headers are present.
    /// </summary>
    public static bool TryExtractInboundAccessToken(
        IReadOnlyDictionary<string, string> headers,
        [NotNullWhen(true)] out string? token)
    {
        foreach (var headerName in InboundTokenHeaderNames)
        {
            if (!HeaderLookup.TryGet(headers, headerName, out var value)
                || string.IsNullOrWhiteSpace(value))
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
