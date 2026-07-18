using System.Net;
using System.Text;
using System.Text.Json;
using McpTools.Downstream;
using McpTools.Tools;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for DownstreamOrdersClient (spec: Testing
/// Decisions, "unit seam"). No Azure dependency: <see cref="FakeTokenAcquirer"/>
/// and <see cref="FakeHttpMessageHandler"/> stand in for the real Entra OBO
/// exchange and the real downstream HTTP call.
///
/// The "never forwards the inbound token" tests are the unit-level proof of
/// the acceptance criterion in docs/decisions/ADR-006 and the ticket 10
/// acceptance checklist: they assert the Authorization header actually sent
/// to the downstream carries the OBO-exchanged token, never the caller's
/// inbound assertion. The live-level proof is the negative test,
/// tests/integration/obo-passthrough-negative.ps1.
/// </summary>
public class DownstreamOrdersClientTests
{
    private const string InboundAssertion = "inbound-user-assertion-token";
    private const string DownstreamToken = "obo-exchanged-downstream-token";
    private const string DownstreamScope = "api://downstream-app/.default";

    [Fact]
    public async Task GetOrderStatusAsync_KnownId_ReturnsTypedSuccessShape()
    {
        var handler = new FakeHttpMessageHandler((request, _) =>
        {
            var body = JsonSerializer.Serialize(new
            {
                orderId = "CONTOSO-1001",
                status = "Delivered",
                updatedUtc = "2026-06-01T14:05:00Z",
            });
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        });

        var client = CreateClient(handler);

        var result = await client.GetOrderStatusAsync("CONTOSO-1001", InboundAssertion, CancellationToken.None);

        var status = Assert.IsType<OrderStatus>(result);
        Assert.Equal("CONTOSO-1001", status.OrderId);
        Assert.Equal("Delivered", status.Status);
        Assert.Equal("2026-06-01T14:05:00Z", status.UpdatedUtc);
    }

    [Fact]
    public async Task GetOrderStatusAsync_UnknownId_ReturnsTypedNotFoundShape()
    {
        var handler = new FakeHttpMessageHandler((request, _) =>
        {
            var body = JsonSerializer.Serialize(new
            {
                orderId = "CONTOSO-9999",
                message = "No order was found for id 'CONTOSO-9999'.",
            });
            return new HttpResponseMessage(HttpStatusCode.NotFound)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        });

        var client = CreateClient(handler);

        var result = await client.GetOrderStatusAsync("CONTOSO-9999", InboundAssertion, CancellationToken.None);

        var notFound = Assert.IsType<OrderNotFound>(result);
        Assert.Equal("CONTOSO-9999", notFound.OrderId);
        Assert.False(notFound.Found);
        Assert.False(string.IsNullOrWhiteSpace(notFound.Message));
    }

    [Fact]
    public async Task GetOrderStatusAsync_NeverSendsTheInboundAssertionToTheDownstream()
    {
        HttpRequestMessage? capturedRequest = null;
        var handler = new FakeHttpMessageHandler((request, _) =>
        {
            capturedRequest = request;
            var body = JsonSerializer.Serialize(new { orderId = "CONTOSO-1001", status = "Delivered", updatedUtc = "2026-06-01T14:05:00Z" });
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        });

        var client = CreateClient(handler);
        await client.GetOrderStatusAsync("CONTOSO-1001", InboundAssertion, CancellationToken.None);

        Assert.NotNull(capturedRequest);
        var authorization = capturedRequest!.Headers.Authorization;
        Assert.NotNull(authorization);
        Assert.Equal("Bearer", authorization!.Scheme);
        // The downstream call must carry the OBO-exchanged token, never the
        // caller's inbound assertion (token passthrough is forbidden).
        Assert.Equal(DownstreamToken, authorization.Parameter);
        Assert.NotEqual(InboundAssertion, authorization.Parameter);
    }

    [Fact]
    public async Task GetOrderStatusAsync_RequestsTheOboExchangeWithTheInboundAssertionAndDownstreamScope()
    {
        var tokenAcquirer = new FakeTokenAcquirer(DownstreamToken);
        var handler = new FakeHttpMessageHandler((request, _) =>
        {
            var body = JsonSerializer.Serialize(new { orderId = "CONTOSO-1001", status = "Delivered", updatedUtc = "2026-06-01T14:05:00Z" });
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            };
        });

        var client = new DownstreamOrdersClient(
            tokenAcquirer, new HttpClient(handler), new Uri("https://downstream.example/"), DownstreamScope);
        await client.GetOrderStatusAsync("CONTOSO-1001", InboundAssertion, CancellationToken.None);

        Assert.Equal(InboundAssertion, tokenAcquirer.LastUserAssertion);
        Assert.Equal(DownstreamScope, tokenAcquirer.LastDownstreamScope);
    }

    private static DownstreamOrdersClient CreateClient(FakeHttpMessageHandler handler) =>
        new(
            new FakeTokenAcquirer(DownstreamToken),
            new HttpClient(handler),
            new Uri("https://downstream.example/"),
            DownstreamScope);

    private sealed class FakeTokenAcquirer(string tokenToReturn) : IOboTokenAcquirer
    {
        public string? LastUserAssertion { get; private set; }
        public string? LastDownstreamScope { get; private set; }

        public Task<string> AcquireDownstreamTokenAsync(
            string userAssertion, string downstreamScope, CancellationToken cancellationToken)
        {
            LastUserAssertion = userAssertion;
            LastDownstreamScope = downstreamScope;
            return Task.FromResult(tokenToReturn);
        }
    }

    private sealed class FakeHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request, cancellationToken));
    }
}
