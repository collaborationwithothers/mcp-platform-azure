using McpTools.Core;
using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// Focused tests for the shared application core. These tests pass normalized
/// caller data directly and use no Azure Functions transport types.
/// </summary>
public class McpToolApplicationCoreTests
{
    private static readonly OrderStatus SampleOrder =
        new("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z");

    [Fact]
    public async Task GetOrderStatus_DelegatedCaller_UsesOboAndReturnsTypedResult()
    {
        var orders = new FakeDownstreamOrdersClient(SampleOrder);
        var application = new McpToolApplication(orders);
        var caller = DelegatedCaller("Orders.Read.AsUser");

        var outcome = await application.GetOrderStatusAsync(
            "CONTOSO-1001", caller, "inbound-token", CancellationToken.None);

        var success = Assert.IsType<OrderStatus>(outcome.Value);
        Assert.Equal("CONTOSO-1001", success.OrderId);
        Assert.Null(outcome.Error);
        Assert.Equal("inbound-token", orders.LastInboundUserAssertion);
        Assert.Equal(DownstreamAccessMode.OnBehalfOf, orders.LastAccessMode);
    }

    [Fact]
    public async Task GetOrderStatus_MissingDelegatedScope_ReturnsForbiddenBeforeTokenCheck()
    {
        var orders = new FakeDownstreamOrdersClient(SampleOrder);
        var application = new McpToolApplication(orders);

        var outcome = await application.GetOrderStatusAsync(
            "CONTOSO-1001", DelegatedCaller("user_impersonation"), null, CancellationToken.None);

        Assert.Null(outcome.Value);
        Assert.Equal(
            "403 Forbidden: get_order_status requires the delegated scope 'Orders.Read.AsUser'.",
            outcome.Error?.Message);
        Assert.Null(orders.LastOrderId);
    }

    [Fact]
    public async Task GetOrderStatus_AuthorizedDelegatedCallerWithoutToken_RequestsAHostAssertion()
    {
        var orders = new FakeDownstreamOrdersClient(SampleOrder);
        var application = new McpToolApplication(orders);

        await Assert.ThrowsAsync<InboundAccessTokenRequiredException>(() =>
            application.GetOrderStatusAsync(
                "CONTOSO-1001",
                DelegatedCaller("Orders.Read.AsUser"),
                null,
                CancellationToken.None));

        Assert.Null(orders.LastOrderId);
    }

    [Fact]
    public async Task GetOrderStatus_AppCaller_UsesApplicationIdentityAndReturnsTypedResult()
    {
        var orders = new FakeDownstreamOrdersClient(SampleOrder);
        var application = new McpToolApplication(orders);

        var outcome = await application.GetOrderStatusAsync(
            "CONTOSO-1001", AppCaller("Orders.Read"), null, CancellationToken.None);

        Assert.IsType<OrderStatus>(outcome.Value);
        Assert.Null(outcome.Error);
        Assert.Equal(DownstreamAccessMode.Application, orders.LastAccessMode);
    }

    [Fact]
    public void GetServiceInfo_WrongRole_ReturnsTheExistingForbiddenMessage()
    {
        var application = new McpToolApplication(new FakeDownstreamOrdersClient(SampleOrder));

        var outcome = application.GetServiceInfo(AppCaller("Orders.Read"));

        Assert.Null(outcome.Value);
        Assert.Equal(
            "403 Forbidden: get_service_info requires the application role 'ServiceInfo.Read'.",
            outcome.Error?.Message);
    }

    [Fact]
    public void GetAccessGuidance_UnderEntitledCaller_ReturnsTheTypedGuidance()
    {
        var application = new McpToolApplication(new FakeDownstreamOrdersClient(SampleOrder));
        var caller = new CallerIdentity(
            IdentityMode.AppContext,
            [],
            [],
            new CallerIdentityCorrelation("client-app-id", "client-object-id"));

        var guidance = application.GetAccessGuidance(caller);

        Assert.IsType<AccessGuidance>(guidance);
        Assert.Equal(6, guidance.RequiredEntitlements.Count);
    }

    [Theory]
    [InlineData("CONTOSO-1001", typeof(OrderStatus))]
    [InlineData("CONTOSO-9999", typeof(OrderNotFound))]
    public void GetOrderStatusFromFixture_ReturnsTheFrozenTypedResult(
        string orderId,
        Type expectedType)
    {
        var result = McpToolApplication.GetOrderStatusFromFixture(orderId);

        Assert.IsType(expectedType, result);
    }

    private static CallerIdentity DelegatedCaller(string scopes) =>
        new(
            IdentityMode.Delegated,
            [],
            scopes.Split(' ', StringSplitOptions.RemoveEmptyEntries),
            new CallerIdentityCorrelation("interactive-client-app-id", "user-object-id"));

    private static CallerIdentity AppCaller(params string[] roles) =>
        new(
            IdentityMode.AppContext,
            roles,
            [],
            new CallerIdentityCorrelation("test-client-app-id", "test-client-object-id"));

    private sealed class FakeDownstreamOrdersClient(OrderLookupResult resultToReturn)
        : IDownstreamOrdersClient
    {
        public string? LastOrderId { get; private set; }
        public string? LastInboundUserAssertion { get; private set; }
        public DownstreamAccessMode? LastAccessMode { get; private set; }

        public Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
            string orderId,
            string inboundUserAssertion,
            CallerIdentityCorrelation? caller,
            CancellationToken cancellationToken)
        {
            LastOrderId = orderId;
            LastInboundUserAssertion = inboundUserAssertion;
            LastAccessMode = DownstreamAccessMode.OnBehalfOf;
            return Task.FromResult(resultToReturn);
        }

        public Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
            string orderId,
            CallerIdentityCorrelation caller,
            CancellationToken cancellationToken)
        {
            LastOrderId = orderId;
            LastAccessMode = DownstreamAccessMode.Application;
            return Task.FromResult(resultToReturn);
        }
    }
}
