#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/deploy-aks-platform.yml"

for setting in \
  '--set controller.metrics.enabled=true' \
  '--set repoServer.metrics.enabled=true' \
  '--set server.metrics.enabled=true'; do
  if ! rg --fixed-strings --quiet -- "${setting}" "${workflow}"; then
    echo "missing Argo CD metrics setting: ${setting}" >&2
    exit 1
  fi
done

echo "Argo CD metrics service settings are present"
