# Manual demo: OBO happy path (delegated user token)

The one part of issue 10 the automated live gate cannot exercise: a real
**delegated** (user-context) token round-tripping through the downstream Orders
API via the On-Behalf-Of exchange. The gate authenticates with a
client-credentials (app-only) token, which has no user and cannot drive OBO, and
no GA, non-interactive, CLAUDE.md-compliant mechanism exists to acquire a
delegated token in CI (ADR-006, "Testing strategy: the user-context token
problem"; docs/runbooks/obo-app-registrations.md, "User-context token
strategy"). So this is the human-run half of acceptance criterion 7, validated
manually with the evidence recorded below.

Nothing here deploys anything; it runs against an already-deployed tracer during
a live-test window. All order data is synthetic (CONTOSO-1001 to CONTOSO-1005).
No app, tenant, or subscription ids are committed here (they are org-identifying;
they live only in the `S1_TFVARS_JSON` live-test secret) -- the evidence below
redacts them and records only the non-identifying facts that prove the path.

## Prerequisites

- A live tracer stamp (e.g. an `ephemeral-env.yml` run left up with
  `skip_teardown=true`, or a manual deploy).
- A **sandbox test user** (cloud-only, no standing access beyond the demo).
- The **allowed client app** -- the one whose id is in the APIM policy's
  `<client-application-ids>` (`infra/terraform/modules/apim-mcp-server/policies/mcp-server.xml`),
  i.e. the same app the gate uses. The gateway's `validate-azure-ad-token`
  rejects a token from any other client, so the demo token MUST be minted by
  this app. It needs, for the delegated flow:
  - **Authentication > Allow public client flows = Yes** (so device code can
    redeem without a client secret), and
  - a **delegated** permission `api://<server-app-id>/user_impersonation` (added
    on the client app, pointing at the server app's scope), admin- or
    user-consented.

## Procedure

### 1. Acquire a delegated token (device code) as the sandbox user

Use the raw device-code flow with the **allowed client id** (not Azure CLI's --
`az account get-access-token` always uses the CLI's own client id, which the
gateway rejects). Keep `CLIENT_ID` identical across both calls.

```bash
TENANT="<tenant-id>"
CLIENT_ID="<the allowed client app id (matches the APIM client-application-ids)>"
SERVER_APP_ID="<server-app-id>"

# initiate; complete the printed URL + code in a browser AS THE SANDBOX USER
resp=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/devicecode" -d "client_id=$CLIENT_ID" --data-urlencode "scope=api://$SERVER_APP_ID/user_impersonation offline_access openid")
echo "$resp" | jq -r .message
DEVICE_CODE=$(echo "$resp" | jq -r .device_code)

# after sign-in, redeem with the SAME client_id
curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" -d "client_id=$CLIENT_ID" -d "device_code=$DEVICE_CODE" | jq -r .access_token
```

Gotchas actually hit while doing this (recorded so the next run is faster):

- **`AADSTS7000218` (client_assertion or client_secret required):** the client
  app is confidential / public client flows are off. Fix: set **Allow public
  client flows = Yes** on the client app (then no secret is needed), or pass
  `--data-urlencode "client_secret=..."` if you still have the plaintext secret
  (the `TEST_CLIENT_SECRET` GitHub secret is write-only, so you usually do not).
- **`AADSTS90023` (ClientId doesn't match the one in cache):** the device code
  was initiated with a different `client_id` than the redemption used. Use one
  `CLIENT_ID` for both calls.
- **`invalid_client` / no token:** confirm the client id is the one in the APIM
  `<client-application-ids>` and has the delegated `user_impersonation`
  permission consented.

Verify the token is delegated (jwt.ms): `scp` = `user_impersonation`, a user
`oid`, and NO `roles` claim. A `roles`-only token is app-context and would take
the fixture branch, not OBO.

### 2. Call get_order_status with the delegated token

```bash
MCP_ACCESS_TOKEN="<the delegated token>" dotnet run --project src/McpTestClient -- "<s2 mcp_server_url>"
```

Because the token carries `scp`, the server takes the **delegated** branch ->
OBO exchange -> downstream. A returned order is the proof: the downstream only
accepts downstream-audience tokens (the negative test measures this), so a
delegated call that returns an order means the server exchanged the token via
OBO. If OBO had failed, the call would have thrown, not returned a result.

### 3. (Recommended) delegated passthrough-closed check

Present the SAME delegated token DIRECTLY to the downstream; expect 401. This is
the manually-evidenced twin of the automated negative test (docs/security.md).

```bash
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer <delegated token>" \
  "$(terraform -chdir=infra/terraform/scenarios/s1-entra-mcp-server output -raw downstream_base_url)/api/orders/CONTOSO-1001"
# expect 401
```

## Captured evidence

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

**What is established (positive arm).** With the gate ON, a delegated (`scp`)
user drove the delegated branch -> OBO -> downstream and returned both frozen
contract shapes (known id -> status, unknown id -> typed not-found). This shows
the assignment-required toggle does NOT break delegated OBO -- the sanctioned
path still works with the gate on. This satisfies issue-53's happy-path
re-validation (acceptance item 3, positive half). Verbatim McpTestClient
transcript to paste:

```
<paste the McpTestClient transcript for the assigned-user run here>
```

**What is NOT established (delegated negative arm) -- earlier claim RETRACTED.**
An earlier revision of this entry claimed an unassigned delegated user was
refused at the OBO exchange with AADSTS50105, "locating enforcement at the OBO
hop." That is retracted: the manual runs that probed this were confounded and do
NOT prove the delegated OBO path is gated.

- A run in which an *unassigned* user's delegated call still returned an order
  used a **Global Administrator** account. Global Administrators bypass
  `appRoleAssignmentRequired` entirely (VERIFIED, azure-docs-verifier
  2026-07-22), so that run is an EXPECTED bypass, not a gate failure -- and it is
  not a valid negative test.
- The run that reported AADSTS50105 has not been confirmed to use a non-admin
  user, so it cannot be relied on as a clean gate-fired result either (an admin
  would not get AADSTS50105 from this gate, so a valid negative result must come
  from a confirmed non-admin, unassigned, consented user).

The code path makes the confound legible: `GetOrderStatus.Run` has NO
delegated->app-only fallback (src/McpTools/Tools/GetOrderStatus.cs), and
`AcquireTokenOnBehalfOf` is not wrapped in a catch
(src/McpTools/Downstream/ManagedIdentityOboTokenAcquirer.cs), so a returned order
means the OBO exchange genuinely succeeded -- for the admin user, via the bypass.

**Whether `appRoleAssignmentRequired` even gates the OBO delegated-scope exchange
is UNPROVEN here and Learn-PARTIAL** (Microsoft Learn documents the requirement
for interactive sign-in and app-only token acquisition; it does not state the OBO
token-exchange step is gated -- azure-docs-verifier 2026-07-21 and 2026-07-22).
Issue-53's app-only gate (the MCP server SP must hold Orders.Read to get an
app-only downstream token) is the doc-VERIFIED, load-bearing claim and is
unaffected by any of this; the delegated OBO "consequence" is the secondary,
still-open question.

**To close it cleanly (not yet done):** re-run the negative test with a
**confirmed non-admin, unassigned, consented sandbox user** and capture, from the
McpTestClient output AND the MCP server Function App logs, that the call FAILS
(not returns an order) with AADSTS50105 at the OBO exchange. Only that closes the
delegated-path question; until then, do not assert the delegated path is gated.

- **Open / honest notes:**
  - This entry is **operator-attested**; the positive-arm transcript is pending
    paste. The delegated negative arm is retracted pending a clean non-admin run.
  - The exact `X-MS-CLIENT-PRINCIPAL` claim-type STRING form (short `scp` vs
    mapped schema URI) is still not directly asserted here; unchanged from the
    2026-07-19 run's open note.
  - Clean teardown of the `azuread` resources was again not exercised
    (`skip_teardown=true`); a full `skip_teardown=false` run still validates the
    destroy path.
