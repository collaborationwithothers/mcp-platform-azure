#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
  The v1 tracer's "call" stage: drives McpTestClient, the raw-HTTP discovery
  assertions, and the bounded registry poll against a live deployment
  (docs/specs/v1-tracer-bullet.md, Testing Decisions). Invoked by
  .github/workflows/ephemeral-env.yml between apply and destroy, in the
  live-test environment only.

.DESCRIPTION
  Steps, in order:
    1. Acquire a client-credentials bearer token for the server app audience on
       the dedicated test app registration (scope <audience>/.default), and a
       deliberately wrong-audience token (Graph .default) for the negative
       discovery check. Client credentials because the SDK's interactive
       auth-code flow cannot run in CI (spec: Testing Decisions).
    2. Run McpTestClient against the deployed gateway MCP endpoint with the
       server-audience token: initialize, tools/list, and the two tool
       contracts.
    3. Acquire a second valid server-audience token for a client without
       Orders.Read, call get_order_status, and require the deterministic
       tool-level 403 result.
    4. Run the raw-HTTP discovery assertions (401 / WWW-Authenticate / PRM /
       wrong-audience / shadow mcp_extension key).
    5. Registry convergence ASSERTION (deterministic, Option Y). The workflow's
       "Force registry convergence" step runs `az apic import-from-apim` (a
       synchronous, idempotent LRO) before this call stage, so the MCP server is
       already in the API Center inventory. Probe /v0.1/servers anonymously (a 401
       is the expected secure-by-default result; that surface is portal-auth-only),
       then ASSERT the server is in the CONTROL-PLANE apis inventory
       (management.azure.com, 2024-06-01-preview) -- match title==ServerName AND
       kind=='mcp' (the live apis list returns kind=mcp, which the documented enum
       omits). FATAL if absent (a short bounded retry covers residual projection
       lag). Captures the raw apis inventory as evidence. See ADR-007,
       COMPATIBILITY.md.
    6. Issue 10 (OBO thickening): run the OBO passthrough negative test,
       reusing the step-1 server-audience token as the inbound token
       presented directly to the downstream Orders API (tests/integration/
       obo-passthrough-negative.ps1). This does not exercise the OBO happy
       path -- see docs/decisions/ADR-006, "OBO exchange: the inbound-token
       gap" and "Testing strategy: the user-context token problem" for why
       that is validated manually, not here.

  Exits non-zero if the MCP client, the discovery assertions, or the registry
  convergence assertion fail. Registry convergence is made deterministic by the
  workflow forcing it synchronously (import-from-apim) before the call stage
  (Option Y, ADR-007), so step 5 asserts it rather than waiting out auto-sync.
  The gate does NOT auto-exercise interactive, client-driven discovery: that is
  validated manually in VS Code and recorded in docs/demos (spec: Testing
  Decisions).

.NOTES
  Verified 2026-07-19 against Microsoft Learn (see COMPATIBILITY.md):
  - Client-credentials scope form <resource>/.default and app-role claims:
    https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow
  - Registry convergence is read from the CONTROL-PLANE apis inventory
    (2024-06-01-preview, management.azure.com), which returns the auto-synced MCP
    server with kind=mcp; the data-plane /v0.1/servers surface is portal-auth-only
    and is only probed anonymously (COMPATIBILITY.md, ADR-007).
  - APIM auto-sync is documented at up to 24 h (Learn), so it cannot be asserted
    synchronously; the gate forces convergence via `az apic import-from-apim` (a
    synchronous, idempotent LRO that coexists with the auto-sync link; verified
    live 2026-07-21) in the workflow, then asserts it here (Option Y, ADR-007):
    https://learn.microsoft.com/azure/api-center/synchronize-api-management-apis
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$McpServerUrl,
    [Parameter(Mandatory)][string]$PrmUrl,
    [Parameter(Mandatory)][string]$RegistryEndpointUrl,
    [Parameter(Mandatory)][string]$BackendMcpUrl,
    # Server app ID URI (entra_validation.audience); the PRM 'resource' and the
    # audience the client-credentials token targets.
    [Parameter(Mandatory)][string]$Audience,
    [Parameter(Mandatory)][string]$TenantId,
    # Dedicated test client app (client credentials).
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory)][string]$ClientWithoutRoleId,
    [Parameter(Mandatory)][string]$ClientWithoutRoleSecret,
    # Resource name of the synced MCP server (s2 var server_name); the token the
    # authenticated registry poll asserts is present in the servers list.
    [Parameter(Mandatory)][string]$ServerName,
    # Issue 10: the downstream Orders API's GET /api/orders/{orderId} URL
    # (s1 output downstream_base_url + "/api/orders/CONTOSO-1001").
    [Parameter(Mandatory)][string]$DownstreamOrderStatusUrl,
    [string]$McpExtensionKey = '',
    [string]$McpTestClientProject,
    [string]$RegistryResource = 'https://azure-apicenter.net',
    # ARM resource id of the API Center service (s2 output api_center_id). The
    # non-blocking convergence evidence reads the CONTROL-PLANE apis inventory
    # under this id (management.azure.com), which is what actually shows the
    # auto-synced MCP server (kind=mcp) -- the data-plane /v0.1/servers surface is
    # portal-auth-only and 401s a bearer token (COMPATIBILITY.md, ADR-007). Empty
    # => convergence read skipped (anonymous /v0.1/servers probe only).
    [string]$ApiCenterResourceId = '',
    # Bounded window for the authenticated registry read. The Data Reader RBAC
    # and the endpoint are created during `terraform apply` (minutes before this
    # call stage), so this covers residual RBAC propagation and a brief sync-
    # evidence look, NOT a cold wait. Dropped from 300 s: the old value was sized
    # for auto-sync, which is up to 24 h (Learn) and never gated here anyway.
    [int]$PollTimeoutSeconds = 90,
    [int]$PollIntervalSeconds = 15,
    # Optional dir to write the captured /v0.1/servers response body plus a
    # summary, uploaded as a gate artifact so the (doc-UNVERIFIABLE) live
    # response shape can be pinned in a follow-up. Empty => log only.
    [string]$EvidenceDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptDir '..' '..')
