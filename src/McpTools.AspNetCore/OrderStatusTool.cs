using System.ComponentModel;
using McpTools.Core;
using McpTools.Identity;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace McpTools.AspNetCore;

[McpServerToolType]
internal sealed class OrderStatusTool(
    IHttpContextAccessor httpContextAccessor,
    McpToolApplication application)
{
    [McpServerTool(Name = McpToolContracts.GetOrderStatusName)]
    [Description(McpToolContracts.GetOrderStatusDescription)]
    public async Task<CallToolResult> GetOrderStatusAsync(
        [Description("The order id to look up, for example CONTOSO-1001.")] string orderId,
        CancellationToken cancellationToken)
    {
        var (httpContext, caller) = AspNetCoreToolContext.Resolve(
            httpContextAccessor,
            McpToolContracts.GetOrderStatusName);
        var inboundAccessToken = caller.Mode == IdentityMode.Delegated
            && DelegatedScopeAuthorization.HasScope(
                caller,
                DelegatedScopeAuthorization.GetOrderStatusScope)
            ? AspNetCoreToolContext.GetValidatedBearerToken(
                httpContext,
                McpToolContracts.GetOrderStatusName)
            : null;
        var outcome = await application.GetOrderStatusAsync(
            orderId,
            caller,
            inboundAccessToken,
            cancellationToken);

        return AspNetCoreToolResultMapper.FromOutcome(
            outcome,
            McpToolContracts.GetOrderStatusName);
    }
}
