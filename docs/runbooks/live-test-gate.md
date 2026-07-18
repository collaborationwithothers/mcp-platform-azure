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

Three live runs (2026-07-16) hit config-zip failing the Kudu
StorageAccessibleCheck with `InaccessibleStorageException` /
`MSITokenUnavailableException: Unable to fetch MSI token ... 400`. The
diagnosis went through two wrong turns before the root cause, both recorded
here so the reasoning is not repeated:

1. A bounded retry over a 600s window did NOT clear it, ruling out an
   RBAC-propagation race: the failure was structural, not timing.
2. Switching deployment storage from a system-assigned to a user-assigned
   identity did NOT change the error at all (run 3 failed byte-for-byte the
   same). That ruled out the identity TYPE: the failure is identity-independent.

Root cause (verified against the `Microsoft.Web/sites` 2024-11-01 ARM schema,
`FunctionsDeploymentStorage.value`): the Flex `deployment.storage.value` must be
the blob CONTAINER URL (`https://<account>.blob.core.windows.net/<container>`),
but the module was passing `azurerm_storage_container.<...>.id`, which on
azurerm 4.x (container created with `storage_account_id`) is the ARM resource
id. A malformed storage value is identity-independent, which is exactly why
system- and user-assigned identities failed identically. The module now builds
the value from the account's blob endpoint (`storage_primary_blob_endpoint`).

Identity configuration retained from the (necessary but not sufficient)
investigation: deployment storage and the runtime `AzureWebJobsStorage` path are
both pinned to one user-assigned identity
(`storage_authentication_type = "UserAssignedIdentity"`,
`AzureWebJobsStorage__credential=managedidentity` + `__clientId`), which holds
Storage Blob Data Owner (superset of the documented Storage Blob Data
Contributor minimum). System-assigned would also be supported per Learn; the
user-assigned config matches the AVM Flex example and was kept to change only
the storage value on the fixing run. The deploy step keeps a bounded retry (30s
backoff, 300s window, fatal on exhaustion) as insurance for grant propagation.
The gate does not fall back to storage-account keys (the account has
`shared_access_key_enabled = false`). If config-zip still exhausts on a future
run, triage via the portal "Flex Consumption Deployment" diagnostic.

## Downstream Orders API deploy and tfvars (issue 10)

The gate now also deploys `src/DownstreamOrdersApi` to its own Flex
Consumption app (a second `mcp-function-host` instance from the same s1
apply), between the s1 apply/deploy and the s2 apply, using the identical
`config-zip` / bounded-retry pattern as the McpTools deploy step above (see
that section's root-cause history; the same identity-based deployment
storage mechanics apply to this instance).

