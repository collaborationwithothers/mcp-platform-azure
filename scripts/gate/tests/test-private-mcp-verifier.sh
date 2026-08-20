#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/scripts/gate/verify-private-mcp.sh"
workflow="${repo_root}/.github/workflows/ephemeral-env.yml"
program="${repo_root}/src/McpTools.AspNetCore/Program.cs"

bash -n "${script}"

for command in curl jq dig openssl; do
  if ! grep --fixed-strings --quiet "${command}" "${script}"; then
    echo "private verifier does not use ${command}" >&2
    exit 1
  fi
done

if grep -E --quiet '(^|[[:space:];|&])(terraform|kubectl|az|dotnet|pwsh|apt|pip|npm)([[:space:];|&]|$)' "${script}"; then
  echo "private verifier contains a forbidden VNet-runner command" >&2
  exit 1
fi

response_functions="$(awk '
  /^fail\(\)/ { capture = 1 }
  /^mcp_body\(\)/ { capture = 1 }
  /^json_rpc\(\)/ { capture = 1 }
  capture { print }
  capture && /^}/ { capture = 0 }
' "${script}")"

diagnostic="$(
  export response_functions
  bash <<'BASH' 2>&1 || true
eval "${response_functions}"
host="mcp.internal.example.test"
MCP_PRIVATE_IP="10.0.0.4"
resource_url="https://${host}/mcp"
curl() {
  printf 'private response body\n__MCP_RESPONSE_META__403\ttext/plain'
}
json_rpc "$(mcp_body 'private-token' '{}')" > /dev/null
BASH
)"
if [ "${diagnostic}" != "private MCP verification failed: the MCP JSON-RPC request returned HTTP 403 with content type text/plain" ]; then
  echo "private verifier did not produce the expected sanitized HTTP diagnostic" >&2
  exit 1
fi
if [[ "${diagnostic}" == *'private response body'* || "${diagnostic}" == *'private-token'* ]]; then
  echo "private verifier leaked a response body or bearer token in its diagnostic" >&2
  exit 1
fi

for required in \
  'MCP_PRIVATE_HOST' \
  'MCP_PRIVATE_IP' \
  'MCP_RESOURCE_AUDIENCE' \
  'dig @1.1.1.1 +short AAAA' \
  '-connect "${MCP_PRIVATE_IP}:443"' \
  'openssl rand -hex 16' \
  'prm_verification_id=%s' \
  'X-Private-Mcp-Verification: ${prm_verification_id}' \
  '__MCP_RESPONSE_META__%{http_code}\t%{content_type}' \
  'the MCP JSON-RPC request returned HTTP ${http_status} with content type ${content_type:-none}' \
  'the MCP response with content type ${content_type:-none} was neither JSON nor a JSON SSE event' \
  'TEST_CLIENT_SECRET' \
  'TEST_CLIENT_WITHOUT_ROLE_SECRET' \
  'unset app_token roleless_token wrong_audience_token'; do
  if ! grep --fixed-strings --quiet -- "${required}" "${script}"; then
    echo "private verifier lost required secret handling: ${required}" >&2
    exit 1
  fi
done

for required in \
  'X-Private-Mcp-Verification' \
  'Private MCP request context {Route} {Scheme} {ImmediatePeerIpAddress} {VerificationId}' \
  'isProtectedResourceMetadataRequest' \
  'var immediatePeerIpAddress = context.Connection.RemoteIpAddress?.ToString();' \
  'requestVerificationId.Length == 32' \
  '"/.well-known/oauth-protected-resource/mcp"' \
  '"/mcp"'; do
  if ! grep --fixed-strings --quiet "${required}" "${program}"; then
    echo "private verifier application correlation contract missing: ${required}" >&2
    exit 1
  fi
done

peer_capture_line="$(grep -n --fixed-strings \
  'var immediatePeerIpAddress = context.Connection.RemoteIpAddress?.ToString();' \
  "${program}" | cut -d: -f1)"
forwarded_headers_line="$(grep -n --fixed-strings 'app.UseForwardedHeaders();' \
  "${program}" | cut -d: -f1)"
