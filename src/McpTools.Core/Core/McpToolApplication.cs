using McpTools.Downstream;
using McpTools.Fixtures;
using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Core;

/// <summary>
/// Host-neutral application rules shared by the Functions and ASP.NET Core
/// adapters.
/// </summary>
public sealed class McpToolApplication(IDownstreamOrdersClient downstreamOrdersClient)
{
    public async Task<ToolOutcome<OrderLookupResult>> GetOrderStatusAsync(
        string orderId,
        CallerIdentity caller,
        string? inboundAccessToken,
        CancellationToken cancellationToken)
    {
        return caller.Mode switch
        {
            IdentityMode.Delegated => await GetDelegatedOrderStatusAsync(
                orderId, caller, inboundAccessToken, cancellationToken),
            IdentityMode.AppContext => await GetApplicationOrderStatusAsync(
                orderId, caller, cancellationToken),
            _ => throw new InvalidOperationException(
                "get_order_status: no supported caller identity mode applies."),
        };
    }

    public ToolOutcome<ServiceInfo> GetServiceInfo(CallerIdentity caller)
    {
        EnsureCallerIsSupported(caller, McpToolContracts.GetServiceInfoName);

        if (!AppRoleAuthorization.HasRole(caller, AppRoleAuthorization.ServiceInfoRole))
        {
            return ToolOutcome<ServiceInfo>.Forbidden(
                "403 Forbidden: get_service_info requires the application role "
                + $"'{AppRoleAuthorization.ServiceInfoRole}'.");
        }

        return ToolOutcome<ServiceInfo>.Success(
            new ServiceInfo(
                McpToolContracts.ServiceInfoServerName,
                McpToolContracts.ServiceInfoTransport,
                McpToolContracts.ServiceInfoDataDisclaimer));
    }

    public AccessGuidance GetAccessGuidance(CallerIdentity caller)
    {
        EnsureCallerIsSupported(caller, McpToolContracts.GetAccessGuidanceName);

        return new AccessGuidance(
            McpToolContracts.AccessGuidanceSummary,
            McpToolContracts.RequiredEntitlements,
            McpToolContracts.AccessGuidanceDocsUrl,
            McpToolContracts.AccessGuidanceDataDisclaimer);
    }

    public static OrderLookupResult GetOrderStatusFromFixture(string orderId)
    {
        if (SyntheticOrders.All.TryGetValue(orderId, out var order))
        {
            return new OrderStatus(orderId, order.Status, order.UpdatedUtc);
        }

        return new OrderNotFound(
            orderId,
            Found: false,
            Message: $"No order was found for id '{orderId}'. Order data is synthetic "
                + "(known ids are CONTOSO-1001 to CONTOSO-1005).");
    }

    private async Task<ToolOutcome<OrderLookupResult>> GetDelegatedOrderStatusAsync(
        string orderId,
        CallerIdentity caller,
        string? inboundAccessToken,
        CancellationToken cancellationToken)
    {
        if (!DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope))
        {
            return ToolOutcome<OrderLookupResult>.Forbidden(
                "403 Forbidden: get_order_status requires the delegated scope "
                + $"'{DelegatedScopeAuthorization.GetOrderStatusScope}'.");
        }

        if (string.IsNullOrWhiteSpace(inboundAccessToken))
        {
            throw new InboundAccessTokenRequiredException();
        }

        var result = await downstreamOrdersClient.GetOrderStatusOnBehalfOfAsync(
            orderId,
            inboundAccessToken,
            caller.Correlation,
            cancellationToken);
        return ToolOutcome<OrderLookupResult>.Success(result);
    }

    private async Task<ToolOutcome<OrderLookupResult>> GetApplicationOrderStatusAsync(
        string orderId,
        CallerIdentity caller,
        CancellationToken cancellationToken)
    {
        if (!AppRoleAuthorization.HasOrdersRead(caller))
        {
            return ToolOutcome<OrderLookupResult>.Forbidden(
                "403 Forbidden: get_order_status requires the application role "
                + $"'{AppRoleAuthorization.RequiredRole}'.");
        }

        var correlation = caller.Correlation
            ?? throw new InvalidOperationException(
                "get_order_status: the validated caller principal must carry azp/appid and oid "
                + "claims so the call can be recorded with audit-grade identity correlation.");

        var result = await downstreamOrdersClient.GetOrderStatusAsApplicationAsync(
            orderId,
            correlation,
            cancellationToken);
        return ToolOutcome<OrderLookupResult>.Success(result);
    }

    private static void EnsureCallerIsSupported(CallerIdentity caller, string toolName)
    {
        if (caller.Mode is not (IdentityMode.Delegated or IdentityMode.AppContext))
        {
            throw new InvalidOperationException(
                $"{toolName}: no supported caller identity mode applies.");
        }
    }
}
