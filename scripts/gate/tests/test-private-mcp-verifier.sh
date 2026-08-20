#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/scripts/gate/verify-private-mcp.sh"
workflow="${repo_root}/.github/workflows/ephemeral-env.yml"

bash -n "${script}"

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

for required in \
  'MCP_PRIVATE_HOST' \
  'MCP_PRIVATE_IP' \
  'MCP_RESOURCE_AUDIENCE' \
  'dig @1.1.1.1 +short AAAA' \
  '-connect "${MCP_PRIVATE_IP}:443"' \
  'TEST_CLIENT_SECRET' \
  'TEST_CLIENT_WITHOUT_ROLE_SECRET' \
  'unset app_token roleless_token wrong_audience_token'; do
  if ! grep --fixed-strings --quiet -- "${required}" "${script}"; then
    echo "private verifier lost required secret handling: ${required}" >&2
    exit 1
  fi
done

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

data_plane_job="$(grep --after-context=55 '^  verify-private-data-plane:' "${workflow}")"
if grep -E --quiet '(^|[[:space:];|&])(terraform|kubectl|az|dotnet|pwsh|apt|pip|npm)([[:space:];|&]|$)' <<< "${data_plane_job}"; then
  echo "the VNet data-plane job contains a forbidden command" >&2
  exit 1
fi

echo "private MCP verifier keeps the VNet runner data-plane-only"
