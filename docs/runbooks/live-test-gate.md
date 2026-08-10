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

## Registry convergence (issue 9): forced, then asserted (Option Y)

APIM -> API Center auto-sync is documented at **up to 24 hours**, so an ephemeral
apply->call->destroy gate cannot wait it out, and there is no automatable way to
register an MCP server at the data-plane `/v0.1/servers` endpoint (which is also
portal-auth-only: it 401s a bearer token). So the gate makes convergence
**deterministic** (see `docs/decisions/ADR-007`) instead of waiting on sync:

- **Force convergence.** The workflow step "Force registry convergence
  (import-from-apim, Option Y)" runs `az apic import-from-apim` for the MCP server
  API after the s2 apply. It is a synchronous, idempotent LRO (~34 s) that lands
  the server in the API Center inventory and coexists with the active auto-sync
  link -- no duplicate/conflict (all verified live 2026-07-21). It installs the
  `apic-extension` and fails the step loudly on any import error.
- **Assert convergence.** Gate step `[5]` reads the **control-plane `apis`
  inventory** (`management.azure.com`, `2024-06-01-preview`, the call stage's
  `az` credential) and ASSERTS an entry with `title == server_name && kind ==
  "mcp"`. FATAL if absent (a short `PollTimeoutSeconds` retry, default 90 s,
  covers residual projection lag -- not an eventual wait). It also probes
  `/v0.1/servers` anonymously (records the secure-by-default 401 posture) and
  captures the raw inventory to `gate-evidence/registry-apis-inventory.json`.

The `kind=mcp` match works because the live `2024-06-01-preview` control-plane
`apis` API returns the synced/imported MCP server with `kind=mcp`, even though the
documented enum omits `mcp` (the live API is ahead of its docs; the entry's own
`name` is auto-generated, so match on `title`+`kind`, not `name`).

