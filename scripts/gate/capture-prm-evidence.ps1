#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
  Diagnostic evidence capture for the PRM / WWW-Authenticate ownership question
  (issue 9). Read-only, anonymous, NON-FATAL: it never fails the gate. It exists
  so a single live run answers three things at once -- what challenge the client
  actually receives, which layer owns it, and which candidate PRM location holds
  a valid document -- instead of looping the live gate once per question.

.DESCRIPTION
  Two competing RFC 9728 protected-resource-metadata (PRM) emitters exist in the
  s1/s2 stack (verified 2026-07-16):
    - a hand-rolled APIM policy that points its WWW-Authenticate challenge at the
      gateway-ROOT PRM (apim-mcp-server/policies/mcp-server.xml), and
    - the backend Functions host's App Service Authentication PRM feature
      (mcp-function-host WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES), which natively
      emits its own challenge on the backend host in the RFC 9728 section 3.1
      path-insertion form.
  The discovery assertion accepts only the gateway-root form, so knowing which
  emitter wins on the wire -- and which PRM URL shape actually resolves -- decides
  the fix. This script records exactly that.

  It captures, writing both to stdout and to a Markdown evidence file:
    1. The verbatim WWW-Authenticate line(s) from an anonymous (no-token) call to
       the client-facing MCP endpoint (via APIM) and to the backend MCP endpoint
       directly, plus the resource_metadata each advertises.
    2. Status + Content-Type + a body excerpt for every candidate PRM location:
         a. gateway root                 <gateway>/.well-known/oauth-protected-resource
         b. path-scoped appended form    <gateway>/<serverPath>/.well-known/oauth-protected-resource
         c. RFC 9728 insertion (segment) <gateway>/.well-known/oauth-protected-resource/<serverPath>
         c2. RFC 9728 insertion (full)   <gateway>/.well-known/oauth-protected-resource/<mcpRelPath>
         d. backend root                 <backend>/.well-known/oauth-protected-resource
         d2. backend advertised form     <backend>/.well-known/oauth-protected-resource/<backendMcpPath>
       plus the exact resource_metadata URLs the two challenges advertise (the
       real oracle: does the advertised document actually return 200?).

  Every probe is wrapped so a network error is recorded, not thrown. Exit code is
  always 0.

