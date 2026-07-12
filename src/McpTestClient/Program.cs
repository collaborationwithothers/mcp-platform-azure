using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

// McpTestClient: the hand-written .NET MCP client that drives a real MCP session
// against the deployed APIM gateway endpoint (spec: Testing Decisions, "primary
// behavioural seam"). The official ModelContextProtocol C# SDK is the client.
//
// THIS IS THE TICKET 2 SKELETON. It wires the session shape end to end -
//   connect -> initialize -> tools/list -> tools/call
// - and prints what it sees. The behavioural ASSERTIONS and the non-interactive
// client-credentials token acquisition are intentionally left as no-op stubs;
// they are filled in by ticket 5 (the live apply-call-destroy gate). Do not add
// them here (ticket 2 out-of-scope: "No filling in of the live-gate assertions
// in McpTestClient").

const string ToolName = "get_order_status";

// Endpoint resolution. Ticket 5 points this at the deployed gateway /mcp
// endpoint and attaches a client-credentials bearer token to the HttpClient.
string endpoint =
    Environment.GetEnvironmentVariable("MCP_SERVER_ENDPOINT")
    ?? (args.Length > 0 ? args[0] : "http://localhost:7071/mcp");

Console.WriteLine($"[McpTestClient] Target MCP endpoint: {endpoint}");

// Steps 1 + 2 - connect and initialize. McpClient.CreateAsync opens the
// transport and performs the MCP initialize handshake as one operation.
var transport = new HttpClientTransport(new HttpClientTransportOptions
{
    Endpoint = new Uri(endpoint),
    Name = "McpTestClient",
    // Ticket 5: supply the Authorization header (client-credentials bearer token
    // for the dedicated test app registration) via the backing HttpClient here.
});

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

// Step 4 - tools/call for a known id and an unknown id (the two tool contracts).
var known = await client.CallToolAsync(
    ToolName,
    new Dictionary<string, object?> { ["orderId"] = "CONTOSO-1001" });
Console.WriteLine($"[McpTestClient] call(known)   -> {Render(known)}");
AssertKnownIdReturnsTypedStatus(known);

var unknown = await client.CallToolAsync(
    ToolName,
    new Dictionary<string, object?> { ["orderId"] = "CONTOSO-9999" });
Console.WriteLine($"[McpTestClient] call(unknown) -> {Render(unknown)}");
AssertUnknownIdReturnsTypedNotFound(unknown);

Console.WriteLine("[McpTestClient] Skeleton run complete. Assertions are stubbed (ticket 5).");

static string Render(CallToolResult result)
    => result.Content.Count > 0 && result.Content[0] is TextContentBlock text
        ? text.Text
        : "(non-text content)";

// --- Assertion stubs -------------------------------------------------------
// Bodies are intentionally empty. Ticket 5 (the live gate) fills them with the
// real behavioural assertions. Keeping them as no-ops means the skeleton runs
// end to end today without pre-empting ticket 5's scope.

static void AssertInitialized(McpClient client)
{
    // Ticket 5: assert the initialize handshake negotiated a protocol version
    // and returned the server's capabilities.
    _ = client;
}

static void AssertToolListed(IList<McpClientTool> tools)
{
    // Ticket 5: assert tools/list contains get_order_status with its typed schema.
    _ = tools;
}

static void AssertKnownIdReturnsTypedStatus(CallToolResult result)
{
    // Ticket 5: assert a known id returns the typed
    // { orderId, status, updatedUtc } success shape.
    _ = result;
}

static void AssertUnknownIdReturnsTypedNotFound(CallToolResult result)
{
    // Ticket 5: assert an unknown id returns the typed
    // { orderId, found:false, message } not-found shape.
    _ = result;
}
