using McpTools.Downstream;
using McpTools.Tools;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for get_order_status (spec: Testing Decisions,
/// "unit seam"). Covers two independently testable pieces: header extraction
/// (plain dictionaries, no Functions/MCP-extension dependency) and the tool
/// contract (name/description). Run's own orchestration (TryGetHttpTransport
/// -> IDownstreamOrdersClient) is exercised in
/// GetOrderStatusRunTests.cs, against a real ToolInvocationContext/HttpTransport
/// (both are publicly constructible outside the Functions host) and a fake
/// IDownstreamOrdersClient.
/// </summary>
public class GetOrderStatusTests
{
    [Fact]
    public void ToolDescription_StatesTheDataIsSynthetic()
    {
        Assert.Equal("get_order_status", GetOrderStatus.ToolName);
        Assert.Contains(
            "synthetic",
            GetOrderStatus.ToolDescription,
            StringComparison.OrdinalIgnoreCase);
    }

    // The app-context branch (roles claim, no scp) is served from the in-memory
    // fixture, unchanged from the tracer's frozen contract. These pin that the
    // fixture path still returns the exact typed success/not-found shapes.
    [Fact]
    public void ServeFromFixture_KnownId_ReturnsTypedSuccessShape()
    {
        var result = GetOrderStatus.ServeFromFixture("CONTOSO-1001");

        var status = Assert.IsType<OrderStatus>(result);
        Assert.Equal("CONTOSO-1001", status.OrderId);
        Assert.Equal("Delivered", status.Status);
        Assert.Equal("2026-06-01T14:05:00Z", status.UpdatedUtc);
    }

    [Fact]
    public void ServeFromFixture_UnknownId_ReturnsTypedNotFoundShape()
    {
        var result = GetOrderStatus.ServeFromFixture("CONTOSO-9999");

        var notFound = Assert.IsType<OrderNotFound>(result);
        Assert.Equal("CONTOSO-9999", notFound.OrderId);
        Assert.False(notFound.Found);
        Assert.Contains("synthetic", notFound.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TryExtractInboundAccessToken_PrefersTheTokenStoreHeader()
    {
        var headers = new Dictionary<string, string>
        {
            ["X-MS-TOKEN-AAD-ACCESS-TOKEN"] = "token-store-token",
            ["Authorization"] = "Bearer raw-bearer-token",
        };

        var found = GetOrderStatus.TryExtractInboundAccessToken(headers, out var token);

        Assert.True(found);
        Assert.Equal("token-store-token", token);
    }

    [Fact]
    public void TryExtractInboundAccessToken_FallsBackToAuthorizationHeader_AndStripsBearerScheme()
    {
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = "Bearer raw-bearer-token",
        };

        var found = GetOrderStatus.TryExtractInboundAccessToken(headers, out var token);

        Assert.True(found);
        Assert.Equal("raw-bearer-token", token);
    }

    [Fact]
    public void TryExtractInboundAccessToken_AuthorizationHeaderWithoutBearerScheme_ReturnsAsIs()
    {
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = "raw-token-no-scheme",
        };

        var found = GetOrderStatus.TryExtractInboundAccessToken(headers, out var token);

        Assert.True(found);
        Assert.Equal("raw-token-no-scheme", token);
    }

    [Theory]
    [MemberData(nameof(EmptyOrMissingHeaderSets))]
    public void TryExtractInboundAccessToken_NoUsableHeader_ReturnsFalse(Dictionary<string, string> headers)
    {
        var found = GetOrderStatus.TryExtractInboundAccessToken(headers, out var token);

        Assert.False(found);
        Assert.Null(token);
    }

    public static TheoryData<Dictionary<string, string>> EmptyOrMissingHeaderSets => new()
    {
        new Dictionary<string, string>(),
        new Dictionary<string, string> { ["Authorization"] = "" },
        new Dictionary<string, string> { ["Some-Other-Header"] = "value" },
    };
}
