#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
site="${NGINX_SITE:-/etc/nginx/sites-available/default}"
snippet_name="patrick-messenger-matrix.conf"
snippet_target="/etc/nginx/snippets/$snippet_name"
include_line="    include /etc/nginx/snippets/$snippet_name;"

if [[ ! -f "$site" ]]; then
  echo "Nginx site not found: $site" >&2
  exit 1
fi

install -o root -g root -m 0644 \
  "$script_dir/nginx-matrix-client.conf" "$snippet_target"

original="$(mktemp)"
candidate="$(mktemp)"
trap 'rm -f "$original" "$candidate"' EXIT
cp --preserve=mode,ownership "$site" "$original"

if grep -Fq "$include_line" "$site"; then
  cp "$site" "$candidate"
else
  awk -v include_line="$include_line" '
    { print }
    !inserted && $0 ~ /^[[:space:]]*error_log \/var\/log\/nginx\/error\.log;/ {
      print ""
      print include_line
      inserted = 1
    }
    END {
      if (!inserted) exit 42
    }
  ' "$site" >"$candidate"
fi

install -o root -g root -m 0644 "$candidate" "$site"
if ! nginx -t; then
  install -o root -g root -m 0644 "$original" "$site"
  nginx -t
  echo "Nginx validation failed; the original active configuration was restored." >&2
  exit 1
fi

systemctl reload nginx
echo "Patrick Messenger's public Matrix client proxy is active."
