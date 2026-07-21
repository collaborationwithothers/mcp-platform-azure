using System.Diagnostics.CodeAnalysis;

namespace McpTools.Identity;

/// <summary>
/// Caller identity copied into structured logs and downstream correlation
/// headers. These values are audit context only and are never authorization
/// inputs at the downstream API.
/// </summary>
public sealed record CallerIdentityCorrelation(string ApplicationId, string ObjectId)
{
    public const string ApplicationIdHeader = "X-Mcp-Caller-Azp";
    public const string ObjectIdHeader = "X-Mcp-Caller-Oid";

    private static readonly string[] ApplicationIdClaimTypes =
    [
        "azp",
        "appid",
        "http://schemas.microsoft.com/identity/claims/azp",
        "http://schemas.microsoft.com/identity/claims/appid",
    ];

    private static readonly string[] ObjectIdClaimTypes =
    [
        "oid",
        "http://schemas.microsoft.com/identity/claims/objectidentifier",
    ];

    /// <summary>
    /// Best-effort extraction that never throws: returns false (and a null
    /// <paramref name="caller"/>) when azp/appid or oid is absent. Use this where
    /// correlation is audit-only and its absence must not fail the request (the
    /// delegated OBO path). The app-only path uses <see cref="FromPrincipal"/>,
    /// which fails closed.
    /// </summary>
    public static bool TryFromPrincipal(
        ClientPrincipal principal,
        [NotNullWhen(true)] out CallerIdentityCorrelation? caller)
    {
        var applicationId = principal.FirstValueFor(ApplicationIdClaimTypes);
        var objectId = principal.FirstValueFor(ObjectIdClaimTypes);
        if (applicationId is null || objectId is null)
        {
            caller = null;
            return false;
        }

        caller = new(applicationId, objectId);
        return true;
    }

    /// <summary>
    /// Fail-closed extraction: throws when azp/appid or oid is absent. Used on the
    /// app-only path, where the caller's application identity IS the authorization
    /// subject and its absence signals a request that did not traverse the
    /// expected trust chain.
    /// </summary>
    public static CallerIdentityCorrelation FromPrincipal(ClientPrincipal principal)
    {
        if (!TryFromPrincipal(principal, out var caller))
        {
            throw new InvalidOperationException(
                "get_order_status: the validated caller principal must carry azp/appid and oid "
                + "claims so the call can be recorded with audit-grade identity correlation.");
        }

        return caller;
    }
}
