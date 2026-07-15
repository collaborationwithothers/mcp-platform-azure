#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
  Raw-HTTP discovery-artifact assertions for the v1 tracer's live gate
  (docs/specs/v1-tracer-bullet.md, Testing Decisions).

.DESCRIPTION
  Asserts the OAuth 2.1 / RFC 9728 discovery artifacts the gateway is supposed
  to serve, at the raw HTTP layer (a client library would hide the very
  challenge being asserted). Every check is against artifacts THIS REPO's own
  APIM policies emit (the 401 + WWW-Authenticate challenge in apim-mcp-server's
  mcp-server.xml, and the root protected resource metadata document served by
  apim-gateway's prm-well-known.xml). The APIM PRM/401 pattern is a hand-rolled
  policy, not a first-party APIM feature (verified against Microsoft Learn
  2026-07-15; see COMPATIBILITY.md), so these assertions are the proof it works.

  Checks:
    1. No-token call            -> 401 with WWW-Authenticate: Bearer
                                   resource_metadata="<PrmUrl>".
    2. PRM document content      -> 200 JSON with the RFC 9728 fields; resource
                                   equals the expected server audience.
    3. Wrong-audience token      -> 401 (validate-azure-ad-token rejects it).
    4. Shadow mcp_extension key  -> 401 with the key and no Entra token, against
                                   BOTH the gateway and the backend host
                                   directly (spec story 31; the shadow auth
                                   path is closed).

  Exits non-zero on the first failed assertion so the gate's call stage fails.

.NOTES
  Reference implementations for the PRM/authorization challenge (named in the
  ticket): https://github.com/blackchoey/remote-mcp-apim-oauth-prm and the
  Azure-Samples AI-Gateway mcp-prm-oauth lab.
#>

[CmdletBinding()]
param(
    # Gateway MCP endpoint (s2 output mcp_server_url).
    [Parameter(Mandatory)][string]$McpServerUrl,
    # Gateway-root protected resource metadata URL (s2 output prm_url).
    [Parameter(Mandatory)][string]$PrmUrl,
    # The server app ID URI the PRM document's "resource" must equal, and the
    # audience the gateway validates (entra_validation.audience).
    [Parameter(Mandatory)][string]$ExpectedResource,
    # A bearer token whose audience is NOT the server app (e.g. a Graph
    # .default token), used for the wrong-audience rejection check.
    [Parameter(Mandatory)][string]$WrongAudienceToken,
    # Backend Functions MCP endpoint, e.g.
    # https://<app>.azurewebsites.net/runtime/webhooks/mcp (s1 default_hostname).
    [Parameter(Mandatory)][string]$BackendMcpUrl,
    # The mcp_extension system key, if retrievable. When empty the shadow-key
    # check still runs (the point is "no Entra token -> 401" even holding a
    # function key), presenting a placeholder key value.
    [string]$McpExtensionKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0

function Fail([string]$message) {
    Write-Host "  [FAIL] $message"
    $script:Failures++
}

function Pass([string]$message) {
    Write-Host "  [PASS] $message"
}

# Invoke a request without throwing on non-2xx, so a 401 is a response we can
# inspect rather than a terminal error.
function Invoke-Raw {
    param(
        [string]$Uri,
        [string]$Method = 'POST',
        [hashtable]$Headers = @{},
        [string]$Body = $null
    )
    $reqArgs = @{
        Uri                = $Uri
        Method             = $Method
        Headers            = $Headers
        SkipHttpErrorCheck = $true
        MaximumRedirection = 0
        ErrorAction        = 'Stop'
    }
    if ($null -ne $Body) {
        $reqArgs['Body'] = $Body
        $reqArgs['ContentType'] = 'application/json'
    }
    return Invoke-WebRequest @reqArgs
}

# WWW-Authenticate may come back as a string or a single-element array.
function Get-HeaderValue {
    param($Response, [string]$Name)
    if (-not $Response.Headers.ContainsKey($Name)) { return $null }
    $v = $Response.Headers[$Name]
    if ($v -is [array]) { return ($v -join ', ') }
    return [string]$v
}

# A minimal JSON-RPC initialize body; the challenge fires in APIM inbound before
# any routing, so the body content does not affect the 401 assertions.
$initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

Write-Host "== Discovery-artifact assertions =="
Write-Host "MCP endpoint : $McpServerUrl"
Write-Host "PRM URL      : $PrmUrl"
Write-Host "Backend MCP  : $BackendMcpUrl"
Write-Host ''

# ---------------------------------------------------------------------------
# 1. No-token call -> 401 + WWW-Authenticate pointing at the root PRM URL.
# ---------------------------------------------------------------------------
Write-Host "[1] No-token call returns 401 with the RFC 9728 challenge"
$r = Invoke-Raw -Uri $McpServerUrl -Body $initBody
if ($r.StatusCode -ne 401) {
    Fail "expected HTTP 401 with no token, got $($r.StatusCode)."
}
else {
    Pass "no-token call returned 401."
    $wwwAuth = Get-HeaderValue -Response $r -Name 'WWW-Authenticate'
    if ([string]::IsNullOrEmpty($wwwAuth)) {
        Fail "401 carried no WWW-Authenticate header."
    }
    elseif ($wwwAuth -notmatch 'Bearer') {
        Fail "WWW-Authenticate is not a Bearer challenge: '$wwwAuth'."
    }
    elseif ($wwwAuth -notmatch [regex]::Escape("resource_metadata=`"$PrmUrl`"")) {
        Fail "WWW-Authenticate resource_metadata does not point at '$PrmUrl'. Got: '$wwwAuth'."
    }
    else {
        Pass "WWW-Authenticate points at the root PRM URL."
    }
}
Write-Host ''

# ---------------------------------------------------------------------------
# 2. PRM document content (RFC 9728). Fetched anonymously: clients must read it
#    before they have a token.
# ---------------------------------------------------------------------------
Write-Host "[2] Protected resource metadata document content"
$p = Invoke-Raw -Uri $PrmUrl -Method 'GET'
if ($p.StatusCode -ne 200) {
    Fail "expected HTTP 200 for the PRM document, got $($p.StatusCode)."
}
else {
    Pass "PRM document returned 200."
    try {
        $doc = $p.Content | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $doc = $null
        Fail "PRM document was not valid JSON: $($_.Exception.Message)"
    }
    if ($null -ne $doc) {
        if ($doc.PSObject.Properties.Name -notcontains 'resource') {
            Fail "PRM document is missing the required 'resource' field (RFC 9728)."
        }
        elseif ($doc.resource -ne $ExpectedResource) {
            Fail "PRM 'resource' is '$($doc.resource)'; expected '$ExpectedResource'."
        }
        else {
            Pass "PRM 'resource' equals the expected server audience."
        }
        foreach ($field in @('authorization_servers', 'bearer_methods_supported', 'scopes_supported')) {
            if ($doc.PSObject.Properties.Name -notcontains $field) {
                Fail "PRM document is missing the '$field' field."
            }
            else {
                Pass "PRM document carries '$field'."
            }
        }
    }
}
Write-Host ''

# ---------------------------------------------------------------------------
# 3. Wrong-audience token -> 401 (validate-azure-ad-token rejects it).
# ---------------------------------------------------------------------------
Write-Host "[3] Wrong-audience token is rejected"
$r = Invoke-Raw -Uri $McpServerUrl -Headers @{ Authorization = "Bearer $WrongAudienceToken" } -Body $initBody
if ($r.StatusCode -ne 401) {
    Fail "expected HTTP 401 for a wrong-audience token, got $($r.StatusCode)."
}
else {
    Pass "wrong-audience token returned 401."
}
Write-Host ''

# ---------------------------------------------------------------------------
# 4. Shadow mcp_extension key + no Entra token -> 401, against the gateway AND
#    the backend host directly (spec story 31).
# ---------------------------------------------------------------------------
Write-Host "[4] Shadow mcp_extension key path is closed"
$keyValue = if ([string]::IsNullOrEmpty($McpExtensionKey)) { 'placeholder-not-a-real-key' } else { $McpExtensionKey }
if ([string]::IsNullOrEmpty($McpExtensionKey)) {
    Write-Host "  (note: no real mcp_extension key supplied; presenting a placeholder. Easy Auth rejects on the absent Entra token regardless of the key.)"
}

foreach ($target in @(
        @{ Name = 'gateway'; Url = $McpServerUrl },
        @{ Name = 'backend host'; Url = $BackendMcpUrl }
    )) {
    $sep = if ($target.Url -match '\?') { '&' } else { '?' }
    $urlWithKey = "$($target.Url)${sep}code=$keyValue"
    $r = Invoke-Raw -Uri $urlWithKey -Headers @{ 'x-functions-key' = $keyValue } -Body $initBody
    if ($r.StatusCode -ne 401) {
        Fail "$($target.Name): mcp_extension key with no Entra token returned $($r.StatusCode); expected 401."
    }
    else {
        Pass "$($target.Name): mcp_extension key with no Entra token returned 401."
    }
}
Write-Host ''

# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Host "== Discovery assertions FAILED: $script:Failures check(s) failed =="
    exit 1
}
Write-Host "== Discovery assertions passed =="
exit 0