.NOTES
  Temporary issue-9 instrumentation, KEPT until the v1.1 interactive-auth work
  (the OAuth-mediation-layer-vs-custom-domain resolution; see ADR-006 and the
  issue #42): it stays useful as a per-run detector of the PRM /
  challenge shape while that surface is still in flux. Remove (script + its
  workflow step + the artifact upload) only when that work lands.
#>

[CmdletBinding()]
param(
    # Client-facing MCP endpoint (s2 output mcp_server_url),
    # e.g. https://<gateway>/<serverPath>/runtime/webhooks/mcp
    [Parameter(Mandatory)][string]$McpServerUrl,
    # Gateway-root PRM URL (s2 output prm_url),
    # e.g. https://<gateway>/.well-known/oauth-protected-resource
    [Parameter(Mandatory)][string]$PrmUrl,
    # Backend Functions MCP endpoint (s1),
    # e.g. https://<app>.azurewebsites.net/runtime/webhooks/mcp
    [Parameter(Mandatory)][string]$BackendMcpUrl,
    # Directory to write the evidence file into (created if absent).
    [Parameter(Mandatory)][string]$OutDir
)

# Deliberately NOT Stop: this is non-fatal instrumentation. A failed probe is a
# recorded observation, never a gate failure.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
$wellKnown = '/.well-known/oauth-protected-resource'

# WWW-Authenticate may arrive as a string or a single-element array; join to a
# stable string (mirrors tests/integration/discovery-assertions.ps1).
function Get-HeaderValue {
    param($Response, [string]$Name)
    if ($null -eq $Response) { return $null }
    if (-not $Response.Headers.ContainsKey($Name)) { return $null }
    $v = $Response.Headers[$Name]
    if ($v -is [array]) { return ($v -join ', ') }
    return [string]$v
}

# Pull the resource_metadata="..." value out of a WWW-Authenticate header.
function Get-ResourceMetadata {
    param([string]$WwwAuthenticate)
    if ([string]::IsNullOrEmpty($WwwAuthenticate)) { return $null }
    $m = [regex]::Match($WwwAuthenticate, 'resource_metadata="([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# One probe. Returns an object; never throws.
function Invoke-Probe {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Body = $null
    )
    $result = [ordered]@{
        uri              = $Uri
        method           = $Method
        status           = $null
        wwwAuthenticate  = $null
        resourceMetadata = $null
        contentType      = $null
        bodyExcerpt      = $null
        error            = $null
    }
    try {
        $reqArgs = @{
            Uri                = $Uri
            Method             = $Method
            SkipHttpErrorCheck = $true
            MaximumRedirection = 0
            TimeoutSec         = 20
            ErrorAction        = 'Stop'
        }
        if ($null -ne $Body) {
            $reqArgs['Body'] = $Body
            $reqArgs['ContentType'] = 'application/json'
        }
        $resp = Invoke-WebRequest @reqArgs
        $result.status = [int]$resp.StatusCode
        $www = Get-HeaderValue -Response $resp -Name 'WWW-Authenticate'
        $result.wwwAuthenticate = $www
        $result.resourceMetadata = Get-ResourceMetadata -WwwAuthenticate $www
        $result.contentType = Get-HeaderValue -Response $resp -Name 'Content-Type'
        $body = [string]$resp.Content
        if (-not [string]::IsNullOrEmpty($body)) {
            $result.bodyExcerpt = $body.Substring(0, [Math]::Min(600, $body.Length))
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }
    return [pscustomobject]$result
}

# Base URL (scheme://host[:port]) of a URI, or $null on parse failure.
function Get-BaseUrl {
    param([string]$Uri)
    try {
        $u = [System.Uri]$Uri
        return $u.GetLeftPart([System.UriPartial]::Authority)
    }
    catch { return $null }
}

# ---------------------------------------------------------------------------
# Derive the pieces every candidate URL is built from.
# ---------------------------------------------------------------------------
$gatewayBase = if ($PrmUrl.EndsWith($wellKnown)) {
    $PrmUrl.Substring(0, $PrmUrl.Length - $wellKnown.Length)
}
else {
    Get-BaseUrl -Uri $PrmUrl
}

# MCP path relative to the gateway, e.g. /orders/runtime/webhooks/mcp, and the
# first path segment (the API path, e.g. "orders").
$mcpRelPath = $null
$serverPath = $null
if (-not [string]::IsNullOrEmpty($gatewayBase) -and $McpServerUrl.StartsWith($gatewayBase)) {
    $mcpRelPath = $McpServerUrl.Substring($gatewayBase.Length)
    $seg = ($mcpRelPath.TrimStart('/') -split '/', 2)[0]
    if (-not [string]::IsNullOrEmpty($seg)) { $serverPath = $seg }
}

$backendBase = Get-BaseUrl -Uri $BackendMcpUrl
$backendRelPath = $null
if (-not [string]::IsNullOrEmpty($backendBase) -and $BackendMcpUrl.StartsWith($backendBase)) {
    $backendRelPath = $BackendMcpUrl.Substring($backendBase.Length)
}

# ---------------------------------------------------------------------------
# 1. Verbatim WWW-Authenticate from anonymous (no-token) calls.
# ---------------------------------------------------------------------------
$apimChallenge = Invoke-Probe -Uri $McpServerUrl -Method 'POST' -Body $initBody
$backendChallenge = Invoke-Probe -Uri $BackendMcpUrl -Method 'POST' -Body $initBody

# ---------------------------------------------------------------------------
# 2. Candidate PRM locations (GET, anonymous). Ordered dictionary: label -> uri.
# ---------------------------------------------------------------------------
$candidates = [ordered]@{}
if ($gatewayBase) {
    $candidates['a. gateway root'] = "$gatewayBase$wellKnown"
    if ($serverPath) {
        $candidates['b. path-scoped appended'] = "$gatewayBase/$serverPath$wellKnown"
        $candidates['c. RFC insertion (segment)'] = "$gatewayBase$wellKnown/$serverPath"
    }
    if ($mcpRelPath) {
        $candidates['c2. RFC insertion (full path)'] = "$gatewayBase$wellKnown$mcpRelPath"
    }
}
if ($backendBase) {
    $candidates['d. backend root'] = "$backendBase$wellKnown"
    if ($backendRelPath) {
        $candidates['d2. backend advertised form'] = "$backendBase$wellKnown$backendRelPath"
    }
}

$candidateResults = [ordered]@{}
foreach ($label in $candidates.Keys) {
    $candidateResults[$label] = Invoke-Probe -Uri $candidates[$label] -Method 'GET'
}

# The real oracle: GET the exact resource_metadata URLs the two challenges
# advertised, whatever their shape, and see if they resolve.
$advertised = [ordered]@{}
if ($apimChallenge.resourceMetadata) { $advertised['advertised by APIM challenge'] = $apimChallenge.resourceMetadata }
if ($backendChallenge.resourceMetadata) { $advertised['advertised by backend challenge'] = $backendChallenge.resourceMetadata }
$advertisedResults = [ordered]@{}
foreach ($label in $advertised.Keys) {
    $advertisedResults[$label] = Invoke-Probe -Uri $advertised[$label] -Method 'GET'
}

# ---------------------------------------------------------------------------
# Emit: Markdown evidence file + a concise stdout summary.
# ---------------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path $OutDir -Force
$evidencePath = Join-Path $OutDir 'prm-evidence.md'

$sb = [System.Text.StringBuilder]::new()
function Add-Line { param([string]$Text = '') ; [void]$sb.AppendLine($Text) }

Add-Line '# PRM / WWW-Authenticate discovery evidence (issue 9)'
Add-Line ''
Add-Line 'Read-only anonymous probes captured during the live gate. Non-fatal;'
Add-Line 'this file is the oracle for which layer owns the challenge and which PRM'
Add-Line 'location resolves. See scripts/gate/capture-prm-evidence.ps1.'
Add-Line ''
Add-Line '## Inputs'
Add-Line ''
Add-Line "- McpServerUrl (client-facing) : $McpServerUrl"
Add-Line "- PrmUrl (gateway root)        : $PrmUrl"
Add-Line "- BackendMcpUrl                : $BackendMcpUrl"
Add-Line "- derived gatewayBase          : $gatewayBase"
Add-Line "- derived serverPath           : $serverPath"
Add-Line "- derived mcpRelPath           : $mcpRelPath"
Add-Line "- derived backendBase          : $backendBase"
Add-Line ''

function Add-ChallengeSection {
    param([string]$Title, $Probe)
    Add-Line "### $Title"
    Add-Line ''
    Add-Line "- URL              : $($Probe.uri)"
    Add-Line "- status           : $($Probe.status)"
    if ($Probe.error) { Add-Line "- error            : $($Probe.error)" }
    Add-Line "- WWW-Authenticate : $($Probe.wwwAuthenticate)"
    Add-Line "- resource_metadata: $($Probe.resourceMetadata)"
    Add-Line ''
}

Add-Line '## 1. Verbatim WWW-Authenticate (anonymous, no token)'
Add-Line ''
Add-ChallengeSection -Title 'Via APIM (client-facing MCP endpoint)' -Probe $apimChallenge
Add-ChallengeSection -Title 'Backend Functions host (direct)' -Probe $backendChallenge

function Add-GetSection {
    param([string]$Label, $Probe)
    Add-Line "### $Label"
    Add-Line ''
    Add-Line "- URL         : $($Probe.uri)"
    Add-Line "- status      : $($Probe.status)"
    if ($Probe.error) { Add-Line "- error       : $($Probe.error)" }
    Add-Line "- contentType : $($Probe.contentType)"
    if ($Probe.bodyExcerpt) {
        Add-Line '- body excerpt:'
        Add-Line '```'
        Add-Line $Probe.bodyExcerpt
        Add-Line '```'
    }
    Add-Line ''
}

Add-Line '## 2. Candidate PRM locations (GET, anonymous)'
Add-Line ''
foreach ($label in $candidateResults.Keys) {
    Add-GetSection -Label $label -Probe $candidateResults[$label]
}

if ($advertisedResults.Count -gt 0) {
    Add-Line '## 3. Does the advertised resource_metadata actually resolve?'
    Add-Line ''
    foreach ($label in $advertisedResults.Keys) {
        Add-GetSection -Label $label -Probe $advertisedResults[$label]
    }
}

Set-Content -Path $evidencePath -Value $sb.ToString() -Encoding utf8

# Concise stdout summary (the workflow log is the first place a human looks).
Write-Host '== PRM discovery evidence (issue 9, non-fatal) =='
Write-Host "  evidence file: $evidencePath"
Write-Host "  [APIM challenge]    status=$($apimChallenge.status) resource_metadata=$($apimChallenge.resourceMetadata)"
Write-Host "    WWW-Authenticate: $($apimChallenge.wwwAuthenticate)"
Write-Host "  [backend challenge] status=$($backendChallenge.status) resource_metadata=$($backendChallenge.resourceMetadata)"
Write-Host "    WWW-Authenticate: $($backendChallenge.wwwAuthenticate)"
foreach ($label in $candidateResults.Keys) {
    $c = $candidateResults[$label]
    Write-Host "  [$label] status=$($c.status) $($c.uri)"
}
foreach ($label in $advertisedResults.Keys) {
    $c = $advertisedResults[$label]
    Write-Host "  [$label] status=$($c.status) $($c.uri)"
}

exit 0
