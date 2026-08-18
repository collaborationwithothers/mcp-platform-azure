using System.Diagnostics.CodeAnalysis;
using McpTools.Core;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;

namespace McpTools.Tools;

/// <summary>
/// Azure Functions adapter for get_order_status. The shared application core
/// owns authorization, branch selection, and typed results. This adapter owns
/// the Functions trigger, HTTP headers, built-in auth parsing, and logging.
/// </summary>
public sealed class GetOrderStatus
{
    internal const string ToolName = McpToolContracts.GetOrderStatusName;
    internal const string ToolDescription = McpToolContracts.GetOrderStatusDescription;

    private static readonly string[] InboundTokenHeaderNames =
        ["X-MS-TOKEN-AAD-ACCESS-TOKEN", "Authorization"];

    private readonly McpToolApplication _application;
    private readonly ILogger<GetOrderStatus> _logger;

    public GetOrderStatus(
        McpToolApplication application,
        ILogger<GetOrderStatus> logger)
    {
        _application = application;
        _logger = logger;
    }

    [Function(nameof(GetOrderStatus))]
    public async Task<object> Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context,
        [McpToolProperty("orderId", "The order id to look up, for example CONTOSO-1001.", isRequired: true)]
            string orderId,
        CancellationToken cancellationToken)
    {
        if (!context.TryGetHttpTransport(out var transport))
        {
            throw new InvalidOperationException(
                "get_order_status: no HTTP transport is available on this invocation. This repo's "
                + "tracer targets the Streamable HTTP transport only (see the doc comment on the "
                + "SSE-transport constraint); headers, and therefore the caller identity and inbound "
                + "token, are unavailable otherwise.");
        }

        var headers = transport!.Headers;
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

        if (outcome.Error is null)
        {
            if (caller.Correlation is not null)
            {
                _logger.LogInformation(
                    "get_order_status authorized caller. CallerApplicationId={CallerApplicationId} "
                    + "CallerObjectId={CallerObjectId} IdentityMode={IdentityMode}",
                    caller.Correlation.ApplicationId,
                    caller.Correlation.ObjectId,
                    caller.Mode);
            }
            else
            {
                _logger.LogWarning(
                    "get_order_status: the delegated caller principal did not carry azp/appid and "
                    + "oid claims; proceeding without caller correlation headers (audit context only, "
                    + "not an authorization input).");
            }
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
