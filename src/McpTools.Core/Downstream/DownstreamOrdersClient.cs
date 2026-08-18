using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using McpTools.Identity;
using McpTools.Tools;

namespace McpTools.Downstream;

/// <summary>
/// Calls the synthetic Orders API with a newly acquired downstream token.
/// Host adapters supply the credential implementation and HTTP configuration.
/// </summary>
public sealed class DownstreamOrdersClient : IDownstreamOrdersClient
{
    private readonly IOboTokenAcquirer _oboTokenAcquirer;
    private readonly IAppTokenAcquirer _appTokenAcquirer;
    private readonly HttpClient _httpClient;
    private readonly Uri _baseUrl;
    private readonly string _downstreamScope;
    private readonly string _downstreamApplicationScope;

    public DownstreamOrdersClient(
        IOboTokenAcquirer oboTokenAcquirer,
        IAppTokenAcquirer appTokenAcquirer,
        HttpClient httpClient,
        Uri baseUrl,
        string downstreamScope,
        string downstreamApplicationScope)
    {
        _oboTokenAcquirer = oboTokenAcquirer;
        _appTokenAcquirer = appTokenAcquirer;
        _httpClient = httpClient;
        _baseUrl = baseUrl;
        _downstreamScope = downstreamScope;
        _downstreamApplicationScope = downstreamApplicationScope;
    }

    public async Task<OrderLookupResult> GetOrderStatusOnBehalfOfAsync(
        string orderId,
        string inboundUserAssertion,
        string tenantId,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken)
    {
        var downstreamToken = await _oboTokenAcquirer.AcquireDownstreamTokenAsync(
            inboundUserAssertion,
            tenantId,
            _downstreamScope,
            cancellationToken);

        return await SendAsync(orderId, downstreamToken, caller, cancellationToken);
    }

    public async Task<OrderLookupResult> GetOrderStatusAsApplicationAsync(
        string orderId,
        CallerIdentityCorrelation caller,
        CancellationToken cancellationToken)
    {
        var downstreamToken = await _appTokenAcquirer.AcquireDownstreamTokenForAppAsync(
            _downstreamApplicationScope,
            cancellationToken);

        return await SendAsync(orderId, downstreamToken, caller, cancellationToken);
    }

    private async Task<OrderLookupResult> SendAsync(
        string orderId,
        string downstreamToken,
        CallerIdentityCorrelation? caller,
        CancellationToken cancellationToken)
    {
        var requestUri = new Uri(
            $"{_baseUrl.ToString().TrimEnd('/')}/api/orders/{Uri.EscapeDataString(orderId)}");
        using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", downstreamToken);

        if (caller is not null)
        {
            request.Headers.Add(
                CallerIdentityCorrelation.ApplicationIdHeader,
                caller.ApplicationId);
            request.Headers.Add(
                CallerIdentityCorrelation.ObjectIdHeader,
                caller.ObjectId);
        }

        using var response = await _httpClient.SendAsync(request, cancellationToken);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            var notFound = await response.Content
                .ReadFromJsonAsync<DownstreamNotFoundBody>(cancellationToken)
                ?? throw new InvalidOperationException(
                    $"Downstream returned 404 for '{orderId}' with no body.");
            return new OrderNotFound(notFound.OrderId, Found: false, notFound.Message);
        }

        response.EnsureSuccessStatusCode();

        var found = await response.Content
            .ReadFromJsonAsync<DownstreamOrderStatusBody>(cancellationToken)
            ?? throw new InvalidOperationException(
                $"Downstream returned 200 for '{orderId}' with no body.");
        return new OrderStatus(found.OrderId, found.Status, found.UpdatedUtc);
    }

    private sealed record DownstreamOrderStatusBody(
        [property: JsonPropertyName("orderId")] string OrderId,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("updatedUtc")] string UpdatedUtc);

    private sealed record DownstreamNotFoundBody(
        [property: JsonPropertyName("orderId")] string OrderId,
        [property: JsonPropertyName("message")] string Message);
}
