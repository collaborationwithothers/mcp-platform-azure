using McpTools.Fixtures;
using McpTools.Tools;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for the tool logic. These call GetOrderStatus.Resolve
/// directly: no Azure Functions host, no network, no Azure dependency (spec:
/// Testing Decisions, "unit seam").
/// </summary>
public class GetOrderStatusTests
{
    // The frozen success contract for every fixture id. Hard-coded here (not
    // read from the fixture) so this is a real regression guard on the values.
    public static readonly TheoryData<string, string, string> KnownOrders = new()
    {
        { "CONTOSO-1001", "Delivered", "2026-06-01T14:05:00Z" },
        { "CONTOSO-1002", "Shipped", "2026-06-03T09:30:00Z" },
        { "CONTOSO-1003", "Processing", "2026-06-05T17:45:00Z" },
        { "CONTOSO-1004", "Cancelled", "2026-06-02T11:15:00Z" },
        { "CONTOSO-1005", "BackOrdered", "2026-06-04T08:20:00Z" },
    };

    [Theory]
    [MemberData(nameof(KnownOrders))]
    public void Resolve_KnownId_ReturnsTypedSuccessShape(
        string orderId, string expectedStatus, string expectedUpdatedUtc)
    {
        var result = GetOrderStatus.Resolve(orderId);

        var status = Assert.IsType<OrderStatus>(result);
        Assert.Equal(orderId, status.OrderId);
        Assert.Equal(expectedStatus, status.Status);
        Assert.Equal(expectedUpdatedUtc, status.UpdatedUtc);
    }

    [Theory]
    [InlineData("CONTOSO-9999")]
    [InlineData("UNKNOWN")]
    [InlineData("")]
    [InlineData("contoso-1001")] // case-sensitive: not the canonical id
    public void Resolve_UnknownId_ReturnsTypedNotFoundShape(string orderId)
    {
        var result = GetOrderStatus.Resolve(orderId);

        var notFound = Assert.IsType<OrderNotFound>(result);
        Assert.Equal(orderId, notFound.OrderId);
        Assert.False(notFound.Found);
        Assert.False(string.IsNullOrWhiteSpace(notFound.Message));
    }

    [Fact]
    public void Resolve_UnknownId_IsATypedResultNotAThrownError()
    {
        // The not-found path must be a typed result, never an exception.
        var exception = Record.Exception(() => GetOrderStatus.Resolve("CONTOSO-0000"));
        Assert.Null(exception);
    }

    [Fact]
    public void Fixture_ContainsExactlyTheFiveContosoIds()
    {
        Assert.Equal(5, SyntheticOrders.All.Count);
        for (int n = 1001; n <= 1005; n++)
        {
            Assert.True(SyntheticOrders.All.ContainsKey($"CONTOSO-{n}"));
        }
    }

    [Fact]
    public void ToolDescription_StatesTheDataIsSynthetic()
    {
        Assert.Equal("get_order_status", GetOrderStatus.ToolName);
        Assert.Contains(
            "synthetic",
            GetOrderStatus.ToolDescription,
            StringComparison.OrdinalIgnoreCase);
    }
}
