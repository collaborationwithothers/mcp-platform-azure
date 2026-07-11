# Infra Context

The provisioning domain: Terraform modules, azapi and azurerm resources, and the
APIM and API Center surfaces that host and govern MCP servers (scenario S3, plus
the compositions that stand up S1 and S2). Glossary only. ASCII punctuation.

## Language

**Scenario composition**:
A Terraform root that composes modules to stand up one scenario at one deployment
profile. It is the unit of remote-state isolation (one state key per composition).
_Avoid_: stack, environment, root module

**Deployment profile**:
A named variant selected by a variable that composes the same modules differently,
for example public-demo (Basic v2, public endpoints) versus private (Standard v2,
isolated). v1 builds public-demo only.
_Avoid_: environment, tier, flavour

**Thick interface**:
A module input and output contract designed for the full feature set even when the
implementation behind it is deliberately minimal, so later work extends behaviour
without restructuring the interface its callers depend on.
_Avoid_: stable API, facade

**Tracer bullet**:
The narrowest end-to-end slice, provisioned and proven by a live run, built to
retire preview-surface risk before breadth. Thin implementation behind thick
interfaces.
_Avoid_: MVP, spike, proof of concept

**AVM wrapper**:
A local module that wraps an Azure Verified Module and exposes this repo's stable
interface, keeping the AVM module a swappable implementation detail.
_Avoid_: passthrough module, shim

**Passthrough MCP server**:
An APIM MCP server that forwards to an external backend which owns the tool
surface, as opposed to a REST-backed MCP server where APIM owns the tools. Modelled
in azapi as an api of type mcp with a serviceUrl.
_Avoid_: proxy server, existing server

**Registry projection**:
API Center treated as a downstream inventory kept current by auto-sync from the
source of truth (APIM), rather than a hand-declared list. The production-correct
posture for the registry plane.
_Avoid_: catalog, source of truth

**Live-test environment**:
The single gated environment in which terraform apply and destroy may run. Apply
and destroy never run anywhere else.
_Avoid_: sandbox, CI environment

**Ephemeral**:
The apply, demo, destroy lifecycle in which nothing is left running; residual
resources are removed by an expiry-tag cleanup sweep.
_Avoid_: temporary, throwaway
