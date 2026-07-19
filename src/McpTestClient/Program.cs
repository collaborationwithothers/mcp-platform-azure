using System.Text.Json;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

// McpTestClient: the hand-written .NET MCP client that drives a real MCP session
// against the deployed APIM gateway endpoint (spec: Testing Decisions, "primary
// behavioural seam"). The official ModelContextProtocol C# SDK is the client.
//
// Ticket 5 (the live apply-call-destroy gate) fills in the behavioural
// assertions and the non-interactive token attachment. The gate acquires a
// client-credentials bearer token for the server app on the dedicated test app
// registration (scripts/gate/invoke-and-assert.ps1) and passes it in via
// MCP_ACCESS_TOKEN; the SDK's interactive auth-code flow cannot run in CI
// (spec: Testing Decisions). Any assertion failure throws, which exits non-zero
// and fails the gate's call stage.

const string ToolName = "get_order_status";
// A known id (CONTOSO-1003 -> "Processing" in the synthetic fixture) and an
// unknown id, matching the ticket's acceptance checklist.
const string KnownOrderId = "CONTOSO-1003";
const string UnknownOrderId = "CONTOSO-9999";

// Endpoint resolution. The gate points this at the deployed gateway MCP
// endpoint (s2 output mcp_server_url); locally it defaults to the emulator.
string endpoint =
    Environment.GetEnvironmentVariable("MCP_SERVER_ENDPOINT")
    ?? (args.Length > 0 ? args[0] : "http://localhost:7071/mcp");

// Non-interactive bearer token for the server app audience, minted by the gate
// via client credentials on the dedicated test app registration. When absent
// (local skeleton runs against the emulator), no Authorization header is sent.
string? accessToken = Environment.GetEnvironmentVariable("MCP_ACCESS_TOKEN");
string? expectedForbiddenRole = Environment.GetEnvironmentVariable("MCP_EXPECT_FORBIDDEN_ROLE");

Console.WriteLine($"[McpTestClient] Target MCP endpoint: {endpoint}");
Console.WriteLine($"[McpTestClient] Authorization header: {(string.IsNullOrEmpty(accessToken) ? "absent (unauthenticated)" : "present (Bearer)")}");

// Steps 1 + 2 - connect and initialize. McpClient.CreateAsync opens the
// transport and performs the MCP initialize handshake as one operation.
var transportOptions = new HttpClientTransportOptions
{
    Endpoint = new Uri(endpoint),
    Name = "McpTestClient",
};
if (!string.IsNullOrEmpty(accessToken))
{
    transportOptions.AdditionalHeaders = new Dictionary<string, string>
    {
        ["Authorization"] = $"Bearer {accessToken}",
    };
}

var transport = new HttpClientTransport(transportOptions);

await using var client = await McpClient.CreateAsync(transport);
AssertInitialized(client);

// Step 3 - tools/list.
var tools = await client.ListToolsAsync();
Console.WriteLine($"[McpTestClient] tools/list returned {tools.Count} tool(s):");
foreach (var tool in tools)
{
    Console.WriteLine($"  - {tool.Name}");
}
AssertToolListed(tools);

if (!string.IsNullOrEmpty(expectedForbiddenRole))
{
    var forbidden = await client.CallToolAsync(
        ToolName,
        new Dictionary<string, object?> { ["orderId"] = KnownOrderId });
    var rendered = Render(forbidden);
    var expected = $"403 Forbidden: get_order_status requires the application role '{expectedForbiddenRole}'.";
    if (forbidden.IsError != true || !rendered.Contains(expected, StringComparison.Ordinal))
    {
        throw new InvalidOperationException(
            $"Expected the deterministic missing-role error '{expected}', got IsError={forbidden.IsError}, "
            + $"content={rendered}");
    }

    Console.WriteLine($"[McpTestClient] Missing-role assertion passed: {expected}");
    return;
}

// Step 4 - tools/call for a known id and an unknown id (the two tool contracts).
var known = await client.CallToolAsync(
    ToolName,
    new Dictionary<string, object?> { ["orderId"] = KnownOrderId });
Console.WriteLine($"[McpTestClient] call(known)   -> {Render(known)}");
AssertKnownIdReturnsTypedStatus(known);

var unknown = await client.CallToolAsync(
    ToolName,
    new Dictionary<string, object?> { ["orderId"] = UnknownOrderId });
Console.WriteLine($"[McpTestClient] call(unknown) -> {Render(unknown)}");
AssertUnknownIdReturnsTypedNotFound(unknown);

