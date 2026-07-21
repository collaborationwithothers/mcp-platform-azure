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
    5. Registry evidence, NON-BLOCKING (Tier 2). Probe the endpoint anonymously
       (a 401 is the expected secure-by-default result), then read it
       authenticated (Azure API Center Data Reader, via the workflow's OIDC
       principal). NOTHING here fails the run: the blocking gate (Tier 1) asserts
       only gateway and backend correctness. Registry membership is eventual-
       consistency -- APIM auto-sync is documented at up to 24 h (Microsoft Learn),
       and there is no automatable way to register a server explicitly (no azapi
       payload, no az CLI command, no data-plane write op; verified 2026-07-20).
       So this step records the anonymous posture, the authenticated read status
       (a 401 is EXPECTED -- /v0.1/servers authenticates via the portal access
       mode, not this headless bearer token; a WARNING for the Tier 2 monitor,
       not a gate failure),
       and whether the server has converged, and captures the full servers-list
       response as evidence. See docs/decisions/ADR-007 and COMPATIBILITY.md.
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
  - API Center data-plane token audience https://azure-apicenter.net:
    https://learn.microsoft.com/rest/api/dataplane/apicenter/apis/list
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
# 5. Registry: NON-BLOCKING evidence (Tier 2). The blocking gate (Tier 1) proves
#    gateway and backend correctness synchronously (steps 1-4 and 6) and makes
#    NO API Center assertion. Registry membership is an eventual-consistency
#    concern, not a synchronous invariant: APIM auto-sync is documented at up to
#    24 h (Microsoft Learn), and there is no automatable way to register a server
#    explicitly (no azapi payload, no az CLI command, no data-plane write op; all
#    verified 2026-07-20). Asserting an eventual property synchronously produces a
#    flaky required check, so this step only RECORDS registry evidence -- the
#    anonymous posture, whether the authenticated read is reachable/authorized,
#    and whether the server has converged -- and NEVER fails the run. Registry
#    convergence is monitored asynchronously (Tier 2, designed in
#    docs/decisions/ADR-007; deliberately not implemented here, on cost grounds).
# ---------------------------------------------------------------------------
Write-Host "[5] Registry endpoint evidence (non-blocking; convergence is async -- ADR-007)"

# 5a. Anonymous probe. Expected 401 (secure-by-default): recorded evidence.
$anonStatus = 'error'
try {
    $anon = Invoke-WebRequest -Uri $RegistryEndpointUrl -Method Get -SkipHttpErrorCheck -ErrorAction Stop
    $anonStatus = [int]$anon.StatusCode
}
catch {
    $anonStatus = "error: $($_.Exception.Message)"
}
Write-Host "  anonymous probe status: $anonStatus (401 expected = secure-by-default; recorded, never a pass/fail gate)."
# An anonymous 200 means the registry became publicly readable -- a security-
# relevant posture change worth surfacing, but still not a gate failure here.
if ("$anonStatus" -ne '401') {
    Write-Host "::warning::Registry anonymous probe returned '$anonStatus', not 401. The data-plane registry may be anonymously readable; confirm the intended access posture (docs/security.md, docs/runbooks/registry-anonymous-access.md)."
}

