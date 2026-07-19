using Microsoft.Identity.Client;
using Microsoft.Identity.Web;

namespace McpTools.Downstream;

/// <summary>
/// Real, Azure-aware <see cref="IOboTokenAcquirer"/>. Not unit-tested (it
/// needs a live Entra token endpoint and a live managed identity); the thin,
/// Azure-facing shim, analogous to <see cref="McpTools.Tools.GetOrderStatus.Run"/>
/// over <c>Resolve</c>.
///
/// Authenticates the confidential client (the MCP server's own app
/// registration) with NO stored secret or certificate: it presents a client
/// assertion signed by the Function App's system-assigned managed identity,
/// which the app registration trusts via a federated identity credential
/// configured out of band (docs/runbooks/obo-app-registrations.md). This is
/// GA Entra workload identity federation, not preview (azure-docs-verifier,
/// 2026-07-18; see COMPATIBILITY.md). managedIdentityClientId is null: the
/// Function App has both a system-assigned identity (used here) and a
/// user-assigned identity (used for storage, see mcp-function-host/main.tf);
/// null selects the system-assigned one, matching the principal id the
/// mcp-function-host module's identity_principal_id output already exposes
/// for exactly this purpose.
/// </summary>
public sealed class ManagedIdentityOboTokenAcquirer : IOboTokenAcquirer
{
    private readonly IConfidentialClientApplication _confidentialClient;

    public ManagedIdentityOboTokenAcquirer(string serverAppClientId, string tenantId)
    {
        // Reused across calls so the signed assertion is cached until it
        // expires (Microsoft Learn: "Reuse this instance so that the
        // assertion is cached and only refreshed once it expires").
        var managedIdentityClientAssertion = new ManagedIdentityClientAssertion(managedIdentityClientId: null);

        _confidentialClient = ConfidentialClientApplicationBuilder
            .Create(serverAppClientId)
            .WithTenantId(tenantId)
            .WithClientAssertion((AssertionRequestOptions options) =>
                managedIdentityClientAssertion.GetSignedAssertionAsync(options))
            .Build();
    }

    public async Task<string> AcquireDownstreamTokenAsync(
        string userAssertion, string downstreamScope, CancellationToken cancellationToken)
    {
        var result = await _confidentialClient
            .AcquireTokenOnBehalfOf([downstreamScope], new UserAssertion(userAssertion))
            .ExecuteAsync(cancellationToken);

        return result.AccessToken;
    }
}
