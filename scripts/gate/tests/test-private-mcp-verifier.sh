#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/scripts/gate/verify-private-mcp.sh"
orders_script="${repo_root}/scripts/gate/verify-private-orders.sh"
workflow="${repo_root}/.github/workflows/ephemeral-env.yml"
program="${repo_root}/src/McpTools.AspNetCore/Program.cs"

bash -n "${script}"
bash -n "${orders_script}"

orders_test_dir="$(mktemp -d)"
trap 'rm -rf "${orders_test_dir}"' EXIT
mkdir -p "${orders_test_dir}/bin"
cat > "${orders_test_dir}/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

authorization=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--header" ]; then
    shift
    case "$1" in
      Authorization:*) authorization="${1#Authorization: }" ;;
    esac
  fi
  shift
done

if [ -z "${authorization}" ]; then
  status="${FAKE_ORDERS_ANONYMOUS_STATUS:-401}"
  challenge='Bearer'
else
  status="${FAKE_ORDERS_SERVER_TOKEN_STATUS:-401}"
  challenge='Bearer error="invalid_token"'
fi

printf 'HTTP/1.1 %s Test\r\nwww-authenticate: %s\r\n\r\n\n__ORDERS_STATUS__%s' \
  "${status}" "${challenge}" "${status}"
CURL
chmod +x "${orders_test_dir}/bin/curl"

orders_output="$(
  PATH="${orders_test_dir}/bin:${PATH}" \
  ORDERS_PRIVATE_HOST=orders.internal.example.test \
  ORDERS_PRIVATE_IP=10.0.0.8 \
  MCP_RESOURCE_AUDIENCE=api://mcp-server \
  ORDERS_RESOURCE_AUDIENCE=api://orders-api \
  MCP_SERVER_AUDIENCE_TOKEN=server-token \
  bash "${orders_script}"
)"
if [ "${orders_output}" != "private Orders audience isolation checks passed" ]; then
  echo "private Orders verifier did not accept the expected application rejections" >&2
  exit 1
fi

same_audience_output="$(
  PATH="${orders_test_dir}/bin:${PATH}" \
  ORDERS_PRIVATE_HOST=orders.internal.example.test \
  ORDERS_PRIVATE_IP=10.0.0.8 \
  MCP_RESOURCE_AUDIENCE=api://shared \
  ORDERS_RESOURCE_AUDIENCE=api://shared \
  MCP_SERVER_AUDIENCE_TOKEN=server-token \
  bash "${orders_script}" 2>&1 || true
)"
if [ "${same_audience_output}" != \
  "private Orders verification failed: the MCP and Orders resource audiences must differ" ]; then
  echo "private Orders verifier did not reject a shared audience" >&2
  exit 1
fi

ambiguous_status_output="$(
  PATH="${orders_test_dir}/bin:${PATH}" \
  FAKE_ORDERS_SERVER_TOKEN_STATUS=403 \
  ORDERS_PRIVATE_HOST=orders.internal.example.test \
  ORDERS_PRIVATE_IP=10.0.0.8 \
  MCP_RESOURCE_AUDIENCE=api://mcp-server \
  ORDERS_RESOURCE_AUDIENCE=api://orders-api \
  MCP_SERVER_AUDIENCE_TOKEN=server-token \
  bash "${orders_script}" 2>&1 || true
)"
if [ "${ambiguous_status_output}" != \
  "private Orders verification failed: the server-audience token returned 403; expected an application authentication rejection with 401" ]; then
  echo "private Orders verifier did not reject an ambiguous response status" >&2
  exit 1
fi
if [[ "${same_audience_output}${ambiguous_status_output}" == *server-token* ]]; then
  echo "private Orders verifier leaked the bearer token in a diagnostic" >&2
  exit 1
