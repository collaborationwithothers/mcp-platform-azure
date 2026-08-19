#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
builder="${repo_root}/scripts/prepare-mcp-promotion-payload.sh"
workflow="${repo_root}/.github/workflows/publish-mcp-server-image.yml"

source_commit="0123456789abcdef0123456789abcdef01234567"
image_reference="acrmcpplatform.azurecr.io/mcp-tools-aspnetcore:${source_commit}"
workload_client_id="11111111-1111-4111-8111-111111111111"
server_client_id="22222222-2222-4222-8222-222222222222"
resource_audience="api://mcp-server"
downstream_base_url="https://orders.example.test"
downstream_scope="api://orders-api/user_impersonation"
downstream_application_scope="api://orders-api/.default"
istio_revision="asm-1-29"
deployment_issue="152"
tests_run=0

build_payload() {
  local override="${1:-}"
  local -a command=(env \
    IMAGE_REFERENCE="${image_reference}" \
    WORKLOAD_IDENTITY_CLIENT_ID="${workload_client_id}" \
    MANAGED_ISTIO_REVISION="${istio_revision}" \
    SERVER_APPLICATION_CLIENT_ID="${server_client_id}" \
    RESOURCE_AUDIENCE="${resource_audience}" \
    DOWNSTREAM_BASE_URL="${downstream_base_url}" \
    DOWNSTREAM_SCOPE="${downstream_scope}" \
    DOWNSTREAM_APPLICATION_SCOPE="${downstream_application_scope}" \
    SOURCE_COMMIT="${source_commit}" \
    DEPLOYMENT_ISSUE="${deployment_issue}")
  if [ -n "${override}" ]; then
    command+=("${override}")
  fi
  command+=("${builder}" build)
  "${command[@]}"
}

validate_payload() {
  printf '%s\n' "$1" | "${builder}" validate-payload
}

expect_rejected() {
  local name="$1"
  shift
  tests_run=$((tests_run + 1))
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: ${name} was accepted." >&2
    exit 1
  fi
}

expected="$(jq -cn \
  --arg image_reference "${image_reference}" \
  --arg workload_identity_client_id "${workload_client_id}" \
  --arg managed_istio_revision "${istio_revision}" \
  --arg server_application_client_id "${server_client_id}" \
  --arg resource_audience "${resource_audience}" \
  --arg downstream_base_url "${downstream_base_url}" \
  --arg downstream_scope "${downstream_scope}" \
  --arg downstream_application_scope "${downstream_application_scope}" \
  --arg source_commit "${source_commit}" \
  --arg deployment_issue "${deployment_issue}" \
  '{event_type: "mcp-server-gitops-promotion-requested", client_payload: {
    image_reference: $image_reference,
    workload_identity_client_id: $workload_identity_client_id,
    managed_istio_revision: $managed_istio_revision,
    server_application_client_id: $server_application_client_id,
    resource_audience: $resource_audience,
    downstream_base_url: $downstream_base_url,
    downstream_scope: $downstream_scope,
    downstream_application_scope: $downstream_application_scope,
    source_commit: $source_commit,
    deployment_issue: $deployment_issue
  }}')"

actual="$(build_payload)"
tests_run=$((tests_run + 1))
if [ "${actual}" != "${expected}" ]; then
  echo "FAIL: valid values did not produce the exact dispatch payload." >&2
  diff -u <(printf '%s\n' "${expected}" | jq -S .) \
    <(printf '%s\n' "${actual}" | jq -S .) >&2 || true
  exit 1
fi

tests_run=$((tests_run + 1))
validated="$(validate_payload "${actual}")"
[ "${validated}" = "${expected}" ] || {
  echo "FAIL: the emitted payload did not pass its own public validator." >&2
  exit 1
}

workflow_contract=(
  'runs-on: ubuntu-latest'
  'output -raw registry_login_server'
  'output -raw mcp_workload_client_id'
  'output -raw mcp_server_application_client_id'
  'output -raw mcp_resource_audience'
  'output -raw istio_revision'
  'output -raw downstream_base_url'
  '.downstream_app.api_scope'
  '.downstream_app.application_scope'
  './scripts/prepare-mcp-promotion-payload.sh build'
  'src/McpTools.AspNetCore/Dockerfile'
)
for required in "${workflow_contract[@]}"; do
  tests_run=$((tests_run + 1))
  rg -Fq -- "${required}" "${workflow}" || {
    echo "FAIL: publisher workflow is missing ${required}." >&2
    exit 1
  }
done

payload_line="$(rg -n -F 'prepare-mcp-promotion-payload.sh build' "${workflow}" | cut -d: -f1)"
push_line="$(rg -n -F 'docker push' "${workflow}" | cut -d: -f1)"
dispatch_line="$(rg -n -F -- '--input "${RUNNER_TEMP}/mcp-promotion-payload.json"' "${workflow}" | cut -d: -f1)"
tests_run=$((tests_run + 1))
((payload_line < push_line && push_line < dispatch_line)) || {
  echo "FAIL: the workflow must validate before push and dispatch after push." >&2
  exit 1
}

expect_rejected "malformed image" build_payload \
  "IMAGE_REFERENCE=acrmcpplatform.azurecr.io/other:${source_commit}"
expect_rejected "image and commit mismatch" build_payload \
  "IMAGE_REFERENCE=acrmcpplatform.azurecr.io/mcp-tools-aspnetcore:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_rejected "malformed commit" build_payload "SOURCE_COMMIT=ABC123"
expect_rejected "wrong deployment issue" build_payload "DEPLOYMENT_ISSUE=151"
expect_rejected "malformed workload client ID" build_payload \
  "WORKLOAD_IDENTITY_CLIENT_ID=not-a-uuid"
expect_rejected "malformed server client ID" build_payload \
  "SERVER_APPLICATION_CLIENT_ID=not-a-uuid"
expect_rejected "identical client IDs" build_payload \
  "SERVER_APPLICATION_CLIENT_ID=${workload_client_id}"
expect_rejected "malformed resource audience" build_payload \
  "RESOURCE_AUDIENCE=https://mcp.example.test"
expect_rejected "malformed downstream base URL" build_payload \
  "DOWNSTREAM_BASE_URL=https://orders.example.test/api"
expect_rejected "malformed delegated scope" build_payload \
  "DOWNSTREAM_SCOPE=api://orders-api/read"
expect_rejected "malformed application scope" build_payload \
  "DOWNSTREAM_APPLICATION_SCOPE=api://orders-api/write"
expect_rejected "scopes for different resources" build_payload \
  "DOWNSTREAM_APPLICATION_SCOPE=api://other-api/.default"
expect_rejected "malformed Istio revision" build_payload \
  "MANAGED_ISTIO_REVISION=asm-1-29-default"

expect_rejected "invalid JSON payload" validate_payload '{'
expect_rejected "wrong event type" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c '.event_type = "wrong"')"
expect_rejected "missing dispatch field" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c 'del(.client_payload.resource_audience)')"
expect_rejected "unexpected dispatch field" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c '.client_payload.tenant_id = "forbidden"')"
expect_rejected "unexpected outer field" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c '.tenant_authority = "forbidden"')"
expect_rejected "non-string dispatch value" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c '.client_payload.deployment_issue = 152')"
expect_rejected "semantically invalid dispatch value" validate_payload \
  "$(printf '%s\n' "${expected}" | jq -c '.client_payload.source_commit = "wrong"')"

echo "PASS: ${tests_run} MCP promotion payload contract checks."
