using McpTools.Hosting;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for <see cref="BuiltInAuthGuard"/> (spec: Testing
/// Decisions, "unit seam"). The startup fail-closed check: in a production-like
/// environment the server must refuse to start unless a built-in-auth (Easy
/// Auth) signal is present, so no tool is ever served on a host where Easy Auth
/// is off and the X-MS-* trust chain does not hold (docs/security.md).
/// </summary>
public class BuiltInAuthGuardTests
{
    [Theory]
    [InlineData("true")]
    [InlineData("True")]
    [InlineData("1")]
    public void EnsureEnabled_Production_WebsiteAuthEnabledTruthy_DoesNotThrow(string websiteAuthEnabled)
    {
        BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Production", websiteAuthEnabled, authV2ConfigJson: null);
    }

    [Fact]
    public void EnsureEnabled_Production_V2ConfigPresent_DoesNotThrow()
    {
        // The documented v2-specific signal: WEBSITE_AUTH_V2_CONFIG_JSON is
        // platform-populated whenever auth_settings_v2 is configured.
        BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Production", websiteAuthEnabled: null, authV2ConfigJson: "{\"platform\":{}}");
    }

    [Fact]
    public void EnsureEnabled_Production_NoSignal_Throws()
    {
        Assert.Throws<InvalidOperationException>(
            () => BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Production", websiteAuthEnabled: null, authV2ConfigJson: null));
    }

    [Fact]
    public void EnsureEnabled_Production_WebsiteAuthEnabledFalse_Throws()
    {
        Assert.Throws<InvalidOperationException>(
            () => BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Production", websiteAuthEnabled: "false", authV2ConfigJson: null));
    }

    [Fact]
    public void EnsureEnabled_UnsetEnvironment_DefaultsToProductionAndThrows()
    {
        // Azure leaves AZURE_FUNCTIONS_ENVIRONMENT unset in production; an unset
        // environment must be treated as production-like (fail-closed), not as
        // a dev exemption.
        Assert.Throws<InvalidOperationException>(
            () => BuiltInAuthGuard.EnsureBuiltInAuthEnabled(environmentName: null, websiteAuthEnabled: null, authV2ConfigJson: null));
    }

    [Fact]
    public void EnsureEnabled_Staging_NoSignal_Throws()
    {
        // Staging is a live slot, not local dev: it is production-like.
        Assert.Throws<InvalidOperationException>(
            () => BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Staging", websiteAuthEnabled: null, authV2ConfigJson: null));
    }

    [Fact]
    public void EnsureEnabled_Development_NoSignal_DoesNotThrow()
    {
        // Local Development is the ONLY exemption: Easy Auth is not present when
        // running the host locally, so the gate is skipped there.
        BuiltInAuthGuard.EnsureBuiltInAuthEnabled("Development", websiteAuthEnabled: null, authV2ConfigJson: null);
    }
}
