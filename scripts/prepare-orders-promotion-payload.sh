#!/usr/bin/env bash

set -euo pipefail

reject() {
  echo "$1" >&2
  exit 1
}

validate_values() {
  [[ "${SOURCE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || \
    reject "source_commit must be a 40-character lowercase commit SHA."
  [[ "${IMAGE_REFERENCE:-}" =~ ^[a-z0-9]{5,50}\.azurecr\.io/downstream-orders-api:[0-9a-f]{40}$ ]] || \
    reject "image_reference must be a commit-tagged downstream-orders-api ACR image."
  [[ "${IMAGE_REFERENCE##*:}" = "${SOURCE_COMMIT}" ]] || \
    reject "image tag must equal source_commit."

  local uuid
  uuid='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
  [[ "${WORKLOAD_IDENTITY_CLIENT_ID:-}" =~ $uuid ]] || \
    reject "workload_identity_client_id must be a UUID."
  [[ "${MANAGED_ISTIO_REVISION:-}" =~ ^asm-[0-9]+-[0-9]+$ ]] || \
    reject "managed_istio_revision must match asm-X-Y."
  [[ "${ORDERS_AUDIENCE:-}" =~ ^api://[A-Za-z0-9._~:/-]+$ ]] || \
    reject "orders_audience must be an api URI."
  [[ "${DOWNSTREAM_BASE_URL:-}" =~ ^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/?$ ]] || \
    reject "downstream_base_url must be an HTTPS origin."
  [[ "${DOWNSTREAM_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/user_impersonation$ ]] || \
    reject "downstream_scope must end with /user_impersonation."
  [[ "${DOWNSTREAM_APPLICATION_SCOPE:-}" =~ ^api://[A-Za-z0-9._~:/-]+/\.default$ ]] || \
    reject "downstream_application_scope must end with /.default."
  [[ "${DOWNSTREAM_SCOPE%/user_impersonation}" = "${ORDERS_AUDIENCE}" ]] || \
    reject "downstream_scope must name orders_audience."
  [[ "${DOWNSTREAM_APPLICATION_SCOPE%/.default}" = "${ORDERS_AUDIENCE}" ]] || \
    reject "downstream_application_scope must name orders_audience."
  [[ "${DEPLOYMENT_ISSUE:-}" = 183 ]] || \
    reject "deployment_issue must be 183."
}

build_payload() {
  validate_values
  jq -cn \
    --arg image_reference "${IMAGE_REFERENCE}" \
    --arg workload_identity_client_id "${WORKLOAD_IDENTITY_CLIENT_ID}" \
    --arg managed_istio_revision "${MANAGED_ISTIO_REVISION}" \
    --arg orders_audience "${ORDERS_AUDIENCE}" \
    --arg downstream_base_url "${DOWNSTREAM_BASE_URL}" \
    --arg downstream_scope "${DOWNSTREAM_SCOPE}" \
    --arg downstream_application_scope "${DOWNSTREAM_APPLICATION_SCOPE}" \
    --arg source_commit "${SOURCE_COMMIT}" \
    --arg deployment_issue "${DEPLOYMENT_ISSUE}" \
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
    }}'
}

validate_payload() {
  local payload expected_client_keys
  payload="$(cat)"
  expected_client_keys='[
    "deployment_issue",
    "downstream_application_scope",
    "downstream_base_url",
    "downstream_scope",
    "image_reference",
    "managed_istio_revision",
    "orders_audience",
    "source_commit",
    "workload_identity_client_id"
  ]'

  jq -e --argjson expected_client_keys "${expected_client_keys}" '
    type == "object" and
    keys == ["client_payload", "event_type"] and
    .event_type == "orders-api-gitops-promotion-requested" and
    (.client_payload | type == "object") and
    (.client_payload | keys == $expected_client_keys) and
    (.client_payload | all(.[]; type == "string"))
  ' <<< "${payload}" >/dev/null || \
    reject "dispatch payload must contain only the exact Orders promotion contract."

  IMAGE_REFERENCE="$(jq -er '.client_payload.image_reference' <<< "${payload}")"
  WORKLOAD_IDENTITY_CLIENT_ID="$(jq -er '.client_payload.workload_identity_client_id' <<< "${payload}")"
  MANAGED_ISTIO_REVISION="$(jq -er '.client_payload.managed_istio_revision' <<< "${payload}")"
  ORDERS_AUDIENCE="$(jq -er '.client_payload.orders_audience' <<< "${payload}")"
  DOWNSTREAM_BASE_URL="$(jq -er '.client_payload.downstream_base_url' <<< "${payload}")"
  DOWNSTREAM_SCOPE="$(jq -er '.client_payload.downstream_scope' <<< "${payload}")"
  DOWNSTREAM_APPLICATION_SCOPE="$(jq -er '.client_payload.downstream_application_scope' <<< "${payload}")"
  SOURCE_COMMIT="$(jq -er '.client_payload.source_commit' <<< "${payload}")"
  DEPLOYMENT_ISSUE="$(jq -er '.client_payload.deployment_issue' <<< "${payload}")"
  validate_values
  jq -c . <<< "${payload}"
}

case "${1:-}" in
  build)
    build_payload
    ;;
  validate-payload)
    validate_payload
    ;;
  *)
    reject "Usage: $0 <build|validate-payload>"
    ;;
esac
