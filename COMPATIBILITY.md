# COMPATIBILITY

This repo depends on Azure features that are preview or newly GA, and on ARM
API versions that are still -preview even where the feature is GA. This file
tracks what we depend on, what we have pinned, and when each claim was last
verified against Microsoft documentation.

Rules:
- Every azapi resource in /infra pins an explicit ARM API version and has a
  row here.
- Any PR that adds or changes a pin updates this file in the same PR.
- "Last verified" means a human or agent checked the linked doc on that date,
  not that the doc was published then.
- If CI or a live test breaks because a preview surface changed, the fix PR
  updates this table and notes the breakage under History.

## Feature status (seeded from blueprint research, verified 2026-07-08)

| Component | Status | Notes | Last verified |
|---|---|---|---|
| Azure Functions MCP extension (tool triggers) | GA (announced Nov 2025) | .NET isolated worker; conflicting signals seen on .NET worker package versioning (a -preview package version observed post-GA); re-verify and record exact package version at first pin | 2026-07-08 |
| Functions MCP extension: resource triggers | GA | | 2026-07-08 |
| Functions MCP extension: prompt triggers, MCP Apps, one-click auth | Preview | not used in v1 | 2026-07-08 |
| Functions self-hosted MCP SDK servers (custom handlers) | Preview | stateless only; gated phase, not v1 | 2026-07-08 |
| APIM MCP servers (expose REST as MCP, passthrough) | GA (feature) | REST-export servers: tools only; not on Consumption tier; not in workspaces | 2026-07-08 |
| APIM MCP server ARM surface | Preview API version | Microsoft.ApiManagement/service/apis, apiType=mcp, API version 2025-09-01-preview at time of research | 2026-07-08 |
| APIM llm-content-safety for MCP tool calls | GA (Build 2026) | | 2026-07-08 |
| API Center data plane MCP registry | GA | no azurerm resource (provider issue #26200); azapi with 2024-06-01-preview API version at time of research | 2026-07-08 |
| MCP Enterprise-Managed Authorization (EMA) extension | Spec stable 2026-06-18 | Okta first spec-level IdP; native Entra ID spec-level support UNVERIFIED; not built in this repo, see ADR-006 | 2026-07-08 |

## Pinned versions

Populated as code lands. One row per pin.

| What | Pin | Where | Rationale | Last verified | Doc link |
|---|---|---|---|---|---|
| (none yet) | | | | | |

Expected early rows: terraform required_version, azurerm provider, azapi
provider, azapi API version per resource type, .NET SDK, Functions MCP
extension package, marketplace GitHub Actions.

## History

- 2026-07-08: file seeded from blueprint research. No code pins exist yet.