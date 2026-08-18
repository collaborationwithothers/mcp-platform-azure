using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using McpTools.Core;
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
    public void RequiredEntitlements_SerializesTheAllOfContract()
    {
        var guidance = new AccessGuidance(
            GetAccessGuidance.SummaryValue,
            GetAccessGuidance.RequiredEntitlementsValue,
            GetAccessGuidance.DocsUrlValue,
            GetAccessGuidance.DataDisclaimerValue);
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(guidance));

        var delegatedOrderStatus = document.RootElement
            .GetProperty("requiredEntitlements")
            .EnumerateArray()
            .Single(entry => entry.GetProperty("tool").GetString() == GetOrderStatus.ToolName
                && entry.GetProperty("appliesTo").GetString() == GetAccessGuidance.AppliesToDelegated);

        Assert.True(delegatedOrderStatus.TryGetProperty("allOf", out var allOf));
        Assert.False(delegatedOrderStatus.TryGetProperty("mechanism", out _));
        Assert.False(delegatedOrderStatus.TryGetProperty("requiredRole", out _));

        var requirements = allOf.EnumerateArray().ToList();
        Assert.Equal(2, requirements.Count);
        Assert.Contains(requirements, requirement =>
            requirement.GetProperty("kind").GetString() == GetAccessGuidance.RequirementKindDelegatedScope
            && requirement.GetProperty("enforcedAt").GetString() == GetAccessGuidance.EnforcedAtBackendTool
            && requirement.GetProperty("requiredValue").GetString()
                == DelegatedScopeAuthorization.GetOrderStatusScope);
        Assert.Contains(requirements, requirement =>
            requirement.GetProperty("kind").GetString()
                == GetAccessGuidance.RequirementKindDownstreamAssignmentRequired
            && requirement.GetProperty("enforcedAt").GetString()
                == GetAccessGuidance.EnforcedAtDownstreamTokenIssuance
            && requirement.GetProperty("requiredValue").ValueKind == JsonValueKind.Null);
    }

    [Fact]
    public void RequiredEntitlements_RequirementsCarryValuesOnlyWhenTheControlNeedsOne()
    {
        foreach (var entry in GetAccessGuidance.RequiredEntitlementsValue)
        {
            foreach (var requirement in entry.AllOf)
            {
                if (requirement.Kind == GetAccessGuidance.RequirementKindDownstreamAssignmentRequired)
                {
                    Assert.Null(requirement.RequiredValue);
                    Assert.Equal(
                        GetAccessGuidance.EnforcedAtDownstreamTokenIssuance,
                        requirement.EnforcedAt);
                    continue;
                }

                Assert.False(
                    string.IsNullOrEmpty(requirement.RequiredValue),
                    $"'{entry.Tool}' ({entry.AppliesTo}) names a claim control without its required value.");
                Assert.Equal(GetAccessGuidance.EnforcedAtBackendTool, requirement.EnforcedAt);
            }
        }
    }

    [Fact]
    public void RequiredEntitlements_UseOnlyTheDeclaredRequirementAndModeVocabulary()
    {
        var kinds = new[]
        {
            GetAccessGuidance.RequirementKindApplicationRole,
            GetAccessGuidance.RequirementKindDelegatedScope,
            GetAccessGuidance.RequirementKindDownstreamAssignmentRequired,
        };
        var enforcementSites = new[]
        {
            GetAccessGuidance.EnforcedAtBackendTool,
            GetAccessGuidance.EnforcedAtDownstreamTokenIssuance,
        };
        var modes = new[]
        {
            GetAccessGuidance.AppliesToApplication,
            GetAccessGuidance.AppliesToDelegated,
        };

        foreach (var entry in GetAccessGuidance.RequiredEntitlementsValue)
        {
            Assert.Contains(entry.AppliesTo, modes);
            foreach (var requirement in entry.AllOf)
            {
                Assert.Contains(requirement.Kind, kinds);
                Assert.Contains(requirement.EnforcedAt, enforcementSites);
            }
        }
    }

    [Fact]
    public void RequiredEntitlements_NameTheControlsTheBackendActuallyChecks()
    {
        var ordersRow = Assert.Single(
            GetAccessGuidance.RequiredEntitlementsValue,
            e => e.Tool == GetOrderStatus.ToolName
                && e.AppliesTo == GetAccessGuidance.AppliesToApplication);
        var ordersRole = Assert.Single(ordersRow.AllOf);
        Assert.Equal(GetAccessGuidance.RequirementKindApplicationRole, ordersRole.Kind);
        Assert.Equal(AppRoleAuthorization.RequiredRole, ordersRole.RequiredValue);

        var delegatedOrdersRow = Assert.Single(
            GetAccessGuidance.RequiredEntitlementsValue,
            e => e.Tool == GetOrderStatus.ToolName
                && e.AppliesTo == GetAccessGuidance.AppliesToDelegated);
        Assert.Collection(
            delegatedOrdersRow.AllOf,
            requirement =>
            {
                Assert.Equal(GetAccessGuidance.RequirementKindDelegatedScope, requirement.Kind);
                Assert.Equal(GetAccessGuidance.EnforcedAtBackendTool, requirement.EnforcedAt);
                Assert.Equal(DelegatedScopeAuthorization.GetOrderStatusScope, requirement.RequiredValue);
            },
            requirement =>
            {
                Assert.Equal(GetAccessGuidance.RequirementKindDownstreamAssignmentRequired, requirement.Kind);
                Assert.Equal(GetAccessGuidance.EnforcedAtDownstreamTokenIssuance, requirement.EnforcedAt);
                Assert.Null(requirement.RequiredValue);
            });

        var serviceRows = GetAccessGuidance.RequiredEntitlementsValue.Where(
            e => e.Tool == GetServiceInfo.ToolName).ToList();
        Assert.Equal(2, serviceRows.Count);
        Assert.All(serviceRows, row =>
        {
            var requirement = Assert.Single(row.AllOf);
            Assert.Equal(GetAccessGuidance.RequirementKindApplicationRole, requirement.Kind);
            Assert.Equal(AppRoleAuthorization.ServiceInfoRole, requirement.RequiredValue);
        });

        var guidanceRows = GetAccessGuidance.RequiredEntitlementsValue.Where(
            e => e.Tool == GetAccessGuidance.ToolName).ToList();
        Assert.Equal(2, guidanceRows.Count);
        Assert.All(guidanceRows, row => Assert.Empty(row.AllOf));
    }

    [Fact]
    public void Summary_KeepsTheQualificationsOnTheLeastCertainClaimItMakes()
    {
        // Governance review of issue 82 found the summary asserting the
        // downstream assignment gate as settled fact while the class doc comment
        // carried the qualifications. The summary is the part that reaches a
        // caller who cannot read the comment, so it is the last place a
        // qualification may be dropped. This test exists so a future edit that
        // tightens the prose cannot quietly drop them again.
        //
        // Verified against Microsoft Learn 2026-08-09: the gate is VERIFIED for
        // OAuth 2.0 access-token requests generally, the Global Administrator
        // bypass is VERIFIED and is the only role Learn names, and the
        // on-behalf-of exchange specifically is UNVERIFIABLE from Learn.
        Assert.Contains("does not document it for the on-behalf-of token exchange",
            GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
        Assert.Contains("2026-07-22", GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
        Assert.Contains("Global Administrators bypass the gate",
            GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
    }

    [Fact]
    public void Summary_NamesThePerServerEntitlementAndDefersToTheGatewayMap()
    {
        // The entitlement a caller holding nothing is most likely missing is the
        // gateway's per-SERVER check, not any per-tool role. Hari's call on the
        // issue-82 review was to name it in prose. These two values come from a
        // deployment secret that this code cannot read and no test can guard, so
        // the deference sentence is not decoration: it is what keeps the claim
        // honest when the deployment changes and this constant does not.
        Assert.Contains("Orders.Invoke.All", GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
        Assert.Contains("Catalog.Invoke.All", GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
        Assert.Contains("the map is authoritative", GetAccessGuidance.SummaryValue, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryAuthorizationValueEmitted_IsEitherRuntimeBackedOrDeclaredUnguarded()
    {
        // Each per-tool value comes from the same authorization constant that
        // the backend checks. The two per-server names in the summary are bare
        // literals sourced from deployment configuration this code cannot read.
        //
        // What IS guardable is the boundary. A third unguarded role name added
        // to the emitted text fails here until someone adds it to this set,
        // which forces the DataDisclaimerValue scope sentence to be revisited at
        // the same time. Content moving while the disclaimer stayed put is
        // exactly what went wrong before.
        var runtimeBacked = new[]
        {
            AppRoleAuthorization.RequiredRole,
            AppRoleAuthorization.ServiceInfoRole,
            DelegatedScopeAuthorization.GetOrderStatusScope,
        };
        var declaredUnguarded = new[] { "Orders.Invoke.All", "Catalog.Invoke.All" };
        var known = runtimeBacked.Concat(declaredUnguarded).ToHashSet(StringComparer.Ordinal);

        var emitted = GetAccessGuidance.SummaryValue
            + " " + GetAccessGuidance.DataDisclaimerValue
            + " " + string.Join(" ", GetAccessGuidance.RequiredEntitlementsValue
                .SelectMany(entry => entry.AllOf)
                .Select(requirement => requirement.RequiredValue)
                .Where(value => value is not null));

        // Role-shaped: two or more dot-separated capitalised words, e.g.
        // Orders.Read or Catalog.Invoke.All. Deliberately not anchored to the
        // known values, or it could only ever find what it already expects.
        var found = Regex.Matches(emitted, @"\b[A-Z][A-Za-z]+(?:\.[A-Z][A-Za-z]+)+\b")
            .Select(match => match.Value)
            .ToHashSet(StringComparer.Ordinal);

        var unaccounted = found.Except(known, StringComparer.Ordinal).ToList();
        Assert.True(
            unaccounted.Count == 0,
            $"authorization value(s) emitted by get_access_guidance that this test does not account for: "
            + $"{string.Join(", ", unaccounted)}. If a value is checked at runtime, source it from "
            + "the relevant authorization constant. If it is deployment configuration this server cannot read, add "
            + "it to declaredUnguarded AND make sure DataDisclaimerValue's scope sentence still "
            + "covers it.");
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

    private static GetAccessGuidance CreateTool() =>
        new(
            new McpToolApplication(new UnusedDownstreamOrdersClient()),
            NullLogger<GetAccessGuidance>.Instance);
}
