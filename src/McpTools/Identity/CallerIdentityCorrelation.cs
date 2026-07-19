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

    public static CallerIdentityCorrelation FromPrincipal(ClientPrincipal principal)
    {
        var applicationId = principal.FirstValueFor(ApplicationIdClaimTypes);
        var objectId = principal.FirstValueFor(ObjectIdClaimTypes);
        if (applicationId is null || objectId is null)
        {
            throw new InvalidOperationException(
                "get_order_status: the validated caller principal must carry azp/appid and oid "
                + "claims so the call can be recorded with audit-grade identity correlation.");
        }

        return new(applicationId, objectId);
    }
}
