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
| `audit_application_insights_id` | s2 | GitHub Environment VARIABLE `TF_VAR_audit_application_insights_id` (not a secret; see `docs/runbooks/observability-bootstrap.md`) |

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
- `docs/runbooks/observability-bootstrap.md`: the audit Application Insights
  resource id (supplied separately, see table above, not in this JSON).

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

`resource_group_name` and `location` are NOT in this file (see table above).
`deployment_profile` and `app_settings` are optional and omitted here
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

  "server_name": "orders-mcp",
  "server_path": "orders",
  "entra_validation": {
    "tenant_id": "<tenant-guid>",
    "audience": "api://<server-app-client-id>",
    "allowed_client_application_ids": ["<test-client-app-id>"]
  },
  "prm_scopes": ["api://<server-app-client-id>/user_impersonation"],
  "required_scope": "mcp.orders.invoke",
  "required_role": "Mcp.Orders.Invoke",

  "server_2_name": "orders-mcp-2",
  "server_2_path": "orders2",
  "server_2_prm_scopes": ["api://<server-app-client-id>/user_impersonation"],
  "server_2_required_scope": "mcp.orders2.invoke",
  "server_2_required_role": "Mcp.Orders2.Invoke",

  "tool_authorization_map": {
    "get_order_status": { "role": "Orders.Read" }
  },
  "server_2_tool_authorization_map": {
    "get_order_status": { "role": "Orders.Read" }
  },

  "registry_name": "apic-mcp-tracer",
  "registry_environment": {
    "title": "Live test"
  }
}
```

`resource_group_name`, `location`, `data_reader_principal_ids`, and
`audit_application_insights_id` are NOT in this file (see table above).
`deployment_profile` and `registry_deployment` are optional and omitted here.

`tool_authorization_map` / `server_2_tool_authorization_map` (issue 18):
`scope` and `unrestricted` are both optional per key and may be omitted
entirely when only `role` applies, exactly as shown -- Terraform's
`optional(...)` fills `scope = null`, `unrestricted = false`. Both servers
carry the SAME map here because both forward to the same backend
(`src/McpTools/Tools/GetOrderStatus.cs`, one tool, gated on `Orders.Read`,
matching the issue-45 `AppRoleAuthorization` check). A server exposing a
different tool set needs a different map; the live gate's per-server
set-equality assertion (ADR-009) is what proves whichever map is configured
still matches that server's real `tools/list`.

## Maintenance: adding a new required variable

When a ticket adds a new REQUIRED variable (no `default`) to
`s1-entra-mcp-server/variables.tf` or `s2-apim-mcp-gateway/variables.tf`:

1. Decide whether it belongs in the JSON secret (static, non-computed,
   non-secret-shaped -- most variables) or as a distinct workflow-level
   `TF_VAR_*` line (computed per-run, or deliberately kept out of the shared
   JSON blob for its own reason -- see `audit_application_insights_id` for
   why it went the second route: it is provisioned by a separate one-time
   runbook, not something Hari edits alongside the rest of this JSON).
2. If it belongs in the JSON secret: add it to the relevant example above IN
   THE SAME PR as the variable, and say so plainly in the PR body that
   `S1_TFVARS_JSON`/`S2_TFVARS_JSON` needs a matching key added by Hari
   before the next live-test run. `terraform validate` in PR CI cannot catch
   a missing secret key -- this step is easy to forget, which is exactly what
   happened before this doc existed.
3. If it belongs as a workflow `TF_VAR_*` line instead: add that line to
   `.github/workflows/ephemeral-env.yml` in the same PR, and add a row to the
   table above.
