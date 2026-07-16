# Runbook: live-test gate prerequisites

Deploy-time prerequisites the gated live-test principal must hold BEFORE the
apply-call-destroy run, recorded here so they are provisioned up front rather
than discovered at the gate. This complements each module's own "Live-gate
prerequisites" section. Nothing here is applied by PR CI (which runs
`init -backend=false` only).

## Role-assignment write (RBAC bootstrap)

Some modules create role assignments as part of standing up their surface. ARM
requires the deploying principal to hold
`Microsoft.Authorization/roleAssignments/write` at the **scope of each
assignment** (for example the built-in **User Access Administrator** or
**Owner** role at that scope). The gated OIDC principal must therefore hold
role-assignment-write at these scopes before the run:

- **APIM instance** -- `api-center-registry` grants the API Center identity the
  **API Management Service Reader** role there so auto-sync can import APIs
  (`assign_apim_reader_role = true`, the default).
- **API Center instance** -- `api-center-registry` grants **Azure API Center
  Data Reader** there to each principal in `data_reader_principal_ids` (the poll
  principal) for authenticated data-plane read.

If the composition instead grants these roles out of band, set
`assign_apim_reader_role = false` and/or pass `data_reader_principal_ids = []`,
and the deploying principal does not need role-assignment-write.

Amendment recorded 2026-07-12 (ticket 4, PR #21) so ticket 5's integration run
does not fail at the gate on a missing grant.

## Function code deploy (issue 9, reopened)

The gate deploys the Functions MCP server (`src/McpTools`) between the s1 apply
and the s2 apply. Without deployed code the Flex Consumption host never
specialises, the MCP extension never registers its `mcp_extension` system key,
and both the McpTestClient assertions and the backend shadow-key arm are
unsatisfiable (the earlier "best-effort key or placeholder" path only ever
proved that an invalid key is rejected). The workflow now:

- builds the app once up front (`dotnet publish -c Release`, then zips the
  publish output with `host.json` at the zip root), and
- deploys it with `az functionapp deployment source config-zip --src <zip>`.

Command choice: Flex Consumption's supported deployment technology is "One
deploy". On a Flex app the `config-zip` CLI verb triggers One deploy (upload to
the module's managed-identity `deploymentpackage` container), NOT the legacy
Kudu `WEBSITE_RUN_FROM_PACKAGE` path the same verb uses on other plans. This is
the command Microsoft Learn documents for Flex
(`flex-consumption-how-to#deploy-your-code-project`, verified 2026-07-15). The
generic `az functionapp deploy` command is Preview and is not the Learn
documented Flex path, so it is not used here.

Because the `mcp_extension` key is registered at host specialisation (after the
deploy call returns, not at it), the call stage polls `systemKeys.mcp_extension`
(15s interval, 300s budget); budget exhaustion is fatal.

First-run Flex watch items (deploy-step configuration, not harness failures):
managed-identity deployment-storage auth errors and a "Failed to fetch host
key" error during deploy are reported for Flex apps with identity-based
deployment storage. These are community-reported (GitHub issues), not documented
Microsoft behaviour, so they are recorded here as risks to watch, not as settled
facts. Note also that Microsoft Learn specifies the deployment-storage identity
role as **Storage Blob Data Contributor**; the module grants **Storage Blob Data
Owner**, a strict superset, which satisfies the requirement.

The first two live runs (2026-07-16) both hit config-zip failing the Kudu
StorageAccessibleCheck with `InaccessibleStorageException` /
`MSITokenUnavailableException: Unable to fetch MSI token ... 400`. A 400 at the
MSI token fetch happens before any blob authorization check, so it is an
identity/token-availability problem, not role scope (the grant is a superset of
the documented role). A bounded retry over the full 600s window did NOT clear
it, which ruled out an RBAC-propagation race: the failure was structural. Root
cause: the app's SYSTEM-assigned identity was not usable on the Flex Kudu
one-deploy storage path. The AVM avm-res-web-site Flex example configures
deployment storage with a USER-assigned identity, so `mcp-function-host` now
does the same, and because this module is storage-key-free it also pins the
runtime `AzureWebJobsStorage` path to that same user-assigned identity
(`AzureWebJobsStorage__credential=managedidentity` + `__clientId`). The
user-assigned identity holds Storage Blob Data Owner on the storage account
(superset of the documented Storage Blob Data Contributor minimum). The deploy
step keeps a shorter bounded retry (30s backoff, 300s window, fatal on
exhaustion) purely as insurance for role-assignment propagation. The gate does
not fall back to storage-account keys (the account has
`shared_access_key_enabled = false`). If config-zip still exhausts on a future
run, triage via the portal "Flex Consumption Deployment" diagnostic.
