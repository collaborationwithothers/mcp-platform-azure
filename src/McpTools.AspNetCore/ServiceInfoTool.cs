using System.ComponentModel;
using McpTools.Core;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace McpTools.AspNetCore;

[McpServerToolType]
internal sealed class ServiceInfoTool(
    IHttpContextAccessor httpContextAccessor,
    McpToolApplication application)
{
    [McpServerTool(Name = McpToolContracts.GetServiceInfoName)]
    [Description(McpToolContracts.GetServiceInfoDescription)]
    public CallToolResult GetServiceInfo()
    {
        var (_, caller) = AspNetCoreToolContext.Resolve(
            httpContextAccessor,
            McpToolContracts.GetServiceInfoName);
        return AspNetCoreToolResultMapper.FromOutcome(
            application.GetServiceInfo(caller),
            McpToolContracts.GetServiceInfoName);
    }
}
