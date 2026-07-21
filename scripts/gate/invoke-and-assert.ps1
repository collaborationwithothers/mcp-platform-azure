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
    5. Registry convergence evidence, NON-BLOCKING. Probe /v0.1/servers
       anonymously (a 401 is the expected secure-by-default result; that surface
       is portal-auth-only and 401s a bearer token), then read the CONTROL-PLANE
       apis inventory (management.azure.com, the call stage's az credential) to
       check the auto-synced MCP server has converged -- match title==ServerName
       AND kind=='mcp' (the live 2024-06-01-preview apis list returns kind=mcp,
       which the documented enum omits). NOTHING here fails the run: the blocking
       gate (Tier 1) asserts only gateway and backend correctness. Registry
       membership is eventual-consistency (auto-sync up to 24 h; Learn), so
       convergence is recorded as evidence and monitored async (Tier 2, ADR-007).
       Captures the raw apis inventory as evidence. See ADR-007, COMPATIBILITY.md.
    6. Issue 10 (OBO thickening): run the OBO passthrough negative test,
       reusing the step-1 server-audience token as the inbound token
       presented directly to the downstream Orders API (tests/integration/
       obo-passthrough-negative.ps1). This does not exercise the OBO happy
       path -- see docs/decisions/ADR-006, "OBO exchange: the inbound-token
       gap" and "Testing strategy: the user-context token problem" for why
       that is validated manually, not here.

  Exits non-zero if the MCP client or the discovery assertions fail (Tier 1:
  gateway and backend). Step 5 (registry) is NON-BLOCKING: it records evidence
  and never exits non-zero, because registry convergence is an eventual-
  consistency concern monitored asynchronously (Tier 2, ADR-007), not a
  synchronous gate invariant. The gate does NOT auto-exercise interactive,
  client-driven discovery: that is validated manually in VS Code and recorded
  in docs/demos (spec: Testing Decisions).

.NOTES
  Verified 2026-07-19 against Microsoft Learn (see COMPATIBILITY.md):
  - Client-credentials scope form <resource>/.default and app-role claims:
    https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow
  - Registry convergence is read from the CONTROL-PLANE apis inventory
    (2024-06-01-preview, management.azure.com), which returns the auto-synced MCP
    server with kind=mcp; the data-plane /v0.1/servers surface is portal-auth-only
    and is only probed anonymously (COMPATIBILITY.md, ADR-007).
  - Explicit MCP-server registration is NOT automatable (no azapi payload, no
    az CLI command, no data-plane write operation; verified 2026-07-20), and
    APIM auto-sync is documented at up to 24 h, so the registry step is
    non-blocking evidence; convergence is monitored async (Tier 2, ADR-007). See
    COMPATIBILITY.md and docs/decisions/ADR-007:
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
# 5. Registry: NON-BLOCKING convergence evidence. The blocking gate (Tier 1)
#    proves gateway and backend correctness synchronously (steps 1-4 and 6) and
#    makes NO API Center assertion. Registry membership is an eventual-consistency
#    concern (APIM auto-sync is documented at up to 24 h; Learn), so this step
#    only RECORDS whether the MCP server has converged and NEVER fails the run.
#
#    Two surfaces, two roles (observed live 2026-07-20/21; COMPATIBILITY.md,
#    ADR-007):
#    - Anonymous /v0.1/servers probe: records the secure-by-default posture (401
#      expected). That MCP-registry surface is portal-auth-only and 401s a
#      headless bearer token, so it is NOT read authenticated here.
#    - Control-plane apis inventory (management.azure.com): this IS where the
#      auto-synced MCP server actually shows up. The live 2024-06-01-preview apis
#      list returns the synced server with kind=mcp (the documented enum omits
#      'mcp'; the live API is ahead of its docs). We match on title==ServerName
#      AND kind=='mcp' (the entry's own name is auto-generated). This is the read
#      the eventual Tier 2 monitor uses; here it is bounded, non-blocking evidence.
# ---------------------------------------------------------------------------
Write-Host "[5] Registry convergence evidence (non-blocking -- ADR-007)"

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

# 5b. Control-plane apis convergence read (evidence). Reads the API Center apis
#     inventory under the service ARM id with the call stage's az (management.
#     azure.com) credential. Wrapped so nothing here can fail the BLOCKING gate.
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
    Write-Host "::warning::Control-plane convergence read errored ($($_.Exception.Message)); recorded as inconclusive, not a gate failure."
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
note                          : NON-BLOCKING. Convergence is eventual (auto-sync up to 24h, Learn); monitored async per ADR-007. Read surface = control-plane apis inventory (kind=mcp), NOT /v0.1/servers.
"@
    Write-Host "  registry evidence written to $EvidenceDir (registry-apis-inventory.json, registry-poll-summary.txt)."
}

Write-Host ''
Write-Host "== Registry convergence evidence (non-blocking) =="
Write-Host "  anonymous /v0.1/servers : $anonStatus (portal-auth-only; 401 expected)"
Write-Host "  control-plane apis read : $convergeStatus"
Write-Host "  MCP server converged     : $converged$(if ($converged) { " (title='$ServerName', kind=mcp, name=$matchedName)" } else { '' })"
Write-Host "  (COMPATIBILITY.md + ADR-007: Tier 1 asserts gateway/backend; registry convergence is Tier 2, async.)"
if (-not $converged) {
    Write-Host "  MCP server '$ServerName' has not converged into the apis inventory within ${PollTimeoutSeconds}s -- expected under eventual consistency (auto-sync up to 24h); recorded as evidence, not a gate failure."
}
Write-Host "[5] Registry convergence evidence recorded (non-blocking). See docs/decisions/ADR-007."
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
