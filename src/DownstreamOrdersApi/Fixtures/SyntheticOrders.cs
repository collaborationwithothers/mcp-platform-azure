namespace DownstreamOrdersApi.Fixtures;

/// <summary>
/// The fixed, in-memory order fixture the downstream API serves from.
///
/// Deliberately NOT shared with McpTools.Fixtures.SyntheticOrders via a
/// project reference: in the real system this would be a separate service
/// with its own data store, and the tracer's "server calls nothing
/// downstream, no shared internals" boundary (docs/specs/v1-tracer-bullet.md)
/// extends naturally to "the downstream owns its own fixture." The values
/// are kept identical to McpTools' fixture so the OBO round trip is
/// observably a no-op on the data shape (same ids, same statuses), proving
/// get_order_status's contract is unchanged even though the source moved.
///
/// The data is SYNTHETIC demo data, not derived from any real system.
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
