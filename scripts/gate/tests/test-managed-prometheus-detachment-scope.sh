#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/shared-observability.yml"

for target in \
  'module.aks.module.aks.azapi_resource.this' \
  'module.aks.azurerm_monitor_data_collection_endpoint.managed_prometheus' \
  'module.aks.azurerm_monitor_data_collection_rule.managed_prometheus' \
  'module.aks.azurerm_monitor_data_collection_rule_association.managed_prometheus_rule' \
  'module.aks.azurerm_monitor_data_collection_rule_association.managed_prometheus_endpoint'; do
  grep --fixed-strings --quiet -- "-target=${target}" "${workflow}"
done

# shellcheck disable=SC2016
grep --fixed-strings --quiet -- '"${managed_prometheus_targets[@]}"' "${workflow}"
grep --fixed-strings --quiet -- 'Refusing metrics teardown because the AKS plan contains unrelated changes' "${workflow}"
echo "managed Prometheus detachment scope is constrained"
