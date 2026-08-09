using System.Text.Json.Serialization;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;

namespace McpTools.Tools;

/// <summary>
/// The third synthetic tool exposed by the tracer: get_access_guidance
/// (issue 82). It is the only tool on this server with NO per-tool entitlement
/// check, and that absence is the deliberate subject of the tool, not an
/// omission in it.
///
/// WHY IT EXISTS AT ALL. The gateway's tool_authorization_map classifies every
/// tool one of three ways: it requires a delegated scope, it requires an
/// application role, or it is unrestricted (ADR-009, D2). Before this tool,
/// every mapped tool used the role branch, so the unrestricted branch had never
/// been executed by anything and a break in it would have gone unnoticed. The
/// map cannot carry a test-only key: the live gate's check (a) asserts
/// set-equality between tools/list and the map keys in BOTH directions, so a key
/// with no matching tool fails the gate as a dead policy branch. Proving the
/// branch therefore requires a tool that genuinely exists and genuinely deploys.
///
/// WHY IT IS NOT MERELY SCAFFOLDING. A tool that existed only to make a test
/// possible would be a smell, and a reader would rightly ask why it is here.
/// This one answers the question a caller actually has when nothing works: which
/// entitlements exist on this server, and how do I ask for one. That information
/// has to be readable BEFORE you hold any entitlement, which is a genuine reason
/// for a tool to be open rather than a convenient one.
///
/// WHAT UNRESTRICTED DOES AND DOES NOT RELAX. It relaxes the per-TOOL
/// entitlement check, and only that. A caller still needs a valid token for this
/// server's audience, still needs the SERVER-level entitlement the gateway
/// checks one layer earlier (Orders.Invoke.All on server 1), and still passes
/// through the backend's Easy Auth. This method still resolves the caller with
/// IdentityModeResolver.ResolveWithPrincipal and still fail-closed rejects
/// MissingPrincipal and MalformedPrincipal, exactly as GetOrderStatus and
/// GetServiceInfo do. There is deliberately NO AppRoleAuthorization call below.
/// Do not add one; doing so would delete the only live proof of the
/// unrestricted branch.
///
/// WHY THE RESPONSE IS SHAPED THE WAY IT IS. RequiredEntitlements is total over
/// tool TIMES identity mode, not over tools. get_order_status does not have one
/// rule with an exception; it has two rules, one per mode. Its app-context path
/// is authorized here, by the Orders.Read role. Its delegated path is not
/// authorized here at all: the caller's own authority is carried to the
/// downstream Orders API through the OBO exchange, and the downstream's
/// appRoleAssignmentRequired gate decides at token-issuance time (docs/security.md,
/// "Trusted-subsystem trade-off and backstop asymmetry"; established live
/// 2026-07-22, AADSTS50105 at MSAL OnBehalfOfRequest.ExecuteAsync). A flat
/// tool-to-role list would state one of those two and stay silent about the
/// other, so the list carries an AppliesTo and a Mechanism per row and covers
/// every combination. ToolEntitlementParityTests enforces that totality at
/// build time; nothing else would.
///
/// WHAT THE LIST DELIBERATELY DOES NOT SAY. It does not say that no user can
/// satisfy ServiceInfo.Read in this deployment, which is true today only because
/// the role is declared with Allowed member types = Applications only. That is a
/// tenant-configuration fact, and this tool is barred from reporting tenant
/// configuration for the same reason it reads no configuration at all. The rows
/// state the RULE; whether a given tenant has a principal that meets it is not
/// this tool's business.
///
/// The response is compiled-in constants only: no environment reads, no
/// configuration reads, no host name, no resource id, no wall clock. Same
/// constraint get_service_info carries, for the same reason. A tool whose job is
/// proving an authorization boundary must not become another route by which a
/// real deployment's identity reaches this public repo's demo output. The role
/// names it does emit are this repository's own public demo role names, drawn
/// from AppRoleAuthorization, and they identify no tenant.
/// </summary>
public sealed class GetAccessGuidance
{
    internal const string ToolName = "get_access_guidance";

    internal const string ToolDescription =
        "Returns fixed guidance on the entitlements this server's tools require and "
        + "where to request them. This tool is deliberately open: it applies no "
        + "per-tool entitlement check, because a caller who cannot yet call any "
        + "other tool still needs to be able to read this. It is not unauthenticated: "
        + "a valid token for this server and this server's own entitlement are still "
        + "required. The response is compiled into the server build, so every call "
        + "returns the same answer.";

