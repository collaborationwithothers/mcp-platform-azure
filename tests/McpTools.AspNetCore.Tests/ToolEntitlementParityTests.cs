using System.Reflection;
using McpTools.Core;
using ModelContextProtocol.Server;
using Xunit;

namespace McpTools.AspNetCore.Tests;

public sealed class ToolEntitlementParityTests
{
    [Fact]
    public void AspNetCoreToolDiscoveryIsNonEmptyAndMatchesTheCoreContract()
    {
        var discovered = DiscoverTools();

        Assert.NotEmpty(discovered);
        Assert.Equal(
            [
                McpToolContracts.GetAccessGuidanceName,
                McpToolContracts.GetOrderStatusName,
                McpToolContracts.GetServiceInfoName,
            ],
            discovered.Order(StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void EveryAspNetCoreToolHasExactlyOneEntitlementRowPerIdentityMode()
    {
        var discovered = DiscoverTools();
        Assert.NotEmpty(discovered);

        foreach (var toolName in discovered)
        {
            foreach (var mode in new[]
            {
                McpToolContracts.AppliesToApplication,
                McpToolContracts.AppliesToDelegated,
            })
            {
                Assert.Single(
                    McpToolContracts.RequiredEntitlements,
                    row => row.Tool == toolName && row.AppliesTo == mode);
            }
        }
    }

    private static HashSet<string> DiscoverTools()
    {
        var toolTypes = typeof(Program).Assembly
            .GetTypes()
            .Where(type => type.GetCustomAttribute<McpServerToolTypeAttribute>() is not null)
            .ToArray();

        Assert.NotEmpty(toolTypes);
        foreach (var toolType in toolTypes)
        {
            Assert.Contains(
                toolType.GetMethods(BindingFlags.Instance | BindingFlags.Public),
                method => method.GetCustomAttribute<McpServerToolAttribute>() is not null);
        }

        var names = toolTypes
            .SelectMany(type => type.GetMethods(BindingFlags.Instance | BindingFlags.Public))
            .Select(method => method.GetCustomAttribute<McpServerToolAttribute>())
            .Where(attribute => attribute is not null)
            .Select(attribute => attribute!.Name)
            .ToArray();

        Assert.All(names, name => Assert.False(string.IsNullOrWhiteSpace(name)));
        Assert.Equal(names.Length, names.Distinct(StringComparer.Ordinal).Count());
        return names.ToHashSet(StringComparer.Ordinal)!;
    }
}
