#!/usr/bin/env bash
set -euo pipefail

gateway="${MATRIX_PUSH_GATEWAY_URL:-https://patrick-lamphier.com/_matrix/push/v1/notify}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 2
fi
if [[ "$gateway" != https://*/_matrix/push/v1/notify ]]; then
  echo "MATRIX_PUSH_GATEWAY_URL must be an HTTPS Matrix push gateway URL." >&2
  exit 2
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT
status="$({ curl --silent --show-error \
  --output "$response_file" \
  --write-out '%{http_code}' \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"notification":{"devices":[]}}' \
  --max-time 15 \
  "$gateway"; } || true)"

if [[ "$status" != 200 ]]; then
  echo "Push gateway check failed: $gateway returned HTTP ${status:-unreachable}." >&2
  echo "Expected Sygnal, not the website application or an nginx error page." >&2
  exit 1
fi
if ! grep -Eq '"rejected"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$response_file"; then
  echo "Push gateway returned HTTP 200 but not Sygnal's expected response." >&2
  exit 1
fi

echo "Matrix push gateway is publicly reachable and Sygnal is responding."
