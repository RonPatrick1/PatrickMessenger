#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_key="${APNS_KEY_FILE:-}"
key_id="${APNS_KEY_ID:-}"
team_id="${APNS_TEAM_ID:-}"
platform="${APNS_PLATFORM:-sandbox}"

if [[ -z "$source_key" || -z "$key_id" || -z "$team_id" ]]; then
  echo "Set APNS_KEY_FILE, APNS_KEY_ID, and APNS_TEAM_ID first." >&2
  exit 2
fi
if [[ ! -f "$source_key" ]]; then
  echo "APNs key file not found: $source_key" >&2
  exit 2
fi
if [[ "$platform" != "sandbox" && "$platform" != "production" ]]; then
  echo "APNS_PLATFORM must be sandbox or production." >&2
  exit 2
fi

mkdir -p "$script_dir/push-secrets"
install -m 0600 "$source_key" "$script_dir/push-secrets/AuthKey.p8"

sed \
  -e "s/REPLACE_WITH_APPLE_KEY_ID/$key_id/" \
  -e "s/REPLACE_WITH_APPLE_TEAM_ID/$team_id/" \
  -e "s/platform: sandbox/platform: $platform/" \
  "$script_dir/sygnal.yaml.example" >"$script_dir/sygnal.yaml"
chmod 0600 "$script_dir/sygnal.yaml"

export HOST_UID="$(id -u)"
export HOST_GID="$(id -g)"
docker compose -f "$script_dir/compose.yaml" --profile push up -d synapse sygnal

echo "Sygnal is configured for APNs $platform delivery."
echo "Reinstall the signed iPhone app so it can register its APNs token."
