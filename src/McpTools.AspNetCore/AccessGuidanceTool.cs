using System.ComponentModel;
using McpTools.Core;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace McpTools.AspNetCore;

[McpServerToolType]
internal sealed class AccessGuidanceTool(
    IHttpContextAccessor httpContextAccessor,
    McpToolApplication application)
{
    [McpServerTool(Name = McpToolContracts.GetAccessGuidanceName)]
    [Description(McpToolContracts.GetAccessGuidanceDescription)]
    public CallToolResult GetAccessGuidance()
    {
        var (_, caller) = AspNetCoreToolContext.Resolve(
            httpContextAccessor,
            McpToolContracts.GetAccessGuidanceName);
        return AspNetCoreToolResultMapper.FromValue(application.GetAccessGuidance(caller));
    }
}
