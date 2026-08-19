#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <local-image:tag>" >&2
  exit 2
fi

image="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_dir="$(mktemp -d)"
container_name="mcp-container-test-${RANDOM}-$$"
oidc_pid=""

cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && docker inspect "$container_name" >/dev/null 2>&1; then
    echo "Container logs:" >&2
    docker logs "$container_name" >&2 || true
  fi
  docker rm --force "$container_name" >/dev/null 2>&1 || true
  if [ -n "$oidc_pid" ]; then
    kill "$oidc_pid" >/dev/null 2>&1 || true
    wait "$oidc_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$state_dir"
  exit "$status"
}
trap cleanup EXIT

for command in curl docker dotnet jq openssl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command '$command' is unavailable." >&2
    exit 1
  fi
done

docker image inspect "$image" >/dev/null
docker image inspect "$image" \
  | jq --exit-status '.[0].Config.ExposedPorts | keys == ["8080/tcp"]' \
  >/dev/null

free_port() {
  python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

oidc_port="$(free_port)"
app_port="$(free_port)"
issuer="http://host.docker.internal:${oidc_port}"
audience="api://mcp-server-app-id"
token_file="${state_dir}/access-token"

python3 "${repo_root}/tests/container/oidc_test_server.py" \
  --host 0.0.0.0 \
  --port "$oidc_port" \
  --issuer "$issuer" \
  --audience "$audience" \
  --token-file "$token_file" \
  >"${state_dir}/oidc.log" 2>&1 &
oidc_pid=$!

for _ in {1..40}; do
  if [ -s "$token_file" ] \
    && curl --fail --silent --show-error \
      "http://127.0.0.1:${oidc_port}/.well-known/openid-configuration" \
      >/dev/null; then
    break
  fi
  sleep 0.25
done
if [ ! -s "$token_file" ]; then
  echo "The local OpenID Connect server did not create a token." >&2
  sed -n '1,160p' "${state_dir}/oidc.log" >&2
  exit 1
fi

docker run --detach \
  --name "$container_name" \
  --add-host host.docker.internal:host-gateway \
  --publish "127.0.0.1:${app_port}:8080" \
  --env ASPNETCORE_ENVIRONMENT=Development \
  --env Authentication__Authority="$issuer" \
  --env Authentication__Audience="$audience" \
  --env Authentication__RequireHttpsMetadata=false \
  --env ReverseProxy__TrustAnyForwarder=true \
  --env MicrosoftEntra__ServerAppClientId=mcp-server-app-id \
  --env MicrosoftEntra__TenantId=server-tenant-id \
  --env DownstreamOrdersApi__BaseUrl=http://unused.example.test \
  --env DownstreamOrdersApi__Scope=api://orders-api/user_impersonation \
  --env DownstreamOrdersApi__ApplicationScope=api://orders-api/.default \
  "$image" >/dev/null

health_url="http://127.0.0.1:${app_port}/healthz"
for _ in {1..80}; do
  if [ "$(curl --silent --show-error "$health_url" 2>/dev/null || true)" = "Healthy" ]; then
    break
  fi
  sleep 0.25
done
if [ "$(curl --fail --silent --show-error "$health_url")" != "Healthy" ]; then
  echo "The anonymous health probe did not return only 'Healthy'." >&2
  exit 1
fi

runtime_uid="$(docker exec "$container_name" id -u)"
if ! [[ "$runtime_uid" =~ ^[0-9]+$ ]] || [ "$runtime_uid" -eq 0 ]; then
  echo "The runtime process user must be a non-root numeric user." >&2
  exit 1
fi

installed_sdks="$(docker exec "$container_name" dotnet --list-sdks)"
if [ -n "$installed_sdks" ]; then
  echo "The runtime image contains a .NET SDK." >&2
  exit 1
fi
docker exec "$container_name" test -f /app/McpTools.AspNetCore.dll
unexpected_files="$(docker exec "$container_name" sh -c \
  'find /app -type f \( -name "*.cs" -o -name "*.csproj" -o -name "*Tests*" \) -print')"
if [ -n "$unexpected_files" ]; then
  echo "The runtime application directory contains source or test files." >&2
  exit 1
fi

metadata="$(curl --fail --silent --show-error \
  --header "Host: mcp.internal.consultwithcloud.com" \
  --header "X-Forwarded-Proto: https" \
  "http://127.0.0.1:${app_port}/.well-known/oauth-protected-resource/mcp")"
jq --exit-status \
  --arg issuer "$issuer" \
  --arg audience "$audience" \
  '.resource == "https://mcp.internal.consultwithcloud.com/mcp" and
   .authorization_servers == [$issuer] and
   .scopes_supported == [
     ($audience + "/Orders.Invoke"),
     ($audience + "/Catalog.Invoke")
   ]' \
  <<<"$metadata" >/dev/null

MCP_SERVER_ENDPOINT="http://127.0.0.1:${app_port}/mcp" \
MCP_ACCESS_TOKEN="$(<"$token_file")" \
MCP_TEST_PROFILE=service-info \
  dotnet run \
    --project "${repo_root}/src/McpTestClient/McpTestClient.csproj" \
    --configuration Release \
    --no-build

echo "Container health, contents, private metadata, and authenticated MCP path passed."
