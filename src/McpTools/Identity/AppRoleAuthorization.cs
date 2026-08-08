namespace McpTools.Identity;

/// <summary>
/// App-only authorization enforced at the MCP tool boundary. It answers one
/// question: does this caller hold the named application role?
///
/// Each tool names its own role, so holding one role does not grant another.
/// That separation is the point: it is what makes per-tool authorization
/// provable rather than merely asserted (issue 76).
/// </summary>
public static class AppRoleAuthorization
{
    /// <summary>
    /// The role get_order_status requires. Deliberately NOT renamed to something
    /// tool-prefixed: GetOrderStatus renders this exact string into the 403
    /// message a caller sees, so renaming it would change a public error message.
    /// </summary>
    public const string RequiredRole = "Orders.Read";

    /// <summary>The role get_service_info requires (issue 79).</summary>
    public const string ServiceInfoRole = "ServiceInfo.Read";

    // Easy Auth may emit the role claim under its short name or under the mapped
    // schema URI, so both are accepted. Same reasoning as IdentityModeResolver's
    // claim-type aliases; see that file for the verification note.
    private static readonly string[] RoleClaimTypes =
    [
        "roles",
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
    ];

    /// <summary>
    /// True when the caller carries the named application role.
    ///
    /// Role comparison is ORDINAL, so "serviceinfo.read" does not match
    /// "ServiceInfo.Read". Entra issues role values with the casing configured on
    /// the app registration, and an authorization check that quietly case-folds
    /// would widen the set of accepted values beyond what was configured.
    /// Claim-TYPE matching stays case-insensitive (see ClientPrincipal.ValuesFor)
    /// because a claim type is a well-known identifier, not a granted value.
    /// </summary>
    public static bool HasRole(ClientPrincipal principal, string role) =>
        principal.ValuesFor(RoleClaimTypes).Contains(role, StringComparer.Ordinal);

    /// <summary>
    /// True when the caller carries Orders.Read. Behaviour is unchanged by the
    /// issue-79 refactor; this is now a named shorthand for the general check.
    /// </summary>
    public static bool HasOrdersRead(ClientPrincipal principal) =>
        HasRole(principal, RequiredRole);
}
