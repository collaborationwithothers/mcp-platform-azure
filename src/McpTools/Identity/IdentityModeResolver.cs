namespace McpTools.Identity;

/// <summary>
/// The outcome of resolving a request's caller identity into the data-source
/// mode get_order_status must use (issue 10 amended acceptance). The two
/// serving modes (<see cref="Delegated"/>, <see cref="AppContext"/>) and the
/// three unservable outcomes are one closed set so the tool can switch on it
/// exhaustively.
/// </summary>
public enum IdentityMode
{
    /// <summary>
    /// A user-context (delegated) caller: the principal carries an OAuth scope
    /// (scp) claim. Sourced from the synthetic downstream Orders API via the
    /// OBO exchange (the caller's inbound token is the OBO user assertion).
    /// </summary>
    Delegated,

    /// <summary>
    /// An app-context (client-credentials, app-only) caller: the principal
    /// carries a roles (app-role) claim and no scp claim. Served from the
    /// in-memory fixture as a documented interim until the workload-identity
    /// hardening issue -- an app-only token has no user to act on behalf of,
    /// so it cannot drive an OBO exchange. The live gate's client-credentials
    /// happy path exercises exactly this branch.
    /// </summary>
    AppContext,

    /// <summary>The X-MS-CLIENT-PRINCIPAL header was absent (fail-closed reject).</summary>
    MissingPrincipal,

    /// <summary>The header was present but not decodable/parseable (fail-closed reject).</summary>
    MalformedPrincipal,

    /// <summary>A valid principal carrying neither an scp nor a roles claim (fail-closed reject).</summary>
    Unsupported,
}

/// <summary>
/// Resolves a request's caller identity into an <see cref="IdentityMode"/> from
/// the Easy-Auth-injected X-MS-CLIENT-PRINCIPAL header alone. This is the one
/// place the delegated-vs-app-context decision is made, kept out of the tool so
/// it is unit-testable in isolation (spec: Testing Decisions, "unit seam").
///
/// The decision is claims-based authorization on a header Easy Auth has already
/// validated; this code does NOT re-validate the token's signature (that is
/// Easy Auth's job -- see docs/security.md, "trust chain"). The per-request
/// rejection of a missing principal is only sound in production because the
/// startup <c>BuiltInAuthGuard</c> asserts Easy Auth is enabled, and enabled
/// Easy Auth strips client-supplied X-MS-* headers before injecting its own.
///
/// Claim-type matching accepts both the short claim name and the mapped schema
/// URI, because Easy Auth applies a claims mapping and Microsoft Learn does not
/// document whether scp/roles survive unmapped inside X-MS-CLIENT-PRINCIPAL
/// (verifier 2026-07-18: UNVERIFIABLE on Learn; the tid->schema-URI example
/// proves mapping happens). Matching both forms avoids coding an unverified
/// assumption as fact; the live trace confirms which form appears
/// (COMPATIBILITY.md; MEMORY debugging-platform-behavior-style).
/// </summary>
public static class IdentityModeResolver
{
    // Delegated tokens carry the OAuth scope claim; app-only tokens do not.
    private static readonly string[] ScopeClaimTypes =
        ["scp", "http://schemas.microsoft.com/identity/claims/scope"];

    // Client-credentials (app-only) tokens carry app-role claims in place of scopes.
    private static readonly string[] RoleClaimTypes =
        ["roles", "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"];

    public static IdentityMode Resolve(IReadOnlyDictionary<string, string> headers)
    {
        if (!HeaderLookup.TryGet(headers, ClientPrincipal.HeaderName, out var raw) || string.IsNullOrWhiteSpace(raw))
        {
            return IdentityMode.MissingPrincipal;
        }

        if (!ClientPrincipal.TryParse(raw, out var principal))
        {
            return IdentityMode.MalformedPrincipal;
        }

        if (principal!.Claims.Any(c => IsAny(c.Typ, ScopeClaimTypes)))
        {
            return IdentityMode.Delegated;
        }

        if (principal.Claims.Any(c => IsAny(c.Typ, RoleClaimTypes)))
        {
            return IdentityMode.AppContext;
        }

        return IdentityMode.Unsupported;
    }

    private static bool IsAny(string claimType, string[] candidates) =>
        candidates.Any(candidate => string.Equals(claimType, candidate, StringComparison.OrdinalIgnoreCase));
}
