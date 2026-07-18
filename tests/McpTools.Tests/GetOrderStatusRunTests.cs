using System.Text;
using System.Text.Json;
using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process tests of GetOrderStatus.Run's orchestration: resolving the
/// caller's identity mode from X-MS-CLIENT-PRINCIPAL and branching between the
/// OBO downstream (delegated) and the in-memory fixture (app-context). Both
/// ToolInvocationContext and HttpTransport are publicly constructible
/// (confirmed by direct reflection against the installed
/// Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1 assembly, 2026-07-18),
/// so this runs with no Functions host and no Azure dependency (spec: Testing
/// Decisions, "unit seam") -- the fake IDownstreamOrdersClient stands in for
/// the real OBO exchange, which DownstreamOrdersClientTests.cs covers at the
/// next layer down.
/// </summary>
public class GetOrderStatusRunTests
{
    private static readonly OrderStatus SampleDownstreamStatus =
        new("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z");

    [Fact]
    public async Task Run_Delegated_TokenOnAuthorizationHeader_PassesItToTheDownstreamClient()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(Delegated(("Authorization", "Bearer inbound-token")));

        var result = await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("CONTOSO-1001", fakeClient.LastOrderId);
        Assert.Equal("inbound-token", fakeClient.LastInboundUserAssertion);
        Assert.IsType<OrderStatus>(result);
    }

    [Fact]
    public async Task Run_Delegated_TokenOnTokenStoreHeader_PrefersItOverAuthorization()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(Delegated(
            ("X-MS-TOKEN-AAD-ACCESS-TOKEN", "token-store-token"),
            ("Authorization", "Bearer raw-bearer-token")));

        await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("token-store-token", fakeClient.LastInboundUserAssertion);
    }

    [Fact]
    public async Task Run_Delegated_LowercaseHeaderKeys_StillReachesDownstream()
    {
        // HTTP/2 lowercases header names on the wire, and the transport's
        // Headers dictionary comparer is not guaranteed case-insensitive. Both
        // the principal lookup and the inbound-token lookup must tolerate that,
        // or the delegated OBO happy path silently breaks. Keys here are all
        // lowercased.
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);

        var payload = new { auth_typ = "aad", claims = new[] { new { typ = "scp", val = "user_impersonation" } } };
        var principal = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["x-ms-client-principal"] = principal,
            ["authorization"] = "Bearer inbound-token",
        };
        var context = ContextWithHeaders(headers);

        var result = await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("inbound-token", fakeClient.LastInboundUserAssertion);
        Assert.IsType<OrderStatus>(result);
    }

    [Fact]
    public async Task Run_Delegated_NoInboundToken_Throws()
    {
        // A delegated (scp) principal but no usable Authorization/token-store
        // header: the OBO user assertion is unavailable, so Run throws rather
        // than call downstream with nothing.
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(Delegated());

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_AppContext_ServesFromFixture_AndNeverCallsDownstream()
    {
        // A roles-claim, no-scp caller (the live gate's client-credentials
        // path): served from the fixture, the OBO downstream is never touched.
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(AppContext());

        var result = await tool.Run(context, "CONTOSO-1002", CancellationToken.None);

        var status = Assert.IsType<OrderStatus>(result);
        Assert.Equal("CONTOSO-1002", status.OrderId);
        Assert.Equal("Shipped", status.Status);
        Assert.Null(fakeClient.LastOrderId);
        Assert.Null(fakeClient.LastInboundUserAssertion);
    }

    [Fact]
    public async Task Run_AppContext_UnknownId_ReturnsTypedNotFound_FromFixture()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(AppContext());

        var result = await tool.Run(context, "CONTOSO-9999", CancellationToken.None);

        var notFound = Assert.IsType<OrderNotFound>(result);
        Assert.Equal("CONTOSO-9999", notFound.OrderId);
        Assert.False(notFound.Found);
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_MissingPrincipal_Throws_AndNeverCallsDownstream()
    {
        // No X-MS-CLIENT-PRINCIPAL: the per-request fail-closed rejection.
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(new Dictionary<string, string> { ["Authorization"] = "Bearer x" });

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_NonHttpTransport_Throws()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = new GetOrderStatus(fakeClient);
        // Transport is null: TryGetHttpTransport returns false (e.g. a non-HTTP
        // transport this repo hasn't verified header availability for).
        var context = new ToolInvocationContext { Name = GetOrderStatus.ToolName, Transport = null };

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
    }

    private static Dictionary<string, string> Delegated(params (string Key, string Value)[] extraHeaders) =>
        WithPrincipal(("scp", "user_impersonation"), extraHeaders);

    private static Dictionary<string, string> AppContext(params (string Key, string Value)[] extraHeaders) =>
        WithPrincipal(("roles", "Orders.Read.All"), extraHeaders);

    private static Dictionary<string, string> WithPrincipal(
        (string Typ, string Val) claim, (string Key, string Value)[] extraHeaders)
    {
        var payload = new { auth_typ = "aad", claims = new[] { new { typ = claim.Typ, val = claim.Val } } };
        var header = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
        var headers = new Dictionary<string, string> { [ClientPrincipal.HeaderName] = header };
        foreach (var (key, value) in extraHeaders)
        {
            headers[key] = value;
        }

        return headers;
    }

    private static ToolInvocationContext ContextWithHeaders(Dictionary<string, string> headers) =>
        new()
        {
            Name = GetOrderStatus.ToolName,
            Transport = new HttpTransport("http") { Headers = headers },
        };

    private sealed class FakeDownstreamOrdersClient(object resultToReturn) : IDownstreamOrdersClient
    {
        public string? LastOrderId { get; private set; }
        public string? LastInboundUserAssertion { get; private set; }

        public Task<object> GetOrderStatusAsync(
            string orderId, string inboundUserAssertion, CancellationToken cancellationToken)
        {
            LastOrderId = orderId;
            LastInboundUserAssertion = inboundUserAssertion;
            return Task.FromResult(resultToReturn);
        }
    }
}
