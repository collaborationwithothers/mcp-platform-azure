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
    [string]$Server1OnlyToken = '',

    # --- Per-tool authorization (issue 18) -----------------------------------
    # Server 1's tool_authorization_map keys, comma-joined (Terraform output
    # tool_authorization_map_keys). Used for set-equality against tools/list
    # and the allow/deny assertions. Optional: when empty the per-tool checks
    # are skipped so earlier gate invocations work unchanged.
    [string]$ToolAuthorizationMapKeys = '',
    # Server 2's tool_authorization_map keys, comma-joined (Terraform output
    # server_2_tool_authorization_map_keys).
    [string]$Server2ToolAuthorizationMapKeys = '',
    # Reuse of $mcpToken from invoke-and-assert.ps1: the same server-audience
    # token already used for step 2 McpTestClient and tools/call successes.
    [string]$EntitledToken = '',
    # Reuse of $missingRoleToken from invoke-and-assert.ps1: the token for the
    # client missing Orders.Read; now asserted at the gateway per-tool layer
    # (one layer earlier than the backend check in step 3).
    [string]$UnderEntitledToken = '',
    # Issue 80: token for the cross-tool differentiation client, entitled to
    # get_service_info (ServiceInfo.Read) and NOT to get_order_status
    # (Orders.Read) -- see entra-app-registrations.md section 3b. Optional:
    # when empty, checks (e)/(f)/(g) are skipped with a warning, exactly like
    # UnderEntitledToken above.
    [string]$ServiceToolToken = '',
    # The tool name ServiceToolToken is entitled to call. A parameter for the
    # same reason MappedToolName is, below.
    [string]$ServiceToolName = 'get_service_info',
    # The mapped tool name for allow/deny assertions. Defaults to
    # get_order_status (server 1's only tool today). A parameter so a future
    # second mapped tool requires only a call-site change, not a script edit.
    [string]$MappedToolName = 'get_order_status',
    # A synthetic tool name guaranteed absent from any map; used for the
    # unmapped-probe-denied assertion (default-deny branch).
    [string]$UnmappedProbeToolName = 'issue18_unmapped_probe_tool',
    # Issue 82: the tool mapped unrestricted = true in both servers' maps. Check
    # (h) calls it with the under-entitled token to prove the policy fragment's
    # unrestricted branch actually admits a caller. A parameter for the same
    # reason MappedToolName is: a future change of which tool is the open one
    # should be a call-site change, not a script edit.
    [string]$OpenToolName = 'get_access_guidance',
    # A second, distinct synthetic tool name used ONLY to warm the Event Hub
    # logger's connection before the timed per-tool audit-event checks run
    # (see the warm-up block ahead of check 9's loop). Kept distinct from
    # UnmappedProbeToolName so its audit event can never be mistaken for
    # check (c)'s by the Event Hub consumer's tool-name filter.
    [string]$EventHubWarmupToolName = 'issue18_eventhub_warmup',
    # ARM resource ID of the shared Log Analytics workspace underlying the
    # out-of-band workspace-based Application Insights resource (Terraform
    # output shared_observability_workspace_id).
    # No longer queried by this script (see EventHubNamespaceFqdn/EventHubName
    # below for the check that gates pass/fail) -- the policy's <trace>
    # element is unchanged, so every per-tool deny still reaches it; this
    # value is accepted only to print as a pointer for anyone who wants the
    # durable, human-reviewable audit trail afterward.
    [string]$SharedObservabilityWorkspaceId = '',
    # Ephemeral audit Event Hub (Terraform outputs eventhub_namespace_fqdn /
    # eventhub_name). The audit-event PASS/FAIL check reads THIS, via the
    # bounded-wait Python consumer (scripts/gate/wait_for_eventhub_audit.py),
    # not SharedObservabilityWorkspaceId: live-gate rounds 7-9 proved Application Insights
    # ingestion has no bounded real-world latency (landed anywhere from ~286s
    # to over 600s after the trace fired, non-deterministically), which
    # cannot gate a same-run pass/fail. Optional: when either is empty, the
    # audit-event assertion is skipped with a warning.
    [string]$EventHubNamespaceFqdn = '',
    [string]$EventHubName = ''
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

# Parses a Streamable HTTP SSE response body into the JSON-RPC message it
# carries. The MCP spec (2025-06-18, "Streamable HTTP", "Sending Messages to
# the Server", item 5) lets the server answer a JSON-RPC request with EITHER
# Content-Type: application/json OR text/event-stream, entirely at the
# server's discretion -- not conditioned on the operation being long-running
# or "streaming" in any user-visible sense (verified directly against the
# spec, 2026-08-06). It defers the wire grammar to the WHATWG SSE living
# standard: "data:" lines, a blank line dispatches/terminates one event,
# consecutive "data:" lines within one event are concatenated with LF. A
# stream may carry more than one event (e.g. an intermediate notification
# ahead of the real response), so this returns the FIRST event whose parsed
# "id" matches $ExpectedId, falling back to the first parseable event if none
# match (a response with no id to compare, or a single-event stream).
function ConvertFrom-SseJsonRpc {
    param(
        [string]$Raw,
        [int]$ExpectedId
    )
    $dataLines = New-Object System.Collections.Generic.List[string]
    $events = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Raw -split "`n")) {
        $trimmed = $line.TrimEnd("`r")
        if ($trimmed -eq '') {
            if ($dataLines.Count -gt 0) {
                $events.Add(($dataLines -join "`n"))
                $dataLines.Clear()
            }
            continue
        }
        if ($trimmed.StartsWith('data:')) {
            $value = $trimmed.Substring(5)
            if ($value.StartsWith(' ')) { $value = $value.Substring(1) }
            $dataLines.Add($value)
        }
    }
    if ($dataLines.Count -gt 0) { $events.Add(($dataLines -join "`n")) }

    foreach ($eventData in $events) {
        try {
            $parsed = $eventData | ConvertFrom-Json -ErrorAction Stop
            $parsedId = Get-SafeProperty $parsed 'id'
            if ($null -ne $parsedId -and [string]$parsedId -eq [string]$ExpectedId) {
                return $parsed
            }
        } catch { continue }
    }
    foreach ($eventData in $events) {
        try { return ($eventData | ConvertFrom-Json -ErrorAction Stop) } catch { continue }
    }
    return $null
}

