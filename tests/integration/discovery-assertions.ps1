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
    [string]$McpExtensionKey = '',

    # --- Multi-server composition (issue 17) ---------------------------------
    # Server 2's client-facing MCP endpoint (s2 output mcp_server_2_url). When
    # supplied, the per-server discovery checks run for server 2 as well: its own
    # path-inserted PRM document and its own client-visible challenge. Optional so
    # the single-server gate invocation keeps working unchanged.
    [string]$McpServer2Url = '',
    # The value server 2's PRM "resource" must equal (s2 output mcp_server_2_url).
    # Defaults to McpServer2Url when omitted (they are the same value: RFC 9728
    # s3.3 matches the document's resource against the server URL the client
    # connects to).
    [string]$ExpectedResource2 = '',
    # A bearer token from the least-privilege client granted ONLY server 1's
    # entitlement (scope/role), used for the cross-server grant-isolation negative
    # (issue 17): accepted at server 1, rejected at server 2 with 403
    # insufficient_scope. Optional; the cross-server negative runs only when both
    # this and McpServer2Url are supplied.
    [string]$Server1OnlyToken = ''
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

$wkSuffixConst = '/.well-known/oauth-protected-resource'

# Gateway base host (scheme+authority) derived from a root well-known URL.
function Get-GatewayBase([string]$rootPrmUrl) {
    if ($rootPrmUrl.EndsWith($wkSuffixConst)) {
        return $rootPrmUrl.Substring(0, $rootPrmUrl.Length - $wkSuffixConst.Length)
    }
    return ([System.Uri]$rootPrmUrl).GetLeftPart([System.UriPartial]::Authority)
}

# The path-scoped resource_metadata value the deployed type=mcp runtime rewrites
# the challenge to on the wire: <gateway>/<server_path>/.well-known/oauth-protected-resource
# (issue-9 trace). Asserted as the CLIENT-VISIBLE challenge (issue 17: the gate
# asserts what the client receives, not what the policy emits).
function Get-ObservedChallengeUrl([string]$serverUrl, [string]$gatewayBase) {
    $sp = ''
    if ($serverUrl.StartsWith($gatewayBase)) {
        $sp = ($serverUrl.Substring($gatewayBase.Length).TrimStart('/') -split '/', 2)[0]
    }
    return "$gatewayBase/$sp$wkSuffixConst"
}

# The RFC 9728 s3.1 path-inserted PRM location for a server: the root well-known
# URL with the server's resource path inserted after it.
function Get-PathInsertedPrmUrl([string]$serverUrl, [string]$rootPrmUrl, [string]$gatewayBase) {
    $mcpPath = if ($serverUrl.StartsWith($gatewayBase)) {
        $serverUrl.Substring($gatewayBase.Length)
    }
    else {
        ([System.Uri]$serverUrl).AbsolutePath
    }
    return "$rootPrmUrl$mcpPath"
}

# True only for the GATEWAY's own per-server entitlement denial (issue 17): a 403
# whose WWW-Authenticate carries RFC 6750 insufficient_scope. This distinguishes
# the gateway per-server check from any downstream backend 403 (e.g. the McpTools
# app-role check, issue 45), so the cross-server isolation proof is about the
# gateway layer specifically, not coupled to backend authorization.
function Test-GatewayInsufficientScope($resp) {
    if ($resp.StatusCode -ne 403) { return $false }
    $w = Get-HeaderValue -Response $resp -Name 'WWW-Authenticate'
    return ($null -ne $w -and $w -match 'insufficient_scope')
}

