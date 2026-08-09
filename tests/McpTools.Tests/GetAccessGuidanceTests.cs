using System.Text;
using System.Text.Json;
using McpTools.Identity;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process tests of GetAccessGuidance.Run. Two properties matter here and
/// they pull in opposite directions, so both are pinned.
///
/// First, this tool admits callers the other two refuse. It performs no
/// per-tool role check, so an Orders.Read holder, a ServiceInfo.Read holder, a
/// caller with no roles claim at all, and a delegated caller all receive the
/// same guidance. That is the point of the tool and the reason issue 82 exists:
/// the gateway's unrestricted branch needs a tool behind it that genuinely
/// admits an under-entitled caller.
///
/// Second, unrestricted does NOT mean unauthenticated. A caller whose principal
/// is missing or undecodable is still rejected, by the same fail-closed throw
/// GetOrderStatus and GetServiceInfo use. A test that only proved the first
/// property would leave the second free to regress silently.
/// </summary>
public class GetAccessGuidanceTests
{
    [Fact]
    public void Run_AppContext_WithNoRolesAtAll_ReturnsTheGuidance()
    {
        // The caller check (h) drives in the live gate: the section-3 client
        // holds Orders.Invoke.All at the gateway and no backend role whatsoever.
        var tool = CreateTool();

        var result = tool.Run(ContextWithHeaders(AppContextWithoutRoles()));

        var guidance = Assert.IsType<AccessGuidance>(result);
        Assert.Equal(GetAccessGuidance.SummaryValue, guidance.Summary);
        Assert.Equal("https://github.com/collaborationwithothers/mcp-platform-azure", guidance.DocsUrl);
        Assert.Equal(GetAccessGuidance.DataDisclaimerValue, guidance.DataDisclaimer);
    }

    [Theory]
    [InlineData("Orders.Read")]
    [InlineData("ServiceInfo.Read")]
    [InlineData("Orders.Invoke.All")]
    [InlineData("Some.Unrelated.Role")]
    public void Run_AppContext_WithAnyRole_ReturnsTheSameGuidance(string role)
    {
        var tool = CreateTool();

        var first = Assert.IsType<AccessGuidance>(
            tool.Run(ContextWithHeaders(AppContext(role))));
        var second = Assert.IsType<AccessGuidance>(
            tool.Run(ContextWithHeaders(AppContextWithoutRoles())));

        // Which role a caller holds must make no difference here. If this ever
        // fails, a per-tool entitlement check has been added to a tool whose
        // whole purpose is not having one.
        Assert.Equal(first.Summary, second.Summary);
        Assert.Equal(first.RequiredEntitlements, second.RequiredEntitlements);
    }

    [Fact]
    public void Run_Delegated_ReturnsTheGuidance()
    {
        // Unlike get_service_info, a delegated caller is NOT refused here.
        // get_service_info routes both identity modes into one role check;
        // this tool has no role check to route into.
        var tool = CreateTool();

        var result = tool.Run(ContextWithHeaders(Delegated()));

        Assert.IsType<AccessGuidance>(result);
    }

    [Fact]
    public void Run_MissingPrincipal_Throws()
    {
        // Unrestricted relaxes the per-tool entitlement check and nothing else.
        // A caller who did not traverse the authenticated path is still refused.
        var tool = CreateTool();
        var context = ContextWithHeaders(
            new Dictionary<string, string> { ["Authorization"] = "Bearer x" });

        Assert.Throws<InvalidOperationException>(() => tool.Run(context));
    }

    [Fact]
    public void Run_MalformedPrincipal_Throws()
    {
        var tool = CreateTool();
        var context = ContextWithHeaders(
            new Dictionary<string, string> { [ClientPrincipal.HeaderName] = "not-base64-json" });

        Assert.Throws<InvalidOperationException>(() => tool.Run(context));
    }

    [Fact]
    public void Run_NonHttpTransport_Throws()
    {
        var tool = CreateTool();
        var context = new ToolInvocationContext { Name = GetAccessGuidance.ToolName, Transport = null };

        Assert.Throws<InvalidOperationException>(() => tool.Run(context));
    }

    [Fact]
    public void Run_CalledTwice_ReturnsIdenticalFieldValues()
    {
        var tool = CreateTool();

        var first = Assert.IsType<AccessGuidance>(
            tool.Run(ContextWithHeaders(AppContextWithoutRoles())));
        var second = Assert.IsType<AccessGuidance>(
            tool.Run(ContextWithHeaders(AppContextWithoutRoles())));

        Assert.Equal(first.Summary, second.Summary);
        Assert.Equal(first.DocsUrl, second.DocsUrl);
        Assert.Equal(first.DataDisclaimer, second.DataDisclaimer);
        Assert.Equal(first.RequiredEntitlements, second.RequiredEntitlements);
    }

