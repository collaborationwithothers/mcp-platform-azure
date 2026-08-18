using McpTools.Identity;

namespace McpTools.AspNetCore;

internal static class ServerEntitlementAuthorization
{
    internal static bool HasExistingServerEntitlement(CallerIdentity caller)
    {
        return caller.DelegatedScopes.Intersect(
                McpHostContract.DelegatedServerScopes,
                StringComparer.Ordinal).Any()
            || caller.Roles.Intersect(
                McpHostContract.ApplicationServerRoles,
                StringComparer.Ordinal).Any();
    }
}
