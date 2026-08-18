using McpTools.Identity;

namespace McpTools.Core;

/// <summary>
/// Receives the authorized caller immediately before get_order_status invokes
/// its downstream dependency. Hosts can use this seam for diagnostic audit
/// logging without moving logging dependencies into the application core.
/// </summary>
public interface IOrderStatusAuthorizationObserver
{
    void OnAuthorized(CallerIdentity caller);
}
