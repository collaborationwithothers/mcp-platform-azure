using Xunit;

namespace McpTools.Tests;

/// <summary>
/// Drift guard for the two DELIBERATELY duplicated synthetic order fixtures:
/// the MCP server's app-context fixture (McpTools.Fixtures.SyntheticOrders) and
/// the downstream Orders API's own fixture (DownstreamOrdersApi.Fixtures.
/// SyntheticOrders). They are kept separate in production on purpose (each
/// service owns its own data; no shared project reference -- see both
/// SyntheticOrders files), which means nothing but discipline keeps them in
/// step. That is a shotgun-surgery risk if the frozen get_order_status contract
/// data ever changes on one side only (issue-10 governance finding). This test
/// fails if they diverge, forcing any future data edit to touch both.
/// </summary>
public class FixtureParityTests
{
    [Fact]
    public void McpAndDownstreamFixtures_HaveIdenticalIdsAndValues()
    {
        var mcp = McpTools.Fixtures.SyntheticOrders.All;
        var downstream = DownstreamOrdersApi.Fixtures.SyntheticOrders.All;

        Assert.Equal(
            mcp.Keys.OrderBy(id => id, StringComparer.Ordinal),
            downstream.Keys.OrderBy(id => id, StringComparer.Ordinal));

        foreach (var (id, order) in mcp)
        {
            Assert.True(downstream.TryGetValue(id, out var downstreamOrder), $"downstream fixture is missing id '{id}'.");
            // ValueTuple structural equality compares Status and UpdatedUtc.
            Assert.Equal(order, downstreamOrder);
        }
    }
}
