# Tradeoffs

Design tradeoffs and principles surfaced while building this platform, with
the concrete decision that surfaced each one. Recorded so the reasoning is
visible, not just the code.

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
