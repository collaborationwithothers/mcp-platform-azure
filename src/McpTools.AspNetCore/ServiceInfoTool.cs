using System.ComponentModel;
using System.Text.Json;
using McpTools.Core;
using McpTools.Identity;
using McpTools.Tools;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace McpTools.AspNetCore;

[McpServerToolType]
internal sealed class ServiceInfoTool
{
    private readonly IHttpContextAccessor _httpContextAccessor;
    private readonly McpToolApplication _application;

    public ServiceInfoTool(
        IHttpContextAccessor httpContextAccessor,
        McpToolApplication application)
    {
        _httpContextAccessor = httpContextAccessor;
        _application = application;
    }

    [McpServerTool(Name = McpToolContracts.GetServiceInfoName)]
    [Description(McpToolContracts.GetServiceInfoDescription)]
    public CallToolResult GetServiceInfo()
    {
        var principal = _httpContextAccessor.HttpContext?.User
            ?? throw new InvalidOperationException(
                "get_service_info: no authenticated HTTP caller is available.");
        var caller = CallerIdentityResolver.Resolve(principal);
        var outcome = _application.GetServiceInfo(caller);

        if (outcome.Error is not null)
        {
            return new CallToolResult
            {
                IsError = true,
                Content = [new TextContentBlock { Text = outcome.Error.Message }],
            };
        }

        var value = outcome.Value
            ?? throw new InvalidOperationException(
                "get_service_info: the application core returned no result.");
        var structuredContent = JsonSerializer.SerializeToElement(value);

        return new CallToolResult
        {
            IsError = false,
            StructuredContent = structuredContent,
            Content = [new TextContentBlock { Text = structuredContent.GetRawText() }],
        };
    }
}
