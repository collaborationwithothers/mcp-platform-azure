namespace McpTools.Downstream;

/// <summary>Acquires a downstream token for the MCP server's own application identity.</summary>
public interface IAppTokenAcquirer
{
    Task<string> AcquireDownstreamTokenForAppAsync(
        string downstreamScope, CancellationToken cancellationToken);
}
