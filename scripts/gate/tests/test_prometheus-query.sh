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
