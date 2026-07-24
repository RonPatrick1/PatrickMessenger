#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
env_file="$script_dir/.env"
data_dir="$script_dir/liam-data"
liam_user="@liam:matrix.patrick-lamphier.com"

if [[ ! -f "$env_file" ]]; then
  umask 077
  matrix_password="$(openssl rand -hex 32)"
  store_passphrase="$(openssl rand -hex 32)"
  {
    printf 'HOST_UID=%s\n' "$(id -u)"
    printf 'HOST_GID=%s\n' "$(id -g)"
    printf 'LIAM_MATRIX_USER=%s\n' "$liam_user"
    printf 'LIAM_MATRIX_PASSWORD=%s\n' "$matrix_password"
    printf 'LIAM_STORE_PASSPHRASE=%s\n' "$store_passphrase"
  } >"$env_file"
  echo "Created private Liam credentials in server/.env."
fi

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
    --arg user "$LIAM_MATRIX_USER" \
    --arg password "$LIAM_MATRIX_PASSWORD" \
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
    --user liam \
    --password "$LIAM_MATRIX_PASSWORD" \
    --no-admin \
    --config /data/homeserver.yaml \
    http://localhost:8008
  echo "Created $LIAM_MATRIX_USER."
else
  echo "$LIAM_MATRIX_USER already exists and its stored credentials work."
fi

docker compose -f "$script_dir/compose.yaml" up -d --build liam
echo "Liam is running. Follow logs with:"
echo "docker compose -f $script_dir/compose.yaml logs -f liam"
