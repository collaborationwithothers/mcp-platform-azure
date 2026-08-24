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
  echo "private MCP verification failed: $1" >&2
  exit 1
}

require \
  MCP_PRIVATE_HOST \
  MCP_PRIVATE_IP \
  MCP_RESOURCE_AUDIENCE \
  ORDERS_RESOURCE_AUDIENCE \
  AZURE_TENANT_ID \
  TEST_CLIENT_ID \
  TEST_CLIENT_SECRET \
  TEST_CLIENT_WITHOUT_ROLE_ID \
  TEST_CLIENT_WITHOUT_ROLE_SECRET

host="${MCP_PRIVATE_HOST}"
base_url="https://${host}"
prm_url="${base_url}/.well-known/oauth-protected-resource/mcp"
resource_url="${base_url}/mcp"
authority="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"
app_token=""
roleless_token=""
wrong_audience_token=""
trap 'unset app_token roleless_token wrong_audience_token' EXIT

private_records="$(dig +short A "${host}")"
if [ "${private_records}" != "${MCP_PRIVATE_IP}" ]; then
  fail "private DNS did not return only the expected ingress address"
fi

public_records="$(dig @1.1.1.1 +short A "${host}")"
if [ -n "${public_records}" ]; then
  fail "public DNS returned an A record for the private host"
fi

public_ipv6_records="$(dig @1.1.1.1 +short AAAA "${host}")"
if [ -n "${public_ipv6_records}" ]; then
  fail "public DNS returned an AAAA record for the private host"
fi

certificate="$(openssl s_client \
  -connect "${MCP_PRIVATE_IP}:443" \
  -servername "${host}" \
  -verify_return_error < /dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName)"
certificate_has_host=false
while IFS= read -r san_line; do
  while [[ "${san_line}" == *DNS:* ]]; do
    san_line="${san_line#*DNS:}"
    san="${san_line%%,*}"
    san="${san//[[:space:]]/}"
    if [ "${san}" = "${host}" ]; then
      certificate_has_host=true
    fi
    if [[ "${san_line}" != *,* ]]; then
      break
    fi
    san_line="${san_line#*,}"
  done
done <<< "${certificate}"
if [ "${certificate_has_host}" != true ]; then
  fail "the TLS certificate does not contain the private hostname"
fi

anonymous_headers="$(curl --silent --show-error \
  --resolve "${host}:443:${MCP_PRIVATE_IP}" \
  --header 'Accept: application/json, text/event-stream' \
  --header 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  --dump-header - \
  --output /dev/null \
  "${resource_url}")"
if [[ "${anonymous_headers}" != *$'HTTP/'*' 401 '* ]]; then
  fail "an unauthenticated MCP request did not return 401"
fi

challenge=""
while IFS= read -r header; do
  case "${header,,}" in
    www-authenticate:*)
      challenge="${header#*: }"
      challenge="${challenge%$'\r'}"
      ;;
  esac
done <<< "${anonymous_headers}"
expected_challenge="Bearer resource_metadata=\"${prm_url}\""
if [ "${challenge}" != "${expected_challenge}" ]; then
  fail "the unauthenticated MCP challenge did not advertise the exact PRM URI"
fi

token() {
  local client_id="$1"
  local client_secret="$2"
  local scope="$3"
  local response
  response="$(curl --fail --silent --show-error \
    --request POST "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "scope=${scope}")"
  jq --exit-status --raw-output '.access_token // empty' <<< "${response}"
}

mcp_body() {
  local bearer_token="$1"
  local body="$2"
  local traceparent="${3:-}"
  local trace_header=()
  local response
  local metadata
  local response_body
  local http_status
  local content_type

  if [ -n "${traceparent}" ]; then
    trace_header=(--header "traceparent: ${traceparent}")
  fi

  response="$(curl --silent --show-error \
    --resolve "${host}:443:${MCP_PRIVATE_IP}" \
    --header "Authorization: Bearer ${bearer_token}" \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Content-Type: application/json' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    "${trace_header[@]}" \
    --data "${body}" \
    --write-out $'\n__MCP_RESPONSE_META__%{http_code}\t%{content_type}' \
    "${resource_url}")"

  metadata="${response##*$'\n'__MCP_RESPONSE_META__}"
  response_body="${response%$'\n'__MCP_RESPONSE_META__*}"
  http_status="${metadata%%$'\t'*}"
  content_type="${metadata#*$'\t'}"

  printf '__MCP_RESPONSE_META__%s\t%s\n%s' \
    "${http_status}" \
    "${content_type}" \
    "${response_body}"
}

mcp_status() {
  local bearer_token="$1"
  local body="$2"
  curl --silent --show-error \
    --resolve "${host}:443:${MCP_PRIVATE_IP}" \
    --header "Authorization: Bearer ${bearer_token}" \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Content-Type: application/json' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data "${body}" \
    --output /dev/null \
    --write-out '%{http_code}' \
    "${resource_url}"
}

