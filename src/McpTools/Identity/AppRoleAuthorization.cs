namespace McpTools.Identity;

/// <summary>App-only authorization enforced at the MCP tool boundary.</summary>
public static class AppRoleAuthorization
{
    public const string RequiredRole = "Orders.Read";

    private static readonly string[] RoleClaimTypes =
    [
        "roles",
        "http://schemas.microsoft.com/ws/2008/06/identity/claims/role",
    ];

    public static bool HasOrdersRead(ClientPrincipal principal) =>
        principal.ValuesFor(RoleClaimTypes).Contains(RequiredRole, StringComparer.Ordinal);
}