# Per-server discovery: the no-token challenge points at THIS server's own
# path-inserted metadata, and the path-inserted PRM location serves THIS server's
# document with its own resource. Runs for each server behind the gateway
# (issue 17). Server 1's equivalents are checks [1] and [2b] below, kept inline
# and unchanged; this function is used for the additional servers.
function Assert-ServerDiscovery {
    param([string]$Label, [string]$ServerUrl, [string]$ExpectedRes, [string]$RootPrmUrl)

    $gwBase = Get-GatewayBase $RootPrmUrl
    $observed = Get-ObservedChallengeUrl $ServerUrl $gwBase

    Write-Host "[$Label-a] $ServerUrl no-token call returns 401 with ITS OWN challenge"
    $r = Invoke-Raw -Uri $ServerUrl -Body $initBody
    if ($r.StatusCode -ne 401) {
        Fail "${Label}: expected HTTP 401 with no token, got $($r.StatusCode)."
    }
    else {
        Pass "${Label}: no-token call returned 401."
        $wwwAuth = Get-HeaderValue -Response $r -Name 'WWW-Authenticate'
        if ([string]::IsNullOrEmpty($wwwAuth)) {
            Fail "${Label}: 401 carried no WWW-Authenticate header."
        }
        elseif ($wwwAuth -notmatch 'Bearer') {
            Fail "${Label}: WWW-Authenticate is not a Bearer challenge: '$wwwAuth'."
        }
        elseif ($wwwAuth -notmatch [regex]::Escape("resource_metadata=`"$observed`"")) {
            Fail "${Label}: client-visible challenge resource_metadata does not match this server's own URL '$observed' (a client here must be led to THIS server's metadata, never another server's). Got: '$wwwAuth'."
        }
        else {
            Pass "${Label}: client-visible challenge points at this server's own metadata ($observed)."
        }
    }
    Write-Host ''

    $rfcUrl = Get-PathInsertedPrmUrl $ServerUrl $RootPrmUrl $gwBase
    Write-Host "[$Label-b] $ServerUrl RFC 9728 path-inserted PRM serves this server's document"
    $pr = Invoke-Raw -Uri $rfcUrl -Method 'GET'
    if ($pr.StatusCode -ne 200) {
        Fail "${Label}: path-inserted PRM ($rfcUrl) returned $($pr.StatusCode); expected 200 (each server serves its own document at its own path-inserted location)."
    }
    else {
        Pass "${Label}: path-inserted PRM returned 200."
        try { $rdoc = $pr.Content | ConvertFrom-Json -ErrorAction Stop } catch { $rdoc = $null; Fail "${Label}: path-inserted PRM was not valid JSON: $($_.Exception.Message)" }
        if ($null -ne $rdoc) {
            if ($rdoc.resource -ne $ExpectedRes) {
                Fail "${Label}: path-inserted PRM 'resource' is '$($rdoc.resource)'; expected this server's URL '$ExpectedRes' (RFC 9728 s3.3 exact match)."
            }
            else {
                Pass "${Label}: path-inserted PRM 'resource' equals this server's URL."
            }
        }
    }
    Write-Host ''
}

# Default server 2's expected resource to its URL when not given explicitly.
if ([string]::IsNullOrEmpty($ExpectedResource2)) { $ExpectedResource2 = $McpServer2Url }

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
# 2b. RFC 9728 s3.1 path-inserted PRM location. A spec-conformant client (VS
#     Code, verified 2026-07-18) validating the path-bearing server URL fetches
#     the metadata at <gateway>/.well-known/oauth-protected-resource<server-path>
#     and REJECTS the bare-root document when its resource carries a path. This
#     asserts the apim-gateway path-inserted operation serves the same document
#     there. URL derived from PrmUrl (root well-known) + the path of McpServerUrl.
# ---------------------------------------------------------------------------
Write-Host "[2b] RFC 9728 path-inserted PRM location serves the document"
$wkSuffix = '/.well-known/oauth-protected-resource'
$gwBase = if ($PrmUrl.EndsWith($wkSuffix)) {
    $PrmUrl.Substring(0, $PrmUrl.Length - $wkSuffix.Length)
}
else {
    ([System.Uri]$PrmUrl).GetLeftPart([System.UriPartial]::Authority)
}
$mcpPath = if ($McpServerUrl.StartsWith($gwBase)) {
    $McpServerUrl.Substring($gwBase.Length)
}
else {
    ([System.Uri]$McpServerUrl).AbsolutePath
}
$rfcUrl = "$PrmUrl$mcpPath"
$pr = Invoke-Raw -Uri $rfcUrl -Method 'GET'
if ($pr.StatusCode -ne 200) {
    Fail "RFC 9728 path-inserted PRM ($rfcUrl) returned $($pr.StatusCode); expected 200 (spec clients fetch the metadata here for a path-bearing resource)."
}
else {
    Pass "RFC 9728 path-inserted PRM returned 200."
    try { $rdoc = $pr.Content | ConvertFrom-Json -ErrorAction Stop } catch { $rdoc = $null; Fail "path-inserted PRM was not valid JSON: $($_.Exception.Message)" }
    if ($null -ne $rdoc) {
        if ($rdoc.resource -ne $ExpectedResource) {
            Fail "path-inserted PRM 'resource' is '$($rdoc.resource)'; expected the MCP server URL '$ExpectedResource'."
        }
        else {
            Pass "path-inserted PRM 'resource' equals the MCP server URL."
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

# ===========================================================================
# Multi-server composition (issue 17). The checks below run only when the
# server-2 / server-1-only-token parameters are supplied, so the single-server
# gate invocation is unchanged.
# ===========================================================================

# ---------------------------------------------------------------------------
# 5. Per-server discovery for server 2: its own client-visible challenge and its
#    own path-inserted PRM document (checks [1]/[2b] but for server 2). PrmUrl is
#    the gateway-root well-known URL; server 2's path-inserted location is that
#    URL plus server 2's resource path.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($McpServer2Url)) {
    Write-Host "[5] Server 2 per-server discovery (issue 17)"
    Assert-ServerDiscovery -Label '5' -ServerUrl $McpServer2Url -ExpectedRes $ExpectedResource2 -RootPrmUrl $PrmUrl
}

# ---------------------------------------------------------------------------
# 6. On-error 401 challenge recording (acceptance: on-error rewrite behaviour
#    recorded). A wrong-audience token drives the validate-azure-ad-token 401,
#    whose WWW-Authenticate is added in the policy's on-error handler. Whether
#    the deployed type=mcp runtime ALSO rewrites resource_metadata on this
#    on-error path (as it does on the no-token path) is UNESTABLISHED
#    (COMPATIBILITY.md, 2026-08-04). This RECORDS the observed value per server;
#    it is intentionally not a hard assertion, so the gate captures the evidence
#    without pre-deciding the answer.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($WrongAudienceToken)) {
    Write-Host "[6] On-error 401 challenge recording (rewrite behaviour, per server)"
    $onErrTargets = @{ 'server 1' = $McpServerUrl }
    if (-not [string]::IsNullOrEmpty($McpServer2Url)) { $onErrTargets['server 2'] = $McpServer2Url }
    foreach ($name in $onErrTargets.Keys) {
        $url = $onErrTargets[$name]
        $gwBase = Get-GatewayBase $PrmUrl
        $expectedPerServer = Get-ObservedChallengeUrl $url $gwBase
        $oe = Invoke-Raw -Uri $url -Headers @{ Authorization = "Bearer $WrongAudienceToken" } -Body $initBody
        if ($oe.StatusCode -ne 401) {
            Write-Host "  [INFO] $name on-error path returned $($oe.StatusCode), not 401; skipping challenge recording."
        }
        else {
            $oeWww = Get-HeaderValue -Response $oe -Name 'WWW-Authenticate'
            Write-Host "  [INFO] $name on-error 401 WWW-Authenticate: '$oeWww'"
            Write-Host "  [INFO] $name expected per-server (path-scoped) resource_metadata if rewritten: '$expectedPerServer'"
            if ($oeWww -match [regex]::Escape("resource_metadata=`"$expectedPerServer`"")) {
                Write-Host "  [INFO] $name on-error challenge is path-scoped to this server (rewrite applies on the on-error path too)."
            }
            elseif ($oeWww -match 'resource_metadata=') {
                Write-Host "  [INFO] $name on-error challenge carries a DIFFERENT resource_metadata (rewrite may not apply on on-error; record and reconcile with COMPATIBILITY.md)."
            }
            else {
                Write-Host "  [INFO] $name on-error challenge carries no resource_metadata (record)."
            }
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# 7. Cross-server grant isolation (acceptance: least-privilege client accepted at
#    server 1, rejected at server 2). A token from the client granted ONLY server
#    1's entitlement is presented to both servers. Isolation is asserted at the
#    GATEWAY layer: server 2 must return the gateway's own insufficient_scope 403
#    (the per-server check fired), and server 1 must NOT (its per-server check
#    passed). Distinguishing the gateway 403 by its insufficient_scope challenge
#    keeps this proof about the issue-17 gateway check, not the backend's own
#    app-role check (issue 45), which may independently 403 server 1 if the client
#    lacks the backend role.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($Server1OnlyToken) -and -not [string]::IsNullOrEmpty($McpServer2Url)) {
    Write-Host "[7] Cross-server grant isolation: server-1-only token (issue 17)"

    $a1 = Invoke-Raw -Uri $McpServerUrl -Headers @{ Authorization = "Bearer $Server1OnlyToken" } -Body $initBody
    if (Test-GatewayInsufficientScope $a1) {
        Fail "server 1 rejected the server-1-only token with the gateway's insufficient_scope 403; expected the per-server check to ACCEPT it (the token carries server 1's entitlement)."
    }
    else {
        Pass "server 1 per-server check accepted the server-1-only token (status $($a1.StatusCode); not a gateway insufficient_scope 403)."
    }

    $a2 = Invoke-Raw -Uri $McpServer2Url -Headers @{ Authorization = "Bearer $Server1OnlyToken" } -Body $initBody
    if (-not (Test-GatewayInsufficientScope $a2)) {
        Fail "server 2 returned status $($a2.StatusCode) without an insufficient_scope challenge for the server-1-only token; expected the gateway's 403 insufficient_scope (grant-level isolation: it lacks server 2's scope/role). WWW-Authenticate: '$(Get-HeaderValue -Response $a2 -Name 'WWW-Authenticate')'."
    }
    else {
        Pass "server 2 rejected the server-1-only token with the gateway's 403 insufficient_scope (grant-level isolation enforced)."
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Host "== Discovery assertions FAILED: $script:Failures check(s) failed =="
    exit 1
}
Write-Host "== Discovery assertions passed =="
exit 0
