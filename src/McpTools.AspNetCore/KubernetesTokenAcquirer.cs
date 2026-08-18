using System.Collections.Concurrent;
using McpTools.Downstream;
using Microsoft.Identity.Client;
using Microsoft.Identity.Web;

namespace McpTools.AspNetCore;

/// <summary>
/// Uses the AKS projected service-account token as the server app credential.
/// One provider instance is reused so its assertion cache survives requests.
/// </summary>
internal sealed class KubernetesTokenAcquirer : IOboTokenAcquirer, IAppTokenAcquirer
{
    private readonly ConcurrentDictionary<string, IConfidentialClientApplication> _clients =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly AzureIdentityForKubernetesClientAssertion _clientAssertion = new();
    private readonly string _serverAppClientId;
    private readonly string _serverTenantId;

    internal KubernetesTokenAcquirer(string serverAppClientId, string serverTenantId)
    {
        _serverAppClientId = serverAppClientId;
        _serverTenantId = serverTenantId;
    }

    public async Task<string> AcquireDownstreamTokenAsync(
        string userAssertion,
        string tenantId,
        string downstreamScope,
        CancellationToken cancellationToken)
    {
        var result = await ClientForTenant(tenantId)
            .AcquireTokenOnBehalfOf([downstreamScope], new UserAssertion(userAssertion))
            .ExecuteAsync(cancellationToken);

        return result.AccessToken;
    }

    public async Task<string> AcquireDownstreamTokenForAppAsync(
        string downstreamScope,
        CancellationToken cancellationToken)
    {
        var result = await ClientForTenant(_serverTenantId)
            .AcquireTokenForClient([downstreamScope])
            .ExecuteAsync(cancellationToken);

        return result.AccessToken;
    }

    private IConfidentialClientApplication ClientForTenant(string tenantId)
    {
        if (string.IsNullOrWhiteSpace(tenantId))
        {
            throw new ArgumentException("A tenant id is required for token acquisition.", nameof(tenantId));
        }

        return _clients.GetOrAdd(
            tenantId,
            static (requestedTenantId, state) => ConfidentialClientApplicationBuilder
                .Create(state.ClientId)
                .WithTenantId(requestedTenantId)
                .WithClientAssertion((AssertionRequestOptions options) =>
                    state.Assertion.GetSignedAssertionAsync(options))
                .Build(),
            (ClientId: _serverAppClientId, Assertion: _clientAssertion));
    }
}
