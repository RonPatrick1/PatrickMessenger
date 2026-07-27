#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$script_dir/.env"
data_dir="$script_dir/search-data"
search_user="@search:matrix.patrick-lamphier.com"

umask 077
touch "$env_file"

append_if_missing() {
  local name="$1"
  local value="$2"
  if ! grep -q "^${name}=" "$env_file"; then
    printf '%s=%s\n' "$name" "$value" >>"$env_file"
  fi
}

append_if_missing HOST_UID "$(id -u)"
append_if_missing HOST_GID "$(id -g)"
append_if_missing SEARCH_MATRIX_USER "$search_user"
append_if_missing SEARCH_MATRIX_PASSWORD "$(openssl rand -hex 32)"
append_if_missing SEARCH_STORE_PASSPHRASE "$(openssl rand -hex 32)"

chmod 600 "$env_file"
mkdir -p "$data_dir"
chmod 700 "$data_dir"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

docker compose -f "$script_dir/compose.yaml" up -d synapse

login_response="$(
  jq -cn \
    --arg user "$SEARCH_MATRIX_USER" \
    --arg password "$SEARCH_MATRIX_PASSWORD" \
    '{type:"m.login.password",identifier:{type:"m.id.user",user:$user},password:$password}' \
    | curl --fail-with-body --silent --show-error \
        --request POST \
        --header 'content-type: application/json' \
        --data-binary @- \
        http://127.0.0.1:8008/_matrix/client/v3/login \
    || true
)"

if ! jq -e '.access_token | type == "string"' >/dev/null 2>&1 <<<"$login_response"; then
  docker compose -f "$script_dir/compose.yaml" exec -T synapse \
    register_new_matrix_user \
    --user search \
    --password "$SEARCH_MATRIX_PASSWORD" \
    --no-admin \
    --config /data/homeserver.yaml \
    http://localhost:8008
  echo "Created $SEARCH_MATRIX_USER."
else
  echo "$SEARCH_MATRIX_USER already exists and its stored credentials work."
fi

docker compose -f "$script_dir/compose.yaml" up -d --build search
echo "Shared Search is running. Follow logs with:"
echo "docker compose -f $script_dir/compose.yaml logs -f search"
