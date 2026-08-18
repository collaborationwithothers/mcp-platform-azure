namespace McpTools.Downstream;

/// <summary>
/// Exchanges a validated inbound user access token for a downstream token.
/// </summary>
public interface IOboTokenAcquirer
{
    Task<string> AcquireDownstreamTokenAsync(
        string userAssertion,
        string tenantId,
        string downstreamScope,
        CancellationToken cancellationToken);
}
