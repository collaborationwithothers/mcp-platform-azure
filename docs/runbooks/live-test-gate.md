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

First live run (2026-07-16) hit exactly one of these: config-zip failed the
Kudu StorageAccessibleCheck with `InaccessibleStorageException` /
`MSITokenUnavailableException: Unable to fetch MSI token ... 400`. A 400 at the
MSI token fetch happens before any blob authorization check, so the cause is
identity/RBAC propagation timing, not role scope (the module already grants a
superset of the documented role). This exact pattern is community-reported for
Flex first deploys (Azure/functions-action#245, Azure/azure-functions-host
#10620), not Microsoft-documented; general Azure RBAC propagation is up to ~10
minutes. The deploy step therefore retries config-zip with a fixed 30s backoff
over a bounded 600s window and stays fatal on exhaustion. The gate does not fall
back to storage-account keys or switch to a user-assigned identity for this (no
evidence a user-assigned identity fixes this specific error, and the gate is
identity-only by design). If retries still exhaust on a future run, triage via
the portal "Flex Consumption Deployment" diagnostic rather than weakening the
deploy path.
