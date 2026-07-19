using System.Net;
using System.Text;
using System.Text.Json;
using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for DownstreamOrdersClient (spec: Testing
/// Decisions, "unit seam"). No Azure dependency: <see cref="FakeTokenAcquirer"/>
/// and <see cref="FakeHttpMessageHandler"/> stand in for the real Entra token
/// acquisitions and the real downstream HTTP call.
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
    private const string AppDownstreamToken = "app-only-downstream-token";
    private const string DownstreamScope = "api://downstream-app/user_impersonation";
    private const string DownstreamApplicationScope = "api://downstream-app/.default";
    private static readonly CallerIdentityCorrelation Caller =
        new("calling-client-app-id", "calling-principal-object-id");

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

        var result = await client.GetOrderStatusOnBehalfOfAsync(
            "CONTOSO-1001", InboundAssertion, Caller, CancellationToken.None);

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

        var result = await client.GetOrderStatusOnBehalfOfAsync(
            "CONTOSO-9999", InboundAssertion, Caller, CancellationToken.None);

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
        await client.GetOrderStatusOnBehalfOfAsync(
            "CONTOSO-1001", InboundAssertion, Caller, CancellationToken.None);

        Assert.NotNull(capturedRequest);
        var authorization = capturedRequest!.Headers.Authorization;
        Assert.NotNull(authorization);
        Assert.Equal("Bearer", authorization!.Scheme);
        // The downstream call must carry the OBO-exchanged token, never the
        // caller's inbound assertion (token passthrough is forbidden).
        Assert.Equal(DownstreamToken, authorization.Parameter);
        Assert.NotEqual(InboundAssertion, authorization.Parameter);
        Assert.Equal(
            Caller.ApplicationId,
            capturedRequest.Headers.GetValues(CallerIdentityCorrelation.ApplicationIdHeader).Single());
        Assert.Equal(
            Caller.ObjectId,
            capturedRequest.Headers.GetValues(CallerIdentityCorrelation.ObjectIdHeader).Single());
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
            tokenAcquirer,
            new FakeAppTokenAcquirer(AppDownstreamToken),
            new HttpClient(handler),
            new Uri("https://downstream.example/"),
            DownstreamScope,
            DownstreamApplicationScope);
        await client.GetOrderStatusOnBehalfOfAsync(
            "CONTOSO-1001", InboundAssertion, Caller, CancellationToken.None);

        Assert.Equal(InboundAssertion, tokenAcquirer.LastUserAssertion);
        Assert.Equal(DownstreamScope, tokenAcquirer.LastDownstreamScope);
    }

    [Fact]
    public async Task GetOrderStatusAsync_WhenOboExchangeRejectsTheAssertion_PropagatesTheRejection()
    {
        // Fed an assertion the OBO exchange rejects -- the "designed rejection"
        // an app-only (app-context) assertion produces at Entra's token
        // endpoint, since a client-credentials token is not a valid OBO
        // user_assertion. The tool never routes app-context callers here (it
        // uses the application-token method; GetOrderStatusRunTests), but if the
        // broker IS fed such an assertion the rejection must surface, never be
        // swallowed into a wrong success or a silent fixture fallback.
        var rejectingAcquirer = new RejectingTokenAcquirer();
        var handler = new FakeHttpMessageHandler((_, _) =>
            throw new InvalidOperationException("the downstream must never be reached when OBO is rejected"));

        var client = new DownstreamOrdersClient(
            rejectingAcquirer,
            new FakeAppTokenAcquirer(AppDownstreamToken),
            new HttpClient(handler),
            new Uri("https://downstream.example/"),
            DownstreamScope,
            DownstreamApplicationScope);

        await Assert.ThrowsAsync<OboExchangeRejectedException>(
            () => client.GetOrderStatusOnBehalfOfAsync(
                "CONTOSO-1001", InboundAssertion, Caller, CancellationToken.None));
    }

    [Fact]
    public async Task GetOrderStatusAsApplicationAsync_UsesAppTokenAndAuditCorrelation()
    {
        HttpRequestMessage? capturedRequest = null;
        var appTokenAcquirer = new FakeAppTokenAcquirer(AppDownstreamToken);
        var handler = new FakeHttpMessageHandler((request, _) =>
        {
            capturedRequest = request;
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
        var client = new DownstreamOrdersClient(
            new FakeTokenAcquirer(DownstreamToken),
            appTokenAcquirer,
            new HttpClient(handler),
            new Uri("https://downstream.example/"),
            DownstreamScope,
            DownstreamApplicationScope);

        await client.GetOrderStatusAsApplicationAsync(
            "CONTOSO-1001", Caller, CancellationToken.None);

        Assert.Equal(DownstreamApplicationScope, appTokenAcquirer.LastDownstreamScope);
        Assert.Equal(AppDownstreamToken, capturedRequest?.Headers.Authorization?.Parameter);
        Assert.Equal(
            Caller.ApplicationId,
            capturedRequest!.Headers.GetValues(CallerIdentityCorrelation.ApplicationIdHeader).Single());
        Assert.Equal(
            Caller.ObjectId,
            capturedRequest.Headers.GetValues(CallerIdentityCorrelation.ObjectIdHeader).Single());
    }

    private static DownstreamOrdersClient CreateClient(FakeHttpMessageHandler handler) =>
        new(
            new FakeTokenAcquirer(DownstreamToken),
            new FakeAppTokenAcquirer(AppDownstreamToken),
            new HttpClient(handler),
            new Uri("https://downstream.example/"),
            DownstreamScope,
            DownstreamApplicationScope);

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

    private sealed class FakeAppTokenAcquirer(string tokenToReturn) : IAppTokenAcquirer
    {
        public string? LastDownstreamScope { get; private set; }

        public Task<string> AcquireDownstreamTokenForAppAsync(
            string downstreamScope, CancellationToken cancellationToken)
        {
            LastDownstreamScope = downstreamScope;
            return Task.FromResult(tokenToReturn);
        }
    }

    private sealed class OboExchangeRejectedException(string message) : Exception(message);

    private sealed class RejectingTokenAcquirer : IOboTokenAcquirer
    {
        public Task<string> AcquireDownstreamTokenAsync(
            string userAssertion, string downstreamScope, CancellationToken cancellationToken) =>
            throw new OboExchangeRejectedException(
                "Entra rejects this assertion for OBO (e.g. an app-only client-credentials token, "
                + "which is not a valid user_assertion).");
    }

    private sealed class FakeHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request, cancellationToken));
    }
}
