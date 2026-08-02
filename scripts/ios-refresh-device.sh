#!/usr/bin/env bash

script_dir="$(
  CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null &&
    pwd
)"

repo_root="$(dirname -- "$script_dir")"
failed=0

printf '### REPOSITORY\n'

if cd "$repo_root"; then
  printf 'PWD=%s\n' "$PWD"
  printf 'BRANCH=%s\n' "$(git branch --show-current 2>/dev/null)"

  if [ -f pubspec.yaml ]; then
    printf 'PASS: pubspec.yaml found\n'
  else
    printf 'FAIL: pubspec.yaml not found\n'
    failed=1
  fi
else
  printf 'FAIL: repository directory not found: %s\n' "$repo_root"
  failed=1
fi

printf '\n### XCODE\n'

if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version
else
  printf 'FAIL: xcodebuild is unavailable\n'
  failed=1
fi

if command -v xcode-select >/dev/null 2>&1; then
  developer_dir="$(xcode-select -p 2>/dev/null)"

  if [ -n "$developer_dir" ]; then
    printf 'DEVELOPER_DIR=%s\n' "$developer_dir"
  else
    printf 'FAIL: xcode-select returned no developer directory\n'
    failed=1
  fi
else
  printf 'FAIL: xcode-select is unavailable\n'
  failed=1
fi

printf '\n### FLUTTER\n'

flutter_path="$(command -v flutter 2>/dev/null)"

if [ -n "$flutter_path" ]; then
  printf 'FLUTTER=%s\n' "$flutter_path"
  flutter --version 2>&1 | sed -n '1,6p'
else
  printf 'FAIL: flutter is not in PATH\n'
  failed=1
fi

printf '\n### FLUTTER DEVICES\n'

if [ -n "$flutter_path" ]; then
  flutter devices 2>&1
else
  printf 'SKIPPED: flutter devices because Flutter is unavailable\n'
fi

printf '\n### CORE DEVICE LIST\n'

if command -v xcrun >/dev/null 2>&1; then
  xcrun devicectl list devices 2>&1
  devicectl_result=$?

  if [ "$devicectl_result" -eq 0 ]; then
    printf 'PASS: devicectl device listing completed\n'
  else
    printf 'FAIL: devicectl device listing returned %s\n' \
      "$devicectl_result"
    failed=1
  fi
else
  printf 'FAIL: xcrun is unavailable\n'
  failed=1
fi

printf '\n### INSTALL COMMAND SUPPORT\n'

if command -v xcrun >/dev/null 2>&1; then
  xcrun devicectl device install app --help 2>&1 |
    sed -n '1,180p'
else
  printf 'SKIPPED: xcrun is unavailable\n'
fi

printf '\n### IOS PROJECT FILES\n'

if [ -d ios ]; then
  find ios -maxdepth 2 \
    \( -name '*.xcworkspace' -o -name '*.xcodeproj' \) \
    -print
else
  printf 'FAIL: ios directory not found\n'
  failed=1
fi

printf '\n### RESULT\n'

if [ "$failed" -eq 0 ]; then
  printf 'PASS: iOS wireless-device environment diagnostics completed\n'
else
  printf 'FAIL: one or more iOS environment checks failed\n'
fi
