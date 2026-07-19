namespace McpTools.Downstream;

/// <summary>
/// Exchanges an inbound delegated user token for a downstream-audience token
/// via the Entra On-Behalf-Of flow. Abstracted so <see cref="DownstreamOrdersClient"/>
/// is unit-testable with no Azure dependency (spec: Testing Decisions, "unit
/// seam"); <see cref="ManagedIdentityOboTokenAcquirer"/> is the real,
/// Azure-aware implementation.
/// </summary>
public interface IOboTokenAcquirer
{
    /// <summary>
    /// Returns an access token for <paramref name="downstreamScope"/>, minted
    /// by exchanging <paramref name="userAssertion"/> (the caller's inbound
    /// access token) via OBO. Never returns <paramref name="userAssertion"/>
    /// itself: the whole point of OBO is that the downstream never sees the
    /// inbound token (docs/decisions/ADR-006, token passthrough is forbidden).
    /// </summary>
    Task<string> AcquireDownstreamTokenAsync(
        string userAssertion, string downstreamScope, CancellationToken cancellationToken);
}
