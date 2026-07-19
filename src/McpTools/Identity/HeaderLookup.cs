namespace McpTools.Identity;

/// <summary>
/// Case-insensitive header lookup shared by the identity-mode resolver and the
/// inbound-token extractor. HTTP header names are case-insensitive, HTTP/2
/// lowercases them on the wire, and the MCP extension's transport Headers
/// dictionary comparer is not guaranteed to be case-insensitive -- so both the
/// principal lookup and the token lookup must tolerate any casing, or the
/// delegated OBO path can silently break on a lowercase-keyed dictionary.
/// </summary>
internal static class HeaderLookup
{
    public static bool TryGet(IReadOnlyDictionary<string, string> headers, string name, out string? value)
    {
        if (headers.TryGetValue(name, out value))
        {
            return true;
        }

        foreach (var pair in headers)
        {
            if (string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                value = pair.Value;
                return true;
            }
        }

        value = null;
        return false;
    }
}
