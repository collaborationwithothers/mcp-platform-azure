using System.Reflection;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// Drift guard for get_access_guidance's RequiredEntitlements list (issue 82).
///
/// The live gate's check (a) already forces a new tool into the GATEWAY's
/// tool_authorization_map: it asserts set-equality between tools/list and the
/// map keys in both directions and fails loudly on a mismatch. Nothing
/// equivalent guards a list compiled into the assembly, so without this test the
/// entitlement list would be a hand-maintained comment with a JSON serialiser
/// attached, and a stale one is worse than none: a caller who cannot call any
/// tool is exactly the caller least able to notice that the guidance is wrong.
///
/// This moves check (a)'s idea to build time, and adds the second dimension the
/// gateway map does not have: the list must be total over tool TIMES identity
/// mode, because get_order_status is authorized by different mechanisms in the
/// two modes (see GetAccessGuidance's class doc comment).
///
/// Reflection here is deliberately narrow. It reads the ToolName const
/// convention and the PRESENCE of FunctionAttribute, both of which this repo
/// controls. It does not read McpToolTriggerAttribute's properties: that would
/// be a claim about the pinned extension package's shape, and this repo requires
/// such claims to carry a COMPATIBILITY.md row and a Microsoft Learn citation.
/// </summary>
public class ToolEntitlementParityTests
{
    [Fact]
    public void EveryToolClassDeclaresAToolNameConst()
    {
        // Runs first in intent: the two tests below trust the ToolName
        // convention, so a tool class that quietly opts out of it would make
        // them pass vacuously.
        foreach (var toolClass in ToolClasses())
        {
            Assert.True(
                ToolNameField(toolClass) is not null,
                $"'{toolClass.Name}' declares an Azure Function but no 'const string ToolName'. "
                + "ToolEntitlementParityTests relies on that convention to enumerate the tool "
                + "surface; a tool without it escapes the entitlement-list drift guard.");
        }
    }

    [Fact]
    public void RequiredEntitlements_CoverExactlyTheToolsTheAssemblyExposes()
    {
        var declaredTools = ToolNames();
        var listedTools = GetAccessGuidance.RequiredEntitlementsValue
            .Select(entry => entry.Tool)
            .ToHashSet(StringComparer.Ordinal);

        var missing = declaredTools.Except(listedTools, StringComparer.Ordinal).ToList();
        var extra = listedTools.Except(declaredTools, StringComparer.Ordinal).ToList();

        Assert.True(
            missing.Count == 0,
            $"tool(s) exposed by this assembly but absent from get_access_guidance's "
            + $"requiredEntitlements: {string.Join(", ", missing)}. Add a row per identity mode.");
        Assert.True(
            extra.Count == 0,
            $"requiredEntitlements name(s) no tool in this assembly (renamed or removed tool): "
            + $"{string.Join(", ", extra)}.");
    }

    [Fact]
    public void RequiredEntitlements_AreTotalOverToolTimesIdentityMode()
    {
        var modes = new[]
        {
            GetAccessGuidance.AppliesToApplication,
            GetAccessGuidance.AppliesToDelegated,
        };

        foreach (var tool in ToolNames())
        {
            foreach (var mode in modes)
            {
                var rows = GetAccessGuidance.RequiredEntitlementsValue
                    .Where(entry => entry.Tool == tool && entry.AppliesTo == mode)
                    .ToList();

                Assert.True(
                    rows.Count == 1,
                    $"expected exactly one requiredEntitlements row for '{tool}' in the '{mode}' "
                    + $"identity mode, found {rows.Count}. The list is total over tool times mode: "
                    + "a tool whose two modes share a rule still gets two rows, so that a tool "
                    + "whose modes DIVERGE cannot be added with a single row that quietly lies.");
            }
        }
    }

    private static HashSet<string> ToolNames() =>
        ToolClasses()
            .Select(ToolNameField)
            .Where(field => field is not null)
            .Select(field => (string)field!.GetRawConstantValue()!)
            .ToHashSet(StringComparer.Ordinal);

    // A tool class is a class in McpTools.Tools with at least one method
    // carrying [Function]. That is broader than "has an McpToolTrigger", on
    // purpose: if a non-MCP Function is ever added to this namespace, this guard
    // fails loudly and a human decides, rather than silently ignoring it.
    private static IEnumerable<Type> ToolClasses() =>
        typeof(GetAccessGuidance).Assembly
            .GetTypes()
            .Where(type => type.IsClass
                && !type.IsAbstract
                && type.Namespace == "McpTools.Tools"
                && type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                    .Any(method => method.GetCustomAttribute<FunctionAttribute>() is not null));

    private static FieldInfo? ToolNameField(Type toolClass) =>
        toolClass.GetField(
            "ToolName",
            BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic) is { IsLiteral: true } field
            && field.FieldType == typeof(string)
            ? field
            : null;
}
