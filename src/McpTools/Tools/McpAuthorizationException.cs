namespace McpTools.Tools;

/// <summary>A deterministic MCP tool error for an authenticated but unauthorized caller.</summary>
public sealed class McpAuthorizationException(string message) : InvalidOperationException(message)
{
    public int StatusCode => 403;
}
