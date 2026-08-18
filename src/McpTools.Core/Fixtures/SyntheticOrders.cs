namespace McpTools.Fixtures;

/// <summary>
/// Fixed synthetic order data used by the pure contract seam. The live paths
/// use <see cref="McpTools.Downstream.IDownstreamOrdersClient"/>.
/// </summary>
public static class SyntheticOrders
{
    public static readonly IReadOnlyDictionary<string, (string Status, string UpdatedUtc)> All =
        new Dictionary<string, (string Status, string UpdatedUtc)>(StringComparer.Ordinal)
        {
            ["CONTOSO-1001"] = ("Delivered", "2026-06-01T14:05:00Z"),
            ["CONTOSO-1002"] = ("Shipped", "2026-06-03T09:30:00Z"),
            ["CONTOSO-1003"] = ("Processing", "2026-06-05T17:45:00Z"),
            ["CONTOSO-1004"] = ("Cancelled", "2026-06-02T11:15:00Z"),
            ["CONTOSO-1005"] = ("BackOrdered", "2026-06-04T08:20:00Z"),
        };
}
