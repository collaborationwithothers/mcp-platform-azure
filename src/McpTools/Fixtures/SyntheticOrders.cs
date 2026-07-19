namespace McpTools.Fixtures;

/// <summary>
/// The fixed, in-memory order fixture the app-context branch of get_order_status
/// serves from (issue 10: delegated callers are sourced from the downstream via
/// OBO, app-context callers from this fixture as a documented interim until the
/// workload-identity hardening issue; see src/README.md and
/// McpTools.Tools.GetOrderStatus).
///
/// The data is SYNTHETIC demo data. It is not derived from any real system.
/// Ids run CONTOSO-1001 to CONTOSO-1005; every other id is a deterministic
/// not-found.
///
/// Timestamps are hard-coded ISO 8601 UTC strings so the tool result is
/// reproducible: unit tests assert exact values and must not depend on the
/// wall clock. These values are kept in step with the downstream Orders API's
/// own fixture (src/DownstreamOrdersApi/Fixtures/SyntheticOrders.cs) so the two
/// data sources present the same synthetic orders.
/// </summary>
public static class SyntheticOrders
{
    /// <summary>
    /// Order id to (status, last-updated) pairs. Lookup is case-sensitive: an
    /// order id is an exact token, and any id not present here is a not-found.
    /// </summary>
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
