namespace McpTools.AspNetCore;

internal static class McpHostContract
{
    internal const string Resource =
        "https://mcp.internal.consultwithcloud.com/mcp";

    internal const string ResourceMetadataUri =
        "https://mcp.internal.consultwithcloud.com/"
        + ".well-known/oauth-protected-resource/mcp";

    internal const string ServerEntryPolicy = "McpServerEntry";

    internal static readonly string[] DelegatedServerScopes =
        ["Orders.Invoke", "Catalog.Invoke"];

    internal static readonly string[] ApplicationServerRoles =
        ["Orders.Invoke.All", "Catalog.Invoke.All"];
}