Console.WriteLine("[McpTestClient] All session and tool assertions passed.");

static string Render(CallToolResult result)
    => result.Content.Count > 0 && result.Content[0] is TextContentBlock text
        ? text.Text
        : "(non-text content)";

// --- Assertions ------------------------------------------------------------
// The behavioural contract asserted at the deployed APIM MCP endpoint (spec:
// Testing Decisions). Exact fixture values (status strings, timestamps) are the
// job of the in-process unit tests; here we assert the session negotiated and
// the tool contract SHAPE, so the gate stays decoupled from the fixture data.

static void AssertInitialized(McpClient client)
{
    // A completed CreateAsync already implies a successful initialize; assert
    // the negotiated handshake artifacts are actually present.
    if (string.IsNullOrEmpty(client.NegotiatedProtocolVersion))
    {
        throw new InvalidOperationException(
            "initialize did not negotiate a protocol version.");
    }
    // ServerCapabilities throws if the client is not connected; reading it is
    // itself the assertion that the session is live.
    _ = client.ServerCapabilities;
    Console.WriteLine(
        $"[McpTestClient] initialize OK: protocol {client.NegotiatedProtocolVersion}, "
        + $"server {client.ServerInfo.Name}.");
}

static void AssertToolListed(IList<McpClientTool> tools)
{
    if (!tools.Any(t => t.Name == ToolName))
    {
        throw new InvalidOperationException(
            $"tools/list did not contain '{ToolName}'. Saw: "
            + string.Join(", ", tools.Select(t => t.Name)));
    }
}

static void AssertKnownIdReturnsTypedStatus(CallToolResult result)
{
    if (result.IsError == true)
    {
        throw new InvalidOperationException(
            $"call({KnownOrderId}) returned an MCP error result; expected the typed success shape.");
    }

    var json = ResultJson(result);
    string orderId = RequireString(json, "orderId");
    string status = RequireString(json, "status");
    string updatedUtc = RequireString(json, "updatedUtc");

    if (orderId != KnownOrderId)
    {
        throw new InvalidOperationException(
            $"call({KnownOrderId}) echoed orderId '{orderId}'; expected '{KnownOrderId}'.");
    }
    Console.WriteLine(
        $"[McpTestClient] known id OK: {{ orderId={orderId}, status={status}, updatedUtc={updatedUtc} }}.");
}

static void AssertUnknownIdReturnsTypedNotFound(CallToolResult result)
{
    // The not-found path is a typed result (found:false), not a thrown error.
    if (result.IsError == true)
    {
        throw new InvalidOperationException(
            $"call({UnknownOrderId}) returned an MCP error result; the unknown-id path must be a typed not-found result, not an error.");
    }

    var json = ResultJson(result);
    string orderId = RequireString(json, "orderId");

    if (!json.TryGetProperty("found", out var found)
        || found.ValueKind != JsonValueKind.False)
    {
        throw new InvalidOperationException(
            $"call({UnknownOrderId}) did not return found:false; expected the typed not-found shape.");
    }
    _ = RequireString(json, "message");

    if (orderId != UnknownOrderId)
    {
        throw new InvalidOperationException(
            $"call({UnknownOrderId}) echoed orderId '{orderId}'; expected '{UnknownOrderId}'.");
    }
    Console.WriteLine($"[McpTestClient] unknown id OK: typed not-found (found:false) for {orderId}.");
}

// Prefer the MCP structuredContent block; fall back to parsing the first text
// content block as JSON. Works whether the Functions MCP extension emits typed
// structured output or a JSON text payload.
static JsonElement ResultJson(CallToolResult result)
{
    if (result.StructuredContent is JsonElement structured
        && structured.ValueKind == JsonValueKind.Object)
    {
        return structured;
    }

    if (result.Content.Count > 0 && result.Content[0] is TextContentBlock text)
    {
        try
        {
            using var doc = JsonDocument.Parse(text.Text);
            return doc.RootElement.Clone();
        }
        catch (JsonException ex)
        {
            throw new InvalidOperationException(
                $"Tool result text was not JSON: {text.Text}", ex);
        }
    }

    throw new InvalidOperationException(
        "Tool result carried neither structuredContent nor a text content block.");
}

static string RequireString(JsonElement json, string property)
{
    if (!json.TryGetProperty(property, out var value)
        || value.ValueKind != JsonValueKind.String
        || string.IsNullOrEmpty(value.GetString()))
    {
        throw new InvalidOperationException(
            $"Tool result is missing the required string property '{property}'.");
    }
    return value.GetString()!;
}
