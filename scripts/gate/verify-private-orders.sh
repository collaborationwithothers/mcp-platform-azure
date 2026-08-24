#!/usr/bin/env bash
set -euo pipefail

require() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "missing required environment value: ${name}" >&2
      exit 1
    fi
  done
}

fail() {
  echo "private Orders verification failed: $1" >&2
  exit 1
}

orders_probe() {
  local bearer_token="$1"
  local curl_arguments=(
    --silent
    --show-error
    --resolve "${ORDERS_PRIVATE_HOST}:443:${ORDERS_PRIVATE_IP}"
    --request GET
    --dump-header -
    --output /dev/null
    --write-out $'\n__ORDERS_STATUS__%{http_code}'
  )

  if [ -n "${bearer_token}" ]; then
    curl_arguments+=(--header "Authorization: Bearer ${bearer_token}")
  fi

  curl "${curl_arguments[@]}" \
    "https://${ORDERS_PRIVATE_HOST}/api/orders/CONTOSO-1001"
}

probe_status() {
  local response="$1"
  printf '%s' "${response##*$'\n'__ORDERS_STATUS__}"
}

probe_challenge() {
  local response="$1"
  local headers="${response%$'\n'__ORDERS_STATUS__*}"
  awk '
    tolower($0) ~ /^www-authenticate:/ {
      sub(/^[^:]+:[[:space:]]*/, "")
      sub(/\r$/, "")
      print
      exit
    }
  ' <<< "${headers}"
}

require \
  ORDERS_PRIVATE_HOST \
  ORDERS_PRIVATE_IP \
  MCP_RESOURCE_AUDIENCE \
  ORDERS_RESOURCE_AUDIENCE \
  MCP_SERVER_AUDIENCE_TOKEN

server_audience_token="${MCP_SERVER_AUDIENCE_TOKEN}"
trap 'unset server_audience_token MCP_SERVER_AUDIENCE_TOKEN' EXIT

if [ "${MCP_RESOURCE_AUDIENCE}" = "${ORDERS_RESOURCE_AUDIENCE}" ]; then
  fail "the MCP and Orders resource audiences must differ"
fi

if ! anonymous_response="$(orders_probe "")"; then
  fail "the private Orders endpoint could not be reached without a token"
fi
anonymous_status="$(probe_status "${anonymous_response}")"
anonymous_challenge="$(probe_challenge "${anonymous_response}")"
if [ "${anonymous_status}" != "401" ]; then
  fail "the no-token request returned ${anonymous_status}; expected an application authentication rejection with 401"
fi
case "${anonymous_challenge,,}" in
  bearer*) ;;
  *) fail "the no-token 401 did not include a Bearer challenge" ;;
esac

if ! server_token_response="$(orders_probe "${server_audience_token}")"; then
  fail "the private Orders endpoint could not be reached with the server-audience token"
fi
server_token_status="$(probe_status "${server_token_response}")"
server_token_challenge="$(probe_challenge "${server_token_response}")"
if [ "${server_token_status}" != "401" ]; then
  fail "the server-audience token returned ${server_token_status}; expected an application authentication rejection with 401"
fi
case "${server_token_challenge,,}" in
  bearer*'error="invalid_token"'*) ;;
  *) fail "the server-audience 401 did not identify an invalid bearer token" ;;
esac

echo "private Orders audience isolation checks passed"
