using System.Text;
using System.Text.Json;
using McpTools.Identity;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for <see cref="DelegatedScopeAuthorization"/>. The
/// check is pure claims logic over an already decoded principal, so these tests
/// need no Functions or MCP-extension host.
/// </summary>
public class DelegatedScopeAuthorizationTests
{
    [Fact]
    public void GetOrderStatusScope_IsTheBackendEntitlementValue()
    {
        Assert.Equal("Orders.Read.AsUser", DelegatedScopeAuthorization.GetOrderStatusScope);
    }

    [Theory]
    [InlineData("scp")]
    [InlineData("http://schemas.microsoft.com/identity/claims/scope")]
    public void HasScope_ScopePresentUnderEitherClaimType_ReturnsTrue(string scopeClaimType)
    {
        var caller = CallerWithClaims((scopeClaimType, "openid Orders.Read.AsUser profile"));

        Assert.True(DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope));
    }

    [Fact]
    public void HasScope_ClaimTypeCasingDiffers_StillMatches()
    {
        var caller = CallerWithClaims(("SCP", DelegatedScopeAuthorization.GetOrderStatusScope));

        Assert.True(DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope));
    }

    [Fact]
    public void HasScope_DifferentScopePresent_ReturnsFalse()
    {
        var caller = CallerWithClaims(("scp", "user_impersonation"));

        Assert.False(DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope));
    }

    [Fact]
    public void HasScope_NoScopeClaim_ReturnsFalse()
    {
        var caller = CallerWithClaims(("azp", "interactive-client-app-id"));

        Assert.False(DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope));
    }

    [Theory]
    [InlineData("orders.read.asuser")]
    [InlineData("Orders.Read.AsUser.Other")]
    public void HasScope_ScopeValueDoesNotExactlyMatch_ReturnsFalse(string differentScope)
    {
        var caller = CallerWithClaims(("scp", differentScope));

        Assert.False(DelegatedScopeAuthorization.HasScope(
            caller, DelegatedScopeAuthorization.GetOrderStatusScope));
    }

    [Fact]
    public void HasScope_IsGenericAcrossDelegatedScopes()
    {
        var caller = CallerWithClaims(("scp", "Orders.Read.AsUser Reports.Read.AsUser"));

        Assert.True(DelegatedScopeAuthorization.HasScope(caller, "Reports.Read.AsUser"));
        Assert.False(DelegatedScopeAuthorization.HasScope(caller, "Reports.Write.AsUser"));
    }

    private static CallerIdentity CallerWithClaims(params (string Typ, string Val)[] claims)
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