    // Identity-mode vocabulary for a ToolEntitlement row.
    internal const string AppliesToApplication = "application";
    internal const string AppliesToDelegated = "delegated";

    // Authorization-mechanism vocabulary for a ToolEntitlement row. Deliberately
    // NOT the gateway map's own three-way vocabulary (scope/role/unrestricted):
    // these describe what the BACKEND does, and the backend has a mechanism the
    // gateway has no word for, the downstream assignment gate on the OBO path.
    internal const string MechanismApplicationRole = "applicationRole";
    internal const string MechanismDownstreamAssignmentRequired = "downstreamAssignmentRequired";
    internal const string MechanismUnrestricted = "unrestricted";

    internal const string DocsUrlValue = "https://github.com/collaborationwithothers/mcp-platform-azure";

    internal const string SummaryValue =
        "Every tool on this server is authorized independently, so holding the "
        + "entitlement for one tool does not grant another. requiredEntitlements "
        + "lists every tool on this server and, for each caller identity mode, the "
        + "mechanism that authorizes it. An application-context caller (client "
        + "credentials) is authorized by the named Entra application role. A "
        + "delegated (user-context) caller is authorized per tool: get_service_info "
        + "applies the same application-role check, while get_order_status carries "
        + "the caller's own authority to the downstream Orders API, where Entra's "
        + "assignment-required gate on that API decides at token-exchange time. "
        + "This tool itself is unrestricted by design so that a caller holding "
        + "nothing can still read this; unrestricted relaxes the per-tool check and "
        + "nothing else, and a valid token plus this server's own entitlement are "
        + "still required. To request an entitlement, see docsUrl.";

    internal const string DataDisclaimerValue =
        "This response is fixed guidance compiled into the server build. It reads no "
        + "configuration and names no deployed Azure resource, tenant, or principal; "
        + "the role names below are this public repository's demo role names. The "
        + "order data this server's get_order_status tool returns is SYNTHETIC demo "
        + "data (ids CONTOSO-1001 to CONTOSO-1005) and is not sourced from any real "
        + "system.";

    // Total over tool TIMES identity mode. Adding a tool without adding both of
    // its rows fails ToolEntitlementParityTests at build time, which is the only
    // thing keeping this list honest; check (a) guards the gateway map, not this.
    internal static readonly IReadOnlyList<ToolEntitlement> RequiredEntitlementsValue =
    [
        new ToolEntitlement(
            GetOrderStatus.ToolName, AppliesToApplication, MechanismApplicationRole,
            AppRoleAuthorization.RequiredRole),
        new ToolEntitlement(
            GetOrderStatus.ToolName, AppliesToDelegated, MechanismDownstreamAssignmentRequired,
            null),
        new ToolEntitlement(
            GetServiceInfo.ToolName, AppliesToApplication, MechanismApplicationRole,
            AppRoleAuthorization.ServiceInfoRole),
        new ToolEntitlement(
            GetServiceInfo.ToolName, AppliesToDelegated, MechanismApplicationRole,
            AppRoleAuthorization.ServiceInfoRole),
        new ToolEntitlement(
            ToolName, AppliesToApplication, MechanismUnrestricted, null),
        new ToolEntitlement(
            ToolName, AppliesToDelegated, MechanismUnrestricted, null),
    ];

    private readonly ILogger<GetAccessGuidance> _logger;

    public GetAccessGuidance(ILogger<GetAccessGuidance> logger)
    {
        _logger = logger;
    }

