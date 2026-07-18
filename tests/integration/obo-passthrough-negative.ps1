#!/usr/bin/env pwsh
#requires -Version 7.0

<#
.SYNOPSIS
  Negative test for issue 10 (OBO thickening): proves token passthrough is
  forbidden as a measured claim, not a README sentence (docs/decisions/ADR-006,
  docs/security.md).

.DESCRIPTION
  The MCP server's inbound token (audience = the server app) must never reach
  the downstream Orders API directly; the server is supposed to exchange it
  via OBO for a downstream-audience token instead (docs/specs/v1-tracer-
  bullet.md, "Token passthrough"). This script does NOT exercise the OBO
  exchange itself (see docs/decisions/ADR-006, "OBO exchange: the
  inbound-token gap" for why the happy path is not automatable here); it
  proves the reverse failure mode is closed: presenting the inbound token
  DIRECTLY to the downstream, bypassing OBO entirely, is rejected.

  This works without any OBO code running at all, by construction: the
  downstream Orders API's Easy Auth allowed_audiences is scoped to ONLY the
  downstream app registration (infra/terraform/scenarios/s1-entra-mcp-server's
  downstream_entra_auth), so a token minted for the MCP server app has the
  wrong audience and is rejected by the platform, before any application
  code runs. This is the same "audience validation as the enforcement
  mechanism" pattern the tracer already uses for the wrong-audience and
  shadow-key checks in discovery-assertions.ps1.

.NOTES
  The inbound token is the same client-credentials token the live gate
  already acquires for its diagnostic probes (audience = the MCP server
  app); no user-context token is needed for this check (spec: Testing
  Decisions knock-on; the user-context strategy for the OBO HAPPY path is
  documented in ADR-006 and is validated manually, not by this script).
#>

[CmdletBinding()]
param(
    # The downstream Orders API's GET /api/orders/{orderId} URL, e.g.
    # <downstream_base_url>/api/orders/CONTOSO-1001 (s1 output downstream_base_url).
    [Parameter(Mandatory)][string]$DownstreamOrderStatusUrl,

    # A bearer token whose audience is the MCP SERVER app (NOT the downstream
    # app) -- i.e. exactly the kind of token an MCP client legitimately holds
    # and that the server must never forward downstream unexchanged.
    [Parameter(Mandatory)][string]$InboundServerAudienceToken
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

function Invoke-Raw {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{}
    )
    return Invoke-WebRequest -Uri $Uri -Method GET -Headers $Headers `
        -SkipHttpErrorCheck -MaximumRedirection 0 -ErrorAction Stop
}

Write-Host "== OBO passthrough negative test (issue 10) =="
Write-Host "Downstream endpoint : $DownstreamOrderStatusUrl"
Write-Host ''

# ---------------------------------------------------------------------------
# The inbound (server-audience) token, presented directly to the downstream,
# must be rejected. A 401 proves Easy Auth's audience check on the downstream
# instance closes the passthrough path; any 2xx is a governance failure (the
# downstream would have served synthetic order data to a caller that never
# went through OBO).
# ---------------------------------------------------------------------------
Write-Host "[1] Inbound server-audience token presented directly to the downstream is rejected"
$r = Invoke-Raw -Uri $DownstreamOrderStatusUrl -Headers @{ Authorization = "Bearer $InboundServerAudienceToken" }
if ($r.StatusCode -eq 401) {
    Pass "downstream rejected the inbound (server-audience) token with 401 (audience mismatch; token passthrough is closed)."
}
elseif ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
    Fail "downstream returned $($r.StatusCode) and served a response to the inbound (server-audience) token -- token passthrough is NOT closed."
}
else {
    Fail "downstream returned $($r.StatusCode); expected 401 (a non-401/2xx may be a network-layer block rather than an auth regression, but this still needs investigation)."
}
Write-Host ''

# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Host "== OBO passthrough negative test FAILED: $script:Failures check(s) failed =="
    exit 1
}
Write-Host "== OBO passthrough negative test passed =="
exit 0
