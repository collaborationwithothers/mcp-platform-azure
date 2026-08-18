using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Core;

/// <summary>The frozen names, descriptions, and fixed values for the MCP tools.</summary>
public static class McpToolContracts
{
    public const string GetOrderStatusName = "get_order_status";

    // Acceptance: the description string must state the data is synthetic.
    public const string GetOrderStatusDescription =
        "Returns the status of a Contoso order by id. The order data is SYNTHETIC "
        + "demo data (ids CONTOSO-1001 to CONTOSO-1005) and is not sourced from any "
        + "real system.";

    public const string GetServiceInfoName = "get_service_info";
    public const string GetServiceInfoDescription =
        "Returns fixed information about this MCP server: its name, its transport, "
        + "and a note that the order data it serves is SYNTHETIC. The response is "
        + "static service metadata compiled into the server. It reads no "
        + "configuration and calls nothing downstream, so every call returns the "
        + "same answer.";

    public const string GetAccessGuidanceName = "get_access_guidance";
    public const string GetAccessGuidanceDescription =
        "Returns fixed guidance on the entitlements this server's tools require and "
        + "where to request them. This tool is deliberately open: it applies no "
        + "per-tool entitlement check, because a caller who cannot yet call any "
        + "other tool still needs to be able to read this. It is not unauthenticated: "
        + "a valid token for this server and this server's own entitlement are still "
        + "required. The response is compiled into the server build, so every call "
        + "returns the same answer.";

    // ServiceInfoServerName is a FIXED DEMO LABEL. It deliberately does not
    // match any deployed resource: the live servers are named orders and
    // catalog (docs/runbooks/live-test-tfvars-reference.md; this comment said
    // orders-mcp and orders-mcp-2 until issue 82, which was wrong, and the
    // runbook records the 2026-08-09 correction). Those two names are
    // correct-on-report, not verified: they come from a direct read of the live
    // tfvars secret, and no gate output, Terraform assertion, or CI check in
    // this repo can see a server NAME. The matching PATHS are verifiable, from
    // the server URLs in any gate run log. The claim this comment is actually
    // making survives either way, because ServiceInfoServerName matches none
    // of the four candidates. The MCP handshake name is whatever the Functions
    // host reports. Not matching them is the point. This tool exists to prove
    // an authorization boundary, and it must not become a route by which a real
    // deployment's identity reaches this public repo's demo output. A caller
    // who needs the real server identity reads it from the initialize handshake,
    // not from here. ServiceInfoDataDisclaimer says this in the payload itself,
    // so the response is self-labelling and nobody has to find this comment to
    // know the value is not a resource name.
    public const string ServiceInfoServerName = "contoso-orders-mcp";
    public const string ServiceInfoTransport = "streamable-http";
    public const string ServiceInfoDataDisclaimer =
        "The order data this server returns is SYNTHETIC demo data (ids "
        + "CONTOSO-1001 to CONTOSO-1005) and is not sourced from any real system. "
        + "The serverName and transport values in this response are fixed demo "
        + "labels compiled into the build; they name no deployed Azure resource.";

    public const string AccessGuidanceDocsUrl =
        "https://github.com/collaborationwithothers/mcp-platform-azure";

    // Governance review of issue 82 found that an earlier summary stated the
    // downstream assignment gate as settled fact and omitted the Global
    // Administrator bypass. Independent verification against Microsoft Learn
    // on 2026-08-09 graded the assignment-required gate VERIFIED for OAuth 2.0
    // access-token requests generally, the Global Administrator bypass
    // VERIFIED, and the on-behalf-of token exchange specifically UNVERIFIABLE
    // from Learn. The summary therefore carries both qualifications and names
    // the 2026-07-22 live test as its basis. See docs/security.md, "Trusted-
    // subsystem trade-off and backstop asymmetry".
    //
    // The summary names the gateway's per-server roles because that is the
    // entitlement a caller holding nothing is most likely missing. Those names
    // remain prose rather than structured requirements because they live in
    // deployment configuration that this core cannot read or guard. The
    // summary therefore declares the gateway map authoritative on disagreement.
    public const string AccessGuidanceSummary =
        "Two layers authorize a call and they fail in a fixed order. FIRST the "
        + "gateway checks a per-SERVER entitlement, before it considers which tool "
        + "you asked for, so a caller that fails it never reaches the tool layer at "
        + "all. That is the entitlement a caller holding nothing is most likely "
        + "missing. As deployed it is the application role Orders.Invoke.All or "
        + "Catalog.Invoke.All, depending on which of this deployment's servers you "
        + "connected to, or the matching delegated scope: either satisfies the "
        + "check. Those two names are deployment configuration rather than a "
        + "property of this software, and this response is compiled in, so if they "
        + "ever disagree with the gateway's own authorization map, the map is "
        + "authoritative. SECOND, each tool is authorized independently, so holding "
        + "the entitlement for one tool does not grant another. "
        + "requiredEntitlements lists every tool and identity mode. Each allOf "
        + "array lists controls that must all pass. An application-context caller "
        + "(client credentials) is authorized by the named Entra application role. "
        + "A delegated (user-context) caller is authorized per tool: "
        + "get_service_info applies the same application-role check, while "
        + "get_order_status first requires the delegated scope Orders.Read.AsUser "
        + "at the backend tool, then carries the caller's authority to the downstream "
        + "Orders API. That API's assignment-required setting governs whether an OBO "
        + "token is issued at all. Two limits on that last statement, because it is "
        + "the least certain thing here. Microsoft documents the "
        + "assignment-required gate for OAuth 2.0 access-token requests generally "
        + "and does not document it for the on-behalf-of token exchange "
        + "specifically; this deployment established that behaviour by its own live "
        + "test on 2026-07-22 rather than from documentation. And Global "
        + "Administrators bypass the gate, so it does not constrain them. This tool "
        + "itself is unrestricted by design so that a caller holding nothing can "
        + "still read this. Unrestricted relaxes the per-tool check and nothing "
        + "else: a valid token for this server, and the per-server entitlement "
        + "above, are both still required. To request an entitlement, see docsUrl.";

