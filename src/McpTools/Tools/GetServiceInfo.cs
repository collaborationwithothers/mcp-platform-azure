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
/// Orders.Read holder calling get_service_info is refused -- the cross-tool
/// property issue 76 exists to prove.
///
/// The response is fixed service metadata compiled into the assembly (see the
/// FROZEN constants below). It reads no configuration, calls no downstream
/// system, and touches no clock, so every authorized call returns the same
/// answer. This is a deliberate design constraint, not an oversight: a tool
/// whose only job is proving an authorization boundary must not become another
/// route by which org-identifying data (a hostname, a resource id, a config
/// value) could reach this public repo's demo output.
///
/// docs/security.md, "get_service_info authorization", is the canonical account
/// of delegated callers and the app-role configuration. It also records why the
/// cross-tool proof applies only to app-context callers. The operator-facing wire
/// outcomes are in docs/mcp-request-flow.md, "Debugging map".
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

    // ServerNameValue is a FIXED DEMO LABEL. It deliberately does not match any
    // deployed resource: the live servers are named orders and catalog
    // (docs/runbooks/live-test-tfvars-reference.md; this comment said orders-mcp
    // and orders-mcp-2 until issue 82, which was wrong, and the runbook records
    // the 2026-08-09 correction). Those two names are correct-on-report, not
    // verified: they come from a direct read of the live tfvars secret, and no
    // gate output, Terraform assertion, or CI check in this repo can see a
    // server NAME. The matching PATHS are verifiable, from the server URLs in
    // any gate run log. The claim this comment is actually making survives
    // either way, because ServerNameValue matches none of the four candidates.
    // The MCP handshake name
    // is whatever the Functions host reports. Not matching them is the point.
    // This tool exists to prove an authorization boundary, and it must not
    // become a route by which a real deployment's identity reaches this public
    // repo's demo output. A caller who needs the real server identity reads it
    // from the initialize handshake, not from here. DataDisclaimerValue says
    // this in the payload itself, so the response is self-labelling and nobody
    // has to find this comment to know the value is not a resource name.
    internal const string ServerNameValue = "contoso-orders-mcp";
    internal const string TransportValue = "streamable-http";
    internal const string DataDisclaimerValue =
        "The order data this server returns is SYNTHETIC demo data (ids "
        + "CONTOSO-1001 to CONTOSO-1005) and is not sourced from any real system. "
        + "The serverName and transport values in this response are fixed demo "
        + "labels compiled into the build; they name no deployed Azure resource.";

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
        // These throws deliberately fail closed without exposing the principal
        // failure to the caller. The pinned SDK turns an ordinary exception into
        // the generic tool-error text and preserves the detail in server logs.
        // VERIFIED source evidence: COMPATIBILITY.md, "MCP tool method: thrown
        // exception wire shape". docs/mcp-request-flow.md owns the client-visible
        // wire outcome and why it differs from the gateway's -32001 response.
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
