namespace McpTools.Core;

/// <summary>
/// A host-neutral tool result. Exactly one of <see cref="Value"/> and
/// <see cref="Error"/> is populated by the application core.
/// </summary>
public sealed class ToolOutcome<T>
    where T : class
{
    private ToolOutcome(T? value, ToolError? error)
    {
        Value = value;
        Error = error;
    }

    public T? Value { get; }

    public ToolError? Error { get; }

    public static ToolOutcome<T> Success(T value) =>
        new(value ?? throw new ArgumentNullException(nameof(value)), null);

    public static ToolOutcome<T> Forbidden(string message) =>
        new(null, new ToolError(message));
}

/// <summary>A tool error that a host adapter can map to its wire format.</summary>
public sealed record ToolError(string Message);

/// <summary>
/// The delegated path was authorized but its host supplied no user assertion
/// for the on-behalf-of exchange.
/// </summary>
public sealed class InboundAccessTokenRequiredException : InvalidOperationException
{
    public InboundAccessTokenRequiredException()
        : base("get_order_status: an inbound access token is required for the delegated OBO path.")
    {
    }
}
