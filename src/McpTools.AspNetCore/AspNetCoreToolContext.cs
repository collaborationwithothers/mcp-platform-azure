using System.Net.Http.Headers;
using McpTools.Identity;

namespace McpTools.AspNetCore;

internal static class AspNetCoreToolContext
{
    internal static (HttpContext HttpContext, CallerIdentity Caller) Resolve(
        IHttpContextAccessor accessor,
        string toolName)
    {
        var context = accessor.HttpContext
            ?? throw new InvalidOperationException(
                $"{toolName}: no authenticated HTTP caller is available.");
        return (context, CallerIdentityResolver.Resolve(context.User));
    }

    internal static string GetValidatedBearerToken(HttpContext context, string toolName)
    {
        var rawHeader = context.Request.Headers.Authorization.ToString();
        if (!AuthenticationHeaderValue.TryParse(rawHeader, out var authorization)
            || !string.Equals(
                authorization.Scheme,
                "Bearer",
                StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(authorization.Parameter))
        {
            throw new InvalidOperationException(
                $"{toolName}: the validated delegated request has no bearer access token for OBO.");
        }

        return authorization.Parameter;
    }
}
