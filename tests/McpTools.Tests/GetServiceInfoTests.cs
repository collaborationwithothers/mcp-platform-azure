using System.Text;
using System.Text.Json;
using McpTools.Identity;
using McpTools.Tools;
using Microsoft.Azure.Functions.Worker.Extensions.Mcp;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol.Protocol;
using Xunit;

namespace McpTools.Tests;

/// <summary>
/// In-process tests of GetServiceInfo.Run: an authorized ServiceInfo.Read
/// caller gets the fixed metadata, every other caller (wrong role, no role,
/// delegated) is refused by the same 403 shape. This is the cross-tool
/// authorization proof issue 76 exists for, so the "different role, still
/// denied" case matters most among these.
/// </summary>
public class GetServiceInfoTests
{
    [Fact]
    public void Run_AppContext_WithServiceInfoRead_ReturnsTheFrozenServiceInfo()
    {
        var tool = CreateTool();

        var result = tool.Run(ContextWithHeaders(AppContext("ServiceInfo.Read")));

        var serviceInfo = Assert.IsType<ServiceInfo>(result);
        Assert.Equal("contoso-orders-mcp", serviceInfo.ServerName);
        Assert.Equal("streamable-http", serviceInfo.Transport);
        Assert.Equal(
            "The order data this server returns is SYNTHETIC demo data (ids "
            + "CONTOSO-1001 to CONTOSO-1005) and is not sourced from any real system.",
            serviceInfo.DataDisclaimer);
    }

    [Fact]
    public void Run_AppContext_WithADifferentRole_ReturnsDeterministic403()
    {
        // The property this ticket exists to prove: an Orders.Read holder (a
        // caller entitled to the OTHER tool) is refused get_service_info because
        // that role is not ServiceInfo.Read.
        var tool = CreateTool();

        var result = tool.Run(ContextWithHeaders(AppContext("Orders.Read")));

        var error = Assert.IsType<CallToolResult>(result);
        Assert.True(error.IsError);
        var content = Assert.IsType<TextContentBlock>(Assert.Single(error.Content));
        Assert.Equal(
            "403 Forbidden: get_service_info requires the application role 'ServiceInfo.Read'.",
            content.Text);
    }

    [Fact]
    public void Run_Delegated_IsDeniedByTheSame403Shape()
    {
        // Pins a documented decision (see GetServiceInfo's class doc comment) for
        // the case this deployment is actually in: a delegated (scp) caller with
        // no roles claim, because this deployment does not assign app roles to
        // users. The app-role grant made to the client application does not
        // surface in this principal, so it fails the same single role check as
        // any other unauthorized caller. This is NOT a claim that every delegated
        // caller is denied -- a delegated principal whose signed-in user was
        // separately assigned ServiceInfo.Read would carry a roles claim and
        // would be granted; that case is out of scope here, not contradicted.
        var tool = CreateTool();
        var headers = Delegated();

        var result = tool.Run(ContextWithHeaders(headers));

        var error = Assert.IsType<CallToolResult>(result);
        Assert.True(error.IsError);
        var content = Assert.IsType<TextContentBlock>(Assert.Single(error.Content));
        Assert.Equal(
            "403 Forbidden: get_service_info requires the application role 'ServiceInfo.Read'.",
            content.Text);
    }

    [Fact]
    public void Run_CalledTwiceWithTheSameAuthorizedCaller_ReturnsIdenticalFieldValues()
    {
        var tool = CreateTool();

        var first = Assert.IsType<ServiceInfo>(
            tool.Run(ContextWithHeaders(AppContext("ServiceInfo.Read"))));
        var second = Assert.IsType<ServiceInfo>(
            tool.Run(ContextWithHeaders(AppContext("ServiceInfo.Read"))));

        Assert.Equal(first, second);
    }

    [Fact]
    public void Run_MissingPrincipal_Throws()
    {
        var tool = CreateTool();
        var context = ContextWithHeaders(
            new Dictionary<string, string> { ["Authorization"] = "Bearer x" });

        Assert.Throws<InvalidOperationException>(() => tool.Run(context));
    }

    [Fact]
    public void Run_NonHttpTransport_Throws()
    {
        var tool = CreateTool();
        var context = new ToolInvocationContext { Name = GetServiceInfo.ToolName, Transport = null };

        Assert.Throws<InvalidOperationException>(() => tool.Run(context));
    }

    [Fact]
    public void ToolName_And_Description_MatchTheFrozenContract()
    {
        Assert.Equal("get_service_info", GetServiceInfo.ToolName);
        Assert.Contains("static service metadata", GetServiceInfo.ToolDescription, StringComparison.Ordinal);
        Assert.Contains("SYNTHETIC", GetServiceInfo.DataDisclaimerValue, StringComparison.Ordinal);
    }

    private static Dictionary<string, string> Delegated() =>
        WithPrincipal(
            [("scp", "user_impersonation"), ("azp", "interactive-client-app-id"), ("oid", "user-object-id")],
            []);

    private static Dictionary<string, string> AppContext(string role) =>
        WithPrincipal(
            [("roles", role), ("azp", "test-client-app-id"), ("oid", "test-client-object-id")],
            []);

    private static Dictionary<string, string> WithPrincipal(
        (string Typ, string Val)[] claims,
        (string Key, string Value)[] extraHeaders)
    {
        var payload = new
        {
            auth_typ = "aad",
            claims = claims.Select(claim => new { typ = claim.Typ, val = claim.Val }).ToArray(),
        };
        var header = Convert.ToBase64String(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload)));
        var headers = new Dictionary<string, string> { [ClientPrincipal.HeaderName] = header };
        foreach (var (key, value) in extraHeaders)
        {
            headers[key] = value;
        }

        return headers;
    }

    private static ToolInvocationContext ContextWithHeaders(
        Dictionary<string, string> headers) =>
        new()
        {
            Name = GetServiceInfo.ToolName,
            Transport = new HttpTransport("http") { Headers = headers },
        };

    private static GetServiceInfo CreateTool() => new(NullLogger<GetServiceInfo>.Instance);
}