json_rpc() {
  local response="$1"
  local metadata
  local http_status
  local content_type
  local line
  local event_json=""

  metadata="${response%%$'\n'*}"
  if [[ "${metadata}" != __MCP_RESPONSE_META__* ]]; then
    fail "the MCP response did not contain HTTP metadata"
  fi
  response="${response#*$'\n'}"
  metadata="${metadata#__MCP_RESPONSE_META__}"
  http_status="${metadata%%$'\t'*}"
  content_type="${metadata#*$'\t'}"

  if [[ "${http_status}" != 2?? ]]; then
    fail "the MCP JSON-RPC request returned HTTP ${http_status} with content type ${content_type:-none}"
  fi

  if jq --exit-status . > /dev/null 2>&1 <<< "${response}"; then
    printf '%s' "${response}"
    return
  fi

  while IFS= read -r line; do
    case "${line}" in
      'data: '*) event_json="${line#data: }" ;;
    esac
  done <<< "${response}"

  if ! jq --exit-status . > /dev/null 2>&1 <<< "${event_json}"; then
    fail "the MCP response with content type ${content_type:-none} was neither JSON nor a JSON SSE event"
  fi
  printf '%s' "${event_json}"
}

app_token="$(token "${TEST_CLIENT_ID}" "${TEST_CLIENT_SECRET}" "${MCP_RESOURCE_AUDIENCE}/.default")"
roleless_token="$(token \
  "${TEST_CLIENT_WITHOUT_ROLE_ID}" \
  "${TEST_CLIENT_WITHOUT_ROLE_SECRET}" \
  "${MCP_RESOURCE_AUDIENCE}/.default")"
wrong_audience_token="$(token \
  "${TEST_CLIENT_ID}" \
  "${TEST_CLIENT_SECRET}" \
  'https://graph.microsoft.com/.default')"
if [ -z "${app_token}" ] || [ -z "${roleless_token}" ] || [ -z "${wrong_audience_token}" ]; then
  fail "the token endpoint returned an empty access token"
fi

initialize='{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"private-verifier","version":"1.0"}}}'
tools_list='{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'
allowed_call='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_access_guidance","arguments":{}}}'
denied_call='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_order_status","arguments":{"orderId":"CONTOSO-1001"}}}'
orders_call='{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_order_status","arguments":{"orderId":"CONTOSO-1001"}}}'

MCP_SERVER_AUDIENCE_TOKEN="${app_token}" \
ORDERS_PRIVATE_HOST="${host}" \
ORDERS_PRIVATE_IP="${MCP_PRIVATE_IP}" \
bash scripts/gate/verify-private-orders.sh

initialized="$(json_rpc "$(mcp_body "${app_token}" "${initialize}")")"
jq --exit-status '.result != null and .error == null' <<< "${initialized}" > /dev/null \
  || fail "an application caller could not initialize the private MCP server"

listed="$(json_rpc "$(mcp_body "${app_token}" "${tools_list}")")"
jq --exit-status '(.result.tools | type) == "array" and (.result.tools | length) > 0' \
  <<< "${listed}" > /dev/null \
  || fail "an application caller could not list private MCP tools"

allowed="$(json_rpc "$(mcp_body "${app_token}" "${allowed_call}")")"
jq --exit-status '.result != null and .result.isError != true and .error == null' \
  <<< "${allowed}" > /dev/null \
  || fail "an application caller could not call the unrestricted private tool"

orders_trace_id="$(openssl rand -hex 16)"
orders_parent_span_id="$(openssl rand -hex 8)"
orders_traceparent="00-${orders_trace_id}-${orders_parent_span_id}-01"
orders="$(json_rpc "$(mcp_body "${app_token}" "${orders_call}" "${orders_traceparent}")")"
jq --exit-status '
  .result.isError != true
  and .error == null
  and .result.structuredContent.orderId == "CONTOSO-1001"
  and .result.structuredContent.status == "Delivered"
  and .result.structuredContent.updatedUtc == "2026-06-01T14:05:00Z"
' <<< "${orders}" > /dev/null \
  || fail "the sanctioned MCP-to-Orders call did not return the expected synthetic fixture"

denied="$(json_rpc "$(mcp_body "${roleless_token}" "${denied_call}")")"
jq --exit-status '
  .result.isError == true
  and ([.result.content[]? | select(.type == "text") | .text] | join(" ")
       | contains("get_order_status requires the application role"))' \
  <<< "${denied}" > /dev/null \
  || fail "the private server did not deny a caller missing the tool entitlement"

if [ "$(mcp_status "${wrong_audience_token}" "${initialize}")" != "401" ]; then
  fail "a wrong-audience token was not rejected with 401"
fi

if [ "$(mcp_status "${app_token}x" "${initialize}")" != "401" ]; then
  fail "a tampered token was not rejected with 401"
fi

prm_verification_id="$(openssl rand -hex 16)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'prm_verification_id=%s\n' "${prm_verification_id}" >> "${GITHUB_OUTPUT}"
  printf 'orders_trace_id=%s\n' "${orders_trace_id}" >> "${GITHUB_OUTPUT}"
fi
prm="$(curl --fail --silent --show-error \
  --resolve "${host}:443:${MCP_PRIVATE_IP}" \
  --header "X-Private-Mcp-Verification: ${prm_verification_id}" \
  "${prm_url}")"
jq --exit-status \
  --arg resource "${resource_url}" \
  --arg authority "${authority}" \
  --arg orders "${MCP_RESOURCE_AUDIENCE}/Orders.Invoke" \
  --arg catalog "${MCP_RESOURCE_AUDIENCE}/Catalog.Invoke" \
  '.resource == $resource
   and .authorization_servers == [$authority]
   and .scopes_supported == [$orders, $catalog]' <<< "${prm}" > /dev/null \
  || fail "the private PRM did not match the resource, authority, and scope union"

echo "private MCP DNS, TLS, PRM, application access, and negative token checks passed"
