namespace McpTools.Identity;

/// <summary>
/// Delegated authorization enforced at the MCP tool boundary. It answers one
/// question: does this caller hold the named delegated scope?
///
/// Each tool names its own scope. The backend keeps this boundary separate from
/// the gateway map so a gateway configuration error cannot grant tool access.
/// </summary>
public static class DelegatedScopeAuthorization
{
    /// <summary>The delegated scope get_order_status requires.</summary>
    public const string GetOrderStatusScope = "Orders.Read.AsUser";

    // Easy Auth may emit the scope claim under its short name or under the
    // mapped schema URI, so both are accepted. This mirrors
    // IdentityModeResolver's claim-type aliases.
    private static readonly string[] ScopeClaimTypes =
    [
        "scp",
        "http://schemas.microsoft.com/identity/claims/scope",
    ];

    /// <summary>
    /// True when the caller carries the named delegated scope.
    ///
    /// Entra represents scopes as a space-separated list. Scope values use an
    /// ordinal comparison, so a differently cased or longer scope does not
    /// grant access.
    /// </summary>
    public static bool HasScope(ClientPrincipal principal, string scope) =>
        principal.ValuesFor(ScopeClaimTypes)
            .SelectMany(value => value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            .Contains(scope, StringComparer.Ordinal);
}
