# Runbook: S1_TFVARS_JSON / S2_TFVARS_JSON reference

Reference for the full shape of the two GitHub Environment secrets
`.github/workflows/ephemeral-env.yml` writes to `s1.tfvars.json` /
`s2.tfvars.json` and passes to `terraform apply -var-file=...` for the
s1-entra-mcp-server and s2-apim-mcp-gateway compositions. This did not exist
before issue #18; its absence is why #18 shipped two required variables
(`tool_authorization_map`, `server_2_tool_authorization_map`) without adding
them to `S2_TFVARS_JSON`, which only surfaced as a live-test failure (`No
value for required variable`) because `terraform validate` in PR CI never
needs real variable values and so cannot catch a missing secret key.

Not every required variable lives in these secrets. A handful are supplied a
different way, directly in the workflow:

| Variable | Composition | Supplied by |
|---|---|---|
| `resource_group_name` | both | Computed per-run (`steps.rg.outputs.name`, `rg-mcp-tracer-<run_id>`) |
| `location` | both | GitHub Environment variable `LIVE_TEST_LOCATION` |
| `data_reader_principal_ids` | s2 | Computed from the OIDC principal (`steps.principal.outputs.object_id`) |
| `shared_observability_application_insights_id` | both | GitHub Environment VARIABLE `TF_VAR_shared_observability_application_insights_id` (not a secret; see `docs/runbooks/observability-bootstrap.md`) |

Every OTHER required variable on both compositions must be a key in the
matching `S1_TFVARS_JSON` / `S2_TFVARS_JSON` secret. Optional variables
(those with a `default` in the composition's `variables.tf`) may be omitted;
omitting one takes the module's default, which is rarely what a live-test run
wants for anything other than `tags`/`app_settings`.

## Where the real values come from

Most keys below are org-identifying (tenant/client ids) or reference
resources this repo does not manage in Terraform. The runbooks that produce
them:

- `docs/runbooks/entra-app-registrations.md`: the server resource app and
  test client apps (`entra_auth`, `entra_validation`, `prm_scope`,
  `prm_scopes`, `required_scope`/`required_role` and their `server_2_*`
  counterparts).
- `docs/runbooks/obo-app-registrations.md`: the downstream Orders API app
  registration (`downstream_app`, `downstream_entra_auth`).
- `docs/runbooks/observability-bootstrap.md`: the shared, workspace-based
  Application Insights resource ID (supplied separately, see table above, not
  in this JSON). Both scenarios derive the shared Log Analytics workspace ARM
  ID from its `WorkspaceResourceId` property.

## S1_TFVARS_JSON (s1-entra-mcp-server)

Every required key on `infra/terraform/scenarios/s1-entra-mcp-server/variables.tf`
as of issue #18 (types abbreviated; see that file for the authoritative
schema, including `optional(...)` defaults inside object types):

```json
{
  "tags": { "scenario": "v1-tracer-bullet" },
  "name_prefix": "mcptracer",
  "storage_account_name": "stmcptracers1",
  "create_storage_account": false,

  "entra_auth": {
    "tenant_id": "<tenant-guid>",
    "server_app_client_id": "<server-app-client-id>",
    "allowed_audiences": ["api://<server-app-client-id>"]
  },
  "prm_scope": "api://<server-app-client-id>/user_impersonation",

  "downstream_app": {
    "client_id": "<downstream-app-client-id>",
    "api_scope": "api://<downstream-app-client-id>/user_impersonation",
    "application_scope": "api://<downstream-app-client-id>/.default"
  },
  "downstream_entra_auth": {
    "tenant_id": "<tenant-guid>",
    "server_app_client_id": "<downstream-app-client-id>",
    "allowed_audiences": ["api://<downstream-app-client-id>"]
  },
  "downstream_storage_account_name": "stmcptracerds1",
  "downstream_create_storage_account": false
}
```

`resource_group_name`, `location`, and
`shared_observability_application_insights_id` are NOT in this file (see table
above). `deployment_profile` and `app_settings` are optional and omitted here
(defaults: `"public-demo"`, `{}`).

## S2_TFVARS_JSON (s2-apim-mcp-gateway)

Every required key on `infra/terraform/scenarios/s2-apim-mcp-gateway/variables.tf`
as of issue #18:

