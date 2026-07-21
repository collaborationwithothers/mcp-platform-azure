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
    5. Probe the registry endpoint anonymously first and RECORD the status (a
       401 is the expected, evidential secure-by-default result, not a
       failure), then poll it authenticated (Azure API Center Data Reader, via
       the workflow's OIDC principal) with a bounded timeout and assert the
       synced server appears.
    6. Issue 10 (OBO thickening): run the OBO passthrough negative test,
       reusing the step-1 server-audience token as the inbound token
       presented directly to the downstream Orders API (tests/integration/
       obo-passthrough-negative.ps1). This does not exercise the OBO happy
       path -- see docs/decisions/ADR-006, "OBO exchange: the inbound-token
       gap" and "Testing strategy: the user-context token problem" for why
       that is validated manually, not here.

  Exits non-zero if the MCP client, the discovery assertions, or the
  authenticated poll fail. The anonymous probe never fails the run; it only
  records what it observed. The gate does NOT auto-exercise interactive,
  client-driven discovery: that is validated manually in VS Code and recorded
  in docs/demos (spec: Testing Decisions).

.NOTES
  Verified 2026-07-19 against Microsoft Learn (see COMPATIBILITY.md):
  - Client-credentials scope form <resource>/.default and app-role claims:
    https://learn.microsoft.com/entra/identity-platform/v2-oauth2-client-creds-grant-flow
  - API Center data-plane token audience https://azure-apicenter.net:
    https://learn.microsoft.com/rest/api/dataplane/apicenter/apis/list
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
    [int]$PollTimeoutSeconds = 300,
    [int]$PollIntervalSeconds = 15
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
# 5. Registry: anonymous probe (evidential), then bounded authenticated poll.
# ---------------------------------------------------------------------------
Write-Host "[5] Registry endpoint access"

# 4a. Anonymous probe FIRST. Expected 401 (secure-by-default): this is an
#     evidential negative test, recorded, never a failure of the run.
$anonStatus = 'error'
try {
    $anon = Invoke-WebRequest -Uri $RegistryEndpointUrl -Method Get -SkipHttpErrorCheck -ErrorAction Stop
    $anonStatus = [int]$anon.StatusCode
}
catch {
    $anonStatus = "error: $($_.Exception.Message)"
}
Write-Host "  anonymous probe status: $anonStatus (401 expected = secure-by-default; recorded, not a pass/fail gate)."
# The read posture is platform-determined (no ARM surface), so this probe never
# fails the run. But an anonymous 200 means the registry became publicly
# readable -- a security-relevant posture change worth surfacing beyond the log.
if ("$anonStatus" -ne '401') {
    Write-Host "::warning::Registry anonymous probe returned '$anonStatus', not 401. The data-plane registry may be anonymously readable; confirm the intended access posture (docs/security.md, docs/runbooks/registry-anonymous-access.md)."
}

# 4b. Authenticated poll. The registry token targets the API Center data plane
#     (https://azure-apicenter.net); the workflow's OIDC principal holds Azure
#     API Center Data Reader on the instance.
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found; the authenticated registry poll needs it to mint an API Center data-plane token."
}
$registryToken = az account get-access-token --resource $RegistryResource --query accessToken -o tsv
if ([string]::IsNullOrEmpty($registryToken)) {
    throw "Failed to acquire an API Center data-plane token (resource $RegistryResource)."
}

# The registry endpoint path form carries a known Microsoft-doc inconsistency
# (template includes /workspaces/, the doc's own example omits it). The module
# emits the /workspaces/ form; try it first, fall back to the stripped form,
# and record which one actually served the servers list.
$primaryUrl = $RegistryEndpointUrl
$fallbackUrl = ($RegistryEndpointUrl -replace '/workspaces/[^/]+/', '/')
$candidates = @($primaryUrl)
if ($fallbackUrl -ne $primaryUrl) { $candidates += $fallbackUrl }

$deadline = (Get-Date).AddSeconds($PollTimeoutSeconds)
$found = $false
$observedPath = $null
$attempt = 0
while ((Get-Date) -lt $deadline -and -not $found) {
    $attempt++
    foreach ($url in $candidates) {
        $resp = Invoke-WebRequest -Uri $url -Method Get `
            -Headers @{ Authorization = "Bearer $registryToken" } `
            -SkipHttpErrorCheck -ErrorAction Stop
        if ([int]$resp.StatusCode -eq 200) {
            if ($resp.Content -match [regex]::Escape($ServerName)) {
                $found = $true
                $observedPath = $url
                break
            }
            $observedPath = $url  # path form works; server not yet synced
        }
    }
    if (-not $found) {
        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        Write-Host "  attempt ${attempt}: server '$ServerName' not yet in the registry; ${remaining}s left."
        if ($remaining -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
}

Write-Host ''
Write-Host "== Registry access modes observed =="
Write-Host "  anonymous read : $anonStatus"
Write-Host "  authenticated  : Azure API Center Data Reader (token audience $RegistryResource)"
Write-Host "  served path     : $(if ($observedPath) { $observedPath } else { 'none (no 200 within timeout)' })"
Write-Host "  (COMPATIBILITY.md registry row records the observed anonymous status and served path form.)"
Write-Host ''

if (-not $found) {
    throw "Registry poll: server '$ServerName' did not appear within $PollTimeoutSeconds s."
}
Write-Host "[5] Registry poll: server '$ServerName' present (authenticated)."
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