# Thin JSON-RPC wrapper over Invoke-Raw: POSTs a JSON-RPC 2.0 envelope and
# returns the parsed response body, or $null if neither plain-JSON nor SSE
# parsing succeeds. Accept: application/json, text/event-stream is REQUIRED
# on every POST to a Streamable HTTP MCP endpoint (MCP spec 2025-06-18, item
# 2: "The client MUST include an Accept header, listing both application/json
# and text/event-stream as supported content types" -- there is no
# JSON-only-response opt-out; the spec never describes server behaviour for a
# client that omits text/event-stream, so doing so is undefined-by-spec, not
# a documented fallback -- verified 2026-08-06). One header, both media types
# comma-joined in a single string value (not an array -- some PowerShell HTTP
# client versions mis-serialize an array-valued Accept header). Omitting it
# is why an earlier pass got back a JSON-RPC error (code -32000, "Not
# Acceptable"). Because the client must offer text/event-stream, it must also
# be prepared to receive it: this repo's own APIM-authored deny responses are
# always plain JSON (this policy writes the body directly, never touching the
# backend), but the real Azure Functions backend answers ordinary,
# non-erroring tools/call and tools/list requests via SSE -- both shapes are
# normal and this helper must handle both, not treat SSE as a failure.
function Invoke-JsonRpc {
    param(
        [string]$Uri,
        [string]$Token,
        [string]$Method,
        [int]$Id,
        [string]$ParamsJson = '{}'
    )
    $body = "{`"jsonrpc`":`"2.0`",`"id`":$Id,`"method`":`"$Method`",`"params`":$ParamsJson}"
    $resp = Invoke-Raw -Uri $Uri -Headers @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json, text/event-stream'
    } -Body $body

    # Invoke-WebRequest's .Content is not guaranteed to be a string for every
    # response Content-Type -- PowerShell may hand back raw bytes for a type
    # it does not recognize as text (a documented Invoke-WebRequest quirk that
    # varies by PowerShell version), and text/event-stream is exactly the kind
    # of less-common type that can trip this. Coerce explicitly rather than
    # relying on ConvertFrom-SseJsonRpc's [string]$Raw parameter to do it: an
    # implicit [string] cast on a byte[] calls .ToString(), which produces the
    # literal, useless text "System.Byte[]", not the decoded content -- a
    # silent failure that would look identical to "the server sent nothing
    # parseable" with no way to tell the two apart.
    $rawText = if ($resp.Content -is [byte[]]) {
        [System.Text.Encoding]::UTF8.GetString($resp.Content)
    } else {
        [string]$resp.Content
    }

    try {
        return $rawText | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $sseResult = ConvertFrom-SseJsonRpc -Raw $rawText -ExpectedId $Id
        if ($null -eq $sseResult) {
            # Neither parse worked. Log real evidence instead of a bare
            # $null -- content type, length, and a bounded preview -- so a
            # failure here is diagnosable from the next run's log rather than
            # another round of guessing.
            $contentType = try { (Get-HeaderValue -Response $resp -Name 'Content-Type') } catch { '(unknown)' }
            $preview = if ($rawText.Length -gt 300) { $rawText.Substring(0, 300) + '...(truncated)' } else { $rawText }
            Write-Host "  [Invoke-JsonRpc] neither plain-JSON nor SSE parsing matched. Content-Type: '$contentType', original .Content type: $($resp.Content.GetType().Name), decoded length: $($rawText.Length). Preview: $preview"
        }
        return $sseResult
    }
}

# Safely extracts the JSON-RPC error code from a parsed body, or $null if
# there is no error, the body is $null, or (issue 18 live-gate finding) the
# body is one of THIS repo's pre-existing, non-JSON-RPC HTTP-layer denials
# (the no-token 401 and the per-server entitlement 403 both predate issue 18
# and return {"error":"insufficient_scope",...} with error as a plain STRING,
# not the JSON-RPC {"error":{"code":...,"message":...}} object shape -- see
# mcp-server.xml). Accessing .error.code directly on a string-shaped error
# throws under Set-StrictMode ("The property 'code' cannot be found on this
# object"), which is exactly the crash a per-server-under-entitled token (as
# opposed to a per-tool-under-entitled one) produces if not guarded against.
# Safe property lookup for a dynamically-shaped JSON-RPC PSCustomObject
# (from ConvertFrom-Json). Uses .PSObject.Properties[Name], a LOOKUP that
# returns $null for a genuinely absent key, rather than dot-notation
# (.Name), which THROWS under Set-StrictMode when the key was never present
# in the source JSON -- not just when it is null. This is the root cause
# behind two separate crashes in this file: a JSON-RPC success response has
# no "error" key at all (result/error are mutually exclusive and the absent
# one is OMITTED, not present-as-null), and an error response has no
# "result" key; dot-access on the absent one throws every time, not
# sometimes. Every access to a parsed JSON-RPC body's top-level or nested
# fields in this file goes through this, with no exceptions.
function Get-SafeProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

# The parsed body's "error" value, or $null if absent (see Get-SafeProperty).
function Get-JsonRpcError($parsedBody) {
    return Get-SafeProperty $parsedBody 'error'
}

function Get-JsonRpcErrorCode($parsedBody) {
    $err = Get-JsonRpcError $parsedBody
    if ($null -eq $err -or $err -is [string]) { return $null }
    return Get-SafeProperty $err 'code'
}

# The parsed body's error MESSAGE, safe regardless of whether .error is the
# legacy string shape (mcp-server.xml's HTTP-layer denials, error_description
# carries the message there) or the JSON-RPC object shape (.error.message).
function Get-JsonRpcErrorMessage($parsedBody) {
    $err = Get-JsonRpcError $parsedBody
    if ($null -eq $err) { return $null }
    if ($err -is [string]) { return Get-SafeProperty $parsedBody 'error_description' }
    return Get-SafeProperty $err 'message'
}

# Companion to Get-JsonRpcErrorCode: true when .error exists but is the OLD,
# non-JSON-RPC string shape (an HTTP-layer denial from a check that predates
# issue 18 -- most likely this token failed the PER-SERVER entitlement check,
# one layer before the per-tool fragment ever runs, per-tool result therefore
# undetermined rather than failed).
function Test-LegacyHttpDenial($parsedBody) {
    $err = Get-JsonRpcError $parsedBody
    return ($null -ne $err -and $err -is [string])
}