```json
{
  "tags": { "scenario": "v1-tracer-bullet" },

  "s1_remote_state": {
    "storage_account_name": "<tf-state-storage-account>",
    "container_name": "<tf-state-container>",
    "key": "s1-entra-mcp-server.tfstate"
  },

  "apim_name": "apim-mcp-tracer",
  "publisher_name": "MCP Platform Azure",
  "publisher_email": "<publisher-email>",

  "server_name": "orders",
  "server_path": "orders",
  "entra_validation": {
    "tenant_id": "<tenant-guid>",
    "audience": "api://<server-app-client-id>",
    "allowed_client_application_ids": ["<test-client-app-id>"]
  },
  "prm_scopes": ["api://<server-app-client-id>/Orders.Invoke"],
  "required_scope": "Orders.Invoke",
  "required_role": "Orders.Invoke.All",

  "server_2_name": "catalog",
  "server_2_path": "catalog",
  "server_2_prm_scopes": ["api://<server-app-client-id>/Catalog.Invoke"],
  "server_2_required_scope": "Catalog.Invoke",
  "server_2_required_role": "Catalog.Invoke.All",

  "tool_authorization_map": {
    "get_order_status": { "role": "Orders.Read" },
    "get_service_info": { "role": "ServiceInfo.Read" },
    "get_access_guidance": { "unrestricted": true }
  },
  "server_2_tool_authorization_map": {
    "get_order_status": { "role": "Orders.Read" },
    "get_service_info": { "role": "ServiceInfo.Read" },
    "get_access_guidance": { "unrestricted": true }
  },

  "registry_name": "apic-mcp-tracer",
  "registry_environment": {
    "title": "Live test"
  }
}
```

`resource_group_name`, `location`, `data_reader_principal_ids`, and
`shared_observability_application_insights_id` are NOT in this file (see table
above).
`deployment_profile` and `registry_deployment` are optional and omitted here.

