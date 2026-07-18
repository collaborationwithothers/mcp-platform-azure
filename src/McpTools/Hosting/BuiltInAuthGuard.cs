namespace McpTools.Hosting;

/// <summary>
/// Startup fail-closed check (issue 10): in a production-like environment the
/// MCP server refuses to start unless a built-in-auth (Easy Auth) signal is
/// present in its process environment. This is what makes the per-request
/// X-MS-CLIENT-PRINCIPAL trust chain sound: the code does NOT validate the
/// inbound token's signature itself (Easy Auth does), so it must at least
/// assert Easy Auth is actually enabled before serving any tool -- otherwise a
/// client could supply its own X-MS-CLIENT-PRINCIPAL header and forge an
/// identity mode (docs/security.md, "trust chain").
///
/// Signal choice (verifier 2026-07-18; see COMPATIBILITY.md notes and
/// docs/security.md): the ticket names WEBSITE_AUTH_ENABLED. Microsoft Learn
/// documents it as "injected ... to indicate whether App Service
/// authentication is enabled," but does not state its value form or confirm
/// its presence under auth_settings_v2 on Flex Consumption specifically. The
/// documented v2-specific signal is WEBSITE_AUTH_V2_CONFIG_JSON
/// ("automatically populated ... corresponds to the V2 (non-classic)
/// authentication configuration"). This guard accepts EITHER, so it holds
/// whichever the platform actually injects; the live gate confirms which is
/// present. Pure and host-independent so it is unit-testable (values are
/// passed in, not read from the ambient environment here).
/// </summary>
public static class BuiltInAuthGuard
{
    /// <summary>The env var the ticket names; primary signal.</summary>
    public const string WebsiteAuthEnabledVar = "WEBSITE_AUTH_ENABLED";

    /// <summary>The documented v2-specific signal; fallback when the above is absent.</summary>
    public const string AuthV2ConfigJsonVar = "WEBSITE_AUTH_V2_CONFIG_JSON";

    /// <summary>
    /// The isolated-worker environment name (AZURE_FUNCTIONS_ENVIRONMENT).
    /// Every environment except local <c>Development</c> is treated as
    /// production-like and enforced; an unset value (Azure's production
    /// default) enforces too. Throws <see cref="InvalidOperationException"/>
    /// with a clear message when enforcement applies and no signal is present.
    /// </summary>
    public static void EnsureBuiltInAuthEnabled(
        string? environmentName, string? websiteAuthEnabled, string? authV2ConfigJson)
    {
        var isLocalDevelopment = string.Equals(environmentName, "Development", StringComparison.OrdinalIgnoreCase);
        if (isLocalDevelopment)
        {
            return;
        }

        if (IsTruthy(websiteAuthEnabled) || !string.IsNullOrWhiteSpace(authV2ConfigJson))
        {
            return;
        }

        throw new InvalidOperationException(
            "FATAL: built-in authentication (Easy Auth) does not appear to be enabled on this host "
            + $"(neither {WebsiteAuthEnabledVar} nor {AuthV2ConfigJsonVar} is present), and the "
            + $"environment is not local Development (AZURE_FUNCTIONS_ENVIRONMENT='{environmentName ?? "<unset>"}'). "
            + "Refusing to start: get_order_status trusts the Easy-Auth-injected X-MS-CLIENT-PRINCIPAL "
            + "header for its identity-mode and authorization decisions and does NOT re-validate the "
            + "token signature itself, so serving tools without Easy Auth would let a caller forge that "
            + "header. Enable built-in auth (auth_settings_v2) on the Function App and redeploy.");
    }

    // WEBSITE_AUTH_ENABLED's value form is not documented; accept the common
    // truthy encodings rather than assume one.
    private static bool IsTruthy(string? value) =>
        string.Equals(value, "true", StringComparison.OrdinalIgnoreCase)
        || string.Equals(value, "1", StringComparison.Ordinal);
}