Before the first live run that includes this deploy, the `S1_TFVARS_JSON`
live-test secret (docs/runbooks/entra-app-registrations.md's pattern) must
gain three new fields, sourced from
[obo-app-registrations.md](obo-app-registrations.md): `downstream_app`
(`{client_id, api_scope}`), `downstream_entra_auth` (same shape as
`entra_auth`, pointed at the downstream app registration), and
`downstream_storage_account_name`. Without these the s1 apply fails on a
missing required variable, not a subtle runtime issue -- `terraform plan`
surfaces it immediately.

**New Graph permission bootstrap (issue 10), beyond the ARM
`roleAssignments/write` above.** `s1-entra-mcp-server/main.tf` now also
configures the `azuread` provider (same OIDC identity) to manage the OBO
federated identity credential and consent grant, which needs the live-test
OIDC principal to hold Microsoft Graph `Application.ReadWrite.All` and
`Directory.ReadWrite.All` application permissions, admin-consented. This is
a ONE-TIME manual bootstrap (a principal cannot grant itself permissions);
see [obo-app-registrations.md](obo-app-registrations.md) section 2 for the
exact steps and a plain statement of the privilege trade-off involved.
Without this, the s1 apply fails on the `azuread_application_federated_identity_credential`
or `azuread_service_principal_delegated_permission_grant` resource with an
authorization error, not a missing-variable error.

The call stage additionally runs
`tests/integration/obo-passthrough-negative.ps1` (via
`scripts/gate/invoke-and-assert.ps1`'s new step [5]), reusing the
step-1 server-audience token as the inbound token presented directly to the
downstream. This proves token passthrough is rejected; it is NOT a test of
the OBO exchange succeeding. `GetOrderStatus.Run` DOES call the OBO
exchange in its live path (ADR-006, "OBO exchange: the inbound-token gap
and its correction"), but the automated gate still cannot exercise that
HAPPY path: no non-interactive mechanism exists to acquire a genuine
delegated user token in CI (same ADR, "Testing strategy: the user-context
token problem"). That path is validated manually.

**Not yet run against a live deployment.** This section, the new deploy
step, and the new tfvars fields are unverified by an actual live-test run as
of this PR (issue 10 does not carry authority to trigger one); the first
live run after this PR merges is where the config-zip deploy, the new
Terraform variables, and the negative test assertion get their first live
proof. If anything here does not match what the gate actually does, the fix
PR updates this runbook and COMPATIBILITY.md, per this file's own History
convention.

## Tracing the no-token WWW-Authenticate / PRM mechanism (issue 9)

The live gate's discovery assertion fails on one check: a no-token call to the
MCP endpoint returns a `WWW-Authenticate: Bearer resource_metadata="..."`
challenge whose URL is path-scoped under the API path
(`https://<gateway>/orders/.well-known/oauth-protected-resource`), where nothing
serves the PRM document (the `orders` MCP API swallows that path and 401s). The
apim-mcp-server policy interpolates the gateway-ROOT URL, and the root document
IS served and valid, so the deployed `type=mcp` runtime appears to rewrite the
`resource_metadata` value to a non-standard, path-appended shape. That shape
matches neither the MCP auth spec example (root) nor RFC 9728 section 3.1
(insert-before-path), and Microsoft Learn documents no native APIM MCP challenge
at all (azure-docs-verifier, 2026-07-16). The remaining unknown is the mechanism:
which policy or runtime step sets that header. This section is the one bounded
debug session that settles it.

### Keeping the stamp alive

Dispatch the gate with `skip_teardown = true`. The teardown steps are guarded by
`!inputs.skip_teardown`, so the stamp stays up even though the call stage fails
its assertion. The run summary prints a loud kept-alive notice with the resource
group name and the `az group delete` command. This is Basic v2 and bills
continuously: destroy it the SAME day. `az group delete -n rg-mcp-tracer-<run_id>
--yes`. The 4-hour expiry tag is only a backstop sweep.

### The trace flow (verified against Microsoft Learn, 2026-07-16)

Request tracing IS supported on Basic v2 ("All API Management tiers"; V2 gateways
list request tracing). But `Ocp-Apim-Trace: true` is deprecated; the current flow
needs a short-lived debug credential from the management plane
(api-management-howto-api-inspector). Against the kept-alive stamp:

1. Get a tracing token (Contributor or higher on the API; the live-test principal
   qualifies):

   ```bash
   az rest --method POST \
     --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/gateways/managed/listDebugCredentials?api-version=2023-05-01-preview" \
     --body '{"credentialsExpireAfter":"PT1H","apiId":"<full ARM id of the mcp-server API>","purposes":["tracing"]}' \
     --query token -o tsv
   ```

2. Send the NO-TOKEN request (no `Authorization` header, which is the case that
   produces the challenge) with the debug token, and read `Apim-Trace-Id`:

   ```bash
   curl -s -D - -o /dev/null -X POST \
     "https://<gateway>/orders/runtime/webhooks/mcp" \
     -H "Content-Type: application/json" \
     -H "Apim-Debug-Authorization: <token from step 1>" \
     --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
   # note the Apim-Trace-Id response header
   ```

3. Fetch the trace and read which policy/runtime step set `WWW-Authenticate`:

   ```bash
   az rest --method POST \
     --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ApiManagement/service/<apim>/gateways/managed/listTrace?api-version=2023-05-01-preview" \
     --body '{"traceId":"<Apim-Trace-Id>"}'
   ```

The portal test console Trace tab uses the same machinery and is fine for a quick
look, but it may auto-inject a subscription/auth; the curl flow above gives exact
control over the no-`Authorization` case. Two caveats, both UNVERIFIABLE on Learn
(azure-docs-verifier, 2026-07-16): tracing on a subscription-optional API
(`subscriptionRequired=false`) and the interactive debug-token flow on a
`type=mcp` API specifically are neither confirmed nor denied. So the first trace
attempt is itself a test; if it does not work, that is a finding, and we take
exit 2 below.

### Timebox and pre-committed exits

This is a tracer, not an APIM reverse-engineering project: ONE debug session
against the kept-alive stamp, with the exits decided in advance.

1. Trace shows a policy or runtime step we can OVERRIDE: do the root fix per
   ADR-006 (challenge points at the gateway-root PRM), with a policy comment
   naming the exact mechanism the trace revealed. Evidence-based, not a guess.
2. Trace shows the rewrite is INTERNAL to the `type=mcp` pipeline with no policy
   hook: do NOT adopt the non-spec path-appended shape into the design. Instead
   the discovery assertion changes to expect the observed platform behaviour,
   explicitly labelled as an undocumented platform observation; the root PRM
   document continues to be served; and COMPATIBILITY.md records the finding
   (platform emits an undocumented, non-spec path-appended `resource_metadata`
   challenge on `type=mcp` APIs, observed on this date and stamp, no Learn
   coverage, re-check each APIM release). Note alongside it that real clients
   worked regardless: McpTestClient completed a full initialize/list/call session,
   so the challenge shape did not break the SDK auth flow. Confirm the same for
   the interactive VS Code client in the demo.
3. Trace INCONCLUSIVE within the session: same as exit 2. An undocumented
   behaviour that is bounded and documented honestly beats an unbounded mechanism
   hunt with no floor.
