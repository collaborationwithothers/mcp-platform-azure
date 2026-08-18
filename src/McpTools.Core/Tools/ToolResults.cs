using System.Text.Json.Serialization;

namespace McpTools.Tools;

/// <summary>The closed result family returned by an order lookup.</summary>
public abstract record OrderLookupResult;

/// <summary>Typed success result for a known order id.</summary>
public sealed record OrderStatus(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("updatedUtc")] string UpdatedUtc) : OrderLookupResult;

/// <summary>Typed not-found result for an unknown order id.</summary>
public sealed record OrderNotFound(
    [property: JsonPropertyName("orderId")] string OrderId,
    [property: JsonPropertyName("found")] bool Found,
    [property: JsonPropertyName("message")] string Message) : OrderLookupResult;

/// <summary>Fixed service metadata.</summary>
public sealed record ServiceInfo(
    [property: JsonPropertyName("serverName")] string ServerName,
    [property: JsonPropertyName("transport")] string Transport,
    [property: JsonPropertyName("dataDisclaimer")] string DataDisclaimer);

/// <summary>Fixed access guidance.</summary>
public sealed record AccessGuidance(
    [property: JsonPropertyName("summary")] string Summary,
    [property: JsonPropertyName("requiredEntitlements")] IReadOnlyList<ToolEntitlement> RequiredEntitlements,
    [property: JsonPropertyName("docsUrl")] string DocsUrl,
    [property: JsonPropertyName("dataDisclaimer")] string DataDisclaimer);

/// <summary>One tool's authorization rule for one caller identity mode.</summary>
public sealed record ToolEntitlement(
    [property: JsonPropertyName("tool")] string Tool,
    [property: JsonPropertyName("appliesTo")] string AppliesTo,
    [property: JsonPropertyName("allOf")] IReadOnlyList<AuthorizationRequirement> AllOf);

/// <summary>One control in a tool entitlement.</summary>
public sealed record AuthorizationRequirement(
    [property: JsonPropertyName("kind")] string Kind,
    [property: JsonPropertyName("enforcedAt")] string EnforcedAt,
    [property: JsonPropertyName("requiredValue")] string? RequiredValue);