    [Fact]
    public void RequiredEntitlements_RoleIsSetIfAndOnlyIfMechanismIsApplicationRole()
    {
        // The invariant that replaces "exactly one of role/unrestricted is set":
        // a null RequiredRole is never a gap, because Mechanism always says
        // which classification produced it. This mirrors the Terraform-side
        // validation at infra/terraform/modules/apim-mcp-server/variables.tf:151.
        foreach (var entry in GetAccessGuidance.RequiredEntitlementsValue)
        {
            if (entry.Mechanism == GetAccessGuidance.MechanismApplicationRole)
            {
                Assert.False(
                    string.IsNullOrEmpty(entry.RequiredRole),
                    $"'{entry.Tool}' ({entry.AppliesTo}) claims mechanism applicationRole but names no role.");
            }
            else
            {
                Assert.True(
                    entry.RequiredRole is null,
                    $"'{entry.Tool}' ({entry.AppliesTo}) names role '{entry.RequiredRole}' under mechanism '{entry.Mechanism}'.");
            }
        }
    }

    [Fact]
    public void RequiredEntitlements_UseOnlyTheDeclaredMechanismAndModeVocabulary()
    {
        var mechanisms = new[]
        {
            GetAccessGuidance.MechanismApplicationRole,
            GetAccessGuidance.MechanismDownstreamAssignmentRequired,
            GetAccessGuidance.MechanismUnrestricted,
        };
        var modes = new[]
        {
            GetAccessGuidance.AppliesToApplication,
            GetAccessGuidance.AppliesToDelegated,
        };

        foreach (var entry in GetAccessGuidance.RequiredEntitlementsValue)
        {
            Assert.Contains(entry.Mechanism, mechanisms);
            Assert.Contains(entry.AppliesTo, modes);
        }
    }

    [Fact]
    public void RequiredEntitlements_NameTheRolesTheOtherToolsActuallyCheck()
    {
        // Sourced from AppRoleAuthorization, the backend's own single source of
        // truth for these values, so a role rename cannot leave this list
        // stating a role no code checks.
        var ordersRow = Assert.Single(
            GetAccessGuidance.RequiredEntitlementsValue,
            e => e.Tool == GetOrderStatus.ToolName
                && e.AppliesTo == GetAccessGuidance.AppliesToApplication);
        Assert.Equal(AppRoleAuthorization.RequiredRole, ordersRow.RequiredRole);

        var serviceRows = GetAccessGuidance.RequiredEntitlementsValue.Where(
            e => e.Tool == GetServiceInfo.ToolName).ToList();
        Assert.Equal(2, serviceRows.Count);
        Assert.All(serviceRows, row => Assert.Equal(AppRoleAuthorization.ServiceInfoRole, row.RequiredRole));
    }

    [Fact]
    public void ToolName_And_Description_MatchTheFrozenContract()
    {
        Assert.Equal("get_access_guidance", GetAccessGuidance.ToolName);
        Assert.Contains("no per-tool entitlement", GetAccessGuidance.ToolDescription, StringComparison.Ordinal);
        Assert.Contains("SYNTHETIC", GetAccessGuidance.DataDisclaimerValue, StringComparison.Ordinal);
    }

    private static Dictionary<string, string> Delegated() =>
        WithPrincipal(("scp", "user_impersonation"), ("azp", "interactive-client-app-id"), ("oid", "user-object-id"));

    private static Dictionary<string, string> AppContext(string role) =>
        WithPrincipal(("roles", role), ("azp", "test-client-app-id"), ("oid", "test-client-object-id"));

    // A valid application identity carrying no roles claim at all: the floor
    // case, weaker than any real caller this deployment produces. It is NOT the
    // section-3 client's shape. That client is granted Orders.Invoke.All as an
    // application permission on the same server resource app that exposes
    // Orders.Read (entra-app-registrations.md section 3, step 3), and
    // mcp-server.xml forwards the caller's Authorization header to the backend
    // unchanged, so its Easy Auth principal does carry roles: Orders.Invoke.All.
    // That shape is covered by the Orders.Invoke.All case on
    // Run_AppContext_WithAnyRole_ReturnsTheSameGuidance; this helper covers the
    // no-roles principal underneath it.
    private static Dictionary<string, string> AppContextWithoutRoles() =>
        WithPrincipal(("azp", "under-entitled-client-app-id"), ("oid", "under-entitled-client-object-id"));

    private static Dictionary<string, string> WithPrincipal(
        params (string Typ, string Val)[] claims)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(claim => new { typ = claim.Typ, val = claim.Val }).ToArray(),
        };
        var header = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));

        return new Dictionary<string, string> { [ClientPrincipal.HeaderName] = header };
    }

    private static ToolInvocationContext ContextWithHeaders(
        Dictionary<string, string> headers) =>
        new()
        {
            Name = GetAccessGuidance.ToolName,
            Transport = new HttpTransport("http") { Headers = headers },
        };

    private static GetAccessGuidance CreateTool() => new(NullLogger<GetAccessGuidance>.Instance);
}
