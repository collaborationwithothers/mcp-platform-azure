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
    1. No-token call            -> 401 with WWW-Authenticate: Bearer. The
                                   resource_metadata is asserted against the
                                   OBSERVED platform-rewritten value (path-scoped
                                   under the MCP API path), NOT the gateway-root
                                   value the policy emits: the deployed type=mcp
                                   runtime rewrites it downstream of the policy
                                   (gateway trace, 2026-07-16; see the check [1]
                                   note, COMPATIBILITY.md, ADR-006).
    2. PRM document content      -> 200 JSON with the RFC 9728 fields; resource
                                   equals the MCP server URL (RFC 9728 s3.3
                                   full-URL match), NOT the token audience.
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
    # The value the PRM document's "resource" must equal. Per RFC 9728 s3.3 a
    # client validates this against the MCP SERVER URL it connects to (a full-URL
    # match incl. path), NOT the token audience, so the gate passes the s2
    # mcp_server_url here. The token audience (entra_validation.audience) is a
    # separate value the gateway/backend validate; scopes_supported carries it.
    [Parameter(Mandatory)][string]$ExpectedResource,
    # A bearer token whose audience is NOT the server app (e.g. a Graph
    # .default token), used for the wrong-audience rejection check.
    [Parameter(Mandatory)][string]$WrongAudienceToken,
    # Backend Functions MCP endpoint, e.g.
    # https://<app>.azurewebsites.net/runtime/webhooks/mcp (s1 default_hostname).
    [Parameter(Mandatory)][string]$BackendMcpUrl,
    # The real mcp_extension system key. REQUIRED for the backend shadow-key arm:
    # that arm proves a VALID key is still blocked by Easy Auth, which a
    # placeholder cannot show (a placeholder only proves an invalid key is
    # rejected). So the backend arm FAILS if this is empty. The gateway arm runs
    # regardless, since APIM has no notion of function keys.
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
# 1. No-token call -> 401 + WWW-Authenticate. The challenge is asserted against
#    the OBSERVED platform behaviour, which is not what this repo's policy emits.
#
#    The apim-mcp-server policy sets resource_metadata to the gateway-ROOT PrmUrl
#    (mcp-server.xml). An APIM gateway trace of the no-token request (2026-07-16,
#    stamp apim-mcp-tracer-42fa1c27, trace f07bae7f) proves the policy pipeline
#    emits that ROOT value and return-response/transfer-response send it "to the
#    caller in full" -- yet the client receives a PATH-SCOPED value under the MCP
#    API path: "<gateway>/<server_path>/.well-known/oauth-protected-resource".
#    So the deployed type=mcp runtime REWRITES resource_metadata downstream of the
#    policy, with no policy hook to prevent it. This shape matches neither the MCP
#    auth spec (root) nor RFC 9728 s3.1 (insert-before-path), and Microsoft Learn
#    documents no native APIM MCP challenge (azure-docs-verifier 2026-07-16; see
#    COMPATIBILITY.md and ADR-006). We assert the observed shape ON PURPOSE: this
#    check then flags it if a future APIM release changes the rewrite. The
#    gateway-ROOT PRM document that this repo actually serves is validated in
#    check [2]. The path-scoped location does NOT serve a document (the orders MCP
#    API swallows it and 401s); interactive client discovery is confirmed
#    separately in the demo (docs/demos), and the McpTestClient session/tool
#    contracts pass regardless (they use client-credentials, not the discovery
#    dance), proving the rewrite does not break the tokened auth flow.
#
#    Derive the observed path-scoped URL from the gateway base + server path.
# ---------------------------------------------------------------------------
$wellKnownSuffix = '/.well-known/oauth-protected-resource'
$gatewayBase = if ($PrmUrl.EndsWith($wellKnownSuffix)) {
    $PrmUrl.Substring(0, $PrmUrl.Length - $wellKnownSuffix.Length)
}
else {
    ([System.Uri]$PrmUrl).GetLeftPart([System.UriPartial]::Authority)
}
$serverPath = ''
if ($McpServerUrl.StartsWith($gatewayBase)) {
    $serverPath = ($McpServerUrl.Substring($gatewayBase.Length).TrimStart('/') -split '/', 2)[0]
}
$observedChallengeUrl = "$gatewayBase/$serverPath$wellKnownSuffix"

