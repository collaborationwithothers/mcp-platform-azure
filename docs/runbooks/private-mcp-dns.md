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

## Resolution checks after the deferred live apply

Issue #149 does not run these checks. The later live-gate step must record the
results from both linked networks.

1. From an AKS pod in the platform VNet, resolve
   `mcp.internal.consultwithcloud.com` and record the returned address.
2. From the VNet runner, resolve the same name and record the returned address.
3. In both results, confirm the address equals the pinned internal gateway
   address.
4. From a public runner, confirm the hostname does not resolve to a public A or
   CNAME record.
5. Confirm the MCP TLS certificate is valid for the private hostname only after
   the companion Certificate and Gateway exist.

Static Terraform tests prove the record and link configuration. They cannot
prove live DNS resolution, routing, or certificate issuance.
