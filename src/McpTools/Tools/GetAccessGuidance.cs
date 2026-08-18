using McpTools.Core;
using McpTools.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging;

namespace McpTools.Tools;

/// <summary>
/// Azure Functions adapter for get_access_guidance. The shared application
/// core owns the unrestricted per-tool rule and the fixed guidance result.
/// </summary>
public sealed class GetAccessGuidance
{
    internal const string ToolName = McpToolContracts.GetAccessGuidanceName;
    internal const string ToolDescription = McpToolContracts.GetAccessGuidanceDescription;
    internal const string AppliesToApplication = McpToolContracts.AppliesToApplication;
    internal const string AppliesToDelegated = McpToolContracts.AppliesToDelegated;
    internal const string RequirementKindApplicationRole = McpToolContracts.RequirementKindApplicationRole;
    internal const string RequirementKindDelegatedScope = McpToolContracts.RequirementKindDelegatedScope;
    internal const string RequirementKindDownstreamAssignmentRequired =
        McpToolContracts.RequirementKindDownstreamAssignmentRequired;
    internal const string EnforcedAtBackendTool = McpToolContracts.EnforcedAtBackendTool;
    internal const string EnforcedAtDownstreamTokenIssuance =
        McpToolContracts.EnforcedAtDownstreamTokenIssuance;
    internal const string DocsUrlValue = McpToolContracts.AccessGuidanceDocsUrl;
    internal const string SummaryValue = McpToolContracts.AccessGuidanceSummary;
    internal const string DataDisclaimerValue = McpToolContracts.AccessGuidanceDataDisclaimer;
    internal static IReadOnlyList<ToolEntitlement> RequiredEntitlementsValue =>
        McpToolContracts.RequiredEntitlements;

    private readonly McpToolApplication _application;
    private readonly ILogger<GetAccessGuidance> _logger;

    public GetAccessGuidance(
        McpToolApplication application,
        ILogger<GetAccessGuidance> logger)
    {
        _application = application;
        _logger = logger;
    }

    [Function(nameof(GetAccessGuidance))]
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
                "get_access_guidance: no HTTP transport is available on this invocation. This "
                + "repo's tracer targets the Streamable HTTP transport only; headers, and "
                + "therefore the caller identity, are unavailable otherwise.");
        }

        // This is the same fail-closed resolution used by the other tools. It
        // is sound only because BuiltInAuthGuard asserts built-in auth is
        // enabled and the platform strips client-supplied X-MS-* headers before
        // injecting its own. The MCP SDK replaces a non-McpException with the
        // generic tool error text and keeps this detail in server logs. See
        // COMPATIBILITY.md, "MCP tool method: thrown exception wire shape", and
        // docs/security.md, "trust chain".
        var resolution = IdentityModeResolver.ResolveWithPrincipal(transport!.Headers);
        var caller = resolution.Mode switch
        {
            IdentityMode.Delegated or IdentityMode.AppContext => resolution.Caller!,
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

        var result = _application.GetAccessGuidance(caller);
        _logger.LogInformation(
            "get_access_guidance served caller (unrestricted by design, no per-tool entitlement "
            + "check applies). CallerApplicationId={CallerApplicationId} CallerObjectId={CallerObjectId}",
            caller.Correlation?.ApplicationId,
            caller.Correlation?.ObjectId);
        return result;
    }
}
