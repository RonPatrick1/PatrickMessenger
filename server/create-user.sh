#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

docker compose -f "$script_dir/compose.yaml" exec synapse \
  register_new_matrix_user \
  --config /data/homeserver.yaml \
  http://localhost:8008