    [Function(nameof(GetAccessGuidance))]
    public object Run(
        [McpToolTrigger(ToolName, ToolDescription)] ToolInvocationContext context)
    {
        // TryGetHttpTransport's out parameter is not nullable-annotated in the
        // extension package, but the method's own contract guarantees it is
        // non-null when it returns true (confirmed by reflection against the
        // installed 1.5.1 assembly; see GetOrderStatus for the verification note).
        if (!context.TryGetHttpTransport(out var transport))
        {
            throw new InvalidOperationException(
                "get_access_guidance: no HTTP transport is available on this invocation. This "
                + "repo's tracer targets the Streamable HTTP transport only; headers, and "
                + "therefore the caller identity, are unavailable otherwise.");
        }

        var headers = transport!.Headers;

        // Identical fail-closed resolution to the other two tools, and identical
        // reasoning: this is only a sound boundary because the startup
        // BuiltInAuthGuard asserts Easy Auth is enabled, and enabled Easy Auth
        // strips client-supplied X-MS-* headers before injecting its own
        // (docs/security.md, "trust chain"). The throw messages reach server logs
        // only, never the caller: the MCP SDK replaces any non-McpException with
        // the bare text "An error occurred invoking '<tool>'." (COMPATIBILITY.md,
        // "MCP tool method: thrown exception wire shape"). That is the outcome we
        // want; a caller who did not traverse the authenticated path is not told
        // which check rejected them.
        var resolution = IdentityModeResolver.ResolveWithPrincipal(headers);
        return resolution.Mode switch
        {
            // NO AppRoleAuthorization CALL HERE, DELIBERATELY. Both identity
            // modes reach the same guidance. See the class doc comment.
            IdentityMode.Delegated or IdentityMode.AppContext => BuildResult(resolution.Principal!),
            IdentityMode.MissingPrincipal => throw new InvalidOperationException(
                $"get_access_guidance: the {ClientPrincipal.HeaderName} header is missing. In "
                + "production this is a fail-closed rejection: Easy Auth injects that header on "
                + "every request it validates, and the startup auth guard guarantees Easy Auth is "
                + "enabled, so a missing header means the request did not traverse the "
                + "authenticated path. An unrestricted tool relaxes the per-tool entitlement "
                + "check only; it does not accept an unidentifiable caller."),
            IdentityMode.MalformedPrincipal => throw new InvalidOperationException(
                $"get_access_guidance: the {ClientPrincipal.HeaderName} header was present but "
                + "could not be decoded as the Base64 JSON client principal Easy Auth emits."),
            _ => throw new InvalidOperationException(
                "get_access_guidance: no caller identity could be established. The validated "
                + "principal carried neither an scp (delegated) claim nor an azp/appid "
                + "application identity."),
        };
    }

    private object BuildResult(ClientPrincipal principal)
    {
        LogOutcome(principal);
        return new AccessGuidance(
            SummaryValue, RequiredEntitlementsValue, DocsUrlValue, DataDisclaimerValue);
    }

    // Best-effort caller correlation only (TryFromPrincipal, never
    // FromPrincipal): logging is diagnostics, not an authorization input, so a
    // principal missing azp/oid must not turn a normal outcome into a thrown
    // error. Logs only the app id and object id, matching the other two tools.
    //
    // Logged at Information with an explicit "unrestricted" marker, and never at
    // Warning: there is no deny outcome on this tool, so an operator scanning
    // logs must be able to tell "this tool admitted an under-entitled caller,
    // as designed" from "an entitlement check was skipped by accident".
    private void LogOutcome(ClientPrincipal principal)
    {
        var hasCaller = CallerIdentityCorrelation.TryFromPrincipal(principal, out var caller);
        _logger.LogInformation(
            "get_access_guidance served caller (unrestricted by design, no per-tool entitlement "
            + "check applies). CallerApplicationId={CallerApplicationId} CallerObjectId={CallerObjectId}",
            hasCaller ? caller!.ApplicationId : null,
            hasCaller ? caller!.ObjectId : null);
    }
}

/// <summary>
/// Typed success result: fixed access guidance, the same on every call.
/// </summary>
public sealed record AccessGuidance(
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("requiredEntitlements")] IReadOnlyList<ToolEntitlement> RequiredEntitlements,
    [property: JsonPropertyName("docsUrl")] string DocsUrl,
    [property: JsonPropertyName("dataDisclaimer")] string DataDisclaimer);

/// <summary>
/// One tool's authorization rule for one caller identity mode.
///
/// RequiredRole is non-null if and only if Mechanism is "applicationRole". A
/// null RequiredRole is therefore never a gap in the data: Mechanism always
/// says which classification produced it. That invariant is the reason this row
/// carries a Mechanism at all rather than a bare nullable role, and
/// GetAccessGuidanceTests enforces it. It mirrors the Terraform-side validation
/// on the gateway map (infra/terraform/modules/apim-mcp-server/variables.tf),
/// which refuses an entry that sets none of scope, role, or unrestricted.
/// </summary>
public sealed record ToolEntitlement(
    [property: JsonPropertyName("tool")] string Tool,
    [property: JsonPropertyName("appliesTo")] string AppliesTo,
    [property: JsonPropertyName("mechanism")] string Mechanism,
    [property: JsonPropertyName("requiredRole")] string? RequiredRole);