If step `[5]` fails: the import step's log shows whether `import-from-apim`
succeeded; a green import + a red assertion points at an `apis` api-version/shape
change; a red import points at the `apic-extension` (the command is renamed to
`az apic import apim` in the 1.2.0b3 beta -- a clean break to fix when it ships
stable). An earlier two-tier design (non-blocking evidence + an async monitor) was
superseded once the import spike proved forced synchronous convergence; see
ADR-007's Alternatives.

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
(`{client_id, api_scope, application_scope}`), `downstream_entra_auth` (same shape as
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

The same apply assigns the downstream app's `Orders.Read` application role to
the MCP server service principal and configures downstream Easy Auth with
`allowedApplications = [<server-app-client-id>]`. This makes the MCP server the
only application identity the downstream accepts. The server acquires a
downstream `/.default` token as itself for app-only callers; it never forwards
the caller token.

The `live-test` GitHub Environment also needs
`TEST_CLIENT_WITHOUT_ROLE_ID` and `TEST_CLIENT_WITHOUT_ROLE_SECRET` for a
second confidential client. That client has no `Orders.Read` assignment but is
listed in the APIM policy's allowed client ids, as described in
[entra-app-registrations.md](entra-app-registrations.md) section 3.

The call stage additionally runs
`tests/integration/obo-passthrough-negative.ps1` (via
`scripts/gate/invoke-and-assert.ps1`'s step [6]), reusing the
step-1 server-audience token as the inbound token presented directly to the
downstream. This proves token passthrough is rejected; it is NOT a test of
the OBO exchange succeeding. `GetOrderStatus.Run` DOES call the OBO
exchange in its live path (ADR-006, "OBO exchange: the inbound-token gap
and its correction"), but the automated gate still cannot exercise that
HAPPY path: no non-interactive mechanism exists to acquire a genuine
delegated user token in CI (same ADR, "Testing strategy: the user-context
token problem"). That path is validated manually. The automated app-context
coverage is now complete: step [2] proves a caller with `Orders.Read` reaches
the downstream through the MCP server's own identity, and step [3] proves an
otherwise valid caller without that role gets the deterministic tool-level 403
response.

The issue-10 downstream deploy and OBO path were exercised in live run
29681694550 on 2026-07-19. The issue-45 app-only role enforcement, server-only
downstream authorization policy, and positive/negative gate arms remain
unverified until this PR receives its gated live test. If the observed behavior
differs, update this runbook and COMPATIBILITY.md with the measured result.

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

## Resource-level diagnostic settings (issue 75)

Before the first issue 75 live test, complete
`docs/runbooks/observability-bootstrap.md`. Hari must create
`TF_VAR_shared_observability_application_insights_id` as a `live-test`
Environment variable before dispatch. The workflow supplies it at job scope, so
both scenario applies and both destroys receive the same required input.

The gated principal must be authorized to create diagnostic settings on every
target resource. This includes an existing caller-supplied storage account. The
storage module collects the account and its Blob, File, Queue, and Table service
scopes, so permission must cover the account-level and service-scope settings.
This is broader than the `deploymentpackage` container.

The existing S1 apply and S2 apply are the configuration proof for the 16
supported settings. Do not add a telemetry-ingestion assertion or wait for logs
to arrive.
Azure documents that resource logs are not collected by default and that
diagnostic settings route resource logs and platform metrics to destinations.
See [Diagnostic settings in Azure
Monitor](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings).

If the gated apply rejects a `Dedicated` destination, preserve the failure
evidence. Change only the proved target to `AzureDiagnostics`, then rerun the
same existing apply-call-destroy gate. If category discovery returns no logs or
metrics, stop and report the failure. API Center remains the APIM-linked
registry, but gated run 31162622718 proved Azure Monitor diagnostic settings
are unsupported there. Do not add an API Center query, setting, fallback, or
capability registry.

The issue 18 per-tool deny audit path is unchanged. The existing call and both
destroy stages must remain green. A successful apply proves Azure accepted the
diagnostic configuration. It does not measure ingestion or cost; perform that
separately using `docs/cost.md` after deployment.

## Cross-tool authorization differentiation (issue 80)

Before the first issue 80 live run, three prerequisites beyond the standard
apply-call-destroy setup must be in place; none of them can be done by an
agent:

1. The server app registration (section 1 of
   [entra-app-registrations.md](entra-app-registrations.md)) must carry the
   application app role `ServiceInfo.Read`.
2. The cross-tool differentiation client
   ([entra-app-registrations.md](entra-app-registrations.md) section 3b)
   must exist, hold `Orders.Invoke.All`, `Catalog.Invoke.All`, and
   `ServiceInfo.Read` (and NOT `Orders.Read`), and be added to
   `entra_validation.allowed_client_application_ids`. Its id and secret must be
   stored as the `live-test` GitHub Environment secrets
   `TEST_CLIENT_MCP_SERVICE_TOOL_ID` and `TEST_CLIENT_MCP_SERVICE_TOOL_SECRET`.
3. `get_service_info` must be added to BOTH `tool_authorization_map` and
   `server_2_tool_authorization_map` in the `S2_TFVARS_JSON` GitHub
   Environment secret, mapped to `{"role": "ServiceInfo.Read"}` (see
   [live-test-tfvars-reference.md](live-test-tfvars-reference.md)). Until this
   is done, check [9]-a (the tools/list-vs-map set-equality assertion) fails
   for every stamp, because the backend has exposed `get_service_info` since
   issue #79 regardless of whether the map has caught up.

With all three in place, check [9] gains three new assertions, (e)/(f)/(g), in
`tests/integration/discovery-assertions.ps1`'s `Assert-ToolAuthorization`: (e)
the positive test client (section 2) is denied `get_service_info`; (f) the
cross-tool differentiation client succeeds on `get_service_info`; (g) that same
client is denied `get_order_status`. On server 1 these three checks are
gating; on server 2 they are `WarnOnly`, matching (a) through (d). If any of
the three prerequisites above is missing, the two new gate secrets
(`TEST_CLIENT_MCP_SERVICE_TOOL_ID`/`_SECRET`) resolve empty and checks
(e)/(f)/(g) are skipped with a `::warning::` rather than failed -- this proves
nothing was set up, not that per-tool authorization is broken.

## The unrestricted branch (issue 82)

Issue 82 adds a fourth prerequisite to the three above. It has the same shape as
item 3, and it is the only setup issue 82 needs:

4. `get_access_guidance` must be added to BOTH `tool_authorization_map` and
   `server_2_tool_authorization_map` in the `S2_TFVARS_JSON` GitHub Environment
   secret, as `{"unrestricted": true}` (see
   [live-test-tfvars-reference.md](live-test-tfvars-reference.md)). Until this
   is done, check [9]-a (the tools/list-vs-map set-equality assertion) fails for
   every stamp, because the backend exposes the tool the moment this branch's
   code deploys, whether or not the map has caught up.

**Update the secret immediately before the branch's gate run, not days ahead.**
The map key and the tool cannot land together: the key lives in a secret, the
tool lives in the repository, and no PR can change the secret. Add the key early
and set-equality fails the other way in the meantime, on any gate run against
`main`, with a map key that has no matching tool. That window closes when this
PR merges. Issue 79 had the same window. Keeping it to minutes is the whole
mitigation; no ordering of the two steps avoids it (see
[live-test-tfvars-reference.md](live-test-tfvars-reference.md), "Deployment
coupling").

With the fourth prerequisite in place, check [9] gains one more assertion, (h):
the under-entitled client of
[entra-app-registrations.md](entra-app-registrations.md) **section 3** (not 3b)
calls `get_access_guidance` and must get a real result rather than a `-32001`.
Checks (b), (d), (e), (f), and (g) exercise the map's `role` branch, and (c)
exercises its default-deny path for a name absent from the map; (h) is the only
check that reaches the `unrestricted` branch.

Unlike (e)/(f)/(g), check (h) runs on server 1 only. The under-entitled client
holds `Orders.Invoke.All` and nothing for server 2, so at server 2 its token is
refused at the per-server check one layer before the per-tool map is consulted.
A success assertion there could never pass, and running it `WarnOnly` would
print a permanent warning that says nothing. The check is guarded on
`-not $WarnOnly` for that reason, so the absence of a server 2 result is
deliberate, not an oversight.

**Issue 82 needs no new Entra object.** No new app registration, no new client
secret, no new app role, no new grant, and no new entry in
`entra_validation.allowed_client_application_ids`. Check (h) reuses the
under-entitled client the gate already uses for check [9]-d, which is already in
that list and whose token the gate already acquires. One inference follows, and
it is an inference rather than a result: issue 45's step [3] drives that same
client's token directly at the backend and gets the backend's own tool-level
403, which means the client already clears the backend's Easy Auth, so check
(h)'s backend leg is expected to work. The 2026-08-09 run
([31314241913](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31314241913))
settled it: check (h) passed, so no new Entra object was needed and the
inference held.

## The id-validity guard (issue 88)

**Issue 88 needs no new prerequisite at all.** No new Entra object, no new
client, no new map key, and no `S2_TFVARS_JSON` edit. Check (i) reuses the
entitled client and the two tool names the gate already has, so unlike issues
79, 80, and 82 there is no secret-versus-repository ordering window to manage.

Check (i) asserts the gateway rejects a `tools/call` whose JSON-RPC `id` is
missing or `null`. MCP 2025-06-18 forbids a null `id` on a request, and before
this fix the gateway echoed the caller's `id` verbatim on its `-32001` deny
path, so both shapes produced `"id":null` on the wire. Run
[31381168415](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31381168415)
captured that pre-fix behaviour; run
[31387242227](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31387242227)
verified the fix. Expected now: HTTP 400, a JSON-RPC error object with code
`-32600`, and no `id` key at all.

The check sends four probes, and which tool each one names is the point, not an
incidental detail:

1. No `id` field, naming the unmapped probe tool. Asserted.
2. `"id": null`, naming the unmapped probe tool. Asserted.
3. No `id` field, naming `get_access_guidance` (the `unrestricted` tool from
   issue 82). Asserted, and it is the only probe that proves anything about
   WHERE the guard sits. Probes 1 and 2 name a tool the map denies anyway, so an
   implementation that validated the `id` only inside the `-32001` deny branch
   would answer them with a 400 too and pass identically. Probe 3 names a tool
   the authorization decision ALLOWS, so a 400 there can only come from a check
   that runs before, and independently of, that decision. That placement is the
   load-bearing claim of the whole change, and this probe is the only thing
   testing it.
4. Deliberately malformed JSON. Recorded, never asserted. It does not reach the
   `tools/call` branch at all: the policy's request-body parse runs
   unconditionally for every method and fails first, so this returns APIM's
   generic HTTP 500 with no JSON-RPC envelope. Known, out of scope for issue 88,
   and captured only so the next reader does not have to rediscover it.

All four write verbatim status, headers, and body to
`gate-evidence/null-id-deny-path-evidence.md`, uploaded as the
`prm-discovery-evidence` artifact.

Unlike the `-32001` deny, this rejection emits NO audit event, so there is
nothing to read back from the Event Hub and check (i) makes no
`Assert-AuditEventEmitted` call. That is deliberate: it is a request-validity
rejection, and no authorization decision happened to record. It is also not a
visibility loss, because the guard never reads the tool name and its response
body is a fixed string, so every id-less `tools/call` gets byte-identical bytes
back whatever tool it names. An id-less probe therefore reveals nothing about
which tools exist or which the caller may call; enumeration needs a well-formed
`id`, and those requests reach the authorization check and emit its audit event
as before. Full reasoning at the guard in `mcp-server.xml`.

One consequence for anyone extending this check: do NOT add an audit assertion
to check (i) without first giving the audit events a type discriminator.
`scripts/gate/wait_for_eventhub_audit.py` matches on `tool` plus a non-empty
`caller` and has no event-type field, so an id-validity event emitted in the
existing shape would be indistinguishable from a genuine authorization deny --
and probes 1 and 2 use `UnmappedProbeToolName`, the same name check (c) asserts
on. This is the collision the deliberately-distinct `EventHubWarmupToolName`
already exists to avoid.