**Correction (2026-08-09, issue #80):** this file previously showed
`required_scope`/`required_role` as `mcp.orders.invoke`/`Mcp.Orders.Invoke`,
`server_2_required_scope`/`server_2_required_role` as
`mcp.orders2.invoke`/`Mcp.Orders2.Invoke`, and both `prm_scopes` and
`server_2_prm_scopes` as `[".../user_impersonation"]`. None of those match
reality. Direct review of the live server app registration's App roles and
Expose an API blades (2026-08-09) confirmed the real role/scope names are
`Orders.Invoke` / `Orders.Invoke.All` (server 1) and `Catalog.Invoke` /
`Catalog.Invoke.All` (server 2); Hari then confirmed the live
`S2_TFVARS_JSON` secret's actual `prm_scopes` and `server_2_prm_scopes`
values directly, which matched `entra-app-registrations.md` section 1a's
convention (each server's PRM carries only its own scope URI) rather than the
stale `user_impersonation` this file showed. All four fields above are now
corrected to the real, confirmed values.

**Correction (2026-08-09, issue #82):** this file previously showed
`server_name` as `orders-mcp`, `server_2_name` as `orders-mcp-2`, and
`server_2_path` as `orders2`. None of those match reality either. Hari read the
live `S2_TFVARS_JSON` secret directly on 2026-08-09; the real values are
`orders` (server 1's name and path) and `catalog` (server 2's name and path).
Server 2's name and path now match its scope family, `Catalog.Invoke`, which the
previous `orders2` did not.

Why this one is worth recording rather than quietly fixing: `server_2_path` is
the URL segment clients actually connect to, so a reader following this file
would have built the wrong server 2 URL. Nothing in the gate depends on the
value in this file, because the gate reads the Terraform outputs rather than
this document, which is exactly why the drift survived two issues without
failing anything.

`tool_authorization_map` / `server_2_tool_authorization_map` (issue 18):
`scope` and `unrestricted` are both optional per key and may be omitted
entirely when only `role` applies, exactly as shown -- Terraform's
`optional(...)` fills `scope = null`, `unrestricted = false`. The same holds in
the other direction: an `unrestricted` entry omits `role` entirely and
`optional(...)` fills `role = null`, so the `get_access_guidance` entry above is
complete rather than truncated. Both servers carry the SAME map here because
both still forward to the same backend. That backend (`src/McpTools/`) now
exposes THREE tools. Two are gated on a role each: `get_order_status` on
`Orders.Read`, and `get_service_info` (issue 79) on `ServiceInfo.Read`, both
checked by the issue-45 `AppRoleAuthorization` mechanism. The third,
`get_access_guidance` (issue 82), is gated on nothing by design. It is the only
tool mapped `unrestricted`, and it is mapped that way so something executes that
branch of the policy fragment. A server exposing a different tool set needs a
different map; the live gate's per-server set-equality assertion (ADR-009) is
what proves whichever map is configured still matches that server's real
`tools/list`.

Both maps must carry the `get_access_guidance` key even though the live gate's
check (h) only calls that tool at server 1. Both servers front the same backend,
so each server's check (a) runs against the same `tools/list`. A key present in
only one map leaves the other server with a tool that has no map entry, which
fails that server's set-equality assertion.

**Deployment coupling: this JSON lives in a secret, not in this repo.**
`tool_authorization_map` and `server_2_tool_authorization_map` are supplied
from the `S2_TFVARS_JSON` GitHub Environment secret
(`.github/workflows/ephemeral-env.yml`, the "Write composition tfvars" step),
not from any file in this repository. A PR that adds a tool to the backend
cannot also add that tool's key to this map, because the map is not code the
PR can touch.
**Hari must update the `S2_TFVARS_JSON` secret** to add `get_service_info` to
BOTH maps above. This is a manual step; no PR can perform it. The same is true
of `get_access_guidance` (issue 82), with one difference: that entry names no
app role, so it has no Entra half to follow. Adding the key is the whole step.

The secret update is necessary but NOT sufficient to make the tool callable.
The app role it names has to exist and be granted as well: `ServiceInfo.Read`
is not in `docs/runbooks/entra-app-registrations.md` or anywhere under `infra/`
at the time of writing. Issue #79 shipped the tool and deferred all Entra work
to issue #80, whose steps 1-5 create the role and entitle a caller. Doing only
the secret update leaves `get_service_info` mapped but uncallable by every
principal. Follow #80 for the Entra half.

Both APIM servers forward to the same backend, so once `get_service_info`
ships, BOTH servers' `tools/list` return it, whether or not the secret has
been updated yet. The live gate's check [9]-a is set-equality in BOTH
directions between `tools/list` and the map keys: a tool with no matching map
key fails it, and a map key with no matching tool fails it too.

Until the secret is updated, the two servers behave DIFFERENTLY, and the
difference matters if you are reading gate output:

- **Server 1 FAILS the gate.** `Assert-ToolAuthorization` runs without
  `-WarnOnly` for server 1 (`tests/integration/discovery-assertions.ps1`,
  server list entry `WarnOnly = $false`), so the mismatch calls `Fail`,
  increments `$script:Failures`, and the script exits 1.
- **Server 2 only WARNS.** The identical condition is passed
  `-WarnOnly:$srv.WarnOnly` with `WarnOnly = $true` for server 2, which
  converts the same `Fail` into a non-fatal `::warning::`.

So "the gate reports drift" understates it for server 1 and overstates it for
server 2. Expect a red run, not a warning.

That drift window cannot be closed by reordering the rollout. Shipping the map
key first (before the tool exists) fails set-equality the other way: a map key
with no matching tool. It must NOT be engineered away by weakening the
assertion. The assertion's strictness is its entire value; ADR-009 rejects a
fixed expected-tool list for exactly this reason, because a loose check would
stop proving that the deployed map matches the deployed tool set.

**Known discrepancy with ADR-009, recorded rather than resolved (2026-08-08).**
ADR-009's "Deployment coupling" section states that default-deny plus the
set-equality assertion "means that ADDING A TOOL TO THE FUNCTIONS BACKEND FAILS
INFRASTRUCTURE CI until the Terraform map is updated in the same change", and
says that is correct only because "the Functions app and the Terraform map must
move together, in the same deployment unit. In this repository they do."

For the `tool_authorization_map` inputs, they do not. The map lives in a GitHub
Environment secret, and `ephemeral-env.yml` is manual-dispatch only, never
triggered by `pull_request` or `push`. Issue #79 added a tool and the required
`terraform-checks` job stayed green, because nothing in PR CI reads that secret
or evaluates set-equality. The ADR's stated mechanism does not operate for this
class of change; the assertion still holds, but it holds at live-gate time, not
at PR time. This runbook does not amend the ADR. Resolving the discrepancy (by
correcting the ADR, by moving the maps out of the secret, or by accepting the
gap explicitly) is a decision for its own ticket.

## Maintenance: adding a new required variable

When a ticket adds a new REQUIRED variable (no `default`) to
`s1-entra-mcp-server/variables.tf` or `s2-apim-mcp-gateway/variables.tf`:

1. Decide whether it belongs in the JSON secret (static, non-computed,
   non-secret-shaped -- most variables) or as a distinct workflow-level
   `TF_VAR_*` line (computed per-run, or deliberately kept out of the shared
   JSON blob for its own reason -- see
   `shared_observability_application_insights_id` for why it went the second
   route: it is provisioned by a separate one-time runbook, not something Hari
   edits alongside the rest of this JSON).
2. If it belongs in the JSON secret: add it to the relevant example above IN
   THE SAME PR as the variable, and say so plainly in the PR body that
   `S1_TFVARS_JSON`/`S2_TFVARS_JSON` needs a matching key added by Hari
   before the next live-test run. `terraform validate` in PR CI cannot catch
   a missing secret key -- this step is easy to forget, which is exactly what
   happened before this doc existed.
3. If it belongs as a workflow `TF_VAR_*` line instead: add that line to
   `.github/workflows/ephemeral-env.yml` in the same PR, and add a row to the
   table above.
