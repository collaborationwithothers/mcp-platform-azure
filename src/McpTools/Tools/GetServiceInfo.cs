using System.Text.Json.Serialization;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Protocol;

namespace McpTools.Tools;

/// <summary>
/// The second synthetic tool exposed by the tracer: get_service_info (issue 79).
///
/// Its entire purpose is to prove per-tool authorization, not to serve useful
/// data. get_order_status is the only other tool on this server, and one tool
/// cannot demonstrate that a caller entitled to tool A is refused tool B: there
/// is no tool B to refuse. This tool IS tool B. It requires a DIFFERENT
/// application role (<see cref="AppRoleAuthorization.ServiceInfoRole"/>) from
/// get_order_status's <see cref="AppRoleAuthorization.RequiredRole"/>, so an
/// Orders.Read holder calling get_service_info is refused, and a
/// ServiceInfo.Read holder calling get_order_status is refused -- the
/// cross-tool property issue 76 exists to prove.
///
/// The response is fixed service metadata compiled into the assembly (see the
/// FROZEN constants below). It reads no configuration, calls no downstream
/// system, and touches no clock, so every authorized call returns the same
/// answer. This is a deliberate design constraint, not an oversight: a tool
/// whose only job is proving an authorization boundary must not become another
/// route by which org-identifying data (a hostname, a resource id, a config
/// value) could reach this public repo's demo output.
///
/// A DELEGATED caller (an scp principal) reaches this same check and is
/// denied in this deployment. That is a decision, not an oversight. The
/// app-role grant made to the client application does not appear in a
/// delegated token that application obtains, so the caller does not hold
/// ServiceInfo.Read. The boundary is worth stating precisely: a delegated
/// caller WOULD pass if the signed-in user had themselves been assigned the
/// ServiceInfo.Read app role, because a user's own role assignment does
/// surface in the roles claim. This deployment does not assign app roles to
/// users, so that path is unreached in practice, not unreachable by
/// construction; there is still only one role check to write, unlike
/// get_order_status's OBO split. Do not restate this as "delegated tokens never
/// carry roles"; Microsoft Learn contradicts that blanket form. Verified
/// 2026-08-08 against "Identify the permission type for an access token"; see
/// docs/security.md, "get_service_info authorization", for the citation.
/// </summary>
public sealed class GetServiceInfo
{
    internal const string ToolName = "get_service_info";

    internal const string ToolDescription =
        "Returns fixed information about this MCP server: its name, its transport, "
        + "and a note that the order data it serves is SYNTHETIC. The response is "
        + "static service metadata compiled into the server. It reads no "
        + "configuration and calls nothing downstream, so every call returns the "
        + "same answer.";

    internal const string ServerNameValue = "contoso-orders-mcp";
    internal const string TransportValue = "streamable-http";
    internal const string DataDisclaimerValue =
        "The order data this server returns is SYNTHETIC demo data (ids "
        + "CONTOSO-1001 to CONTOSO-1005) and is not sourced from any real system.";

    private readonly ILogger<GetServiceInfo> _logger;

    public GetServiceInfo(ILogger<GetServiceInfo> logger)
    {
        _logger = logger;
    }

    [Function(nameof(GetServiceInfo))]
    public object Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context)
    {
        // TryGetHttpTransport's out parameter is not nullable-annotated in the
        // extension package, but the method's own contract guarantees it is
        // non-null when it returns true (confirmed by reflection against the
        // installed 1.5.1 assembly; see GetOrderStatus for the full verification
        // note).
        if (!context.TryGetHttpTransport(out var transport))
        {
            throw new InvalidOperationException(
                "get_service_info: no HTTP transport is available on this invocation. This repo's "
                + "tracer targets the Streamable HTTP transport only; headers, and therefore the "
                + "caller identity, are unavailable otherwise.");
        }

        var headers = transport!.Headers;

        // Same per-request fail-closed resolution get_order_status uses; only a
        // sound security boundary in production because the startup
        // BuiltInAuthGuard asserts Easy Auth is enabled, and enabled Easy Auth
        // strips client-supplied X-MS-* headers before injecting its own
        // (docs/security.md, "trust chain").
        var resolution = IdentityModeResolver.ResolveWithPrincipal(headers);
        return resolution.Mode switch
        {
            IdentityMode.Delegated or IdentityMode.AppContext => AuthorizeAndBuildResult(resolution.Principal!),
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
    }

    // Delegated and app-context callers both land here (see the class doc
    // comment): the check is a single application-role test, so a delegated
    // caller is refused by the same path as an unauthorized app-context caller,
    // not by a separate branch.
    private object AuthorizeAndBuildResult(ClientPrincipal principal)
    {
        if (!AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole))
        {
            LogOutcome(principal, granted: false);
            return new CallToolResult
            {
                IsError = true,
                Content =
                [
                    new TextContentBlock
                    {
                        Text = "403 Forbidden: get_service_info requires the application role "
                            + $"'{AppRoleAuthorization.ServiceInfoRole}'.",
                    },
                ],
            };
        }

        LogOutcome(principal, granted: true);
        return new ServiceInfo(ServerNameValue, TransportValue, DataDisclaimerValue);
    }

    // Best-effort caller correlation only (TryFromPrincipal, never
    // FromPrincipal): logging is diagnostics, not an authorization input, so a
    // principal missing azp/oid must not turn a normal grant/deny outcome into a
    // thrown error. Logs only the app id and object id, never a token or claim
    // value beyond those two, matching get_order_status's logging scope.
    private void LogOutcome(ClientPrincipal principal, bool granted)
    {
        var hasCaller = CallerIdentityCorrelation.TryFromPrincipal(principal, out var caller);
        var message = "get_service_info {Outcome} caller. CallerApplicationId={CallerApplicationId} "
            + "CallerObjectId={CallerObjectId}";
        var outcome = granted ? "authorized" : "denied";
        var applicationId = hasCaller ? caller!.ApplicationId : null;
        var objectId = hasCaller ? caller!.ObjectId : null;

        if (granted)
        {
            _logger.LogInformation(message, outcome, applicationId, objectId);
        }
        else
        {
            _logger.LogWarning(message, outcome, applicationId, objectId);
        }
    }
}

/// <summary>Typed success result: fixed service metadata, the same on every call.</summary>
public sealed record ServiceInfo(
    [property: JsonPropertyName("serverName")] string ServerName,
    [property: JsonPropertyName("transport")] string Transport,
    [property: JsonPropertyName("dataDisclaimer")] string DataDisclaimer);
