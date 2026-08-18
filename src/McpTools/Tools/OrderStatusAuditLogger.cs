using McpTools.Core;
using McpTools.Identity;
using Microsoft.Extensions.Logging;

namespace McpTools.Tools;

/// <summary>
/// Writes the diagnostic caller audit event after core authorization succeeds
/// and before the downstream call starts.
/// </summary>
internal sealed class OrderStatusAuditLogger(ILogger<GetOrderStatus> logger)
    : IOrderStatusAuthorizationObserver
{
    public void OnAuthorized(CallerIdentity caller)
    {
        if (caller.Correlation is not null)
        {
            logger.LogInformation(
                "get_order_status authorized caller. CallerApplicationId={CallerApplicationId} "
                + "CallerObjectId={CallerObjectId} IdentityMode={IdentityMode}",
                caller.Correlation.ApplicationId,
                caller.Correlation.ObjectId,
                caller.Mode);
            return;
        }

        logger.LogWarning(
            "get_order_status: the delegated caller principal did not carry azp/appid and "
            + "oid claims; proceeding without caller correlation headers (audit context only, "
            + "not an authorization input).");
    }
}