# True when the parsed JSON-RPC body is the per-tool gateway denial shape:
# HTTP 200 with error.code == -32001 (issue 18). Distinguishes the per-tool
# deny from HTTP 401/403 (per-session/per-server checks) and from a normal
# tools/call result. Uses Get-JsonRpcErrorCode so a legacy string-shaped
# .error (see above) safely resolves to "not a -32001 deny" rather than
# throwing.
function Test-ToolAuthDenial($parsedBody) {
    $code = Get-JsonRpcErrorCode $parsedBody
    return ($null -ne $code -and [int]$code -eq -32001)
}

# Per-tool authorization (issue 18): set-equality between tools/list and the
# map keys (both directions), mapped-tool callable, unmapped probe denied,
# (if UnderEntitledToken supplied) mapped-tool denied for the under-entitled
# caller, and (if ServiceToolToken supplied, issue 80) the cross-tool
# differentiation proof in both directions: the entitled caller is denied the
# service tool (e), the service-tool caller succeeds on the service tool (f),
# and the service-tool caller is denied the mapped tool (g). Generic: same
# code path for every server instance (issue-18 acceptance criterion
# "expressed as a loop over the server instances").
# ... and (h, issue 82, server 1 only) the unrestricted branch: the
# under-entitled caller SUCCEEDS on the deliberately open tool.
# WarnOnly converts Fail calls to ::warning:: (used for server 2 where token
# entitlement is out-of-band and results may be inconclusive).
function Assert-ToolAuthorization {
    param(
        [string]$Label,
        [string]$ServerUrl,
        [string]$Token,
        [string[]]$ExpectedMapKeys,
        [string]$MappedToolName,
        [string]$UnmappedProbeToolName,
        [string]$UnderEntitledToken = '',
        [string]$ServiceToolToken = '',
        [string]$ServiceToolName = 'get_service_info',
        [string]$OpenToolName = 'get_access_guidance',
        [string]$EventHubNamespaceFqdn = '',
        [string]$EventHubName = '',
        [switch]$WarnOnly
    )

    $assertFail = if ($WarnOnly) {
        { param([string]$msg) Write-Host "::warning::[$Label non-fatal] $msg" }
    } else {
        { param([string]$msg) Fail "${Label}: $msg" }
    }

    # (a) Set-equality: tools/list vs map keys, both directions.
    # Token is the pinned fully-granted identity: same entitled client already
    # used for the McpTestClient session (step 2 of invoke-and-assert) and the
    # existing get_order_status calls. It passes both the per-server entitlement
    # check and each mapped tool's role/scope check, so tools/list returns the
    # full server surface without hitting the per-tool gate (which fires only on
    # tools/call, per mcp-server.xml).
    Write-Host "[$Label-a] $ServerUrl tools/list set equals tool_authorization_map keys"
    $listResult = Invoke-JsonRpc -Uri $ServerUrl -Token $Token -Method 'tools/list' -Id 1 -ParamsJson '{}'
    if (Test-LegacyHttpDenial $listResult) {
        # This token failed the PER-SERVER entitlement check (issue 17), one
        # layer before the per-tool fragment (issue 18) ever runs -- e.g. the
        # "entitled" token supplied is entitled at a DIFFERENT server, not this
        # one (a real possibility for server 2, whose entitlement this gate
        # cannot independently provision -- see the call site). Every check
        # below shares this token (or a variant of it) and would hit the same
        # wall, so report it ONCE, clearly, and stop for this server rather
        # than cascading into confusing or crashing downstream results.
        & $assertFail "tools/list was rejected before reaching the per-tool gate: '$(Get-JsonRpcError $listResult)' ($(Get-JsonRpcErrorMessage $listResult)). This token is not entitled at the PER-SERVER layer for $ServerUrl; per-tool results for this server are UNDETERMINED, not tested. Skipping (b)/(c)/(d) for $Label."
        Write-Host ''
        return
    }
    $listResultResult = Get-SafeProperty $listResult 'result'
    $listResultTools = Get-SafeProperty $listResultResult 'tools'
    if ($null -eq $listResult) {
        & $assertFail "tools/list response was not valid JSON (the request may have been rejected upstream of the per-tool gate; check token entitlement for this server)."
    } elseif ($null -ne (Get-JsonRpcError $listResult)) {
        & $assertFail "tools/list with the entitled token returned a JSON-RPC error (code $(Get-JsonRpcErrorCode $listResult)): $(Get-JsonRpcErrorMessage $listResult). The per-tool gate must not block tools/list (gate fires only on tools/call)."
    } elseif ($null -eq $listResultResult -or $null -eq $listResultTools) {
        & $assertFail "tools/list response did not contain a result.tools array (unexpected response shape)."
    } else {
        $listedTools = @($listResultTools | ForEach-Object { Get-SafeProperty $_ 'name' })
        $inListNotMap = @($listedTools | Where-Object { $_ -notin $ExpectedMapKeys })
        $inMapNotList = @($ExpectedMapKeys | Where-Object { $_ -notin $listedTools })
        if ($inListNotMap.Count -gt 0) {
            & $assertFail "tool(s) returned by tools/list but absent from tool_authorization_map -- would be silently default-denied in production: $($inListNotMap -join ', ')."
        }
        if ($inMapNotList.Count -gt 0) {
            & $assertFail "tool_authorization_map key(s) with no matching tool in tools/list -- dead policy branch, renamed or removed tool: $($inMapNotList -join ', ')."
        }
        if ($inListNotMap.Count -eq 0 -and $inMapNotList.Count -eq 0) {
            Pass "${Label}: tools/list and tool_authorization_map key set are equal ($($listedTools.Count) tool(s))."
        }
    }
    Write-Host ''

    # (b) Mapped tool callable: entitled token must NOT be denied by the per-tool
    # gate. A POSITIVE check (a real result.tools/call succeeded), not merely
    # "the response wasn't a -32001 error" -- that weaker check would silently
    # pass on ANY other failure (e.g. it did, once, when the response was
    # actually a DIFFERENT JSON-RPC error the gate never checked for; see the
    # Accept-header fix on Invoke-JsonRpc above).
    Write-Host "[$Label-b] $ServerUrl tools/call '$MappedToolName' with entitled token is NOT denied by the gateway"
    # get_order_status declares orderId isRequired: true (src/McpTools/Tools/GetOrderStatus.cs);
    # an empty arguments object never reaches the per-tool gate's pass/fail
    # outcome -- it fails backend param validation first (-32602), which this
    # check previously misread as a gate denial. CONTOSO-1001 is a known
    # synthetic fixture id (SyntheticOrders), so this exercises a real
    # success path, not just "didn't error on missing params".
    $callResult = Invoke-JsonRpc -Uri $ServerUrl -Token $Token -Method 'tools/call' -Id 2 `
        -ParamsJson "{`"name`":`"$MappedToolName`",`"arguments`":{`"orderId`":`"CONTOSO-1001`"}}"
    if ($null -eq $callResult) {
        & $assertFail "tools/call '$MappedToolName' with the entitled token: response was not valid JSON."
    } elseif (Test-LegacyHttpDenial $callResult) {
        & $assertFail "tools/call '$MappedToolName' with the entitled token was rejected before reaching the per-tool gate: '$(Get-JsonRpcError $callResult)'; this token is not entitled at the per-server layer."
    } elseif ($null -ne (Get-JsonRpcError $callResult)) {
        & $assertFail "tools/call '$MappedToolName' with the entitled token returned an unexpected JSON-RPC error (code $(Get-JsonRpcErrorCode $callResult)): $(Get-JsonRpcErrorMessage $callResult). Expected a successful result, not any error."
    } elseif ($null -eq (Get-SafeProperty $callResult 'result')) {
        & $assertFail "tools/call '$MappedToolName' with the entitled token returned neither a result nor an error (unexpected response shape)."
    } else {
        Pass "${Label}: tools/call '$MappedToolName' succeeded with the entitled token (per-tool check passed, result returned)."
    }
    Write-Host ''

    # (c) Unmapped probe denied: the default-deny branch fires for a tool name
    # absent from the map. The deny response is HTTP 200 + JSON-RPC -32001, with
    # the request id echoed at the TOP LEVEL of the JSON-RPC envelope (not nested
    # under error): per mcp-server.xml the body is
    # {"jsonrpc":"2.0","id":<echoed>,"error":{"code":-32001,"message":"..."}}.
    $probeId = 42
    Write-Host "[$Label-c] $ServerUrl tools/call '$UnmappedProbeToolName' IS denied (-32001, id=$probeId echoed)"
    # Captured immediately before the call that triggers the deny: the Event
    # Hub consumer's --since cutoff, so it only considers messages enqueued
    # after THIS check's own deny, never a stale message from an earlier
    # check or an earlier live-test run against the same ephemeral instance.
    $unmappedCallTimeUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $probeResult = Invoke-JsonRpc -Uri $ServerUrl -Token $Token -Method 'tools/call' -Id $probeId `
        -ParamsJson "{`"name`":`"$UnmappedProbeToolName`",`"arguments`":{}}"
    if (-not (Test-ToolAuthDenial $probeResult)) {
        & $assertFail "tools/call '$UnmappedProbeToolName' was NOT denied with -32001; an unmapped tool name must be default-denied by the gateway."
    } else {
        $echoedId = [string](Get-SafeProperty $probeResult 'id')
        if ($echoedId -ne [string]$probeId) {
            & $assertFail "tools/call '$UnmappedProbeToolName' returned -32001 but echoed id '$echoedId'; expected '$probeId' (top-level JSON-RPC envelope id field, not nested under error)."
        } else {
            Pass "${Label}: tools/call '$UnmappedProbeToolName' denied with -32001 and id=$probeId echoed correctly at the envelope top level."
            Assert-AuditEventEmitted -ServerLabel "$Label-c" -EventHubNamespaceFqdn $EventHubNamespaceFqdn -EventHubName $EventHubName -ToolName $UnmappedProbeToolName -SinceUtc $unmappedCallTimeUtc -WarnOnly:$WarnOnly
        }
    }
    Write-Host ''

    # (d) Under-entitled caller denied on a mapped tool (optional). Runs only when
    # UnderEntitledToken is supplied. Same -32001 error shape as (c): the policy
    # uses a single deny path for both the unmapped and the under-entitled cases
    # (non-concealment; the audit event carries the tool name for operators who
    # need to distinguish them).
    if (-not [string]::IsNullOrEmpty($UnderEntitledToken)) {
        Write-Host "[$Label-d] $ServerUrl tools/call '$MappedToolName' with under-entitled token IS denied (-32001)"
        $underEntitledCallTimeUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $denyResult = Invoke-JsonRpc -Uri $ServerUrl -Token $UnderEntitledToken -Method 'tools/call' -Id 3 `
            -ParamsJson "{`"name`":`"$MappedToolName`",`"arguments`":{}}"
        if (-not (Test-ToolAuthDenial $denyResult)) {
            & $assertFail "tools/call '$MappedToolName' with the under-entitled token was NOT denied with -32001; a caller missing the required role/scope must be denied by the per-tool check."
        } else {
            Pass "${Label}: tools/call '$MappedToolName' with the under-entitled token denied with -32001 (per-tool check enforced)."
            Assert-AuditEventEmitted -ServerLabel "$Label-d" -EventHubNamespaceFqdn $EventHubNamespaceFqdn -EventHubName $EventHubName -ToolName $MappedToolName -SinceUtc $underEntitledCallTimeUtc -WarnOnly:$WarnOnly
        }
        Write-Host ''
    }

    # (e)/(f)/(g) Cross-tool differentiation (issue 80, closing #76): the thing
    # per-tool authorization actually promises is that a caller entitled for
    # one tool on a server is not thereby entitled for another tool on the
    # SAME server. (b)/(d) above only ever exercise $MappedToolName; they
    # cannot show that, because a single tool has no "other tool" to be wrongly
    # let through to. ServiceToolToken is entitled to ServiceToolName
    # (get_service_info, role ServiceInfo.Read) and NOT to MappedToolName
    # (get_order_status, role Orders.Read) -- see entra-app-registrations.md
    # section 3b. All three checks run only when ServiceToolToken is supplied;
    # the secret is out-of-band, exactly like UnderEntitledToken.
    #
    # Deliberately NOT calling Assert-AuditEventEmitted from (e) or (g): the
    # audit-event mechanism is already proven by (c) and (d), and each call
    # adds a bounded 60s wait. Live-gate rounds 11 and 12 (ADR-009, Appendix A)
    # showed Event Hub delivery timing is the most fragile part of this gate;
    # re-proving the same mechanism on two more denies adds risk for no new
    # information.
    if (-not [string]::IsNullOrEmpty($ServiceToolToken)) {
        # (e) The entitled caller (Token, entitled to MappedToolName) must be
        # denied the service tool. This assumes the positive test client was
        # never granted ServiceInfo.Read (entra-app-registrations.md section
        # 2); if it ever is, this check inverts and fails.
        Write-Host "[$Label-e] $ServerUrl tools/call '$ServiceToolName' with the entitled (get_order_status) token IS denied (-32001)"
        $entitledDenyResult = Invoke-JsonRpc -Uri $ServerUrl -Token $Token -Method 'tools/call' -Id 4 `
            -ParamsJson "{`"name`":`"$ServiceToolName`",`"arguments`":{}}"
        if (-not (Test-ToolAuthDenial $entitledDenyResult)) {
            & $assertFail "tools/call '$ServiceToolName' with the entitled (get_order_status) token was NOT denied with -32001; entitlement for one tool must not grant another tool on the same server."
        } else {
            Pass "${Label}: tools/call '$ServiceToolName' with the entitled (get_order_status) token denied with -32001 (cross-tool differentiation, direction 1)."
        }
        Write-Host ''

        # (f) The service-tool caller must SUCCEED on the service tool. A
        # POSITIVE assertion (a real result came back), not merely "not a
        # -32001" -- see check (b)'s comment on why the weaker form is unsafe.
        # Test-LegacyHttpDenial guard so a per-server rejection (server 2's
        # entitlement is out-of-band and may be missing) is reported as
        # "not entitled at the per-server layer", not misread as a per-tool
        # failure.
        Write-Host "[$Label-f] $ServerUrl tools/call '$ServiceToolName' with the service-tool token succeeds"
        $serviceCallResult = Invoke-JsonRpc -Uri $ServerUrl -Token $ServiceToolToken -Method 'tools/call' -Id 5 `
            -ParamsJson "{`"name`":`"$ServiceToolName`",`"arguments`":{}}"
        if ($null -eq $serviceCallResult) {
            & $assertFail "tools/call '$ServiceToolName' with the service-tool token: response was not valid JSON."
        } elseif (Test-LegacyHttpDenial $serviceCallResult) {
            & $assertFail "tools/call '$ServiceToolName' with the service-tool token was rejected before reaching the per-tool gate: '$(Get-JsonRpcError $serviceCallResult)'; this token is not entitled at the per-server layer."
        } elseif ($null -ne (Get-JsonRpcError $serviceCallResult)) {
            & $assertFail "tools/call '$ServiceToolName' with the service-tool token returned an unexpected JSON-RPC error (code $(Get-JsonRpcErrorCode $serviceCallResult)): $(Get-JsonRpcErrorMessage $serviceCallResult). Expected a successful result, not any error."
        } elseif ($null -eq (Get-SafeProperty $serviceCallResult 'result')) {
            $bodyPreview = ($serviceCallResult | ConvertTo-Json -Depth 8 -Compress)
            if ($bodyPreview.Length -gt 500) { $bodyPreview = $bodyPreview.Substring(0, 500) + '...(truncated)' }
            & $assertFail "tools/call '$ServiceToolName' with the service-tool token returned neither a result nor an error (unexpected response shape). Parsed body: $bodyPreview"
        } else {
            Pass "${Label}: tools/call '$ServiceToolName' succeeded with the service-tool token (per-tool check passed, result returned)."
        }
        Write-Host ''

        # (g) The service-tool caller must be denied the mapped tool -- the
        # other direction of the same proof as (e). get_order_status declares
        # orderId isRequired: true, so pass a real orderId, not empty
        # arguments: an empty arguments object fails backend param validation
        # with -32602 BEFORE the per-tool gate resolves (see check (b)'s
        # comment), which would misread a param-validation failure as this
        # check's result. The gate fires in inbound and denies first, but a
        # real orderId removes the ambiguity entirely. Same
        # Test-LegacyHttpDenial guard as (f), for the same reason.
        Write-Host "[$Label-g] $ServerUrl tools/call '$MappedToolName' with the service-tool token IS denied (-32001)"
        $serviceDenyResult = Invoke-JsonRpc -Uri $ServerUrl -Token $ServiceToolToken -Method 'tools/call' -Id 6 `
            -ParamsJson "{`"name`":`"$MappedToolName`",`"arguments`":{`"orderId`":`"CONTOSO-1001`"}}"
        if (Test-LegacyHttpDenial $serviceDenyResult) {
            & $assertFail "tools/call '$MappedToolName' with the service-tool token was rejected before reaching the per-tool gate: '$(Get-JsonRpcError $serviceDenyResult)'; this token is not entitled at the per-server layer."
        } elseif (-not (Test-ToolAuthDenial $serviceDenyResult)) {
            $bodyPreview = ($serviceDenyResult | ConvertTo-Json -Depth 8 -Compress)
            if ($bodyPreview.Length -gt 500) { $bodyPreview = $bodyPreview.Substring(0, 500) + '...(truncated)' }
            & $assertFail "tools/call '$MappedToolName' with the service-tool token was NOT denied with -32001; entitlement for one tool must not grant another tool on the same server. Parsed body: $bodyPreview"
        } else {
            Pass "${Label}: tools/call '$MappedToolName' with the service-tool token denied with -32001 (cross-tool differentiation, direction 2)."
        }
        Write-Host ''
    } else {
        Write-Host "::warning::[$Label] cross-tool differentiation checks (e)/(f)/(g) skipped: no ServiceToolToken supplied."
    }

    # (h) The unrestricted branch (issue 82). tool_authorization_map classifies
    # every tool as requiring a scope, requiring a role, or unrestricted
    # (ADR-009, D2). Checks (b), (d), (e), (f) and (g) exercise the ROLE
    # branch, and (c) exercises default-deny for a name absent from the map;
    # before this check nothing had ever executed the unrestricted branch, so a
    # break in it would have gone unnoticed while the repo claimed the map was
    # total and every branch deliberate.
    #
    # SERVER 1 ONLY, and the guard is deliberate rather than incidental. The
    # under-entitled client (entra-app-registrations.md section 3) holds
    # Orders.Invoke.All and nothing for server 2, so at server 2 its token is
    # rejected at the PER-SERVER check one layer before the per-tool map is
    # consulted. A success assertion there could never pass; running it
    # warn-only would print a permanent, meaningless warning on every run. If a
    # future client is granted both servers' entitlements, drop the -not
    # $WarnOnly guard and this check covers server 2 for free.
    #
    # No Assert-AuditEventEmitted call: an ALLOW emits no deny event, so there
    # is nothing to read back.
    if (-not [string]::IsNullOrEmpty($UnderEntitledToken) -and -not $WarnOnly) {
        Write-Host "[$Label-h] $ServerUrl tools/call '$OpenToolName' with the under-entitled token SUCCEEDS (unrestricted branch)"
        $openCallResult = Invoke-JsonRpc -Uri $ServerUrl -Token $UnderEntitledToken -Method 'tools/call' -Id 7 `
            -ParamsJson "{`"name`":`"$OpenToolName`",`"arguments`":{}}"
        $openCallError = Get-JsonRpcError $openCallResult
        $openCallResultBody = Get-SafeProperty $openCallResult 'result'
        if ($null -eq $openCallResult) {
            & $assertFail "tools/call '$OpenToolName' with the under-entitled token: response was not valid JSON."
        } elseif (Test-LegacyHttpDenial $openCallResult) {
            & $assertFail "tools/call '$OpenToolName' with the under-entitled token was rejected before reaching the per-tool gate: '$(Get-JsonRpcError $openCallResult)'; this token is not entitled at the per-server layer, so the unrestricted branch was never reached."
        } elseif ($null -ne $openCallError) {
            & $assertFail "tools/call '$OpenToolName' with the under-entitled token returned a JSON-RPC error (code $(Get-JsonRpcErrorCode $openCallResult)): $(Get-JsonRpcErrorMessage $openCallResult). A tool mapped unrestricted = true must admit any caller that clears the per-server check; a -32001 here means the unrestricted branch did not allow."
        } elseif ($null -eq $openCallResultBody) {
            $bodyPreview = ($openCallResult | ConvertTo-Json -Depth 8 -Compress)
            if ($bodyPreview.Length -gt 500) { $bodyPreview = $bodyPreview.Substring(0, 500) + '...(truncated)' }
            & $assertFail "tools/call '$OpenToolName' with the under-entitled token returned neither a result nor an error (unexpected response shape). Parsed body: $bodyPreview"
        } elseif ($true -eq (Get-SafeProperty $openCallResultBody 'isError')) {
            # Not redundant with the error check above, and (b)/(f) do not have
            # this condition. A tool method cannot emit a JSON-RPC error; a
            # fail-closed throw becomes a 200 + result + isError = true carrying
            # the SDK's generic "An error occurred invoking '<tool>'."
            # (COMPATIBILITY.md, "MCP tool method: thrown exception wire shape").
            # Without this branch, the gateway allowing the call and the BACKEND
            # then refusing the caller would both read as a pass.
            $errorPreview = ($openCallResultBody | ConvertTo-Json -Depth 8 -Compress)
            if ($errorPreview.Length -gt 500) { $errorPreview = $errorPreview.Substring(0, 500) + '...(truncated)' }
            & $assertFail "tools/call '$OpenToolName' with the under-entitled token passed the gateway but the TOOL returned isError = true; the unrestricted branch allowed, the backend then refused. Result: $errorPreview"
        } else {
            Pass "${Label}: tools/call '$OpenToolName' succeeded with the under-entitled token (unrestricted branch allowed, real result returned, isError not set)."
        }
        Write-Host ''
    }
}

# Asserts a per-tool deny emitted its audit event (issue 18), by reading the
# ephemeral audit Event Hub the policy's <log-to-eventhub> element writes to,
# via a bounded-wait Python consumer (scripts/gate/wait_for_eventhub_audit.py
# -- az CLI has no Event Hubs data-plane receive command; verified
# 2026-08-07). This REPLACES the Log Analytics/Application Insights KQL path
# this function used through live-gate round 9 as the thing that gates
# pass/fail. That query was proven correct three separate times (manually
# re-run, and via the exact az CLI invocation this script issued, both
# matched real data every time), but real Application Insights ingestion
# latency ranged from ~286s to over 600s across rounds 7-9, non-
# deterministically -- Application Insights documents no latency SLA, so no
# fixed timeout is provably safe against it. Event Hub delivery has no such
# batching/ingestion indirection between the policy firing and a consumer
# reading it (COMPATIBILITY.md, 2026-08-07). The <trace> element and its
# Application Insights sink are UNCHANGED by this: they still receive every
# per-tool deny and remain the durable, human-reviewable audit trail; this
# function just no longer reads them back for pass/fail.
function Assert-AuditEventEmitted {
    param(
        [string]$ServerLabel,
        [string]$EventHubNamespaceFqdn,
        [string]$EventHubName,
        [string]$ToolName,
        # UTC timestamp (yyyy-MM-ddTHH:mm:ss.fffZ), captured by the caller
        # immediately before issuing the tools/call that triggers this deny.
        # Anchors the consumer's starting_position so it only considers
        # events enqueued after THIS check's own deny -- never a stale event
        # from an earlier check or an earlier live-test run against the same
        # ephemeral Event Hub instance name.
        [string]$SinceUtc,
        [int]$TimeoutSeconds = 60,
        [switch]$WarnOnly
    )

    if ([string]::IsNullOrEmpty($EventHubNamespaceFqdn) -or [string]::IsNullOrEmpty($EventHubName)) {
        Write-Host "::warning::[$ServerLabel] audit-event assertion skipped: no Event Hub supplied."
        return
    }

    $assertFail = if ($WarnOnly) {
        { param([string]$msg) Write-Host "::warning::[$ServerLabel non-fatal] $msg" }
    } else {
        { param([string]$msg) Fail "${ServerLabel}: $msg" }
    }

    $consumerScript = Join-Path $PSScriptRoot '..' '..' 'scripts' 'gate' 'wait_for_eventhub_audit.py'
    $raw = python3 $consumerScript `
        --namespace-fqdn $EventHubNamespaceFqdn `
        --eventhub-name $EventHubName `
        --tool-name $ToolName `
        --since $SinceUtc `
        --timeout-seconds $TimeoutSeconds 2>&1
    # The consumer script always prints exactly one JSON object as its last
    # line and always exits 0 (errors are reported IN the JSON, not via exit
    # code or a thrown failure) -- Select-Object -Last 1 is defensive against
    # any incidental SDK log lines landing on the merged stderr stream ahead
    # of it, not a sign the script itself can fail ambiguously.
    $result = $null
    try {
        $result = ($raw | Select-Object -Last 1) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        & $assertFail "audit-event check for tool '$ToolName' could not parse the consumer script's output. Raw output: $raw"
        return
    }

    if ($result.found) {
        Pass "${ServerLabel}: audit event found for tool '$ToolName' via Event Hub, dimensioned by caller (enqueued $($result.enqueued_time))."
    } else {
        $errDetail = if (Get-SafeProperty $result 'error') { " Consumer error: $($result.error)" } else { '' }
        & $assertFail "no audit event found for tool '$ToolName' on the audit Event Hub within ${TimeoutSeconds}s.$errDetail Either the deny did not emit its event, or the policy's Event Hub logger is misconfigured (ADR-009)."
    }
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
# 6. On-error 401 challenge, per server (acceptance: on-error rewrite behaviour
#    recorded, and per-server correctness asserted). A wrong-audience token
#    drives the validate-azure-ad-token 401, whose WWW-Authenticate is added in
#    the policy's on-error handler. Established at the issue-17 live gate: the
#    deployed type=mcp runtime does NOT rewrite the on-error challenge (unlike
#    the no-token path), so the policy's literal value reaches the client. The
#    policy emits THIS server's path-inserted PRM URL there, so the on-error
#    challenge must equal that URL -- proving a second server's on-error points
#    at its OWN metadata and never the shared root (server 1's document). The
#    actual value is logged either way (the "recorded" half of the acceptance
#    item); if the platform ever starts rewriting on-error, this assertion trips
#    so the change is caught (COMPATIBILITY.md).
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($WrongAudienceToken)) {
    Write-Host "[6] On-error 401 challenge points at each server's own metadata"
    $gwBase = Get-GatewayBase $PrmUrl
    $onErrTargets = @{ 'server 1' = $McpServerUrl }
    if (-not [string]::IsNullOrEmpty($McpServer2Url)) { $onErrTargets['server 2'] = $McpServer2Url }
    foreach ($name in $onErrTargets.Keys) {
        $url = $onErrTargets[$name]
        $expectedOwn = Get-PathInsertedPrmUrl $url $PrmUrl $gwBase
        $rootPrm = $PrmUrl
        $oe = Invoke-Raw -Uri $url -Headers @{ Authorization = "Bearer $WrongAudienceToken" } -Body $initBody
        if ($oe.StatusCode -ne 401) {
            Fail "$name on-error path returned $($oe.StatusCode), not 401; cannot assert the on-error challenge."
            continue
        }
        $oeWww = Get-HeaderValue -Response $oe -Name 'WWW-Authenticate'
        Write-Host "  [INFO] $name on-error 401 WWW-Authenticate: '$oeWww'"
        if ($oeWww -match [regex]::Escape("resource_metadata=`"$expectedOwn`"")) {
            Pass "$name on-error challenge points at this server's own path-inserted metadata ($expectedOwn)."
        }
        elseif ($oeWww -match [regex]::Escape("resource_metadata=`"$rootPrm`"")) {
            Fail "$name on-error challenge points at the SHARED ROOT PRM ($rootPrm), not this server's own metadata -- a client on this server would be sent to another server's document. Expected '$expectedOwn'."
        }
        else {
            Fail "$name on-error challenge resource_metadata is neither this server's own path-inserted URL ('$expectedOwn') nor the shared root; the on-error emit or the platform's on-error behaviour changed. Got: '$oeWww'. Reconcile with COMPATIBILITY.md."
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
# 8. No-token challenge URL resolution, RECORDED per server (coverage). Checks 1
#    and 5-a assert the client-visible no-token challenge STRING; this GETs that
#    exact URL to record what a client literally following resource_metadata
#    receives. It is the platform-rewritten path-scoped form
#    <gateway>/<server_path>/.well-known/oauth-protected-resource. Known from
#    issue 9 (see COMPATIBILITY.md, ADR-006): this location does NOT serve the PRM
#    document -- it routes into the MCP server API, which has no such operation --
#    so it 401s/404s. A spec client therefore relies on the RFC 9728 s3.1
#    path-inserted location instead, which IS served (checks 2b / 5-b, GET-200 +
#    resource verified). This step is RECORDED, not asserted: making the literal
#    no-token challenge URL resolve is the interactive-discovery gap owned by
#    issue #42, not closed by #17. Recording it makes the coverage explicit and
#    flags a change if a future platform/design ever makes it serve the document.
# ---------------------------------------------------------------------------
Write-Host "[8] No-token challenge URL resolution (recorded; issue 9 / issue 42 gap)"
$chGwBase = Get-GatewayBase $PrmUrl
$chTargets = @{ 'server 1' = $McpServerUrl }
if (-not [string]::IsNullOrEmpty($McpServer2Url)) { $chTargets['server 2'] = $McpServer2Url }
foreach ($cname in $chTargets.Keys) {
    $curl = $chTargets[$cname]
    $expectedRes = if ($cname -eq 'server 2') { $ExpectedResource2 } else { $ExpectedResource }
    $chUrl = Get-ObservedChallengeUrl $curl $chGwBase
    $cg = Invoke-Raw -Uri $chUrl -Method 'GET'
    if ($cg.StatusCode -eq 200) {
        $served = $false
        try { $served = (($cg.Content | ConvertFrom-Json -ErrorAction Stop).resource -eq $expectedRes) } catch { $served = $false }
        if ($served) {
            Write-Host "  [INFO] $cname no-token challenge URL ($chUrl) now SERVES this server's document (200, resource matches). The issue-9/#42 gap has closed for the literal challenge; update COMPATIBILITY.md and ADR-006."
        }
        else {
            Write-Host "  [INFO] $cname no-token challenge URL ($chUrl) returned 200 but not this server's document; record and reconcile."
        }
    }
    else {
        Write-Host "  [INFO] $cname no-token challenge URL ($chUrl) returned $($cg.StatusCode) and does NOT serve a document (expected: issue-9/#42 gap). Working discovery is the RFC 9728 s3.1 path-inserted location asserted in checks 2b/5-b."
    }
}
Write-Host ''

# ---------------------------------------------------------------------------
# 9. Per-tool authorization (issue 18): set-equality between tools/list and the
#    map keys (both directions), mapped-tool callable, unmapped-probe denied
#    (HTTP 200 + JSON-RPC -32001 Protocol Error, id echoed at the envelope top
#    level), under-entitled-denied, and (Assert-AuditEventEmitted, called from
#    within each deny check) that deny emitted its audit event, read back from
#    the ephemeral audit Event Hub with a short bounded wait (issue 18: see
#    Assert-AuditEventEmitted for why this replaced the Application Insights
#    KQL path after live-gate rounds 7-9). Expressed as a loop over configured
#    server instances (issue-18 acceptance criterion). Server 2 uses WarnOnly
#    throughout: its token entitlement is out-of-band and results may be
#    inconclusive.
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($SharedObservabilityWorkspaceId)) {
    Write-Host "Shared observability workspace (durable trail, unchanged by issue 18's Event Hub check): $SharedObservabilityWorkspaceId"
} else {
    Write-Host "::warning::SharedObservabilityWorkspaceId not supplied; no pointer to the durable observability trail will be printed. Does not affect the Event Hub audit-event assertion below."
}
if ([string]::IsNullOrEmpty($EventHubNamespaceFqdn) -or [string]::IsNullOrEmpty($EventHubName)) {
    Write-Host "::warning::EventHubNamespaceFqdn/EventHubName not supplied; audit-event assertions will be skipped."
}
$perToolServers = [System.Collections.Generic.List[hashtable]]::new()
if (-not [string]::IsNullOrEmpty($ToolAuthorizationMapKeys) -and -not [string]::IsNullOrEmpty($EntitledToken)) {
    $perToolServers.Add(@{
        Label    = '9 (server 1)'; Url = $McpServerUrl
        MapKeys  = @(($ToolAuthorizationMapKeys -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        WarnOnly = $false
    })
}
if (-not [string]::IsNullOrEmpty($McpServer2Url) -and
    -not [string]::IsNullOrEmpty($Server2ToolAuthorizationMapKeys) -and
    -not [string]::IsNullOrEmpty($EntitledToken)) {
    $perToolServers.Add(@{
        Label    = '9 (server 2)'; Url = $McpServer2Url
        MapKeys  = @(($Server2ToolAuthorizationMapKeys -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        WarnOnly = $true
    })
}
if ($perToolServers.Count -gt 0) {
    Write-Host "[9] Per-tool authorization (issue 18)"
    # Warm-up (not gated): live-gate rounds 11 and 12 observed that the FIRST
    # deny event through a freshly created eventhub_logger is the slow one --
    # round 11 (isBuffered default true) took ~16s, round 12 (isBuffered
    # explicitly false) exceeded the 60s gate timeout entirely -- while a
    # SECOND event moments later was consistently fast in both rounds (~16s,
    # ~5.5s). That pattern (first-use slow, subsequent-use fast) is consistent
    # with a cold-start effect on APIM's connection to a brand-new Event Hub,
    # not with the per-check timeout itself being too tight. Firing one
    # throwaway deny here, before check (c)'s timed assertion, moves that
    # cold-start cost out of a gating check and into a non-fatal warm-up: its
    # own deny and audit-event result are logged but never call Fail,
    # regardless of server WarnOnly settings (see COMPATIBILITY.md, "APIM
    # `log-to-eventhub` policy", and ADR-009, "audit-event pass/fail check",
    # round 11/12 entries).
    if (-not [string]::IsNullOrEmpty($EventHubNamespaceFqdn) -and -not [string]::IsNullOrEmpty($EventHubName)) {
        $warmupServer = $perToolServers[0]
        Write-Host "[9-warmup] $($warmupServer.Url) throwaway tools/call '$EventHubWarmupToolName' to warm the Event Hub logger connection before timed checks"
        $warmupCallTimeUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        Invoke-JsonRpc -Uri $warmupServer.Url -Token $EntitledToken -Method 'tools/call' -Id 41 `
            -ParamsJson "{`"name`":`"$EventHubWarmupToolName`",`"arguments`":{}}" | Out-Null
        Assert-AuditEventEmitted -ServerLabel '9-warmup' -EventHubNamespaceFqdn $EventHubNamespaceFqdn `
            -EventHubName $EventHubName -ToolName $EventHubWarmupToolName -SinceUtc $warmupCallTimeUtc `
            -TimeoutSeconds 90 -WarnOnly
        Write-Host ''
    }
    foreach ($srv in $perToolServers) {
        Assert-ToolAuthorization `
            -Label $srv.Label `
            -ServerUrl $srv.Url `
            -Token $EntitledToken `
            -ExpectedMapKeys $srv.MapKeys `
            -MappedToolName $MappedToolName `
            -UnmappedProbeToolName $UnmappedProbeToolName `
            -UnderEntitledToken $UnderEntitledToken `
            -ServiceToolToken $ServiceToolToken `
            -ServiceToolName $ServiceToolName `
            -OpenToolName $OpenToolName `
            -EventHubNamespaceFqdn $EventHubNamespaceFqdn `
            -EventHubName $EventHubName `
            -WarnOnly:$srv.WarnOnly
    }
}

# ---------------------------------------------------------------------------
if ($script:Failures -gt 0) {
    Write-Host "== Discovery assertions FAILED: $script:Failures check(s) failed =="
    exit 1
}
Write-Host "== Discovery assertions passed =="
exit 0
