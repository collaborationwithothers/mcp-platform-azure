using System.Text;
using System.Text.Json;
using McpTools.Downstream;
using McpTools.Identity;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process tests of GetOrderStatus.Run's orchestration: delegated callers
/// use OBO, authorized app-only callers use the trusted-subsystem application
/// path, and unauthorized callers fail before any downstream request.
/// </summary>
public class GetOrderStatusRunTests
{
    private static readonly OrderStatus SampleDownstreamStatus =
        new("CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z");

    [Fact]
    public async Task Run_Delegated_TokenOnAuthorizationHeader_PassesItToTheDownstreamClient()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);
        var context = ContextWithHeaders(Delegated(("Authorization", "Bearer inbound-token")));

        var result = await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("CONTOSO-1001", fakeClient.LastOrderId);
        Assert.Equal("inbound-token", fakeClient.LastInboundUserAssertion);
        Assert.Equal(DownstreamAccessMode.OnBehalfOf, fakeClient.LastAccessMode);
        Assert.Equal("interactive-client-app-id", fakeClient.LastCaller?.ApplicationId);
        Assert.Equal("user-object-id", fakeClient.LastCaller?.ObjectId);
        Assert.IsType<OrderStatus>(result);
    }

    [Fact]
    public async Task Run_Delegated_TokenOnTokenStoreHeader_PrefersItOverAuthorization()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);
        var context = ContextWithHeaders(Delegated(
            ("X-MS-TOKEN-AAD-ACCESS-TOKEN", "token-store-token"),
            ("Authorization", "Bearer raw-bearer-token")));

        await tool.Run(context, "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("token-store-token", fakeClient.LastInboundUserAssertion);
    }

    [Fact]
    public async Task Run_Delegated_LowercaseHeaderKeys_StillReachesDownstream()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);

        var payload = new
        {
            auth_typ = "aad",
            claims = new[]
            {
                new { typ = "scp", val = "user_impersonation" },
                new { typ = "azp", val = "interactive-client-app-id" },
                new { typ = "oid", val = "user-object-id" },
            },
        };
        var principal = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
        var headers = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["x-ms-client-principal"] = principal,
            ["authorization"] = "Bearer inbound-token",
        };

        var result = await tool.Run(
            ContextWithHeaders(headers), "CONTOSO-1001", CancellationToken.None);

        Assert.Equal("inbound-token", fakeClient.LastInboundUserAssertion);
        Assert.IsType<OrderStatus>(result);
    }

    [Fact]
    public async Task Run_Delegated_NoInboundToken_Throws()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(ContextWithHeaders(Delegated()), "CONTOSO-1001", CancellationToken.None));
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_AppContext_WithOrdersRead_CallsDownstreamAsApplication()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);

        var result = await tool.Run(
            ContextWithHeaders(AppContext()), "CONTOSO-1002", CancellationToken.None);

        Assert.IsType<OrderStatus>(result);
        Assert.Equal("CONTOSO-1002", fakeClient.LastOrderId);
        Assert.Equal(DownstreamAccessMode.Application, fakeClient.LastAccessMode);
        Assert.Equal("test-client-app-id", fakeClient.LastCaller?.ApplicationId);
        Assert.Equal("test-client-object-id", fakeClient.LastCaller?.ObjectId);
        Assert.Null(fakeClient.LastInboundUserAssertion);
    }

    [Fact]
    public async Task Run_AppContext_WithoutOrdersRead_ThrowsDeterministic403_AndNeverCallsDownstream()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);

        var error = await Assert.ThrowsAsync<McpAuthorizationException>(() => tool.Run(
            ContextWithHeaders(AppContext("Orders.Write")),
            "CONTOSO-1001",
            CancellationToken.None));

        Assert.Equal(403, error.StatusCode);
        Assert.Equal(
            "403 Forbidden: get_order_status requires the application role 'Orders.Read'.",
            error.Message);
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_AppContext_MissingAuditIdentity_FailsClosed()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);
        var headers = PrincipalHeaders(("roles", "Orders.Read"));

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => tool.Run(
            ContextWithHeaders(headers), "CONTOSO-1001", CancellationToken.None));

        Assert.Contains("azp/appid and oid", error.Message, StringComparison.Ordinal);
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_MissingPrincipal_Throws_AndNeverCallsDownstream()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);
        var context = ContextWithHeaders(
            new Dictionary<string, string> { ["Authorization"] = "Bearer x" });

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
        Assert.Null(fakeClient.LastOrderId);
    }

    [Fact]
    public async Task Run_NonHttpTransport_Throws()
    {
        var fakeClient = new FakeDownstreamOrdersClient(SampleDownstreamStatus);
        var tool = CreateTool(fakeClient);
        var context = new ToolInvocationContext { Name = GetOrderStatus.ToolName, Transport = null };

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => tool.Run(context, "CONTOSO-1001", CancellationToken.None));
    }

    private static Dictionary<string, string> Delegated(
        params (string Key, string Value)[] extraHeaders) =>
        WithPrincipal(
            [("scp", "user_impersonation"), ("azp", "interactive-client-app-id"), ("oid", "user-object-id")],
            extraHeaders);

    private static Dictionary<string, string> AppContext(string role = "Orders.Read") =>
        PrincipalHeaders(
            ("roles", role),
            ("azp", "test-client-app-id"),
            ("oid", "test-client-object-id"));

    private static Dictionary<string, string> PrincipalHeaders(
        params (string Typ, string Val)[] claims) =>
        WithPrincipal(claims, []);

    private static Dictionary<string, string> WithPrincipal(
        (string Typ, string Val)[] claims,
        (string Key, string Value)[] extraHeaders)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(claim => new { typ = claim.Typ, val = claim.Val }).ToArray(),
        };
        var header = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
        var headers = new Dictionary<string, string> { [ClientPrincipal.HeaderName] = header };
        foreach (var (key, value) in extraHeaders)
        {
            headers[key] = value;
        }

        return headers;
    }

    private static ToolInvocationContext ContextWithHeaders(
        Dictionary<string, string> headers) =>
        new()
        {
            Name = GetOrderStatus.ToolName,
            Transport = new HttpTransport("http") { Headers = headers },
        };

    private static GetOrderStatus CreateTool(IDownstreamOrdersClient downstreamOrdersClient) =>
        new(downstreamOrdersClient, NullLogger<GetOrderStatus>.Instance);

    private sealed class FakeDownstreamOrdersClient(object resultToReturn) : IDownstreamOrdersClient
    {
        public string? LastOrderId { get; private set; }
        public string? LastInboundUserAssertion { get; private set; }
        public DownstreamAccessMode? LastAccessMode { get; private set; }
        public CallerIdentityCorrelation? LastCaller { get; private set; }

        public Task<object> GetOrderStatusOnBehalfOfAsync(
            string orderId,
            string inboundUserAssertion,
            CallerIdentityCorrelation caller,
            CancellationToken cancellationToken)
        {
            LastOrderId = orderId;
            LastInboundUserAssertion = inboundUserAssertion;
            LastAccessMode = DownstreamAccessMode.OnBehalfOf;
            LastCaller = caller;
            return Task.FromResult(resultToReturn);
        }

        public Task<object> GetOrderStatusAsApplicationAsync(
            string orderId,
            CallerIdentityCorrelation caller,
            CancellationToken cancellationToken)
        {
            LastOrderId = orderId;
            LastAccessMode = DownstreamAccessMode.Application;
            LastCaller = caller;
            return Task.FromResult(resultToReturn);
        }
    }
}
