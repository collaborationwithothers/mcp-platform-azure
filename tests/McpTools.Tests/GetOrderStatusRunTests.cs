using McpTools.Downstream;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process tests of GetOrderStatus.Run's orchestration: extracting the
/// inbound token via ToolInvocationContext.TryGetHttpTransport and handing
/// it to IDownstreamOrdersClient. Both ToolInvocationContext and HttpTransport
/// are publicly constructible (confirmed by direct reflection against the
/// installed Microsoft.Azure.Functions.Worker.Extensions.Mcp 1.5.1 assembly,
/// 2026-07-18), so this runs with no Functions host and no Azure dependency
/// (spec: Testing Decisions, "unit seam") -- the fake IDownstreamOrdersClient
/// stands in for the real OBO exchange and downstream call, which
/// DownstreamOrdersClientTests.cs already covers at the next layer down.
/// </summary>
public class GetOrderStatusRunTests
{
    [Fact]
    public async Task Run_TokenOnAuthorizationHeader_PassesItToTheDownstreamClient()
    {
        var fakeClient = new FakeDownstreamOrdersClient(new OrderStatus("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z"));
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(new() { ["Authorization"] = "Bearer inbound-token" });

        var result = await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("CONTOSO-1001", fakeClient.LastOrderId);
        Assert.Equal("inbound-token", fakeClient.LastInboundUserAssertion);
        Assert.IsType<OrderStatus>(result);
    }

    [Fact]
    public async Task Run_TokenOnTokenStoreHeader_PrefersItOverAuthorization()
    {
        var fakeClient = new FakeDownstreamOrdersClient(new OrderStatus("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z"));
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders(new()
        {
            ["X-MS-TOKEN-AAD-ACCESS-TOKEN"] = "token-store-token",
            ["Authorization"] = "Bearer raw-bearer-token",
        });

        await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("token-store-token", fakeClient.LastInboundUserAssertion);
    }

    [Fact]
    public async Task Run_NoUsableHeader_Throws()
    {
        var fakeClient = new FakeDownstreamOrdersClient(new OrderStatus("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z"));
        var tool = new GetOrderStatus(fakeClient);
        var context = ContextWithHeaders([]);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
    }

    [Fact]
    public async Task Run_NonHttpTransport_Throws()
    {
        var fakeClient = new FakeDownstreamOrdersClient(new OrderStatus("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z"));
        var tool = new GetOrderStatus(fakeClient);
        // Transport is the abstract base, not an HttpTransport: TryGetHttpTransport
        // returns false in this shape (e.g. a non-HTTP transport this repo hasn't
        // verified header availability for -- see GetOrderStatus's doc comment).
        var context = new ToolInvocationContext { Name = GetOrderStatus.ToolName, Transport = null };

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
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