if [ "${peer_capture_line}" -ge "${forwarded_headers_line}" ]; then
  echo "private request context must capture the immediate peer before forwarded headers" >&2
  exit 1
fi

request_context_log="$(awk '
  /app\.Logger\.LogInformation\(/ { capture = 1 }
  capture { print }
  capture && /^[[:space:]]*verificationId\);/ { exit }
' "${program}")"
if grep --fixed-strings --quiet 'context.Request.Path' <<< "${request_context_log}"; then
  echo "private verifier must not log the raw request path" >&2
  exit 1
fi

workflow_job() {
  local job_name="$1"

  awk -v header="  ${job_name}:" '
    $0 == header { capture = 1 }
    capture && /^  [[:alnum:]_-]+:$/ && $0 != header { exit }
    capture { print }
  ' "${workflow}"
}

for required in \
  '          - verify-private' \
  'group: ${{ vars.PRIVATE_MCP_VNET_RUNNER_GROUP }}' \
  'labels: ${{ vars.PRIVATE_MCP_VNET_RUNNER_LABEL }}' \
  'bash scripts/gate/verify-private-mcp.sh'; do
  if ! grep --fixed-strings --quiet "${required}" "${workflow}"; then
    echo "private verifier workflow contract missing: ${required}" >&2
    exit 1
  fi
done

control_plane_job="$(workflow_job verify-private-control-plane)"
if [ -z "${control_plane_job}" ]; then
  echo "private control-plane job is missing" >&2
  exit 1
fi

for required in \
  'for application in mcp-platform-mcp mcp-platform-demo; do' \
  'Istio revision contract mcp-platform: installed=${installed_istio_revisions}; namespace=${mcp_namespace_revision}' \
  'restartPolicy == "Always"' \
  '.status.initContainerStatuses[]?' \
  "Argo CD application \${application}: sync=\${sync_status}; health=\${health_status}; message=\${health_message}" \
  '::error title=Argo CD application not ready::' \
  "MCP deployment mcp-server: desired=\${desired_replicas}; updated=\${updated_replicas}; available=\${available_replicas}" \
  "MCP pod states: \${mcp_pod_states}" \
  "MCP ReplicaSet states: \${mcp_replica_set_states}" \
  '::error title=Private MCP certificate not ready::' \
  '::error title=Istio sidecar missing::' \
  '::error title=Istio REDIRECT init mode missing::' \
  'hashicorp/setup-terraform@v4' \
  'terraform_version: 1.15.8' \
  'terraform -chdir=infra/compositions/shared-observability-core init -input=false' \
  'terraform -chdir=infra/compositions/shared-observability-core output -raw application_insights_id' \
  'Private MCP deployment image reference: ${deployed_image}' \
  '::add-mask::${component_id}' \
  'az rest' \
  '--method get' \
  'https://management.azure.com${component_id}?api-version=2020-02-02-preview' \
  'upper: properties.DisableLocalAuth, lower: properties.disableLocalAuth' \
  'if .upper != null then if (.upper | type) == "boolean" then .upper else "invalid" end elif .lower != null then if (.lower | type) == "boolean" then .lower else "invalid" end else "missing" end' \
  'Application Insights DisableLocalAuth=true' \
  '::error title=Application Insights local authentication enabled::Application Insights DisableLocalAuth=false; expected true.' \
  '::error title=Application Insights local authentication state missing::Application Insights DisableLocalAuth was not returned; expected true.' \
  '::error title=Application Insights local authentication state invalid::Application Insights DisableLocalAuth was not a Boolean; expected true.' \
  "Private MCP certificate mcp-platform-mcp-tls: Ready=\${certificate_ready}" \
  "MCP pod \${pod}: istio-proxy present" \
  "MCP pod \${pod}: Istio init interception=REDIRECT configured"; do
  if ! grep --fixed-strings --quiet -- "${required}" <<< "${control_plane_job}"; then
    echo "private control-plane diagnostic missing: ${required}" >&2
    exit 1
  fi
