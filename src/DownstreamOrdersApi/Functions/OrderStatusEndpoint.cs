using System.Net;
using System.Text.Json.Serialization;
using DownstreamOrdersApi.Fixtures;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;

namespace DownstreamOrdersApi.Functions;

/// <summary>
/// The synthetic downstream Orders API (issue 10: OBO thickening). A plain
/// REST endpoint, not an MCP tool: ordinary HTTP status codes convey found
/// vs not-found (200 vs 404), unlike get_order_status's typed MCP result
/// shapes. McpTools.Downstream.DownstreamOrdersClient is the adapter that
/// maps this REST shape back onto the frozen MCP contract.
///
/// Authorization is Anonymous at the function level: this endpoint relies
/// entirely on the Function App's Entra built-in auth (Easy Auth,
/// entra_auth.allowed_audiences = [downstream app id URI] and
/// allowed_applications = [MCP server app client id]), the same
/// posture McpTools takes for the mcp_extension system key (see
/// mcp-function-host's README, "mcp_extension key posture"). A caller
/// presenting a token minted for the MCP server app (a different audience)
/// is rejected by Easy Auth before this code runs; that rejection is the
/// negative test in tests/integration/obo-passthrough-negative.ps1. The
/// correlation headers this endpoint logs identify the original caller for
/// audit only; they are not authorization inputs.
/// </summary>
public sealed class OrderStatusEndpoint
{
    private const string CallerApplicationIdHeader = "X-Mcp-Caller-Azp";
    private const string CallerObjectIdHeader = "X-Mcp-Caller-Oid";
    private readonly ILogger<OrderStatusEndpoint> _logger;

    public OrderStatusEndpoint(ILogger<OrderStatusEndpoint> logger)
    {
        _logger = logger;
    }

    [Function(nameof(OrderStatusEndpoint))]
    public async Task<HttpResponseData> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "orders/{orderId}")]
            HttpRequestData request,
        string orderId)
    {
        var callerApplicationId = FirstHeaderValue(request, CallerApplicationIdHeader);
        var callerObjectId = FirstHeaderValue(request, CallerObjectIdHeader);
        _logger.LogInformation(
            "Downstream order lookup correlation. CallerApplicationId={CallerApplicationId} "
            + "CallerObjectId={CallerObjectId}",
            callerApplicationId ?? "missing",
            callerObjectId ?? "missing");

        var (statusCode, body) = Resolve(orderId);
        var response = request.CreateResponse(statusCode);
        await response.WriteAsJsonAsync(body);
        return response;
    }

    private static string? FirstHeaderValue(HttpRequestData request, string headerName) =>
        request.Headers.TryGetValues(headerName, out var values)
            ? values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))
            : null;

    /// <summary>
    /// Pure lookup logic, unit-tested in process with no Functions host (spec:
    /// Testing Decisions, "unit seam"). Known ids return 200 with the typed
    /// success body; any other id returns 404 with a typed not-found body.
    /// </summary>
    public static (HttpStatusCode StatusCode, object Body) Resolve(string orderId)
    {
        if (SyntheticOrders.All.TryGetValue(orderId, out var order))
        {
            return (HttpStatusCode.OK, new OrderStatusResponse(orderId, order.Status, order.UpdatedUtc));
        }

        return (HttpStatusCode.NotFound, new OrderNotFoundResponse(
            orderId,
            Message: $"No order was found for id '{orderId}'. Order data is synthetic "
                + "(known ids are CONTOSO-1001 to CONTOSO-1005)."));
    }
}

/// <summary>Typed success body: a known order id.</summary>
public sealed record OrderStatusResponse(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("updatedUtc")] string UpdatedUtc);

/// <summary>Typed not-found body: any id not in the fixture.</summary>
public sealed record OrderNotFoundResponse(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("message")] string Message);
