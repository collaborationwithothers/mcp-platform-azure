#!/usr/bin/env bash

# Shared helpers for Azure Monitor managed Prometheus verification.

azure_monitor_workspace_query_endpoint() {
  local workspace_id="$1"
  local endpoint

  if ! endpoint="$(az rest --method get \
    --url "https://management.azure.com${workspace_id}?api-version=2023-04-03" \
    --query properties.metrics.prometheusQueryEndpoint \
    -o tsv)"; then
    echo "::error::Could not retrieve the Azure Monitor workspace Prometheus query endpoint." >&2
    return 1
  fi

  if [ -z "${endpoint}" ]; then
    echo "::error::Azure Monitor workspace did not return a Prometheus query endpoint from ARM API 2023-04-03." >&2
    return 1
  fi

  printf '%s\n' "${endpoint}"
}

query_prometheus() {
  local endpoint="$1"
  local token="$2"
  local query="$3"
  local response_body
  local http_status
  local response_type
  local response_status

  if ! response_body="$(curl --silent --show-error --get \
    --write-out '\n%{http_code}' \
    "${endpoint%/}/api/v1/query" \
    --header "Authorization: Bearer ${token}" \
    --data-urlencode "query=${query}")"; then
    echo "::error::Prometheus request failed before receiving an HTTP response." >&2
    return 1
  fi

  http_status="${response_body##*$'\n'}"
  response_body="${response_body%$'\n'*}"
  if [ "${http_status}" != "200" ]; then
    echo "::error::Prometheus query returned HTTP ${http_status}." >&2
    return 1
  fi

  if ! jq -e '.status == "success"' >/dev/null <<< "${response_body}"; then
    response_type="$(jq -r 'type' <<< "${response_body}" 2>/dev/null || printf 'non-json')"
    response_status="$(jq -r '.status // "missing"' <<< "${response_body}" 2>/dev/null || printf 'unavailable')"
    echo "::error::Prometheus query returned unexpected content (type=${response_type}, status=${response_status})." >&2
    return 1
  fi

  printf '%s\n' "${response_body}"
}
