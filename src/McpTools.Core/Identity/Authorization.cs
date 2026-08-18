namespace McpTools.Identity;

/// <summary>Application-role authorization at the tool boundary.</summary>
public static class AppRoleAuthorization
{
    public const string RequiredRole = "Orders.Read";
    public const string ServiceInfoRole = "ServiceInfo.Read";

    public static bool HasRole(CallerIdentity caller, string role) =>
        caller.Roles.Contains(role, StringComparer.Ordinal);

    public static bool HasOrdersRead(CallerIdentity caller) =>
        HasRole(caller, RequiredRole);
}

/// <summary>Delegated-scope authorization at the tool boundary.</summary>
public static class DelegatedScopeAuthorization
{
    public const string GetOrderStatusScope = "Orders.Read.AsUser";

    public static bool HasScope(CallerIdentity caller, string scope) =>
        caller.DelegatedScopes.Contains(scope, StringComparer.Ordinal);
}