    // This distinguishes values taken from runtime authorization constants
    // from the per-server values named in the summary. The latter are
    // deployment configuration and this server deliberately cannot read them.
    public const string AccessGuidanceDataDisclaimer =
        "This response is fixed guidance compiled into the server build. It reads no "
        + "configuration and names no deployed Azure resource, tenant, or principal. "
        + "Every per-tool entitlement value it emits comes from the same constants "
        + "this server checks at runtime, so requiredEntitlements cannot name a value "
        + "no code enforces. The two per-server role names in the summary are deployment "
        + "configuration this server never reads, so nothing in the build can "
        + "detect it if they go stale; the gateway's authorization map is "
        + "authoritative for those. The order data this server's get_order_status "
        + "tool returns is SYNTHETIC demo data (ids CONTOSO-1001 to CONTOSO-1005) "
        + "and is not sourced from any real system.";

    // Identity-mode vocabulary for a ToolEntitlement row.
    public const string AppliesToApplication = "application";
    public const string AppliesToDelegated = "delegated";

    // Requirement vocabulary for a ToolEntitlement row. This intentionally
    // describes the backend and downstream controls, not the gateway map.
    public const string RequirementKindApplicationRole = "applicationRole";
    public const string RequirementKindDelegatedScope = "delegatedScope";
    public const string RequirementKindDownstreamAssignmentRequired =
        "downstreamAssignmentRequired";
    public const string EnforcedAtBackendTool = "backendTool";
    public const string EnforcedAtDownstreamTokenIssuance =
        "downstreamTokenIssuance";

    // Total over tool TIMES identity mode. get_order_status has separate
    // application and delegated rules. The delegated rule also records the
    // downstream Orders API assignment-required gate at token issuance. That
    // behavior was established live on 2026-07-22 by AADSTS50105 from
    // OnBehalfOfRequest.ExecuteAsync; the summary above preserves the limits of
    // the available Microsoft documentation. Adding a tool without adding both
    // of its rows fails ToolEntitlementParityTests at build time, which is the
    // only thing keeping this list honest; check (a) guards the gateway map,
    // not this.
    public static readonly IReadOnlyList<ToolEntitlement> RequiredEntitlements =
    [
        new ToolEntitlement(
            GetOrderStatusName,
            AppliesToApplication,
            [
                new AuthorizationRequirement(
                    RequirementKindApplicationRole,
                    EnforcedAtBackendTool,
                    AppRoleAuthorization.RequiredRole),
            ]),
        new ToolEntitlement(
            GetOrderStatusName,
            AppliesToDelegated,
            [
                new AuthorizationRequirement(
                    RequirementKindDelegatedScope,
                    EnforcedAtBackendTool,
                    DelegatedScopeAuthorization.GetOrderStatusScope),
                new AuthorizationRequirement(
                    RequirementKindDownstreamAssignmentRequired,
                    EnforcedAtDownstreamTokenIssuance,
                    null),
            ]),
        new ToolEntitlement(
            GetServiceInfoName,
            AppliesToApplication,
            [
                new AuthorizationRequirement(
                    RequirementKindApplicationRole,
                    EnforcedAtBackendTool,
                    AppRoleAuthorization.ServiceInfoRole),
            ]),
        new ToolEntitlement(
            GetServiceInfoName,
            AppliesToDelegated,
            [
                new AuthorizationRequirement(
                    RequirementKindApplicationRole,
                    EnforcedAtBackendTool,
                    AppRoleAuthorization.ServiceInfoRole),
            ]),
        new ToolEntitlement(GetAccessGuidanceName, AppliesToApplication, []),
        new ToolEntitlement(GetAccessGuidanceName, AppliesToDelegated, []),
    ];
}
