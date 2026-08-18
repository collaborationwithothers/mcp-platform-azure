using System.Security.Claims;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace McpTools.Identity;

/// <summary>
/// The decoded X-MS-CLIENT-PRINCIPAL header that App Service and Functions
/// built-in auth (auth_settings_v2) injects on every validated request.
/// The header value is Base64-encoded JSON whose envelope shape
/// (<c>auth_typ</c> / <c>name_typ</c> / <c>role_typ</c> / a <c>claims</c> array
/// of <c>{typ,val}</c> objects) is documented and verified (COMPATIBILITY.md,
/// docs/security.md; Microsoft Learn "Work with user identities").
///
/// This type is part of the Functions host adapter. It parses the host-specific
/// envelope but leaves claim semantics to the shared core.
///
/// In this topology built-in auth injects X-MS-CLIENT-PRINCIPAL purely from
/// validating the bearer APIM forwards; the token-store header
/// X-MS-TOKEN-AAD-ACCESS-TOKEN is expected ABSENT because no token store is
/// enabled (verified: the token-store header requires the token store; see
/// COMPATIBILITY.md and docs/security.md). Whether claims mapping is fully
/// populated without the token store is a documented ambiguity flagged for
/// live confirmation (docs/security.md, "trust chain").
/// </summary>
public sealed class ClientPrincipal
{
    /// <summary>The header name built-in auth injects the decoded principal under.</summary>
    public const string HeaderName = "X-MS-CLIENT-PRINCIPAL";

    private ClientPrincipal(IReadOnlyList<ClientPrincipalClaim> claims) => Claims = claims;

    /// <summary>
    /// The claims carried by the validated token, with their original claim
    /// types as built-in auth emits them. Never null; empty if the principal
    /// carried no claims array.
    /// </summary>
    public IReadOnlyList<ClientPrincipalClaim> Claims { get; }

    /// <summary>Returns all values whose claim type matches any supplied alias.</summary>
    public IEnumerable<string> ValuesFor(params string[] claimTypeAliases) =>
        Claims
            .Where(claim => claimTypeAliases.Any(alias =>
                string.Equals(claim.Typ, alias, StringComparison.OrdinalIgnoreCase)))
            .Select(claim => claim.Val);

    /// <summary>Returns the first non-empty value matching any supplied alias.</summary>
    public string? FirstValueFor(params string[] claimTypeAliases) =>
        ValuesFor(claimTypeAliases).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

    /// <summary>
    /// Converts the built-in auth envelope into the host-neutral claims shape the
    /// shared application core accepts.
    /// </summary>
    public ClaimsPrincipal ToClaimsPrincipal() =>
        new(new ClaimsIdentity(
            Claims.Select(claim => new Claim(claim.Typ, claim.Val)),
            authenticationType: "EasyAuth"));

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
