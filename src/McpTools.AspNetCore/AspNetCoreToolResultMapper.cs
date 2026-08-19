using System.Text.Json;
using McpTools.Core;
using ModelContextProtocol.Protocol;

namespace McpTools.AspNetCore;

internal static class AspNetCoreToolResultMapper
{
    internal static CallToolResult FromOutcome<T>(ToolOutcome<T> outcome, string toolName)
        where T : class
    {
        if (outcome.Error is not null)
        {
            return new CallToolResult
            {
                IsError = true,
                Content = [new TextContentBlock { Text = outcome.Error.Message }],
            };
        }

        return FromValue(
            outcome.Value
                ?? throw new InvalidOperationException(
                    $"{toolName}: the application core returned no result."));
    }

    internal static CallToolResult FromValue<T>(T value)
        where T : class
    {
        var structuredContent = JsonSerializer.SerializeToElement(value, value.GetType());
        return new CallToolResult
        {
            IsError = false,
            StructuredContent = structuredContent,
            Content = [new TextContentBlock { Text = structuredContent.GetRawText() }],
        };
    }
}