if ([string]::IsNullOrEmpty($McpTestClientProject)) {
    $McpTestClientProject = Join-Path $repoRoot 'src/McpTestClient/McpTestClient.csproj'
}
$discoveryScript = Join-Path $repoRoot 'tests/integration/discovery-assertions.ps1'
$oboNegativeScript = Join-Path $repoRoot 'tests/integration/obo-passthrough-negative.ps1'

$tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

function Get-ClientCredentialToken {
    param(
        [string]$Scope,
        [string]$TokenClientId = $ClientId,
        [string]$TokenClientSecret = $ClientSecret
    )
    try {
        $resp = Invoke-RestMethod -Uri $tokenEndpoint -Method Post `
            -ContentType 'application/x-www-form-urlencoded' -Body @{
            client_id     = $TokenClientId
            client_secret = $TokenClientSecret
            scope         = $Scope
            grant_type    = 'client_credentials'
        }
    }
    catch {
        throw "Token acquisition failed for scope '$Scope': $($_.Exception.Message)"
    }
    if ([string]::IsNullOrEmpty($resp.access_token)) {
        throw "Token endpoint returned no access_token for scope '$Scope'."
    }
    return $resp.access_token
}

Write-Host "== Tracer call stage =="
Write-Host "MCP endpoint : $McpServerUrl"
Write-Host "Registry     : $RegistryEndpointUrl"
Write-Host ''

# ---------------------------------------------------------------------------
# 1. Tokens.
# ---------------------------------------------------------------------------
Write-Host "[1] Acquiring client-credentials tokens"
$mcpToken = Get-ClientCredentialToken -Scope "$Audience/.default"
Write-Host "  server-audience token acquired ($Audience)."
$missingRoleToken = Get-ClientCredentialToken `
    -Scope "$Audience/.default" `
    -TokenClientId $ClientWithoutRoleId `
    -TokenClientSecret $ClientWithoutRoleSecret
Write-Host "  server-audience token acquired for the caller without Orders.Read."
$wrongToken = Get-ClientCredentialToken -Scope 'https://graph.microsoft.com/.default'
Write-Host "  wrong-audience token acquired (Microsoft Graph)."
Write-Host ''

# ---------------------------------------------------------------------------
# 2. McpTestClient (session + tool contracts).
# ---------------------------------------------------------------------------
Write-Host "[2] McpTestClient session and tool assertions"
$env:MCP_SERVER_ENDPOINT = $McpServerUrl
$env:MCP_ACCESS_TOKEN = $mcpToken
dotnet run --project $McpTestClientProject -c Release
$clientExit = $LASTEXITCODE
$env:MCP_ACCESS_TOKEN = $null
if ($clientExit -ne 0) {
    throw "McpTestClient failed (exit $clientExit)."
}
Write-Host ''

# ---------------------------------------------------------------------------
# 3. App-role negative path: valid token reaches the MCP tool, but the caller
#    lacks Orders.Read and receives the deterministic tool-level 403.
# ---------------------------------------------------------------------------
Write-Host "[3] App-role authorization negative assertion"
$env:MCP_ACCESS_TOKEN = $missingRoleToken
$env:MCP_EXPECT_FORBIDDEN_ROLE = 'Orders.Read'
dotnet run --project $McpTestClientProject -c Release
$missingRoleExit = $LASTEXITCODE
$env:MCP_EXPECT_FORBIDDEN_ROLE = $null
$env:MCP_ACCESS_TOKEN = $null
if ($missingRoleExit -ne 0) {
    throw "McpTestClient missing-role assertion failed (exit $missingRoleExit)."
}
Write-Host ''

# ---------------------------------------------------------------------------
# 4. Raw-HTTP discovery assertions.
# ---------------------------------------------------------------------------
Write-Host "[4] Raw-HTTP discovery assertions"
& $discoveryScript `
    -McpServerUrl $McpServerUrl `
    -PrmUrl $PrmUrl `
    -ExpectedResource $McpServerUrl `
    -WrongAudienceToken $wrongToken `
    -BackendMcpUrl $BackendMcpUrl `
    -McpExtensionKey $McpExtensionKey
if ($LASTEXITCODE -ne 0) {
    throw "Discovery assertions failed (exit $LASTEXITCODE)."
}
Write-Host ''

# ---------------------------------------------------------------------------
# 5. Registry: DETERMINISTIC convergence ASSERTION (Option Y, ADR-007). The
#    workflow's "Force registry convergence" step runs `az apic import-from-apim`
#    -- a synchronous, idempotent LRO that coexists with the production auto-sync
#    link (verified live 2026-07-21) -- BEFORE this call stage, so the MCP server
#    is already in the API Center inventory. This step therefore ASSERTS its
#    presence rather than waiting out auto-sync (up to 24 h). The bounded retry is
#    a safety margin for residual projection lag, not an eventual-consistency wait.
#
#    - Anonymous /v0.1/servers probe: records the secure-by-default posture (401
#      expected). That MCP-registry surface is portal-auth-only and 401s a bearer
#      token, so it is only probed anonymously, never asserted.
#    - Control-plane apis inventory (management.azure.com): the surface where the
#      MCP server shows up. The live 2024-06-01-preview apis list returns it with
#      kind=mcp (the documented enum omits 'mcp'; the live API is ahead of docs).
#      Assert an entry with title==ServerName AND kind=='mcp' (its own name is
#      auto-generated). FATAL if absent -- the forced import should have landed it.
# ---------------------------------------------------------------------------
Write-Host "[5] Registry convergence assertion (deterministic -- Option Y, ADR-007)"

# 5a. Anonymous /v0.1/servers probe. Expected 401 (secure-by-default): evidence.
$anonStatus = 'error'
try {
    $anon = Invoke-WebRequest -Uri $RegistryEndpointUrl -Method Get -SkipHttpErrorCheck -ErrorAction Stop
    $anonStatus = [int]$anon.StatusCode
}
catch {
    $anonStatus = "error: $($_.Exception.Message)"
}
Write-Host "  anonymous /v0.1/servers probe: $anonStatus (401 expected = secure-by-default; recorded, never a gate)."
if ("$anonStatus" -ne '401') {
    Write-Host "::warning::Registry anonymous probe returned '$anonStatus', not 401. The data-plane registry may be anonymously readable; confirm the intended access posture (docs/security.md, docs/runbooks/registry-anonymous-access.md)."
}

# 5b. Control-plane apis convergence read. Reads the API Center apis inventory
#     under the service ARM id with the call stage's az (management.azure.com)
#     credential. The read is wrapped so an unexpected error is caught cleanly;
#     the assertion after the loop decides pass/fail.
$converged = $false
$convergeStatus = 'skipped'
$matchedName = ''
$apisRaw = ''
try {
    if ([string]::IsNullOrEmpty($ApiCenterResourceId)) {
        Write-Host "::warning::ApiCenterResourceId not provided; skipping the control-plane convergence read (anonymous probe only)."
        $convergeStatus = 'skipped (no ApiCenterResourceId)'
    }
    elseif (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "::warning::az CLI not found; skipping the control-plane convergence read."
        $convergeStatus = 'skipped (no az)'
    }
    else {
        $apisUrl = "https://management.azure.com$ApiCenterResourceId/workspaces/default/apis?api-version=2024-06-01-preview"
        $deadline = (Get-Date).AddSeconds($PollTimeoutSeconds)
        $attempt = 0
        while ((Get-Date) -lt $deadline -and -not $converged) {
            $attempt++
            $apisRaw = (az rest --method GET --url $apisUrl -o json 2>$null) -join "`n"
            if (-not [string]::IsNullOrEmpty($apisRaw)) {
                $convergeStatus = 'read ok'
                $items = @()
                try { $items = ($apisRaw | ConvertFrom-Json).value } catch { $items = @() }
                foreach ($api in $items) {
                    try {
                        if ("$($api.properties.title)" -eq $ServerName -and "$($api.properties.kind)" -eq 'mcp') {
                            $converged = $true
                            $matchedName = "$($api.name)"
                            break
                        }
                    }
                    catch { }
                }
            }
            else {
                $convergeStatus = 'read failed/unauthorized'
            }
            if (-not $converged) {
                $remaining = [int]($deadline - (Get-Date)).TotalSeconds
                Write-Host "  attempt ${attempt}: MCP server '$ServerName' (kind=mcp) not yet in the apis inventory ($convergeStatus); ${remaining}s left."
                if ($remaining -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
            }
        }
    }
}
catch {
    Write-Host "::warning::Control-plane convergence read errored ($($_.Exception.Message)); the assertion below treats an unreadable inventory as a failure."
    $convergeStatus = "error: $($_.Exception.Message)"
}

# Capture evidence artifacts (empty EvidenceDir => log only): the raw apis
# inventory (the real live shape, incl. the undocumented kind=mcp) + a summary.
if (-not [string]::IsNullOrEmpty($EvidenceDir)) {
    $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
    Set-Content -Path (Join-Path $EvidenceDir 'registry-apis-inventory.json') -Value "$apisRaw" -Encoding utf8
    Set-Content -Path (Join-Path $EvidenceDir 'registry-poll-summary.txt') -Encoding utf8 -Value @"
anonymous /v0.1/servers status : $anonStatus (portal-auth-only surface; 401 expected)
control-plane apis read        : $convergeStatus
MCP server '$ServerName' converged (title match + kind=mcp) : $converged
matched auto-generated api name : $(if ($matchedName) { $matchedName } else { 'none' })
poll window seconds            : $PollTimeoutSeconds
note                          : Option Y (ADR-007). Convergence is FORCED synchronously by the workflow's import-from-apim step, then ASSERTED here. Read surface = control-plane apis inventory (kind=mcp), NOT /v0.1/servers.
"@
    Write-Host "  registry evidence written to $EvidenceDir (registry-apis-inventory.json, registry-poll-summary.txt)."
}

Write-Host ''
Write-Host "== Registry convergence assertion (Option Y) =="
Write-Host "  anonymous /v0.1/servers : $anonStatus (portal-auth-only; 401 expected, evidence)"
Write-Host "  control-plane apis read : $convergeStatus"
Write-Host "  MCP server converged     : $converged$(if ($converged) { " (title='$ServerName', kind=mcp, name=$matchedName)" } else { '' })"
Write-Host "  (COMPATIBILITY.md + ADR-007: convergence is forced synchronously via import-from-apim, then asserted here.)"

if ($convergeStatus -like 'skipped*') {
    Write-Host "::warning::Control-plane convergence read skipped ($convergeStatus); cannot assert registry convergence. Pass -ApiCenterResourceId and ensure az is available (the live-gate workflow always does). Not failing the run in this non-gate context."
}
elseif (-not $converged) {
    throw "Registry convergence assertion FAILED: MCP server '$ServerName' (kind=mcp) is not in the API Center apis inventory within $PollTimeoutSeconds s (read: $convergeStatus). Option Y forces convergence via 'az apic import-from-apim' in the workflow's 'Force registry convergence' step before this call stage; its absence means the import did not land the server, or the apis api-version/shape changed. See docs/decisions/ADR-007 and COMPATIBILITY.md."
}
else {
    Write-Host "[5] Registry convergence ASSERTED: MCP server '$ServerName' present (kind=mcp, name=$matchedName)."
}
Write-Host ''

# ---------------------------------------------------------------------------
# 6. Issue 10: OBO passthrough negative test. Reuses the step-1
#    server-audience token ($mcpToken) as the inbound token presented
#    directly to the downstream Orders API. Does not need a delegated/user
#    token (ADR-006, "Testing strategy: the user-context token problem").
# ---------------------------------------------------------------------------
Write-Host "[6] OBO passthrough negative test"
& $oboNegativeScript `
    -DownstreamOrderStatusUrl $DownstreamOrderStatusUrl `
    -InboundServerAudienceToken $mcpToken
if ($LASTEXITCODE -ne 0) {
    throw "OBO passthrough negative test failed (exit $LASTEXITCODE)."
}
Write-Host ''

Write-Host "== Call stage passed =="
exit 0
