namespace McpTools.Identity;

/// <summary>
/// Resolves a request's caller identity into an <see cref="IdentityMode"/> from
/// the built-in-auth-injected X-MS-CLIENT-PRINCIPAL header. This adapter owns header
/// lookup and decoding. The shared core owns the claim-to-mode decision.
///
/// The decision is claims-based authorization on a header built-in auth has already
/// validated; this code does NOT re-validate the token's signature (that is
/// built-in auth's job -- see docs/security.md, "trust chain"). The per-request
/// rejection of a missing principal is only sound in production because the
/// startup <c>BuiltInAuthGuard</c> asserts built-in auth is enabled, and enabled
/// built-in auth strips client-supplied X-MS-* headers before injecting its own.
///
/// Claim-type matching accepts both the short claim name and the mapped schema
/// URI, because built-in auth applies a claims mapping and Microsoft Learn does not
/// document whether scp/roles survive unmapped inside X-MS-CLIENT-PRINCIPAL
/// (verifier 2026-07-18: UNVERIFIABLE on Learn; the tid->schema-URI example
/// proves mapping happens). Matching both forms avoids coding an unverified
/// assumption as fact; the live trace confirms which form appears
/// (COMPATIBILITY.md; MEMORY debugging-platform-behavior-style).
/// </summary>
public static class IdentityModeResolver
{
    public static IdentityMode Resolve(IReadOnlyDictionary<string, string> headers) =>
        ResolveWithPrincipal(headers).Mode;

    public static IdentityResolution ResolveWithPrincipal(IReadOnlyDictionary<string, string> headers)
    {
        if (!HeaderLookup.TryGet(headers, ClientPrincipal.HeaderName, out var raw) || string.IsNullOrWhiteSpace(raw))
        {
            return new(IdentityMode.MissingPrincipal, null);
        }

        if (!ClientPrincipal.TryParse(raw, out var principal))
        {
            return new(IdentityMode.MalformedPrincipal, null);
        }

        var caller = CallerIdentityResolver.Resolve(principal!.ToClaimsPrincipal());
        return new(caller.Mode, principal, caller);
    }
}

/// <summary>The built-in auth parse result plus the normalized shared-core caller.</summary>
public sealed record IdentityResolution(
    IdentityMode Mode,
    ClientPrincipal? Principal,
    CallerIdentity? Caller = null);
