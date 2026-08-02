#!/usr/bin/env bash

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/patrick-messenger"
state_file="$config_dir/adb-devices.tsv"

phone_serial="R3GL10DJ01F"
tablet_serial="R5GL351F5QL"
targets=("$phone_serial" "$tablet_serial")

declare -A labels endpoints models connected
labels["$phone_serial"]="PHONE"
labels["$tablet_serial"]="TABLET"

failed=0
wifi_enabled_by_script=0
wifi_before="$(nmcli radio wifi 2>/dev/null)"

is_target() {
  case "$1" in
    "$phone_serial"|"$tablet_serial") return 0 ;;
    *) return 1 ;;
  esac
}

for tool in adb avahi-browse nmcli python3 timeout stdbuf; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL: required command is unavailable: %s\n' "$tool"
    failed=1
  fi
done

mkdir -p "$config_dir"

if [ -f "$state_file" ]; then
  while IFS=$'\t' read -r serial endpoint model; do
    if is_target "$serial" && [ -n "$endpoint" ]; then
      endpoints["$serial"]="$endpoint"
      models["$serial"]="$model"
    fi
  done < "$state_file"
fi

connect_endpoint() {
  local expected_serial="$1"
  local endpoint="$2"
  local actual_serial
  local model

  [ -n "$endpoint" ] || return 1

  adb connect "$endpoint" >/dev/null 2>&1

  if ! adb -s "$endpoint" get-state 2>/dev/null | grep -qx 'device'; then
    return 1
  fi

  actual_serial="$(
    adb -s "$endpoint" shell getprop ro.serialno 2>/dev/null |
      tr -d '\r'
  )"

  if [ "$actual_serial" != "$expected_serial" ]; then
    return 1
  fi

  model="$(
    adb -s "$endpoint" shell getprop ro.product.model 2>/dev/null |
      tr -d '\r'
  )"

  endpoints["$expected_serial"]="$endpoint"
  models["$expected_serial"]="$model"
  connected["$expected_serial"]=1
  return 0
}

record_current_connections() {
  local endpoint
  local state
  local actual_serial
  local model

  while read -r endpoint state rest; do
    [ "$state" = "device" ] || continue

    actual_serial="$(
      adb -s "$endpoint" shell getprop ro.serialno 2>/dev/null |
        tr -d '\r'
    )"

    if is_target "$actual_serial"; then
      model="$(
        adb -s "$endpoint" shell getprop ro.product.model 2>/dev/null |
          tr -d '\r'
      )"

      endpoints["$actual_serial"]="$endpoint"
      models["$actual_serial"]="$model"
      connected["$actual_serial"]=1

      printf 'PASS: %s already connected at %s\n' \
        "${labels[$actual_serial]}" "$endpoint"
    fi
  done < <(
    adb devices |
      sed '1d' |
      sed '/^[[:space:]]*$/d'
  )
}

discover_endpoints() {
  local discovery_file
  local pass

  discovery_file="$(mktemp)"

  for pass in 1 2 3; do
    timeout 8 stdbuf -oL avahi-browse \
      --resolve \
      --parsable \
      _adb-tls-connect._tcp \
      >> "$discovery_file" 2>/dev/null

    sleep 1
  done

  python3 - "$discovery_file" "$phone_serial" "$tablet_serial" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
targets = sys.argv[2:]
found = {}

for line in path.read_text(errors="replace").splitlines():
    fields = line.split(";")

    if len(fields) < 9:
        continue

    if fields[0] != "=" or fields[2] != "IPv4":
        continue

    service = fields[3]
    address = fields[7]
    port = fields[8]

    for serial in targets:
        if f"adb-{serial}-" not in service:
            continue

        text = ";".join(fields[9:])
        match = re.search(r'name=([^"\s]+)', text)
        model = match.group(1) if match else ""

        found[serial] = (f"{address}:{port}", model)

for serial in targets:
    if serial in found:
        endpoint, model = found[serial]
        print(f"{serial}\t{endpoint}\t{model}")
PY

  rm -f "$discovery_file"
}

