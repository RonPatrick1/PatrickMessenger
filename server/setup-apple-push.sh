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
if [[ ! "$key_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "APNS_KEY_ID must be the 10-character Apple key ID." >&2
  exit 2
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "APNS_TEAM_ID must be the 10-character Apple team ID." >&2
  exit 2
fi
if ! grep -q '^-----BEGIN PRIVATE KEY-----$' "$source_key"; then
  echo "APNS_KEY_FILE is not an Apple .p8 private key." >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 ||
   ! docker compose version >/dev/null 2>&1; then
  echo "Docker with the Compose plugin is required." >&2
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

healthy=false
for _ in {1..15}; do
  if docker compose -f "$script_dir/compose.yaml" --profile push exec -T \
      sygnal python -c \
      'import urllib.request; urllib.request.urlopen("http://127.0.0.1:5000/health", timeout=2)' \
      >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  echo "Sygnal did not become healthy. Inspect it with:" >&2
  echo "  docker compose -f $script_dir/compose.yaml --profile push logs sygnal" >&2
  exit 1
fi

echo "Sygnal is configured for APNs $platform delivery."
echo "Run server/verify-apple-push.sh after publishing the nginx route."
echo "Then reinstall the signed iPhone app so it registers a fresh APNs token."
