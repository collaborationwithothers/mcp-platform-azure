# Runbook: private MCP DNS

The migrated MCP server has one stable private name:
`mcp.internal.consultwithcloud.com`. Azure Private DNS owns the zone and makes
the name resolvable only from the platform and live-test runner virtual
networks. This foundation does not make the MCP endpoint public and does not
change APIM routing.

## Ownership

The `s1-aks-platform` Terraform composition owns these resources:

- Private DNS zone `internal.consultwithcloud.com`.
- A record `mcp`, pointing to the pinned Istio internal gateway address.
- A link to the platform VNet, with auto-registration disabled.
- A link to the existing GitHub Actions runner VNet, with auto-registration
  disabled.

The reusable `private-network` module does not own DNS. The runner VNet exists
outside that module, so the scenario composition is the first layer that can
join both networks to one zone.

Cloudflare must not contain an A or CNAME record for the private MCP hostname.
Cert-manager may create public `_acme-challenge` TXT records for DNS-01 proof.
A TXT challenge proves domain control. It does not publish a route to the
private gateway.

## Pre-apply checks

1. Hari confirms `AKS_PLATFORM_INGRESS_PRIVATE_IP` still matches the internal
   Istio gateway Service address.
2. Hari confirms `AKS_PLATFORM_RUNNER_VNET_ID` identifies the live-test runner
   VNet.
3. The later live-gate step confirms the configured Istio revision is installed
   before any companion namespace uses that revision label.
4. If the S1 AKS plan shows a delete or replace action for an existing
   placeholder or Argo CD resource, Hari stops the run.
5. Hari confirms the diff does not change the separate Function or APIM
   compositions. Those resources live in different Terraform states and cannot
   appear in the S1 AKS plan.

## Issue #154 live verification

The private DNS record only selects the ingress address. The live verification also proves the certificate, sidecar interception, protected-resource metadata, and authenticated MCP route. API Management remains on the Functions route.

1. If the ephemeral stack is ready, the workflow creates or updates the
   live-only `mcp-server-telemetry` Secret before Argo CD applies the MCP
   Deployment. The Secret contains the Application Insights component resource
   ID, not a connection string or credential.
2. The VNet runner resolves `mcp.internal.consultwithcloud.com`. The workflow
   records the address and requires the pinned internal gateway address.
3. The VNet runner validates the TLS certificate against exactly
   `mcp.internal.consultwithcloud.com`.
4. The VNet runner calls the protected-resource metadata document and an
   unauthenticated `/mcp` request. The metadata document returns 200 with
   resource `https://mcp.internal.consultwithcloud.com/mcp` and the existing
   `Orders.Invoke` and `Catalog.Invoke` delegated-scope union. The MCP request
   returns 401 with the exact advertised metadata URI.
5. The VNet runner calls `/mcp` with a valid application token. The response
   records HTTPS as the application-visible scheme and a loopback proxy peer.
6. The workflow inspects the MCP pod. The `istio-proxy` container and effective
   `REDIRECT` rules must both be present.
7. A public runner checks DNS only. If public DNS returns an A or CNAME for the
   private hostname, Hari stops the run.
8. Hari performs the delegated OBO call from a private-network client while the
   ephemeral downstream is still running. The automated gate cannot mint a
   delegated user token or a validly signed expired token.

Static Terraform tests prove the record and links. They do not prove live DNS
resolution, routing, certificate issuance, sidecar interception, or OBO.
