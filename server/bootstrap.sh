#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
data_dir="$script_dir/data"
image="ghcr.io/element-hq/synapse:v1.153.0"
server_name="${MATRIX_SERVER_NAME:-matrix.patrick-lamphier.com}"

mkdir -p "$data_dir"

if [[ ! -f "$data_dir/homeserver.yaml" ]]; then
  echo "Generating Synapse configuration for $server_name"
  docker run --rm \
    -e "SYNAPSE_SERVER_NAME=$server_name" \
    -e SYNAPSE_REPORT_STATS=no \
    -e "UID=$(id -u)" \
    -e "GID=$(id -g)" \
    -v "$data_dir:/data" \
    "$image" generate
else
  echo "Keeping the existing Synapse configuration."
fi

export HOST_UID
export HOST_GID
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

docker compose -f "$script_dir/compose.yaml" up -d synapse

for _ in {1..45}; do
  if curl --fail --silent http://127.0.0.1:8008/health >/dev/null; then
    echo "Synapse is healthy at http://127.0.0.1:8008"
    exit 0
  fi
  sleep 1
done

echo "Synapse did not become healthy. Inspect logs with:" >&2
echo "docker compose -f $script_dir/compose.yaml logs synapse" >&2
exit 1
