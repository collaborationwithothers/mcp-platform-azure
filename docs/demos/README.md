# Demos

Demo scripts and manual walkthroughs for the v1 tracer. Everything here runs
against an already-deployed tracer (for example during the ephemeral live-test
window from `.github/workflows/ephemeral-env.yml`, or a manual deploy). Nothing
here deploys anything, and the tracer is ephemeral by design (apply -> call ->
destroy in the gated live-test run only), so a demo is a short-lived thing.

All demo data is synthetic and labelled synthetic (order ids CONTOSO-1001 to
CONTOSO-1005). No latency, throughput, or cost figures are printed by any demo:
per the repo's honesty rules, no performance number is written that was not
measured under a defined method, and a demo warm-up is not that.

## Scripted demo: the governed path

`scripts/demo/demo.ps1` walks the full governed path end to end:

1. Warms the endpoint (Flex Consumption and APIM can cold-start; a 401 here is
   the expected no-token response and warms the path).
2. Fetches the RFC 9728 protected resource metadata document the gateway serves
   at its root well-known path, anonymously (a client must be able to read it
   before it has a token).
3. Acquires a client-credentials token for the server app on the dedicated test
   app registration and makes one authenticated `get_order_status` call through
   the gateway via `McpTestClient`.

```pwsh
pwsh scripts/demo/demo.ps1 `
  -McpServerUrl  "<s2 output mcp_server_url>" `
  -PrmUrl        "<s2 output prm_url>" `
  -Audience      "api://<server-app-id>" `
  -TenantId      "<tenant-id>" `
  -ClientId      "<test-client-app-id>" `
  -ClientSecret  "<test-client-secret>"
```

The client id/secret are the dedicated test client app from
[`docs/runbooks/entra-app-registrations.md`](../runbooks/entra-app-registrations.md);
never commit them. This is the same non-interactive token acquisition the live
gate uses, so the scripted demo shows exactly what the gate asserts.

## Manual walkthrough: interactive discovery in VS Code

The live gate validates non-interactive session and discovery artifacts
(`scripts/gate/invoke-and-assert.ps1`). It deliberately does NOT auto-exercise
client-driven interactive discovery -- a host resolving the challenge, running
the interactive OAuth flow, and listing tools -- because that path needs an
interactive redirect the CI gate cannot perform (spec: Testing Decisions). That
path is validated manually here and recorded so the human path is shown even
though the gate does not automate it.

Steps (record the outcome and the date each time you run it against a fresh
deploy):

1. In VS Code, open the MCP servers view and add an MCP server pointing at the
   gateway MCP endpoint (`mcp_server_url`). Do not paste a token.
2. The host makes an unauthenticated request, receives the 401 with the
   `WWW-Authenticate: Bearer resource_metadata="..."` challenge, resolves the
   protected resource metadata document at the gateway root, and starts the
   interactive OAuth 2.1 sign-in against Microsoft Entra.
3. Complete the sign-in. Confirm the host then lists `get_order_status` and can
   call it for a known id (CONTOSO-1003 -> Processing) and an unknown id (typed
   not-found).

### MCP Inspector

[MCP Inspector](https://github.com/modelcontextprotocol/inspector) is a useful
second interactive client for the same walkthrough. The pinned, last-verified
version is tracked in [`COMPATIBILITY.md`](../../COMPATIBILITY.md) (Pinned
versions) so a stale tool version stays visible and re-checkable without adding
new automation to this slice.

```
npx @modelcontextprotocol/inspector@<pinned-version>
```

Point it at `mcp_server_url` and confirm the same challenge -> sign-in ->
tools/list -> tool-call sequence. Record the version you used and the date.

## Last-run log

Record each manual interactive-discovery run here (date, tracer deploy, client,
outcome). Left empty until the first live deploy is walked through by a human.

| Date | Client | Deploy | Outcome |
|---|---|---|---|
| _pending first live run_ | | | |
