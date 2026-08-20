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

prm="$(curl --fail --silent --show-error \
  --resolve "${host}:443:${MCP_PRIVATE_IP}" \
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
  curl --silent --show-error \
    --resolve "${host}:443:${MCP_PRIVATE_IP}" \
    --header "Authorization: Bearer ${bearer_token}" \
    --header 'Accept: application/json, text/event-stream' \
    --header 'Content-Type: application/json' \
    --header 'MCP-Protocol-Version: 2025-06-18' \
    --data "${body}" \
    "${resource_url}"
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
  local line
  local event_json=""

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
    fail "the MCP response was neither JSON nor a JSON SSE event"
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

echo "private MCP DNS, TLS, PRM, application access, and negative token checks passed"
