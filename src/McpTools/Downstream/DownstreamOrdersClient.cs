using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Downstream;

/// <summary>
/// Fetches order status from the synthetic downstream Orders API through
/// either delegated OBO or the server's own application identity, and maps
/// its plain-REST response (200/404) onto get_order_status's frozen typed
/// MCP contract (<see cref="OrderStatus"/> / <see cref="OrderNotFound"/>).
///
/// Unit-testable with no Azure dependency: <see cref="IOboTokenAcquirer"/>,
/// <see cref="IAppTokenAcquirer"/>, and <see cref="HttpClient"/> are injected,
/// so tests fake both token modes and the downstream HTTP response (see
/// tests/McpTools.Tests/DownstreamOrdersClientTests.cs). Those tests are the
/// unit-level proof of "never forwards the inbound client token downstream"
/// (docs/decisions/ADR-006): they assert the Authorization header sent to
/// the downstream carries the newly acquired downstream token, never the
/// caller's inbound assertion.
///
/// Called by <see cref="GetOrderStatus.Run"/> via <see cref="IDownstreamOrdersClient"/>:
/// the caller's inbound bearer token reaches the tool function through
/// <c>ToolInvocationContext.TryGetHttpTransport</c> (see GetOrderStatus.cs's
/// doc comment and ADR-006, "OBO exchange: confused deputy, audience
/// validation, and the inbound-token gap").
/// </summary>
public sealed class DownstreamOrdersClient : IDownstreamOrdersClient
{
    private readonly IOboTokenAcquirer _tokenAcquirer;
    private readonly IAppTokenAcquirer _appTokenAcquirer;
    private readonly HttpClient _httpClient;
    private readonly Uri _baseUrl;
    private readonly string _downstreamScope;
    private readonly string _downstreamApplicationScope;

    public DownstreamOrdersClient(
        IOboTokenAcquirer tokenAcquirer,
        IAppTokenAcquirer appTokenAcquirer,
        HttpClient httpClient,
        Uri baseUrl,
        string downstreamScope,
        string downstreamApplicationScope)
    {
        _tokenAcquirer = tokenAcquirer;
        _appTokenAcquirer = appTokenAcquirer;
        _httpClient = httpClient;
        _baseUrl = baseUrl;
        _downstreamScope = downstreamScope;
        _downstreamApplicationScope = downstreamApplicationScope;
    }

    /// <summary>
    /// Returns the same typed shapes get_order_status has always returned
    /// (contract unchanged): <see cref="OrderStatus"/> for a known id,
    /// <see cref="OrderNotFound"/> for any other id.
    /// </summary>
    public async Task<object> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken)
    {
        var downstreamToken = await _tokenAcquirer.AcquireDownstreamTokenAsync(
            inboundUserAssertion, _downstreamScope, cancellationToken);

        return await SendAsync(orderId, downstreamToken, caller, cancellationToken);
    }

    public async Task<object> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken)
    {
        var downstreamToken = await _appTokenAcquirer.AcquireDownstreamTokenForAppAsync(
            _downstreamApplicationScope, cancellationToken);

        return await SendAsync(orderId, downstreamToken, caller, cancellationToken);
    }

    private async Task<object> SendAsync(
        string orderId,
        string downstreamToken,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken)
    {
        var requestUri = new Uri($"{_baseUrl.ToString().TrimEnd('/')}/api/orders/{Uri.EscapeDataString(orderId)}");
        using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", downstreamToken);
        request.Headers.Add(CallerIdentityCorrelation.ApplicationIdHeader, caller.ApplicationId);
        request.Headers.Add(CallerIdentityCorrelation.ObjectIdHeader, caller.ObjectId);

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