done

if grep --fixed-strings --quiet 'az resource list' <<< "${control_plane_job}"; then
  echo "private control-plane verifier must target the shared-observability state output" >&2
  exit 1
fi

if [ "$(jq -nr '({upper: false, lower: null} | if .upper != null then if (.upper | type) == "boolean" then .upper else "invalid" end elif .lower != null then if (.lower | type) == "boolean" then .lower else "invalid" end else "missing" end)')" != "false" ]; then
  echo "private verifier must preserve DisableLocalAuth=false" >&2
  exit 1
fi

if [ "$(jq -nr '({upper: "true", lower: null} | if .upper != null then if (.upper | type) == "boolean" then .upper else "invalid" end elif .lower != null then if (.lower | type) == "boolean" then .lower else "invalid" end else "missing" end)')" != "invalid" ]; then
  echo "private verifier must reject a non-Boolean DisableLocalAuth value" >&2
  exit 1
fi

if grep --fixed-strings --quiet 'jq --exit-status' <<< "${control_plane_job}"; then
  echo "private control-plane checks must report failed prerequisites" >&2
  exit 1
fi

data_plane_job="$(workflow_job verify-private-data-plane)"
if grep -E --quiet '(^|[[:space:];|&])(terraform|kubectl|az|dotnet|pwsh|apt|pip|npm)([[:space:];|&]|$)' <<< "${data_plane_job}"; then
  echo "the VNet data-plane job contains a forbidden command" >&2
  exit 1
fi
for required in \
  'outputs:' \
  'prm_verification_id: ${{ steps.private_mcp_data_plane.outputs.prm_verification_id }}' \
  'id: private_mcp_data_plane'; do
  if ! grep --fixed-strings --quiet "${required}" <<< "${data_plane_job}"; then
    echo "private VNet verifier PRM correlation contract missing: ${required}" >&2
    exit 1
  fi
done

request_context_job="$(workflow_job verify-private-request-context)"
if [ -z "${request_context_job}" ]; then
  echo "private request-context job is missing" >&2
  exit 1
fi
for required in \
  'needs: verify-private-data-plane' \
  'runs-on: ubuntu-latest' \
  'prm_verification_id="${{ needs.verify-private-data-plane.outputs.prm_verification_id }}"' \
  'kubectl logs "${pod}" -n mcp-platform -c mcp-server' \
  'Private MCP request context /\\.well-known/oauth-protected-resource/mcp https .* ${prm_verification_id}$' \
  'Private MCP request context /\\.well-known/oauth-protected-resource/mcp https ((::ffff:)?127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|::1) ${prm_verification_id}$' \
  '::error title=Private MCP forwarded PRM context missing::' \
  '::error title=Private MCP forwarded PRM peer is not loopback::The correlated PRM request recorded immediate peer ${observed_peer:-unparsed}.' \
  'Private MCP PRM request context observed: scheme=https; peer=loopback'; do
  if ! grep --fixed-strings --quiet "${required}" <<< "${request_context_job}"; then
    echo "private request-context verifier contract missing: ${required}" >&2
    exit 1
  fi
done

loopback_pattern='Private MCP request context /\.well-known/oauth-protected-resource/mcp https ((::ffff:)?127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|::1) [0-9a-f]{32}$'
if ! grep --extended-regexp --quiet "${loopback_pattern}" \
  <<< 'Private MCP request context /.well-known/oauth-protected-resource/mcp https ::ffff:127.0.0.6 e0320b12efbe54b4afbc673051c7cb0a'; then
  echo "private request-context verifier must accept mapped IPv4 loopback" >&2
  exit 1
fi
if grep --extended-regexp --quiet "${loopback_pattern}" \
  <<< 'Private MCP request context /.well-known/oauth-protected-resource/mcp https 10.20.1.4 e0320b12efbe54b4afbc673051c7cb0a'; then
  echo "private request-context verifier must reject a non-loopback peer" >&2
  exit 1
fi

echo "private MCP verifier keeps the VNet runner data-plane-only"
