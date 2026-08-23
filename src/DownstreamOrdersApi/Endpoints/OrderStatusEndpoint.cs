using System.Net;
using System.Text.Json.Serialization;
using DownstreamOrdersApi.Fixtures;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace DownstreamOrdersApi.Endpoints;

/// <summary>
/// The synthetic downstream Orders API (issue 10: OBO thickening). A plain
/// REST endpoint, not an MCP tool. Ordinary HTTP status codes convey found
/// versus not-found (200 versus 404), unlike get_order_status's typed MCP
/// result shapes. McpTools.Downstream.DownstreamOrdersClient maps this REST
/// shape back onto the frozen MCP contract.
///
/// JWT bearer middleware validates the Orders audience before this handler
/// runs. Correlation headers identify the original caller for audit only.
/// They are not authorization inputs.
/// </summary>
public sealed class OrderStatusEndpoint
{
    private const string CallerApplicationIdHeader = "X-Mcp-Caller-Azp";
    private const string CallerObjectIdHeader = "X-Mcp-Caller-Oid";
    public static IResult Handle(
        string orderId,
        HttpRequest request,
        ILogger<OrderStatusEndpoint> logger)
    {
        var callerApplicationId = FirstHeaderValue(request.Headers, CallerApplicationIdHeader);
        var callerObjectId = FirstHeaderValue(request.Headers, CallerObjectIdHeader);
        logger.LogInformation(
            "Downstream order lookup correlation. CallerApplicationId={CallerApplicationId} "
            + "CallerObjectId={CallerObjectId}",
            callerApplicationId ?? "missing",
            callerObjectId ?? "missing");

        var (statusCode, body) = Resolve(orderId);
        return Results.Json(body, statusCode: (int)statusCode);
    }

    private static string? FirstHeaderValue(IHeaderDictionary headers, string headerName) =>
        headers.TryGetValue(headerName, out var values)
            ? values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))
            : null;

    /// <summary>
    /// Pure lookup logic, unit-tested in process with no web host. Known ids
    /// return 200 with the typed success body. Any other id returns 404 with
    /// a typed not-found body.
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