try_saved_endpoints() {
  local serial
  local endpoint

  for serial in "${targets[@]}"; do
    [ "${connected[$serial]:-0}" = "1" ] && continue

    endpoint="${endpoints[$serial]:-}"

    if connect_endpoint "$serial" "$endpoint"; then
      printf 'PASS: %s connected using saved endpoint %s\n' \
        "${labels[$serial]}" "$endpoint"
    fi
  done
}

discover_and_connect() {
  local serial
  local endpoint
  local model

  while IFS=$'\t' read -r serial endpoint model; do
    if is_target "$serial" && [ -n "$endpoint" ]; then
      endpoints["$serial"]="$endpoint"
      models["$serial"]="$model"
    fi
  done < <(discover_endpoints)

  for serial in "${targets[@]}"; do
    [ "${connected[$serial]:-0}" = "1" ] && continue

    endpoint="${endpoints[$serial]:-}"

    if connect_endpoint "$serial" "$endpoint"; then
      printf 'PASS: %s discovered and connected at %s\n' \
        "${labels[$serial]}" "$endpoint"
    fi
  done
}

unresolved_count() {
  local serial
  local count=0

  for serial in "${targets[@]}"; do
    if [ "${connected[$serial]:-0}" != "1" ]; then
      count=$((count + 1))
    fi
  done

  printf '%s\n' "$count"
}

save_known_endpoints() {
  local temporary_state
  local serial
  local endpoint
  local model

  temporary_state="${state_file}.tmp.$$"
  : > "$temporary_state"

  for serial in "${targets[@]}"; do
    endpoint="${endpoints[$serial]:-}"
    model="${models[$serial]:-}"

    if [ -n "$endpoint" ]; then
      printf '%s\t%s\t%s\n' \
        "$serial" "$endpoint" "$model" >> "$temporary_state"
    fi
  done

  if [ -s "$temporary_state" ]; then
    mv "$temporary_state" "$state_file"
    chmod 600 "$state_file"
  else
    rm -f "$temporary_state"
  fi
}

if [ "$failed" -eq 0 ]; then
  adb start-server >/dev/null 2>&1

  record_current_connections
  try_saved_endpoints

  if [ "$(unresolved_count)" -gt 0 ]; then
    printf 'INFO: saved endpoint unavailable; discovering over current network\n'
    discover_and_connect
  fi

  if [ "$(unresolved_count)" -gt 0 ] && [ "$wifi_before" = "disabled" ]; then
    printf 'INFO: current-network discovery incomplete; temporarily enabling Wi-Fi\n'

    if nmcli radio wifi on; then
      wifi_enabled_by_script=1

      for attempt in $(seq 1 20); do
        if nmcli -t -f TYPE,STATE device status |
          grep -qx 'wifi:connected'; then
          break
        fi

        sleep 1
      done

      discover_and_connect
    else
      printf 'FAIL: could not enable Wi-Fi\n'
      failed=1
    fi
  fi
fi

save_known_endpoints

if [ "$wifi_enabled_by_script" -eq 1 ]; then
  if nmcli radio wifi off; then
    printf 'PASS: Wi-Fi restored to disabled\n'
  else
    printf 'FAIL: could not restore Wi-Fi to disabled\n'
    failed=1
  fi
fi

printf '\n### DEVICE RESULTS\n'

for serial in "${targets[@]}"; do
  label="${labels[$serial]}"
  endpoint="${endpoints[$serial]:-UNKNOWN}"
  model="${models[$serial]:-UNKNOWN}"

  if [ "${connected[$serial]:-0}" = "1" ]; then
    printf 'PASS: %s SERIAL=%s MODEL=%s ENDPOINT=%s\n' \
      "$label" "$serial" "$model" "$endpoint"
  else
    printf 'FAIL: %s SERIAL=%s ENDPOINT=%s\n' \
      "$label" "$serial" "$endpoint"
    failed=1
  fi
done

printf '\nSTATE_FILE=%s\n' "$state_file"
printf 'WIFI_BEFORE=%s\n' "$wifi_before"
printf 'WIFI_AFTER=%s\n' "$(nmcli radio wifi 2>/dev/null)"

if [ "$failed" -eq 0 ]; then
  printf 'PASS: device endpoints refreshed\n'
else
  printf 'FAIL: one or more device endpoints could not be refreshed\n'
fi
