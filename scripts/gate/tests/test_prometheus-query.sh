#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "${repo_root}/scripts/gate/prometheus-query.sh"

prometheus_response='{"status":"success","data":{"result":[{"metric":{"cluster":"aks-mcp-platform"}}]}}'

az() {
  local arguments="$*"

  case "${arguments}" in
    *'api-version=2023-04-03'*) ;;
    *)
      echo "expected ARM API version 2023-04-03" >&2
      return 1
      ;;
  esac

  case "${arguments}" in
    *'properties.metrics.prometheusQueryEndpoint'*) ;;
    *)
      echo "expected the Prometheus query endpoint property" >&2
      return 1
      ;;
  esac

  printf '%s\n' 'https://prometheus.example.test'
}

curl() {
  printf '%s\n200\n' "${prometheus_response}"
}

endpoint="$(azure_monitor_workspace_query_endpoint '/subscriptions/example/resourceGroups/example/providers/Microsoft.Monitor/accounts/example')"
test "${endpoint}" = 'https://prometheus.example.test'

response="$(query_prometheus "${endpoint}" '<REDACTED>' 'up')"
cluster_label="$(jq -r '[.data.result[] | .metric.cluster // empty] | unique | .[0] // empty' <<< "${response}")"
test "${cluster_label}" = 'aks-mcp-platform'

ready_node_response='{"status":"success","data":{"result":[{"metric":{"cluster":"aks-mcp-platform","condition":"Ready","status":"true"}}]}}'
cluster_label="$(prometheus_single_cluster_label "${ready_node_response}")"
test "${cluster_label}" = 'aks-mcp-platform'
prometheus_require_results "${ready_node_response}" 'kube_node_status_condition Ready=true'

if error_output="$(prometheus_require_results '{"status":"success","data":{"result":[]}}' 'argocd_app_info' 2>&1)"; then
  echo "expected an empty Prometheus result to fail" >&2
  exit 1
fi

case "${error_output}" in
  *'Prometheus query argocd_app_info returned no series.'*) ;;
  *)
    echo "expected an empty-result diagnostic" >&2
    exit 1
    ;;
esac

if error_output="$(prometheus_single_cluster_label '{"status":"success","data":{"result":[]}}' 2>&1)"; then
  echo "expected missing cluster labels to fail" >&2
  exit 1
fi

case "${error_output}" in
  *'Ready-node metrics returned 0 series and no non-empty cluster labels.'*) ;;
  *)
    echo "expected a missing-cluster-label diagnostic" >&2
    exit 1
    ;;
esac

if error_output="$(prometheus_single_cluster_label '{"status":"success","data":{"result":[{"metric":{"cluster":"aks-a"}},{"metric":{"cluster":"aks-b"}}]}}' 2>&1)"; then
  echo "expected multiple cluster labels to fail" >&2
  exit 1
fi

case "${error_output}" in
  *'Ready-node metrics returned 2 series across 2 cluster labels; expected exactly one: aks-a, aks-b.'*) ;;
  *)
    echo "expected a multiple-cluster-label diagnostic" >&2
    exit 1
    ;;
esac

retry_responses=(
  '{"status":"success","data":{"result":[]}}'
  '{"status":"success","data":{"result":[{"metric":{"cluster":"aks-mcp-platform"}}]}}'
)
retry_state_file="$(mktemp)"
trap 'rm -f "${retry_state_file}"' EXIT
printf '%s\n' '0' > "${retry_state_file}"

query_prometheus() {
  local retry_response_index

  retry_response_index="$(<"${retry_state_file}")"
  printf '%s\n' "${retry_responses[${retry_response_index}]}"
  printf '%s\n' "$((retry_response_index + 1))" > "${retry_state_file}"
}

sleep() {
  :
}

retried_response="$(prometheus_wait_for_results "${endpoint}" '<REDACTED>' 'argocd_app_info' 'argocd_app_info' 2 0)"
test "$(jq '[.data.result[]] | length' <<< "${retried_response}")" = '1'

retry_responses=(
  '{"status":"success","data":{"result":[]}}'
  '{"status":"success","data":{"result":[]}}'
)
printf '%s\n' '0' > "${retry_state_file}"

if error_output="$(prometheus_wait_for_results "${endpoint}" '<REDACTED>' 'argocd_app_info' 'argocd_app_info' 2 0 2>&1)"; then
  echo "expected a Prometheus retry timeout to fail" >&2
  exit 1
fi

case "${error_output}" in
  *'Prometheus query argocd_app_info returned no series after 2 attempts.'*) ;;
  *)
    echo "expected a retry-timeout diagnostic" >&2
    exit 1
    ;;
esac

unset -f query_prometheus sleep
source "${repo_root}/scripts/gate/prometheus-query.sh"

curl() {
  printf '%s\n503\n' '{"status":"error"}'
}

if error_output="$(query_prometheus "${endpoint}" '<REDACTED>' 'up' 2>&1)"; then
  echo "expected HTTP 503 to fail" >&2
  exit 1
fi

case "${error_output}" in
  *'Prometheus query returned HTTP 503.'*) ;;
  *)
    echo "expected a safe HTTP-status diagnostic" >&2
    exit 1
    ;;
esac

echo "prometheus helper tests passed"
