using System.Text;
using System.Text.Json;
using McpTools.Identity;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for <see cref="ClientPrincipal"/> (spec: Testing
/// Decisions, "unit seam"). Parsing the Base64 JSON X-MS-CLIENT-PRINCIPAL
/// header Easy Auth injects is pure, host-independent logic; these tests use
/// plain strings with no Functions/MCP-extension dependency. The header
/// envelope shape (auth_typ / name_typ / role_typ / claims[{typ,val}]) is
/// documented and verified (COMPATIBILITY.md, docs/security.md).
/// </summary>
public class ClientPrincipalTests
{
    [Fact]
    public void TryParse_ValidPrincipal_ExposesTheClaimTypesAndValues()
    {
        var header = EncodePrincipal(("scp", "user_impersonation"), ("aud", "api://server-app"));

        var parsed = ClientPrincipal.TryParse(header, out var principal);

        Assert.True(parsed);
        Assert.NotNull(principal);
        Assert.Contains(principal!.Claims, c => c.Typ == "scp" && c.Val == "user_impersonation");
        Assert.Contains(principal.Claims, c => c.Typ == "aud" && c.Val == "api://server-app");
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void TryParse_NullOrBlank_ReturnsFalse(string? header)
    {
        var parsed = ClientPrincipal.TryParse(header, out var principal);

        Assert.False(parsed);
        Assert.Null(principal);
    }

    [Fact]
    public void TryParse_NotBase64_ReturnsFalse()
    {
        var parsed = ClientPrincipal.TryParse("this is not base64 %%%", out var principal);

        Assert.False(parsed);
        Assert.Null(principal);
    }

    [Fact]
    public void TryParse_Base64ButNotJsonObject_ReturnsFalse()
    {
        var notJson = Convert.ToBase64String(Encoding.UTF8.GetBytes("just a bare string"));

        var parsed = ClientPrincipal.TryParse(notJson, out var principal);

        Assert.False(parsed);
        Assert.Null(principal);
    }

    [Fact]
    public void TryParse_JsonObjectWithNoClaimsArray_ReturnsTrueWithNoClaims()
    {
        var noClaims = Convert.ToBase64String(Encoding.UTF8.GetBytes("""{"auth_typ":"aad"}"""));

        var parsed = ClientPrincipal.TryParse(noClaims, out var principal);

        Assert.True(parsed);
        Assert.NotNull(principal);
        Assert.Empty(principal!.Claims);
    }

    private static string EncodePrincipal(params (string Typ, string Val)[] claims)
    {
        var payload = new
        {
            auth_typ = "aad",
            name_typ = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name",
            role_typ = "roles",
            claims = claims.Select(c => new { typ = c.Typ, val = c.Val }).ToArray(),
        };
        var json = JsonSerializer.Serialize(payload);
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
    }
}
