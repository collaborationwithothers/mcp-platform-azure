using System.Text;
using System.Text.Json;
using McpTools.Identity;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for <see cref="AppRoleAuthorization"/> (spec: Testing
/// Decisions, "unit seam"). The check is pure claims logic over an already
/// decoded principal, so these tests need no Functions or MCP-extension host.
///
/// Issue 79 generalised the check from one hardcoded role to
/// <see cref="AppRoleAuthorization.HasRole"/>. Two of the assertions below are
/// load-bearing beyond ordinary coverage:
///
/// <list type="bullet">
///   <item>the ordinal case-sensitivity test, because an authorization check
///   that quietly case-folds accepts values nobody configured;</item>
///   <item>the "one role does not grant another" test, which is the property
///   issue 76 exists to prove and the reason a second tool was added at all.</item>
/// </list>
/// </summary>
public class AppRoleAuthorizationTests
{
    [Fact]
    public void RoleConstants_AreTheValuesTheToolsAndTheGatewayMapAgreeOn()
    {
        // Pinned because these strings are a contract with three things outside
        // this file: the Entra app-role definitions, the gateway's
        // tool_authorization_map, and the 403 message text a caller sees.
        Assert.Equal("Orders.Read", AppRoleAuthorization.RequiredRole);
        Assert.Equal("ServiceInfo.Read", AppRoleAuthorization.ServiceInfoRole);
    }

    [Theory]
    [InlineData("roles")]
    [InlineData("http://schemas.microsoft.com/ws/2008/06/identity/claims/role")]
    public void HasRole_RolePresentUnderEitherClaimType_ReturnsTrue(string roleClaimType)
    {
        // Easy Auth may emit the role claim under its short name or under the
        // mapped schema URI. Both must satisfy the check.
        var principal = PrincipalWith((roleClaimType, AppRoleAuthorization.ServiceInfoRole));

        Assert.True(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Fact]
    public void HasRole_ClaimTypeCasingDiffers_StillMatches()
    {
        // A claim TYPE is a well-known identifier, not a granted value, so it is
        // matched case-insensitively (ClientPrincipal.ValuesFor). Contrast the
        // role VALUE, pinned as ordinal below.
        var principal = PrincipalWith(("ROLES", AppRoleAuthorization.ServiceInfoRole));

        Assert.True(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Fact]
    public void HasRole_RoleAbsent_ReturnsFalse()
    {
        var principal = PrincipalWith(("roles", "Orders.Write"));

        Assert.False(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Fact]
    public void HasRole_NoRoleClaimAtAll_ReturnsFalse()
    {
        var principal = PrincipalWith(("azp", "role-less-client-app-id"), ("oid", "role-less-object-id"));

        Assert.False(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Theory]
    [InlineData("serviceinfo.read")]
    [InlineData("SERVICEINFO.READ")]
    [InlineData("ServiceInfo.read")]
    public void HasRole_RoleValueCasingDiffers_ReturnsFalse(string differentlyCasedRole)
    {
        // Ordinal on purpose. Entra issues the role value with the casing set on
        // the app registration; accepting other casings would grant access on a
        // value nobody configured. A silent case-fold here is a real defect class,
        // so it is pinned rather than left to the implementation.
        var principal = PrincipalWith(("roles", differentlyCasedRole));

        Assert.False(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Fact]
    public void HasRole_PrincipalWithSeveralRoles_MatchesOnlyTheNamedOne()
    {
        var principal = PrincipalWith(
            ("roles", "Orders.Read"),
            ("roles", "Reports.Read"));

        Assert.True(AppRoleAuthorization.HasRole(principal, "Reports.Read"));
        Assert.False(AppRoleAuthorization.HasRole(principal, AppRoleAuthorization.ServiceInfoRole));
    }

    [Fact]
    public void HasRole_OneRoleDoesNotGrantAnother()
    {
        // The property issue 76 exists to prove: entitlement for one tool is not
        // entitlement for another on the same server. This is the unit-level
        // statement of it; the live gate proves it end to end (issue 80).
        var ordersOnly = PrincipalWith(("roles", AppRoleAuthorization.RequiredRole));

        Assert.True(AppRoleAuthorization.HasRole(ordersOnly, AppRoleAuthorization.RequiredRole));
        Assert.False(AppRoleAuthorization.HasRole(ordersOnly, AppRoleAuthorization.ServiceInfoRole));
    }

    // The four tests below are the issue-79 regression guard, not new coverage.
    // HasOrdersRead became a shorthand for HasRole; its behaviour must be
    // identical to what get_order_status relied on before the refactor.
    [Theory]
    [InlineData("roles")]
    [InlineData("http://schemas.microsoft.com/ws/2008/06/identity/claims/role")]
    public void HasOrdersRead_OrdersReadPresent_ReturnsTrue(string roleClaimType)
    {
        var principal = PrincipalWith((roleClaimType, "Orders.Read"));

        Assert.True(AppRoleAuthorization.HasOrdersRead(principal));
    }

    [Fact]
    public void HasOrdersRead_DifferentRolePresent_ReturnsFalse()
    {
        var principal = PrincipalWith(("roles", "Orders.Write"));

        Assert.False(AppRoleAuthorization.HasOrdersRead(principal));
    }

    [Fact]
    public void HasOrdersRead_NoRoleClaim_ReturnsFalse()
    {
        var principal = PrincipalWith(("azp", "role-less-client-app-id"));

        Assert.False(AppRoleAuthorization.HasOrdersRead(principal));
    }

    [Fact]
    public void HasOrdersRead_DifferentCasing_ReturnsFalse()
    {
        var principal = PrincipalWith(("roles", "orders.read"));

        Assert.False(AppRoleAuthorization.HasOrdersRead(principal));
    }

    /// <summary>
    /// Builds a decoded principal from claims, the only way in: ClientPrincipal
    /// has no public constructor, so tests go through the real Base64 JSON parse
    /// path rather than a test-only back door.
    /// </summary>
    private static CallerIdentity PrincipalWith(params (string Typ, string Val)[] claims)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(claim => new { typ = claim.Typ, val = claim.Val }).ToArray(),
        };
        var header = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));

        Assert.True(ClientPrincipal.TryParse(header, out var principal));
        return CallerIdentityResolver.Resolve(principal!.ToClaimsPrincipal());
    }
}
