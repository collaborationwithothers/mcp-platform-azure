# Tradeoffs

Design tradeoffs and principles surfaced while building this platform, with
the concrete decision that surfaced each one. Recorded so the reasoning is
visible, not just the code.

## Build a tracer bullet through the preview surfaces first

Surfaced 2026-07-15 when the v1 slice landed its live apply-call-destroy gate
(issue 9 / ticket 5). This records the reasoning the spec (Verification and
compatibility; Further Notes) asked to capture when the slice lands. It sits
alongside, not inside, ADR-001: ADR-001 fixes the gateway-fronted architecture;
this explains why the first thing built against that architecture was a thin
vertical slice rather than a complete module library.

### The principle

When the risk in a system is concentrated at the seams between newest-surface
components, build the narrowest end-to-end path that touches every seam before
building any component out in depth. A tracer bullet is thin implementation
behind production-shaped interfaces: it fires one round down the whole barrel so
you can see where it lands, rather than perfecting the first inch of the barrel.

The alternative -- build each module fully, then integrate -- defers the seam
risk to the end, which is exactly where it is most expensive to discover. If the
APIM MCP passthrough resource cannot be modelled the way you assumed, or API
Center's asynchronous sync does not surface a server the way the docs imply, you
want to learn that in week one against a one-tool deployment, not in month three
against four finished modules whose interfaces have already hardened around the
wrong assumption.

### Why it applied here

Every load-bearing uncertainty in this platform is at a seam, and all of them
are on preview or newly-GA surfaces that change monthly:

- Entra built-in auth (Easy Auth) on a Functions-hosted MCP server, including
  closing the `mcp_extension` shadow-key path.
- The APIM MCP server resource: a GA feature exposed only through a preview ARM
  API version (2025-09-01-preview) with no native azurerm resource, so it is
  hand-authored azapi.
- API Center registration by APIM auto-sync and discovery on the data-plane MCP
  registry endpoint, whose read-access posture turned out to be platform-
  determined with no ARM surface at all.

The tracer proved these seams work together in one reproducible deploy: one
synthetic tool travelling MCP client -> APIM MCP gateway -> Functions MCP server
-> synthetic result, discoverable through API Center, provisioned end to end by
Terraform, proven by a live apply-call-destroy gate. Building the modules out in
depth first would have hidden the seam behaviour behind unfinished components.

### What it cost, honestly

The tracer's own live runs are where the preview surfaces bit back, and the cost
landed as a string of small fix PRs, not a clean first pass:
`COMPATIBILITY.md` records where the deployed preview resource providers
disagreed with their own published docs -- the APIM MCP `mcpProperties.endpoints`
map-vs-array shape, the `backendId`-not-`serviceUrl` wiring for `type=mcp`, the
API Center `apiSources` `targetEnvironmentId` workspace-relative path, and the
API Center / APIM soft-delete tombstones that forced unique-per-run names. Every
one of those is a seam fact that a module-first build would have discovered later
and paid for more dearly. The tracer's thin-implementation-thick-interface shape
is what lets the follow-on thickening PRs (OBO, multi-tenant products and
quotas, content safety, private networking, observability) extend behaviour
without restructuring the interfaces the compositions already depend on.

## Singletons belong to the layer whose cardinality they share

Surfaced 2026-07-12 in the governance review of the S2 gateway modules
(ticket 3, PR #16).

### The principle

A singleton -- a resource that can exist at most once within a given parent
scope -- must be owned by the module whose instance cardinality matches that
scope. If a module that can be instantiated more than once within a scope
owns a resource that can exist only once in that scope, then the module
cannot in fact be instantiated more than once: the second instance collides
on the singleton. The singleton has been baked into the wrong layer, and the
collision surfaces only at apply time, not at review time.

The test is direct: for any resource a module creates, ask whether the
owning module could be instantiated twice within the same parent scope. If
it could, and the resource is a singleton in that scope, the resource is in
the wrong module. Move it up to the layer that is itself a singleton in that
scope.

### Worked example: the root PRM document

The protected resource metadata (PRM) document is served at the gateway root
well-known path, `/.well-known/oauth-protected-resource`. There is exactly
one root path per API Management service, so exactly one root PRM document
per gateway (see ADR-006 for why the root, not a subpath).

The first implementation created the root PRM API inside apim-mcp-server,
the module for a single MCP server. But apim-mcp-server can be instantiated
more than once against one gateway (several MCP servers behind one APIM). A
second instance would try to create a second API at the root path (`path =
""`) and collide. The singleton (one root document per gateway) had been
placed in a layer that is not a singleton per gateway (the server).

The fix moved the root PRM API, its operation, and its return-response
policy into apim-gateway, which is instantiated once per gateway. Now the
cardinalities match: one gateway, one root document. Only the document's
contents describe a specific server, and those flow into the gateway module
as inputs. A second MCP server added to the same gateway reuses the one
document rather than fighting over the root path.

What stayed in apim-mcp-server is the part whose cardinality does match the
server: the 401 plus `WWW-Authenticate` challenge in its server-scope
policy. The challenge is per-server; the document it points at is
per-gateway. Splitting them along the cardinality boundary is the whole
point.
