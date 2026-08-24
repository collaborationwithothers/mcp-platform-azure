#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
builder="${repo_root}/scripts/prepare-orders-promotion-payload.sh"
workflow="${repo_root}/.github/workflows/publish-mcp-server-image.yml"

source_commit="0123456789abcdef0123456789abcdef01234567"
image_reference="acrmcpplatform.azurecr.io/downstream-orders-api:${source_commit}"
workload_client_id="11111111-1111-4111-8111-111111111111"
orders_audience="api://orders-api"
downstream_scope="${orders_audience}/user_impersonation"
downstream_application_scope="${orders_audience}/.default"
downstream_base_url="https://mcp.internal.consultwithcloud.com"
istio_revision="asm-1-29"
deployment_issue="183"
tests_run=0

build_payload() {
  local override="${1:-}"
  local -a command=(env \
    IMAGE_REFERENCE="${image_reference}" \
    WORKLOAD_IDENTITY_CLIENT_ID="${workload_client_id}" \
    MANAGED_ISTIO_REVISION="${istio_revision}" \
    ORDERS_AUDIENCE="${orders_audience}" \
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
  --arg orders_audience "${orders_audience}" \
  --arg downstream_base_url "${downstream_base_url}" \
  --arg downstream_scope "${downstream_scope}" \
  --arg downstream_application_scope "${downstream_application_scope}" \
  --arg source_commit "${source_commit}" \
  --arg deployment_issue "${deployment_issue}" \
  '{event_type: "orders-api-gitops-promotion-requested", client_payload: {
    image_reference: $image_reference,
    workload_identity_client_id: $workload_identity_client_id,
    managed_istio_revision: $managed_istio_revision,
    orders_audience: $orders_audience,
    downstream_base_url: $downstream_base_url,
    downstream_scope: $downstream_scope,
    downstream_application_scope: $downstream_application_scope,
    source_commit: $source_commit,
    deployment_issue: $deployment_issue
  }}')"

actual="$(build_payload)"
tests_run=$((tests_run + 1))
[ "${actual}" = "${expected}" ] || {
  echo "FAIL: valid values did not produce the exact dispatch payload." >&2
  exit 1
}

tests_run=$((tests_run + 1))
[ "$(validate_payload "${actual}")" = "${expected}" ] || {
  echo "FAIL: the emitted payload did not pass its validator." >&2
  exit 1
}

workflow_contract=(
  'workload:'
  'orders-api'
  'output -raw registry_login_server'
  'output -raw orders_workload_client_id'
  'output -raw mcp_private_hostname'
  'output -raw istio_revision'
  '.downstream_entra_auth.allowed_audiences[0]'
  '.downstream_app.api_scope'
  '.downstream_app.application_scope'
  './scripts/prepare-orders-promotion-payload.sh build'
  'src/DownstreamOrdersApi/Dockerfile'
)
for required in "${workflow_contract[@]}"; do
  tests_run=$((tests_run + 1))
  grep -Fq -- "${required}" "${workflow}" || {
    echo "FAIL: publisher workflow is missing ${required}." >&2
    exit 1
  }
done

expect_rejected "malformed image" build_payload \
  "IMAGE_REFERENCE=acrmcpplatform.azurecr.io/other:${source_commit}"
expect_rejected "image and commit mismatch" build_payload \
  "IMAGE_REFERENCE=acrmcpplatform.azurecr.io/downstream-orders-api:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
expect_rejected "malformed commit" build_payload "SOURCE_COMMIT=ABC123"
expect_rejected "wrong deployment issue" build_payload "DEPLOYMENT_ISSUE=184"
expect_rejected "malformed workload client ID" build_payload \
  "WORKLOAD_IDENTITY_CLIENT_ID=not-a-uuid"
expect_rejected "malformed audience" build_payload \
  "ORDERS_AUDIENCE=https://orders.example.test"
expect_rejected "malformed private base URL" build_payload \
  "DOWNSTREAM_BASE_URL=http://mcp.internal.consultwithcloud.com"
expect_rejected "base URL with a path" build_payload \
  "DOWNSTREAM_BASE_URL=https://mcp.internal.consultwithcloud.com/api"
expect_rejected "malformed delegated scope" build_payload \
  "DOWNSTREAM_SCOPE=${orders_audience}/read"
expect_rejected "malformed application scope" build_payload \
  "DOWNSTREAM_APPLICATION_SCOPE=${orders_audience}/write"
expect_rejected "scope for a different audience" build_payload \
  "DOWNSTREAM_SCOPE=api://other-api/user_impersonation"
expect_rejected "application scope for a different audience" build_payload \
  "DOWNSTREAM_APPLICATION_SCOPE=api://other-api/.default"
expect_rejected "malformed Istio revision" build_payload \
  "MANAGED_ISTIO_REVISION=asm-1-29-default"

expect_rejected "invalid JSON payload" validate_payload '{'
expect_rejected "wrong event type" validate_payload \
  "$(jq -c '.event_type = "wrong"' <<< "${expected}")"
expect_rejected "missing dispatch field" validate_payload \
  "$(jq -c 'del(.client_payload.orders_audience)' <<< "${expected}")"
expect_rejected "unexpected dispatch field" validate_payload \
  "$(jq -c '.client_payload.tenant_id = "forbidden"' <<< "${expected}")"
expect_rejected "non-string dispatch value" validate_payload \
  "$(jq -c '.client_payload.deployment_issue = 183' <<< "${expected}")"

echo "PASS: ${tests_run} Orders promotion payload contract checks."
