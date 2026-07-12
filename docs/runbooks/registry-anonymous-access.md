# Runbook: enable anonymous read on the API Center registry (OPTIONAL, Copilot-only)

Status: **optional; not executed by this deployment.** The v1 tracer keeps the
authenticated default (see `docs/security.md`, Registry access). Follow this
runbook ONLY if you deliberately want the registry readable without an Entra
token, whose one known consumer is **GitHub Copilot's registry integration**.

There is no Terraform/ARM surface for this toggle in any published
`Microsoft.ApiCenter` API version (as of 2026-07-12), so it is a manual portal
step by design, not an omission from the `api-center-registry` module.

## Cost of enabling (read before doing this)

Anonymous read makes the registry inventory **publicly enumerable**: server
names, endpoint URLs, transport types, and tool descriptions become readable by
anyone with the endpoint URL and no authentication. Acceptable only for a
synthetic public demo whose registered metadata contains nothing sensitive
(`docs/security.md`). Do not enable it against a registry that lists real
internal servers.

## Portal steps

1. In the Azure portal, open the API Center instance.
2. In the sidebar, select **Consumption** > **Portal settings**.
3. On the **Access** tab, select **Allow anonymous access**.
4. Save. The data-plane registry endpoint
   (`https://<name>.data.<region>.azure-apicenter.ms/workspaces/default/v0.1/servers`)
   is now readable without a token.

To revert, return to the same tab and configure Microsoft Entra ID
authentication instead (the default posture).

Reference:
[Set up the API Center portal](https://learn.microsoft.com/azure/api-center/set-up-api-center-portal#configure-access-to-the-api-center-portal).

See also `docs/security.md` (Registry access) for the security posture this
runbook trades away.
