using System.Security.Claims;

namespace McpTools.Identity;

/// <summary>The normalized caller data consumed by the application core.</summary>
public sealed record CallerIdentity(
    IdentityMode Mode,
    IReadOnlyList<string> Roles,
    IReadOnlyList<string> DelegatedScopes,
    CallerIdentityCorrelation? Correlation,
    string? TenantId = null);

/// <summary>
/// Caller identity used for audit correlation. It is optional on the delegated
/// path and required on the application path.
/// </summary>
public sealed record CallerIdentityCorrelation(string ApplicationId, string ObjectId)
{
    public const string ApplicationIdHeader = "X-Mcp-Caller-Azp";
    public const string ObjectIdHeader = "X-Mcp-Caller-Oid";
}

public enum IdentityMode
{
    Delegated,
    AppContext,
    MissingPrincipal,
    MalformedPrincipal,
    Unsupported,
}

/// <summary>
/// Converts a validated host principal into the one host-neutral caller shape.
/// Claim type aliases are matched case-insensitively. Granted role and scope
/// values retain their original casing for fail-closed ordinal checks.
/// </summary>
public static class CallerIdentityResolver
{
    private static readonly string[] ScopeClaimTypes =
        ["scp", "http://schemas.microsoft.com/identity/claims/scope"];

    private static readonly string[] RoleClaimTypes =
        ["roles", "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"];

    private static readonly string[] ApplicationIdClaimTypes =
    [
        "azp",
        "appid",
        "http://schemas.microsoft.com/identity/claims/azp",
        "http://schemas.microsoft.com/identity/claims/appid",
    ];

    private static readonly string[] ObjectIdClaimTypes =
        ["oid", "http://schemas.microsoft.com/identity/claims/objectidentifier"];

    private static readonly string[] TenantIdClaimTypes =
        ["tid", "http://schemas.microsoft.com/identity/claims/tenantid"];

    public static CallerIdentity Resolve(ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var claims = principal.Claims.ToArray();
        var hasScopeClaim = claims.Any(claim => IsAny(claim.Type, ScopeClaimTypes));
        var applicationId = FirstNonEmptyValue(claims, ApplicationIdClaimTypes);
        var hasRoleClaim = claims.Any(claim => IsAny(claim.Type, RoleClaimTypes));

        var mode = hasScopeClaim
            ? IdentityMode.Delegated
            : hasRoleClaim || applicationId is not null
                ? IdentityMode.AppContext
                : IdentityMode.Unsupported;

        var roles = ValuesFor(claims, RoleClaimTypes).ToArray();
        var delegatedScopes = ValuesFor(claims, ScopeClaimTypes)
            .SelectMany(value => value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            .ToArray();
        var objectId = FirstNonEmptyValue(claims, ObjectIdClaimTypes);
        var correlation = applicationId is not null && objectId is not null
            ? new CallerIdentityCorrelation(applicationId, objectId)
            : null;
        var tenantId = FirstNonEmptyValue(claims, TenantIdClaimTypes);

        return new CallerIdentity(mode, roles, delegatedScopes, correlation, tenantId);
    }

    private static IEnumerable<string> ValuesFor(
        IEnumerable<Claim> claims,
        string[] claimTypeAliases) =>
        claims
            .Where(claim => IsAny(claim.Type, claimTypeAliases))
            .Select(claim => claim.Value);

    private static string? FirstNonEmptyValue(
        IEnumerable<Claim> claims,
        string[] claimTypeAliases) =>
        ValuesFor(claims, claimTypeAliases)
            .FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

    private static bool IsAny(string claimType, string[] candidates) =>
        candidates.Any(candidate =>
            string.Equals(claimType, candidate, StringComparison.OrdinalIgnoreCase));
}
