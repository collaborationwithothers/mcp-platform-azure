using System.Text;
using System.Text.Json;
using McpTools.Identity;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process unit tests for <see cref="IdentityModeResolver"/> (spec: Testing
/// Decisions, "unit seam"). This is the single, testable identity-mode
/// decision component the tool delegates to (issue 10 amended acceptance:
/// delegated callers with an scp claim are sourced from the downstream via
/// OBO; app-context callers with a roles claim or an app id and no scp are
/// routed to application-role authorization). The required cases -- scp,
/// roles, a role-less app, both absent,
/// malformed principal -- plus a missing header and the schema-URI claim-type
/// forms are covered here.
/// </summary>
public class IdentityModeResolverTests
{
    [Fact]
    public void Resolve_ScpClaimPresent_IsDelegated()
    {
        var headers = PrincipalHeaders(("scp", "user_impersonation"));

        Assert.Equal(IdentityMode.Delegated, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_RolesClaimAndNoScp_IsAppContext()
    {
        var headers = PrincipalHeaders(("roles", "Orders.Read.All"));

        Assert.Equal(IdentityMode.AppContext, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_BothScpAndRoles_PrefersDelegated()
    {
        // The discriminator is "roles AND no scp => app-context", so any scp
        // claim wins for delegated regardless of a roles claim also present.
        var headers = PrincipalHeaders(("scp", "user_impersonation"), ("roles", "Orders.Read.All"));

        Assert.Equal(IdentityMode.Delegated, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_NeitherScpNorRoles_IsUnsupported()
    {
        var headers = PrincipalHeaders(("aud", "api://server-app"), ("tid", "contoso"));

        Assert.Equal(IdentityMode.Unsupported, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_RoleLessApplicationPrincipal_IsAppContext()
    {
        var headers = PrincipalHeaders(
            ("azp", "role-less-client"),
            ("oid", "service-principal"));

        Assert.Equal(IdentityMode.AppContext, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_NoPrincipalHeader_IsMissingPrincipal()
    {
        var headers = new Dictionary<string, string> { ["Authorization"] = "Bearer x" };

        Assert.Equal(IdentityMode.MissingPrincipal, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_MalformedPrincipalHeader_IsMalformedPrincipal()
    {
        var headers = new Dictionary<string, string> { [ClientPrincipal.HeaderName] = "not base64 %%%" };

        Assert.Equal(IdentityMode.MalformedPrincipal, IdentityModeResolver.Resolve(headers));
    }

    // The exact claim-type string inside X-MS-CLIENT-PRINCIPAL is not
    // Learn-documented (Easy Auth applies claims mapping; scp/roles may be
    // remapped to schema URIs). The resolver therefore matches both forms;
    // these two tests pin that robustness (COMPATIBILITY.md, docs/security.md).
    [Fact]
    public void Resolve_ScopeUnderSchemaUri_IsDelegated()
    {
        var headers = PrincipalHeaders(("http://schemas.microsoft.com/identity/claims/scope", "user_impersonation"));

        Assert.Equal(IdentityMode.Delegated, IdentityModeResolver.Resolve(headers));
    }

    [Fact]
    public void Resolve_RoleUnderSchemaUri_IsAppContext()
    {
        var headers = PrincipalHeaders(("http://schemas.microsoft.com/ws/2008/06/identity/claims/role", "Orders.Read.All"));

        Assert.Equal(IdentityMode.AppContext, IdentityModeResolver.Resolve(headers));
    }

    private static Dictionary<string, string> PrincipalHeaders(params (string Typ, string Val)[] claims)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(c => new { typ = c.Typ, val = c.Val }).ToArray(),
        };
        var json = JsonSerializer.Serialize(payload);
        var header = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        return new Dictionary<string, string> { [ClientPrincipal.HeaderName] = header };
    }
}
