using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using McpTools.Tools;

namespace McpTools.Downstream;

/// <summary>
/// Fetches order status from the synthetic downstream Orders API
/// (src/DownstreamOrdersApi) via the Entra On-Behalf-Of exchange, and maps
/// its plain-REST response (200/404) onto get_order_status's frozen typed
/// MCP contract (<see cref="OrderStatus"/> / <see cref="OrderNotFound"/>).
///
/// Unit-testable with no Azure dependency: <see cref="IOboTokenAcquirer"/>
/// and <see cref="HttpClient"/> are both injected, so tests fake the token
/// exchange and the downstream HTTP response (see
/// tests/McpTools.Tests/DownstreamOrdersClientTests.cs). Those tests are the
/// unit-level proof of "never forwards the inbound client token downstream"
/// (docs/decisions/ADR-006): they assert the Authorization header sent to
/// the downstream carries the OBO-exchanged token, never the caller's
/// inbound assertion.
///
/// NOT currently called by <see cref="GetOrderStatus.Run"/>: the Azure
/// Functions MCP extension's McpToolTrigger binding has no Microsoft-Learn-
/// documented path to the caller's inbound bearer token (azure-docs-verifier,
/// 2026-07-18; see ADR-006, "OBO exchange: the inbound-token gap" and
/// COMPATIBILITY.md). This class is the complete, tested building block
/// ready to wire in once that gap is resolved.
/// </summary>
public sealed class DownstreamOrdersClient
{
    private readonly IOboTokenAcquirer _tokenAcquirer;
    private readonly HttpClient _httpClient;
    private readonly Uri _baseUrl;
    private readonly string _downstreamScope;

    public DownstreamOrdersClient(
        IOboTokenAcquirer tokenAcquirer, HttpClient httpClient, Uri baseUrl, string downstreamScope)
    {
        _tokenAcquirer = tokenAcquirer;
        _httpClient = httpClient;
        _baseUrl = baseUrl;
        _downstreamScope = downstreamScope;
    }

    /// <summary>
    /// Returns the same typed shapes get_order_status has always returned
    /// (contract unchanged): <see cref="OrderStatus"/> for a known id,
    /// <see cref="OrderNotFound"/> for any other id.
    /// </summary>
    public async Task<object> GetOrderStatusAsync(
        string orderId, string inboundUserAssertion, CancellationToken cancellationToken)
    {
        var downstreamToken = await _tokenAcquirer.AcquireDownstreamTokenAsync(
            inboundUserAssertion, _downstreamScope, cancellationToken);

        var requestUri = new Uri($"{_baseUrl.ToString().TrimEnd('/')}/api/orders/{Uri.EscapeDataString(orderId)}");
        using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", downstreamToken);

        using var response = await _httpClient.SendAsync(request, cancellationToken);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            var notFound = await response.Content.ReadFromJsonAsync<DownstreamNotFoundBody>(cancellationToken)
                ?? throw new InvalidOperationException($"Downstream returned 404 for '{orderId}' with no body.");
            return new OrderNotFound(notFound.OrderId, Found: false, notFound.Message);
        }

        response.EnsureSuccessStatusCode();

        var found = await response.Content.ReadFromJsonAsync<DownstreamOrderStatusBody>(cancellationToken)
            ?? throw new InvalidOperationException($"Downstream returned 200 for '{orderId}' with no body.");
        return new OrderStatus(found.OrderId, found.Status, found.UpdatedUtc);
    }

    /// <summary>Mirrors DownstreamOrdersApi.Functions.OrderStatusResponse's wire shape.</summary>
    private sealed record DownstreamOrderStatusBody(
        [property: JsonPropertyName("orderId")] string OrderId,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("updatedUtc")] string UpdatedUtc);

    /// <summary>Mirrors DownstreamOrdersApi.Functions.OrderNotFoundResponse's wire shape.</summary>
    private sealed record DownstreamNotFoundBody(
        [property: JsonPropertyName("orderId")] string OrderId,
        [property: JsonPropertyName("message")] string Message);
}
