#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/shared-observability.yml"

# shellcheck disable=SC2016
root_wait_line="$(grep -n -F 'root_synced_revision="$(kubectl get application "${root_application}"' "${workflow}" | cut -d: -f1)"
child_patch_line="$(grep -n -F 'kubectl patch application mcp-platform-observability' "${workflow}" | cut -d: -f1)"

test -n "${root_wait_line}"
test -n "${child_patch_line}"

if [ "${root_wait_line}" -ge "${child_patch_line}" ]; then
  echo "the root companion revision must reconcile before the child is patched" >&2
  exit 1
fi

# shellcheck disable=SC2016
grep --fixed-strings --quiet -- 'Last source revision: ${child_revision:-missing}' "${workflow}"
echo "shared observability companion revision guard is ordered correctly"
