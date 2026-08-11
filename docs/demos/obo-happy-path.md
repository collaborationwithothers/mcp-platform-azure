# Manual demo: OBO happy path (delegated user token)

The one part of issue 10 the automated live gate cannot exercise: a real
**delegated** (user-context) token round-tripping through the downstream Orders
API via the On-Behalf-Of exchange. The gate authenticates with a
client-credentials (app-only) token, which has no user and cannot drive OBO, and
no GA, non-interactive, CLAUDE.md-compliant mechanism exists to acquire a
delegated token in CI (ADR-006, "Testing strategy: the user-context token
problem"; docs/runbooks/obo-app-registrations.md, "User-context token
strategy"). So this is the human-run half of acceptance criterion 7.

## What this demo covers

Two established checks and one current proof procedure use delegated tokens:

1. **OBO happy path (issue 10).** A signed-in human, not a program, reaches
   `get_order_status` and gets a real order back, sourced from the downstream
   Orders API via an On-Behalf-Of token exchange, not a fixture and not
   passthrough.
2. **The gateway's per-tool `scope` check discriminates, not just executes
   (issue 83).** `get_order_status` is gated on BOTH a role (`Orders.Read`,
   checked for app-only callers) and a delegated scope (`Orders.Read.AsUser`,
   checked for human callers). A caller holding the scope succeeds (step 2
   below); a caller who cleared the per-server check but lacks the scope is
   refused with a JSON-RPC `-32001` before OBO ever runs (step 2a below).
   Before issue 83 no tool row named a scope at all, so this branch of the
   policy had never executed, by anyone -- ADR-009 records why no automated
   mechanism can close that gap.
3. **The backend delegated-scope check (issue #98).** Step 2b calls the
   Function directly with the same `Orders.Invoke`-only token. The client
   expects the tool-level 403 for missing `Orders.Read.AsUser`, not the
   gateway's `-32001` error. This is a current procedure only. It is not proven
   until its result is recorded under "Captured evidence".

This demo does not prove observability ingestion (diagnostic-setting
acceptance, telemetry arrival, or cost -- issue 75's separate scope) or the
per-tool deny audit path (issue 18's `<trace>`/`log-to-eventhub`, which step 2a
below exercises but this demo does not itself inspect).

Whether this has actually been run, and when, is recorded in **Captured
evidence** below, by date -- check the most recent entry before treating either
claim above as currently proven rather than merely the intended procedure. The
2026-08-10 entry proves the gateway check only. It does not prove the backend
check added by issue #98.

Nothing here deploys anything; it runs against an already-deployed tracer during
a live-test window. All order data is synthetic (CONTOSO-1001 to CONTOSO-1005).
No app, tenant, or subscription ids are committed here (they are org-identifying;
they live only in the `S1_TFVARS_JSON` live-test secret) -- the evidence below
redacts them and records only the non-identifying facts that prove the path.

## Prerequisites

- A live tracer stamp (e.g. an `ephemeral-env.yml` run left up with
  `skip_teardown=true`, or a manual deploy).
- A **sandbox test user** (cloud-only, no standing access beyond the demo).
- The **positive-arm client**, `docs/runbooks/entra-app-registrations.md`
  section 4 (`mcp-tracer-vscode-client`) -- an app whose id is in the APIM
  policy's `<client-application-ids>`
  (`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`). The
  gateway's `validate-azure-ad-token` rejects a token from any other client, so
  every demo token MUST be minted by an allowed client. Needs:
  - **Authentication > Allow public client flows = Yes** (so device code can
    redeem without a client secret), and
  - delegated permissions `api://<server-app-id>/Orders.Invoke` (clears the
    per-server check) and `api://<server-app-id>/Orders.Read.AsUser` (clears
    `get_order_status`'s per-tool check, issue #83), both consented.
- The **negative-arm client**, `entra-app-registrations.md` section 4a
  (`mcp-tracer-test-client-delegated-without-scope`) -- also an allowed
  client, holding `Orders.Invoke` only, never `Orders.Read.AsUser`. A single
  client cannot produce both a token that carries the scope and one that
  omits it: once a client is consented for a scope on a resource, Entra
  returns every scope it holds for that resource on every token for that
  resource, regardless of what `scope=` requests (verified against Microsoft
  Learn, 2026-08-10; section 4a explains why this needs a second app
  registration, not a second scope on the first).

## Procedure

### 1. Acquire a delegated token (device code) as the sandbox user

Use the raw device-code flow with an **allowed client id** (not Azure CLI's --
`az account get-access-token` always uses the CLI's own client id, which the
gateway rejects). Keep `CLIENT_ID` identical across both calls in a run. Run
this once per client -- positive-arm, then negative-arm.

```bash
TENANT="<tenant-id>"
CLIENT_ID="<the allowed client app id (matches the APIM client-application-ids)>"
SERVER_APP_ID="<server-app-id>"

# initiate; complete the printed URL + code in a browser AS THE SANDBOX USER
resp=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/devicecode" -d "client_id=$CLIENT_ID" --data-urlencode "scope=api://$SERVER_APP_ID/Orders.Invoke offline_access openid")
echo "$resp" | jq -r .message
DEVICE_CODE=$(echo "$resp" | jq -r .device_code)

# after sign-in, redeem with the SAME client_id
curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "client_id=$CLIENT_ID" -d "device_code=$DEVICE_CODE" | jq -r .access_token
```

Gotchas actually hit while doing this (recorded so the next run is faster):

- **`AADSTS7000218` (client_assertion or client_secret required):** the client
  app is confidential / public client flows are off. Fix: set **Allow public
  client flows = Yes** on the client app.
- **`AADSTS90023` (ClientId doesn't match the one in cache):** the device code
  was initiated with a different `client_id` than the redemption used. Use one
  `CLIENT_ID` for both calls.
- **`invalid_client` / no token:** confirm the client id is in the APIM
  `<client-application-ids>` and has the delegated `Orders.Invoke` permission
  consented.

Verify the token is delegated (jwt.ms): `scp` contains `Orders.Invoke` (and, for
the positive-arm client only, `Orders.Read.AsUser`), a user `oid`, and NO
`roles` claim. A `roles`-only token is app-context and would take the fixture
branch, not OBO.

### 2. Call get_order_status with the positive-arm token

```bash
MCP_ACCESS_TOKEN="<the positive-arm delegated token>" dotnet run --project src/McpTestClient -- "<s2 mcp_server_url>"
```

Because the token carries `scp` with both `Orders.Invoke` and
`Orders.Read.AsUser`, the gateway forwards the call and the backend takes the
**delegated** branch, sourcing the result from the downstream via OBO. A
returned order is the proof: the downstream only accepts downstream-audience
tokens (the negative test measures this), so a delegated call that returns an
order means the server exchanged the token via OBO. If OBO had failed, the call
would have thrown, not returned a result.

### 2a. Call get_order_status with the negative-arm token (issue #83)

```bash
MCP_ACCESS_TOKEN="<the negative-arm delegated token>" dotnet run --project src/McpTestClient -- "<s2 mcp_server_url>"
```

`tools/list` still returns all three tools -- this token's `Orders.Invoke`
clears the per-server check the same as the positive arm's. The tool call
itself is refused: a JSON-RPC error, `code: -32001`, `message` starting
`insufficient_scope: the caller is not authorized to call tool
'get_order_status'.` This never reaches OBO or the downstream; the gateway's
per-tool check denies it first. Paired with step 2's success -- same server,
same per-server entitlement, different per-tool entitlement -- this is what
proves the `scope` branch discriminates rather than merely executes.

### 2b. Prove the backend delegated-scope check directly (issue #98)

Use the same negative-arm token, but call the Function endpoint directly. Do not
send this request through APIM. APIM denies the token first, so its `-32001`
result cannot prove the backend check.

Start in the repository root. Step 1 obtains the negative-arm token. Keep it in
the current shell only. Before this call, inspect it in jwt.ms and confirm its
redacted `scp` value is `Orders.Invoke` with no `Orders.Read.AsUser`.

```bash
cd "$(git rev-parse --show-toplevel)"

# Copy the access token printed by step 1 for the negative-arm client.
# Do not print, save, or commit this token.
export NEGATIVE_TOKEN="<negative-arm access token>"

# This must resolve to the Function URL, not the APIM URL.
export BACKEND_MCP_URL="$(terraform -chdir=infra/terraform/scenarios/s1-entra-mcp-server output -raw mcp_backend_base_url)/runtime/webhooks/mcp"

MCP_ACCESS_TOKEN="$NEGATIVE_TOKEN" \
MCP_EXPECT_FORBIDDEN_SCOPE="Orders.Read.AsUser" \
  dotnet run --project src/McpTestClient -- "$BACKEND_MCP_URL"
```

The client must report its authorization-denial assertion passed for
`Orders.Read.AsUser`.
That assertion requires the MCP tool result `403 Forbidden: get_order_status
requires the delegated scope 'Orders.Read.AsUser'.` The server's unit test proves
that this branch does not start OBO or contact the downstream API. Record the
direct endpoint's redacted transcript below. Do not rewrite the 2026-08-10
gateway transcript as evidence of this check.

### 3. (Recommended) delegated passthrough-closed check

Present the positive-arm token DIRECTLY to the downstream; expect 401. This is
the manually-evidenced twin of the automated negative test (docs/security.md).

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer <positive-arm delegated token>" \
  "$(terraform -chdir=infra/terraform/scenarios/s1-entra-mcp-server output -raw downstream_base_url)/api/orders/CONTOSO-1001"
# expect 401
```

## Captured evidence

### Run 2026-08-11: direct backend delegated-scope negative (issue #98)

- **Deploy:** `ephemeral-env.yml` run
  [31451865753](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31451865753)
  deployed commit `0a7fd75` and was held alive with `skip_teardown=true` for
  this manual check.
- **Delegated token (redacted):** `scp` = `Orders.Invoke`.
  `Orders.Read.AsUser` was absent.
- **Endpoint:**
  `https://mcp-tracer-func.azurewebsites.net/runtime/webhooks/mcp`.
  This is the direct Function endpoint, not APIM.
- **McpTestClient transcript:**

  ```
  [McpTestClient] Target MCP endpoint: https://mcp-tracer-func.azurewebsites.net/runtime/webhooks/mcp
  [McpTestClient] Authorization header: present (Bearer)
  [McpTestClient] initialize OK: protocol 2025-06-18, server Azure Functions MCP server.
  [McpTestClient] tools/list returned 3 tool(s):
    - get_access_guidance
    - get_order_status
    - get_service_info
  [McpTestClient] Authorization-denial assertion passed: 403 Forbidden: get_order_status requires the delegated scope 'Orders.Read.AsUser'.
  ```

- **Interpretation:** the Function received a delegated caller without the
  required scope and returned the deterministic tool-level 403. This is not
  APIM's JSON-RPC `-32001` denial. The unit test covers that this branch exits
  before OBO or a downstream call.

### Run 2026-07-19

- **Deploy:** `ephemeral-env.yml` run
  [29681694550](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/29681694550),
  stamp `apim-mcp-tracer-2d636a84`. That run proved **apply + call** (the s1
  apply including the `azuread` federated identity credential and consent grant,
  the downstream deploy, and the call stage: McpTestClient app-context happy
  path, discovery assertions, and the OBO passthrough negative test at
  `invoke-and-assert.ps1` step [5]). It ran with `skip_teardown=true`, so the
  **destroy** half of apply-call-destroy was NOT exercised in this run.
- **Delegated token (redacted, non-identifying facts only):** `appid` = the
  allowed client app (matches the APIM `<client-application-ids>`); `aud` =
  `api://<server-app-id>` (the MCP server app); `scp` = `user_impersonation`;
  delegated (user `oid` present, no `roles` claim).
- **McpTestClient (delegated token) transcript:**

  ```
  [McpTestClient] Target MCP endpoint: https://apim-mcp-tracer-2d636a84.azure-api.net/orders/runtime/webhooks/mcp
  [McpTestClient] Authorization header: present (Bearer)
  [McpTestClient] initialize OK: protocol 2025-06-18, server Azure Functions MCP server.
  [McpTestClient] tools/list returned 1 tool(s):
    - get_order_status
  [McpTestClient] call(known)   -> { "orderId": "CONTOSO-1003", "status": "Processing", "updatedUtc": "2026-06-05T17:45:00Z" }
  [McpTestClient] known id OK.
  [McpTestClient] call(unknown) -> { "orderId": "CONTOSO-9999", "found": false, "message": "No order was found for id 'CONTOSO-9999'. Order data is synthetic (known ids are CONTOSO-1001 to CONTOSO-1005)." }
  [McpTestClient] unknown id OK: typed not-found (found:false).
  [McpTestClient] All session and tool assertions passed.
  ```

- **Interpretation:** a delegated (scp) token drove the delegated branch -> OBO
  -> downstream, and both frozen contract shapes came back correct (known ->
  status, unknown -> typed not-found). Since the downstream rejects
  non-downstream-audience tokens, this is OBO, not the fixture and not
  passthrough. Also confirms the delegated `scp` claim-type detection works live
  (the delegated branch fired).

- **Open / honest notes:**
  - The exact `X-MS-CLIENT-PRINCIPAL` claim-type STRING form (short `scp` vs a
    mapped schema URI) was NOT directly observed from server logs; it is
    inferred present because the delegated branch fired, and the resolver
    matches both forms so it is correct either way (COMPATIBILITY.md).
  - The step-3 delegated passthrough-closed check (delegated token direct to
    downstream -> 401): record the observed code here when run.
  - Clean teardown of the new `azuread` resources was not exercised (this run
    used `skip_teardown=true`); a full `skip_teardown=false` run still validates
    the destroy path.

### Run 2026-07-22 (issue 53: assignment-required gate re-validation)

Re-validation after enabling "Assignment required?" = Yes
(`appRoleAssignmentRequired`) on the downstream Orders API's enterprise
application (issue 53), against `ephemeral-env.yml` run
[29892332176](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/29892332176)
(apply-call-destroy green; `skip_teardown=true`, so the environment stayed up for
the manual run and the destroy half was not exercised). Stamp
`mcp-tracer-apim-9f82a4f5`; gateway MCP endpoint
`https://mcp-tracer-apim-9f82a4f5.azure-api.net/orders/runtime/webhooks/mcp`.
Branch `claude/issue-53-downstream-assignment-required-gate`.

**Result: the downstream assignment gate is enforced on the delegated OBO path for
non-admin users.** Confirmed by a matched pair on the SAME non-admin sandbox user,
differing only by the downstream app assignment, plus a Global Admin control.

**Positive arm (non-admin, assigned).** The user, assigned to the downstream
enterprise application, drove the delegated branch -> OBO -> downstream and
returned both frozen contract shapes (known id -> status, unknown id -> typed
not-found). The assignment-required toggle does NOT break delegated OBO for an
authorized user (issue-53 acceptance item 3, positive half). Verbatim
McpTestClient output:

```
[McpTestClient] Target MCP endpoint: https://mcp-tracer-apim-9f82a4f5.azure-api.net/orders/runtime/webhooks/mcp
[McpTestClient] Authorization header: present (Bearer)
[McpTestClient] initialize OK: protocol 2025-06-18, server Azure Functions MCP server.
[McpTestClient] tools/list returned 1 tool(s):
  - get_order_status
[McpTestClient] call(known)   -> {"orderId":"CONTOSO-1003","status":"Processing","updatedUtc":"2026-06-05T17:45:00Z"}
[McpTestClient] known id OK: { orderId=CONTOSO-1003, status=Processing, updatedUtc=2026-06-05T17:45:00Z }.
[McpTestClient] call(unknown) -> {"orderId":"CONTOSO-9999","found":false,"message":"No order was found for id 'CONTOSO-9999'. Order data is synthetic (known ids are CONTOSO-1001 to CONTOSO-1005)."}
[McpTestClient] unknown id OK: typed not-found (found:false) for CONTOSO-9999.
[McpTestClient] All session and tool assertions passed.
```

**Negative arm (same non-admin, unassigned).** With the user removed from the
downstream app, the delegated call FAILED -- `get_order_status` returned an MCP
error instead of an order:

```
[McpTestClient] call(known)   -> An error occurred invoking 'get_order_status'.
Unhandled exception. System.InvalidOperationException: call(CONTOSO-1003) returned an MCP error result; expected the typed success shape.
```

Server-side exception captured via `az webapp log tail` (2026-07-22; app id, trace
id, correlation id REDACTED per this file's no-org-ids rule; the user is already
`{EUII Hidden}` by Entra):

```
Exception: AADSTS50105: Your administrator has configured the application
<downstream-app> ('<downstream-app-id>') to block users unless they are
specifically granted ('assigned') access to the application. The signed in
user '{EUII Hidden}' is blocked because they are not a direct member of a
group with access, nor had access directly assigned by an administrator.
...
  at Microsoft.Identity.Client.Internal.Requests.OnBehalfOfRequest.ExecuteAsync(CancellationToken cancellationToken)
  ...
```

The MSAL stack frame `OnBehalfOfRequest.ExecuteAsync` pins the enforcement point:
AADSTS50105 is thrown AT the OBO token exchange, not at the user's original
sign-in -- the exact point Microsoft Learn leaves unstated, now measured.

**Why the assignment is the cause.** The positive and negative arms use the same
non-admin user and differ only by the downstream app assignment, so the assignment
is the isolated variable. Consent is tenant-wide
(`azuread_service_principal_delegated_permission_grant`, all users), identical for
both. `GetOrderStatus.Run` has NO delegated->app-only fallback and
`AcquireTokenOnBehalfOf` is not caught (src/McpTools/Tools/GetOrderStatus.cs;
src/McpTools/Downstream/ManagedIdentityOboTokenAcquirer.cs), so a thrown tool means
the OBO exchange genuinely failed. Consent, principal-parsing, and code paths are
ruled out.

**Global Administrator bypass (operational rule).** A separate run showed an
unassigned Global Administrator's delegated call still SUCCEEDS, because Global
Administrators bypass `appRoleAssignmentRequired` entirely (VERIFIED,
azure-docs-verifier 2026-07-22). Any manual negative test of this gate MUST
therefore use a non-admin user, or the bypass masks the result.

**Conclusion.** `appRoleAssignmentRequired` on the downstream gates the delegated
OBO token exchange for non-admin principals (Learn-PARTIAL, live-confirmed here;
enforcement point measured at the OBO exchange). The downstream role assignment is
a real issuance gate on BOTH the app-only path (VERIFIED by docs) and the
delegated path, with the standing GA-bypass caveat.

- **Open / honest notes:**
  - The exact code was captured via `az webapp log tail`; the tracer Function App
    has no App Insights / Log Analytics wired (checked via Azure Monitor
    2026-07-22), so the live log stream was the capture path.
  - The exact `X-MS-CLIENT-PRINCIPAL` claim-type STRING form (short `scp` vs
    mapped schema URI) is still not directly asserted here; unchanged from the
    2026-07-19 run's open note.
  - Clean teardown of the `azuread` resources was again not exercised
    (`skip_teardown=true`); a full `skip_teardown=false` run still validates the
    destroy path.

### Run 2026-08-10 (issue #83: the delegated scope branch, matched pair)

The evidence this demo's "What this demo proves" section (claim 2) points at:
proof that the gateway's per-tool `scope` check on `get_order_status`
discriminates, not merely renders. Against `ephemeral-env.yml` run
[31364080957](https://github.com/collaborationwithothers/mcp-platform-azure/actions/runs/31364080957)
(apply-call-destroy green, `skip_teardown=true`). Stamp `apim-mcp-tracer-5dcee91f`;
gateway MCP endpoint
`https://apim-mcp-tracer-5dcee91f.azure-api.net/orders/runtime/webhooks/mcp`.
Branch `claude/issue-83-evidence-scope-branch`.

**Result: the `scope` branch admits a caller who holds it and refuses one who
does not, both having cleared the identical per-server check.** Confirmed by a
matched pair of real, MFA-backed interactive sign-ins as the same user, from
two different client app registrations, differing only in which one was
consented for `Orders.Read.AsUser`.

**Positive arm (`entra-app-registrations.md` section 4,
`mcp-tracer-vscode-client`).** Decoded token (redacted, non-identifying facts
only): `scp` = `Orders.Invoke Orders.Read.AsUser user_impersonation`, no
`roles` claim, `amr` = `["pwd","mfa"]` (genuine interactive sign-in, not a
scripted bypass). `get_order_status` succeeded via the delegated branch -> OBO
-> downstream, both frozen contract shapes correct:

```
[McpTestClient] Target MCP endpoint: https://apim-mcp-tracer-5dcee91f.azure-api.net/orders/runtime/webhooks/mcp
[McpTestClient] Authorization header: present (Bearer)
[McpTestClient] initialize OK: protocol 2025-06-18, server Azure Functions MCP server.
[McpTestClient] tools/list returned 3 tool(s):
  - get_access_guidance
  - get_order_status
  - get_service_info
[McpTestClient] call(known)   -> {"orderId":"CONTOSO-1003","status":"Processing","updatedUtc":"2026-06-05T17:45:00Z"}
[McpTestClient] known id OK: { orderId=CONTOSO-1003, status=Processing, updatedUtc=2026-06-05T17:45:00Z }.
[McpTestClient] call(unknown) -> {"orderId":"CONTOSO-9999","found":false,"message":"No order was found for id 'CONTOSO-9999'. Order data is synthetic (known ids are CONTOSO-1001 to CONTOSO-1005)."}
[McpTestClient] unknown id OK: typed not-found (found:false) for CONTOSO-9999.
[McpTestClient] All session and tool assertions passed.
```

**Negative arm (`entra-app-registrations.md` section 4a,
`mcp-tracer-test-client-delegated-without-scope`).** Decoded token (redacted,
non-identifying facts only): `scp` = `Orders.Invoke` ONLY -- no
`Orders.Read.AsUser`, no `user_impersonation` -- no `roles` claim, `amr` =
`["pwd","mfa"]`. `tools/list` still returned all three tools, confirming this
token cleared the identical per-server check the positive arm's did.
`get_order_status` was refused before OBO ever ran:

```
[McpTestClient] Target MCP endpoint: https://apim-mcp-tracer-5dcee91f.azure-api.net/orders/runtime/webhooks/mcp
[McpTestClient] Authorization header: present (Bearer)
[McpTestClient] initialize OK: protocol 2025-06-18, server Azure Functions MCP server.
[McpTestClient] tools/list returned 3 tool(s):
  - get_access_guidance
  - get_order_status
  - get_service_info
Unhandled exception. ModelContextProtocol.McpProtocolException: Request failed (remote): insufficient_scope: the caller is not authorized to call tool 'get_order_status'.
```

The exception type (`McpProtocolException`, not a parsed `CallToolResult` with
`isError`) and the message text (`insufficient_scope: the caller is not
authorized to call tool 'get_order_status'.`) match `mcp-server.xml`'s per-tool
deny body verbatim -- code `-32001`, the JSON-RPC Protocol Error wire shape
ADR-009 documents, not an HTTP 401/403 (which would mean the per-server check
had refused it instead) and not a tool-execution failure.

**Why this is the scope branch specifically, not the already-proven role
branch.** The same `-32001` text is also what an app-only caller lacking
`Orders.Read` gets, via the role check issue 18 already proved. What isolates
this as the `scope` branch: both arms here are delegated tokens (`scp`
present, no `roles` claim on either), both cleared the SAME per-server check
with the SAME scope (`Orders.Invoke`), and the only difference between them is
`Orders.Read.AsUser`. That difference is what produced the different outcome.

**Interpretation.** This closes the gap ADR-009's issue-#80 close-out left
open: "`scope`... is unprovable by THIS gate as constructed." It is not
provable by the automated gate, and remains so (ADR-006's constraint is
structural, not something this run changes). It is provable by a human, and
now has been, once, with the negative arm establishing discrimination rather
than mere execution.

- **Open / honest notes:**
  - This is one recorded run, not a standing gate. Nothing about `scope`
    branch coverage is re-checked automatically; a future change to this
    fragment could silently break it and only the `terraform test` fixture
    (render-time) plus a repeat of this manual demo (execution-time) would
    catch it.
  - Step 3 (delegated passthrough-closed check) was not exercised in this run.
  - The exact `X-MS-CLIENT-PRINCIPAL` claim-type STRING form is still not
    directly asserted from server-side logs; unchanged open item from the
    2026-07-19 run.
  - Deploy stamp `apim-mcp-tracer-5dcee91f` was kept alive
    (`skip_teardown=true`) specifically to run this demo; tear it down after
    (`az group delete -n rg-mcp-tracer-31364080957 --yes`) -- it is not
    destroyed automatically and bills continuously until removed.
