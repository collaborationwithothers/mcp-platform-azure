#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
  Human-facing demo of the v1 tracer's governed path: fetch the discovery
  document, show the unauthenticated challenge, then make one authenticated
  tool call through the gateway (docs/specs/v1-tracer-bullet.md; demo index in
  docs/demos/README.md).

.DESCRIPTION
  A thin wrapper around the same token acquisition and McpTestClient the live
  gate uses, meant to be run by a human against an already-deployed tracer (for
  example during the ephemeral live-test window, or a manual walkthrough).

  It deliberately WARMS the endpoint first (Flex Consumption and APIM can cold-
  start) and prints NO latency, timing, or throughput figures: per the repo's
  honesty rules, no performance number is written that was not measured under a
  defined method, and a demo warm-up is not that.

  This script does not automate interactive, client-driven discovery. That path
  (a host like VS Code resolving the PRM, running the OAuth flow, and listing
  tools) is validated manually and recorded in docs/demos/README.md.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$McpServerUrl,
    [Parameter(Mandatory)][string]$PrmUrl,
    [Parameter(Mandatory)][string]$Audience,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [string]$McpTestClientProject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptDir '..' '..')
if ([string]::IsNullOrEmpty($McpTestClientProject)) {
    $McpTestClientProject = Join-Path $repoRoot 'src/McpTestClient/McpTestClient.csproj'
}

Write-Host "== v1 tracer demo =="
Write-Host "Gateway MCP endpoint: $McpServerUrl"
Write-Host ''

# 1. Warm the endpoint. A first request may cold-start Flex Consumption and the
#    gateway; a 401 here is the expected unauthenticated response and also warms
#    the path. No timing is recorded.
Write-Host "[1] Warming the endpoint (a 401 here is the expected no-token response)"
$warm = Invoke-WebRequest -Uri $McpServerUrl -Method Post `
    -Body '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' `
    -ContentType 'application/json' -SkipHttpErrorCheck -ErrorAction Stop
Write-Host "  warm-up status: $([int]$warm.StatusCode)"
$challenge = if ($warm.Headers.ContainsKey('WWW-Authenticate')) { $warm.Headers['WWW-Authenticate'] } else { '(none)' }
Write-Host "  WWW-Authenticate challenge: $challenge"
Write-Host ''

# 2. Show the discovery document a client would resolve from that challenge.
Write-Host "[2] Protected resource metadata (RFC 9728), fetched anonymously"
$prm = Invoke-WebRequest -Uri $PrmUrl -Method Get -SkipHttpErrorCheck -ErrorAction Stop
if ([int]$prm.StatusCode -eq 200) {
    Write-Host ($prm.Content | ConvertFrom-Json | ConvertTo-Json -Depth 5)
}
else {
    Write-Host "  unexpected status fetching PRM: $([int]$prm.StatusCode)"
}
Write-Host ''

# 3. Acquire a token and make the governed tool call.
Write-Host "[3] Authenticated tool call through the gateway"
try {
    $resp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Method Post -ContentType 'application/x-www-form-urlencoded' -Body @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "$Audience/.default"
        grant_type    = 'client_credentials'
    }
}
catch {
    throw "Token acquisition failed: $($_.Exception.Message)"
}
if ([string]::IsNullOrEmpty($resp.access_token)) {
    throw "Token endpoint returned no access_token."
}

$env:MCP_SERVER_ENDPOINT = $McpServerUrl
$env:MCP_ACCESS_TOKEN = $resp.access_token
dotnet run --project $McpTestClientProject -c Release
$clientExit = $LASTEXITCODE
$env:MCP_ACCESS_TOKEN = $null
if ($clientExit -ne 0) {
    throw "McpTestClient failed (exit $clientExit)."
}
Write-Host ''
Write-Host "== Demo complete =="
