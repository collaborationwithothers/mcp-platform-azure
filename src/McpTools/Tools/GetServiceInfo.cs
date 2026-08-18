using McpTools.Core;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;

namespace McpTools.Tools;

/// <summary>
/// Azure Functions adapter for get_service_info. The shared application core
/// owns its authorization rule and fixed typed result.
/// </summary>
public sealed class GetServiceInfo
{
    internal const string ToolName = McpToolContracts.GetServiceInfoName;
    internal const string ToolDescription = McpToolContracts.GetServiceInfoDescription;
    internal const string ServerNameValue = McpToolContracts.ServiceInfoServerName;
    internal const string TransportValue = McpToolContracts.ServiceInfoTransport;
    internal const string DataDisclaimerValue = McpToolContracts.ServiceInfoDataDisclaimer;

    private readonly McpToolApplication _application;
    private readonly ILogger<GetServiceInfo> _logger;

    public GetServiceInfo(
        McpToolApplication application,
        ILogger<GetServiceInfo> logger)
    {
        _application = application;
        _logger = logger;
    }

    [Function(nameof(GetServiceInfo))]
    public object Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context)
    {
        // TryGetHttpTransport's out parameter is not nullable-annotated in the
        // extension package, but the method's own contract guarantees it is
        // non-null when it returns true. This was confirmed by reflection
        // against the installed 1.5.1 assembly; GetOrderStatus carries the full
        // verification note.
        if (!context.TryGetHttpTransport(out var transport))
        {
            throw new InvalidOperationException(
                "get_service_info: no HTTP transport is available on this invocation. This repo's "
                + "tracer targets the Streamable HTTP transport only; headers, and therefore the "
                + "caller identity, are unavailable otherwise.");
        }

        // The same per-request fail-closed resolution get_order_status uses.
        // This is a sound production boundary only because BuiltInAuthGuard
        // asserts built-in auth is enabled and the platform strips client-
        // supplied X-MS-* headers before injecting its own. These throws fail
        // closed without exposing the principal failure to the caller. The
        // pinned SDK turns an ordinary exception into generic tool-error text
        // and preserves the detail in server logs. See COMPATIBILITY.md, "MCP
        // tool method: thrown exception wire shape", and docs/security.md,
        // "trust chain".
        var resolution = IdentityModeResolver.ResolveWithPrincipal(transport!.Headers);
        var caller = resolution.Mode switch
        {
            IdentityMode.Delegated or IdentityMode.AppContext => resolution.Caller!,
            IdentityMode.MissingPrincipal => throw new InvalidOperationException(
                $"get_service_info: the {ClientPrincipal.HeaderName} header is missing. In production "
                + "this is a fail-closed rejection: Easy Auth injects that header on every request it "
                + "validates, and the startup auth guard guarantees Easy Auth is enabled, so a missing "
                + "header means the request did not traverse the authenticated path."),
            IdentityMode.MalformedPrincipal => throw new InvalidOperationException(
                $"get_service_info: the {ClientPrincipal.HeaderName} header was present but could not be "
                + "decoded as the Base64 JSON client principal Easy Auth emits."),
            _ => throw new InvalidOperationException(
                "get_service_info: no caller identity could be established. The validated principal "
                + "carried neither an scp (delegated) claim nor an azp/appid application identity."),
        };

        var outcome = _application.GetServiceInfo(caller);
        LogOutcome(caller, outcome.Error is null);
        return ToolOutcomeMapper.ToFunctionResult(outcome);
    }

    private void LogOutcome(CallerIdentity caller, bool granted)
    {
        const string message =
            "get_service_info {Outcome} caller. CallerApplicationId={CallerApplicationId} "
            + "CallerObjectId={CallerObjectId}";
        var outcome = granted ? "authorized" : "denied";

        if (granted)
        {
            _logger.LogInformation(
                message,
                outcome,
                caller.Correlation?.ApplicationId,
                caller.Correlation?.ObjectId);
        }
        else
        {
            _logger.LogWarning(
                message,
                outcome,
                caller.Correlation?.ApplicationId,
                caller.Correlation?.ObjectId);
        }
    }
}