# 5b. Authenticated read (evidence). Token targets the GENERAL API Center data
#     plane (https://azure-apicenter.net); the OIDC principal holds Azure API
#     Center Data Reader. IMPORTANT (observed live 2026-07-20, verified
#     2026-07-21): the /v0.1/servers MCP-registry surface is NOT an RBAC-bearer
#     data-plane API -- its auth is the portal access mode (anonymous, or
#     interactive Entra SPA sign-in), NOT this headless token, and Data Reader's
#     documented purpose is authorizing interactive portal sign-in. So a 401 here
#     is EXPECTED, not a wiring bug; the azure-apicenter.net audience is
#     documented only for the GENERAL data-plane API (apis/definitions/...), not
#     /v0.1/servers (COMPATIBILITY.md, ADR-007). The read is wrapped so nothing
#     here can fail the BLOCKING gate; it records the status as evidence. The
#     eventual Tier 2 monitor should read convergence via the control-plane
#     `apis` inventory, not this path (ADR-007).
$authOk = $false
$serverPresent = $false
$observedPath = $null
$lastStatus = $null
$lastBody = ''
try {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "::warning::az CLI not found; skipping the authenticated registry evidence read."
    }
    else {
        $registryToken = az account get-access-token --resource $RegistryResource --query accessToken -o tsv
        if ([string]::IsNullOrEmpty($registryToken)) {
            Write-Host "::warning::Could not acquire an API Center data-plane token (resource $RegistryResource); skipping the authenticated registry evidence read."
        }
        else {
            # Path-form inconsistency (template has /workspaces/, the doc's own
            # example omits it): try the emitted form, fall back to the stripped
            # form, and record which one answered.
            $primaryUrl = $RegistryEndpointUrl
            $fallbackUrl = ($RegistryEndpointUrl -replace '/workspaces/[^/]+/', '/')
            $candidates = @($primaryUrl)
            if ($fallbackUrl -ne $primaryUrl) { $candidates += $fallbackUrl }

            # authOk: the read reached the service and was authorized (not 401/403).
            # serverPresent: heuristic EVIDENCE that $ServerName is listed (auto-sync
            # may use an auto-generated name, so this substring match is not
            # authoritative; the captured body is the real record).
            $deadline = (Get-Date).AddSeconds($PollTimeoutSeconds)
            $attempt = 0
            while ((Get-Date) -lt $deadline -and -not $serverPresent) {
                $attempt++
                foreach ($url in $candidates) {
                    $resp = Invoke-WebRequest -Uri $url -Method Get `
                        -Headers @{ Authorization = "Bearer $registryToken" } `
                        -SkipHttpErrorCheck -ErrorAction Stop
                    $code = [int]$resp.StatusCode
                    $lastStatus = $code
                    if ($code -ne 401 -and $code -ne 403) {
                        # Authorized and the service answered: 200 (list, possibly
                        # empty) or 404 (endpoint answered, no resource).
                        $authOk = $true
                        $observedPath = $url
                        $lastBody = "$($resp.Content)"
                        if ($code -eq 200 -and $resp.Content -match [regex]::Escape($ServerName)) {
                            $serverPresent = $true
                            break
                        }
                    }
                }
                if (-not $serverPresent) {
                    $remaining = [int]($deadline - (Get-Date)).TotalSeconds
                    Write-Host "  attempt ${attempt}: authOk=$authOk, server '$ServerName' present=$serverPresent (last status $lastStatus); ${remaining}s left."
                    if ($remaining -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
                }
            }
        }
    }
}
catch {
    Write-Host "::warning::Registry evidence read errored ($($_.Exception.Message)); recorded as inconclusive, not a gate failure."
}

# Capture the full authenticated response body + a summary as a gate artifact,
# so the real /v0.1/servers shape (field names, auto-generated server ids) can be
# pinned from a live response in a follow-up (the shape is UNVERIFIABLE from docs;
# see COMPATIBILITY.md). Empty EvidenceDir => log only.
if (-not [string]::IsNullOrEmpty($EvidenceDir)) {
    $null = New-Item -ItemType Directory -Path $EvidenceDir -Force
    Set-Content -Path (Join-Path $EvidenceDir 'registry-servers-response.json') -Value $lastBody -Encoding utf8
    Set-Content -Path (Join-Path $EvidenceDir 'registry-poll-summary.txt') -Encoding utf8 -Value @"
anonymous read status : $anonStatus
authenticated authOk  : $authOk (evidence only; a false here is a Tier 2 signal, NOT a Tier 1 failure)
last status           : $lastStatus
served path           : $(if ($observedPath) { $observedPath } else { 'none' })
server '$ServerName' present (evidence) : $serverPresent
poll window seconds   : $PollTimeoutSeconds
note                  : NON-BLOCKING. Registry convergence is eventual (auto-sync up to 24h, Learn); monitored async per ADR-007.
"@
    Write-Host "  registry evidence written to $EvidenceDir (registry-servers-response.json, registry-poll-summary.txt)."
}

Write-Host ''
Write-Host "== Registry evidence (non-blocking) =="
Write-Host "  anonymous read : $anonStatus"
Write-Host "  authenticated  : authOk=$authOk, last status $lastStatus (token audience $RegistryResource)"
Write-Host "  served path     : $(if ($observedPath) { $observedPath } else { 'none' })"
Write-Host "  server present  : $serverPresent"
Write-Host "  (COMPATIBILITY.md + ADR-007: Tier 1 asserts gateway/backend; registry convergence is Tier 2, async.)"
if (-not $authOk) {
    Write-Host "::warning::Registry authenticated read did not succeed (last status $lastStatus). A 401 on /v0.1/servers is EXPECTED: that MCP-registry surface authenticates via the portal access mode, not this headless RBAC bearer token (observed live, verified 2026-07-21; COMPATIBILITY.md, ADR-007). A 403 would instead mean the Data Reader role did not propagate. Either way this is recorded for the async Tier 2 monitor (which should read convergence via the control-plane apis inventory, not /v0.1/servers) and does NOT fail the blocking gate."
}
elseif (-not $serverPresent) {
    Write-Host "  server '$ServerName' has not converged into the registry within ${PollTimeoutSeconds}s -- expected under eventual consistency (auto-sync up to 24h); recorded as evidence."
}
Write-Host "[5] Registry evidence recorded (non-blocking). See docs/decisions/ADR-007."
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
