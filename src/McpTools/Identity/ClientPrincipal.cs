using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace McpTools.Identity;

/// <summary>
/// The decoded X-MS-CLIENT-PRINCIPAL header Easy Auth (App Service / Functions
/// built-in auth, auth_settings_v2) injects on every request it has validated.
/// The header value is Base64-encoded JSON whose envelope shape
/// (<c>auth_typ</c> / <c>name_typ</c> / <c>role_typ</c> / a <c>claims</c> array
/// of <c>{typ,val}</c> objects) is documented and verified (COMPATIBILITY.md,
/// docs/security.md; Microsoft Learn "Work with user identities").
///
/// This type is pure, host-independent parsing only: no claim-semantics
/// decision lives here (that is <see cref="IdentityModeResolver"/>), so it is
/// unit-testable with plain strings and no Functions/MCP-extension dependency.
///
/// In this topology Easy Auth injects X-MS-CLIENT-PRINCIPAL purely from
/// validating the bearer APIM forwards; the token-store header
/// X-MS-TOKEN-AAD-ACCESS-TOKEN is expected ABSENT because no token store is
/// enabled (verified: the token-store header requires the token store; see
/// COMPATIBILITY.md and docs/security.md). Whether claims mapping is fully
/// populated without the token store is a documented ambiguity flagged for
/// live confirmation (docs/security.md, "trust chain").
/// </summary>
public sealed class ClientPrincipal
{
    /// <summary>The header name Easy Auth injects the decoded principal under.</summary>
    public const string HeaderName = "X-MS-CLIENT-PRINCIPAL";

    private ClientPrincipal(IReadOnlyList<ClientPrincipalClaim> claims) => Claims = claims;

    /// <summary>
    /// The claims carried by the validated token, with their original claim
    /// types as Easy Auth emits them. Never null; empty if the principal
    /// carried no claims array.
    /// </summary>
    public IReadOnlyList<ClientPrincipalClaim> Claims { get; }

    /// <summary>
    /// Decodes and parses the Base64 JSON header value. Returns false (and a
    /// null principal) for a missing, non-Base64, or non-JSON-object value:
    /// callers treat that as a malformed principal, never as a silent empty
    /// one.
    /// </summary>
    public static bool TryParse(string? headerValue, out ClientPrincipal? principal)
    {
        principal = null;
        if (string.IsNullOrWhiteSpace(headerValue))
        {
            return false;
        }

        byte[] decoded;
        try
        {
            decoded = Convert.FromBase64String(headerValue);
        }
        catch (FormatException)
        {
            return false;
        }

        ClientPrincipalEnvelope? envelope;
        try
        {
            envelope = JsonSerializer.Deserialize<ClientPrincipalEnvelope>(Encoding.UTF8.GetString(decoded));
        }
        catch (JsonException)
        {
            return false;
        }

        if (envelope is null)
        {
            return false;
        }

        var claims = envelope.Claims is null
            ? []
            : envelope.Claims
                .Where(c => c.Typ is not null)
                .Select(c => new ClientPrincipalClaim(c.Typ!, c.Val ?? string.Empty))
                .ToArray();

        principal = new ClientPrincipal(claims);
        return true;
    }

    private sealed class ClientPrincipalEnvelope
    {
        [JsonPropertyName("claims")]
        public List<RawClaim>? Claims { get; set; }
    }

    private sealed class RawClaim
    {
        [JsonPropertyName("typ")]
        public string? Typ { get; set; }

        [JsonPropertyName("val")]
        public string? Val { get; set; }
    }
}

/// <summary>A single decoded claim: its original type string and its value.</summary>
public sealed record ClientPrincipalClaim(string Typ, string Val);
