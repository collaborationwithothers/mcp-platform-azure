using McpTools.Core;
using ModelContextProtocol.Protocol;

namespace McpTools.Tools;

/// <summary>Maps host-neutral core outcomes onto the Functions MCP SDK result.</summary>
internal static class ToolOutcomeMapper
{
    public static object ToFunctionResult<T>(ToolOutcome<T> outcome)
        where T : class
    {
        if (outcome.Error is null)
        {
            return outcome.Value
                ?? throw new InvalidOperationException("The shared MCP application returned an empty success.");
        }

        return new CallToolResult
        {
            IsError = true,
            Content =
            [
                new TextContentBlock
                {
                    Text = outcome.Error.Message,
                },
            ],
        };
    }
}