Write-Host "[1] No-token call returns 401 with the RFC 9728 challenge"
Write-Host "    (asserting the OBSERVED platform-rewritten challenge URL; see the note above)"
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
    elseif ($wwwAuth -notmatch [regex]::Escape("resource_metadata=`"$observedChallengeUrl`"")) {
        Fail "WWW-Authenticate resource_metadata does not match the observed platform-rewritten URL '$observedChallengeUrl'. Got: '$wwwAuth'. If the platform stopped rewriting, the policy value is the gateway root '$PrmUrl' -- re-check the APIM release and update this assertion + COMPATIBILITY.md."
    }
    else {
        Pass "WWW-Authenticate matches the observed platform-rewritten challenge URL ($observedChallengeUrl)."
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
        # RFC 9728 s3.3: resource must equal the MCP server URL the client
        # connects to (VS Code rejected the doc when this was the api:// audience
        # instead; see docs/demos and COMPATIBILITY.md). ExpectedResource is the
        # s2 mcp_server_url. This also cross-checks that the composition's
        # constructed server_mcp_url matches the live endpoint byte-for-byte.
        elseif ($doc.resource -ne $ExpectedResource) {
            Fail "PRM 'resource' is '$($doc.resource)'; expected the MCP server URL '$ExpectedResource' (RFC 9728 s3.3 full-URL match, not the token audience)."
        }
        else {
            Pass "PRM 'resource' equals the MCP server URL."
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

# Two distinct arms with distinct meaning:
# - Gateway arm: APIM has no notion of function keys, so presenting one with no
#   Authorization header 401s regardless of the key value. This proves the
#   gateway requires an Entra token; it says nothing about function keys, so any
#   key value (even a dummy) is fine here.
# - Backend arm: the real shadow-key proof. It must present a VALID mcp_extension
#   key and still get 401 (Easy Auth intercepts before the key is honoured). A
#   placeholder would only show "an invalid key is rejected", not "a valid key is
#   blocked", so a real key is REQUIRED; the arm fails loudly if none was supplied
#   (spec story 31).

# Gateway arm.
$gwKey = if ([string]::IsNullOrEmpty($McpExtensionKey)) { 'not-a-real-key' } else { $McpExtensionKey }
$gwSep = if ($McpServerUrl -match '\?') { '&' } else { '?' }
$rg = Invoke-Raw -Uri "$McpServerUrl${gwSep}code=$gwKey" -Headers @{ 'x-functions-key' = $gwKey } -Body $initBody
if ($rg.StatusCode -ne 401) {
    Fail "gateway: a function key with no Entra token returned $($rg.StatusCode); expected 401."
}
else {
    Pass "gateway: a function key with no Entra token returned 401 (gateway requires an Entra token)."
}

# Backend arm: requires the real key.
if ([string]::IsNullOrEmpty($McpExtensionKey)) {
    Fail "backend host: no real mcp_extension key supplied, so the shadow-key proof cannot run. A placeholder would only show an invalid key is rejected, not that a VALID key is blocked by Easy Auth (spec story 31). Pass -McpExtensionKey with the real system key."
}
else {
    $beSep = if ($BackendMcpUrl -match '\?') { '&' } else { '?' }
    $rb = Invoke-Raw -Uri "$BackendMcpUrl${beSep}code=$McpExtensionKey" -Headers @{ 'x-functions-key' = $McpExtensionKey } -Body $initBody
    if ($rb.StatusCode -ne 401) {
        # A non-401 here can also be a network-layer block (403/404 from public-
        # network restrictions) rather than an auth regression. In the tracer the
        # backend is public with Easy Auth, so 401 is the expected proof the shadow
        # path is closed; revisit this expectation once v1.1 private networking lands.
        Fail "backend host: the REAL mcp_extension key with no Entra token returned $($rb.StatusCode); expected 401 (a non-401 may be a network block, not an auth regression)."
    }
    else {
        Pass "backend host: the real mcp_extension key with no Entra token returned 401 (Easy Auth blocks the shadow path)."
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