fi

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
  'ORDERS_RESOURCE_AUDIENCE' \
  '(.roles // []) | index("Orders.Read") != null' \
  'MCP_SERVER_AUDIENCE_TOKEN="${app_token}"' \
  'bash scripts/gate/verify-private-orders.sh' \
  'orders_trace_id="$(openssl rand -hex 16)"' \
  'traceparent: ${traceparent}' \
  'orders_trace_id=%s' \
  '.result.structuredContent.orderId == "CONTOSO-1001"' \
  '.result.structuredContent.status == "Delivered"' \
  '.result.structuredContent.updatedUtc == "2026-06-01T14:05:00Z"' \
  'tool error without an application-role marker' \
  'successful result without structuredContent' \
  'structured fixture mismatch' \
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
  'for application in mcp-platform-mcp mcp-platform-orders mcp-platform-demo; do' \
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
  '--query api.requestedAccessTokenVersion' \
  'Orders access token version mismatch' \
  'Orders resource app: requestedAccessTokenVersion=2' \
  '.spec.template.spec.serviceAccountName == "mcp-server"' \
  '.spec.template.metadata.labels["azure.workload.identity/use"] == "true"' \
  'kubectl get serviceaccount mcp-server' \
  '.metadata.annotations["azure.workload.identity/client-id"] // empty' \
  '.name == "AZURE_CLIENT_ID" and .value == $client_id' \
  'contains("clientsecret")' \
  'MCP pod ${pod}: workload identity injected; no client secret' \
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
  "MCP pod \${pod}: Istio init interception=REDIRECT configured" \
  'kubectl rollout status deployment/orders-api -n mcp-platform --timeout=120s' \
  '.spec.template.spec.serviceAccountName == "orders-api"' \
  '.spec.template.metadata.labels["azure.workload.identity/use"] == "true"' \
  '(.spec.template.spec.imagePullSecrets // []) | length == 0' \
  '.metadata.annotations["azure.workload.identity/client-id"] // empty' \
  '.name == "AZURE_CLIENT_ID" and .value == $client_id' \
  '"AZURE_TENANT_ID"' \
  '"AZURE_FEDERATED_TOKEN_FILE"' \
  '"AZURE_AUTHORITY_HOST"' \
  'workload identity injected; Ready=true; no image pull secret'; do
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
  'orders_trace_id: ${{ steps.private_mcp_data_plane.outputs.orders_trace_id }}' \
  'S1_TFVARS_JSON: ${{ secrets.S1_TFVARS_JSON }}' \
  "orders_resource_audience=\"\$(jq -er '.downstream_entra_auth.allowed_audiences[0]' <<< \"\${S1_TFVARS_JSON}\")\"" \
  'ORDERS_RESOURCE_AUDIENCE="${orders_resource_audience}"' \
  'id: private_mcp_data_plane'; do
  if ! grep --fixed-strings --quiet "${required}" <<< "${data_plane_job}"; then
    echo "private VNet verifier PRM correlation contract missing: ${required}" >&2
    exit 1
  fi
done

observability_job="$(workflow_job verify-private-observability)"
if [ -z "${observability_job}" ]; then
  echo "private observability job is missing" >&2
  exit 1
fi
for required in \
  "if: always() && inputs.action == 'verify-private'" \
  'needs: verify-private-data-plane' \
  'runs-on: ubuntu-latest' \
  'actions/checkout@v7' \
  'hashicorp/setup-terraform@v4' \
  'terraform_version: 1.15.8' \
  'prm_verification_id="${{ needs.verify-private-data-plane.outputs.prm_verification_id }}"' \
  'orders_trace_id="${{ needs.verify-private-data-plane.outputs.orders_trace_id }}"' \
  'data_plane_result="${{ needs.verify-private-data-plane.result }}"' \
  "kubectl logs \"\${pod}\" -n mcp-platform -c mcp-server --since=10m" \
  "'AADSTS[0-9]+'" \
  'scope contract matches=${scope_contract_matches}' \
  'audience contract matches=${audience_contract_matches}' \
  'Raw pod logs and identifiers were not emitted.' \
  'kubectl logs "${pod}" -n mcp-platform -c mcp-server' \
  'Private MCP request context /\\.well-known/oauth-protected-resource/mcp https .* ${prm_verification_id}$' \
  'Private MCP request context /\\.well-known/oauth-protected-resource/mcp https ((::ffff:)?127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|::1) ${prm_verification_id}$' \
  '::error title=Private MCP forwarded PRM context missing::' \
  '::error title=Private MCP forwarded PRM peer is not loopback::The correlated PRM request recorded immediate peer ${observed_peer:-unparsed}.' \
  'Private MCP PRM request context observed: scheme=https; peer=loopback' \
  'terraform -chdir=infra/compositions/shared-observability-core output -raw log_analytics_workspace_id' \
  'az monitor log-analytics workspace show' \
  '--ids "${workspace_resource_id}"' \
  '--query customerId' \
  'AppRequests' \
  'AppDependencies' \
  'OperationId == trace_id' \
  'Url endswith "/api/orders/CONTOSO-1001"' \
  'Data contains_cs "/api/orders/CONTOSO-1001"' \
  '.[0].requestCount == 1 and .[0].dependencyCount >= 1' \
  'Orders workload identity telemetry observed: correlated request=1; dependency>=1'; do
  if ! grep --fixed-strings --quiet -- "${required}" <<< "${observability_job}"; then
    echo "private observability verifier contract missing: ${required}" >&2
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
