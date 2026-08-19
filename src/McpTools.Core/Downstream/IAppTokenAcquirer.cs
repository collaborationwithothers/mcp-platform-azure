namespace McpTools.Downstream;

/// <summary>Acquires a downstream token for the server application identity.</summary>
public interface IAppTokenAcquirer
{
    Task<string> AcquireDownstreamTokenForAppAsync(
        string downstreamScope,
        CancellationToken cancellationToken);
}
