using System.Net;
using DownstreamOrdersApi.Functions;
using Xunit;

namespace DownstreamOrdersApi.Tests;

/// <summary>
/// In-process unit tests for the downstream API's lookup logic. These call
/// OrderStatusEndpoint.Resolve directly: no Azure Functions host, no
/// network, no Azure dependency (spec: Testing Decisions, "unit seam").
/// </summary>
public class OrderStatusEndpointTests
{
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
    public void Resolve_KnownId_Returns200WithTypedBody(
        string orderId, string expectedStatus, string expectedUpdatedUtc)
    {
        var (statusCode, body) = OrderStatusEndpoint.Resolve(orderId);

        Assert.Equal(HttpStatusCode.OK, statusCode);
        var response = Assert.IsType<OrderStatusResponse>(body);
        Assert.Equal(orderId, response.OrderId);
        Assert.Equal(expectedStatus, response.Status);
        Assert.Equal(expectedUpdatedUtc, response.UpdatedUtc);
    }

    [Theory]
    [InlineData("CONTOSO-9999")]
    [InlineData("UNKNOWN")]
    [InlineData("contoso-1001")] // case-sensitive: not the canonical id
    public void Resolve_UnknownId_Returns404WithTypedBody(string orderId)
    {
        var (statusCode, body) = OrderStatusEndpoint.Resolve(orderId);

        Assert.Equal(HttpStatusCode.NotFound, statusCode);
        var response = Assert.IsType<OrderNotFoundResponse>(body);
        Assert.Equal(orderId, response.OrderId);
        Assert.False(string.IsNullOrWhiteSpace(response.Message));
    }

    [Fact]
    public void Fixture_ContainsExactlyTheFiveContosoIds()
    {
        Assert.Equal(5, Fixtures.SyntheticOrders.All.Count);
        for (int n = 1001; n <= 1005; n++)
        {
            Assert.True(Fixtures.SyntheticOrders.All.ContainsKey($"CONTOSO-{n}"));
        }
    }
}
