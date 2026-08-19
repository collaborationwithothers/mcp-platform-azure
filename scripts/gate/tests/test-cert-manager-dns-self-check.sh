#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/deploy-aks-platform.yml"

for setting in \
  '--set dns01RecursiveNameserversOnly=true' \
  "--set-string 'dns01RecursiveNameservers=1.1.1.1:53\\,8.8.8.8:53'"; do
  if ! grep --fixed-strings --quiet -- "${setting}" "${workflow}"; then
    echo "missing cert-manager DNS self-check setting: ${setting}" >&2
    exit 1
  fi
done

echo "cert-manager DNS self-check uses public recursive resolvers"
