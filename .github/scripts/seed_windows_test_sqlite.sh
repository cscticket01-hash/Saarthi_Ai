#!/usr/bin/env bash
set -euo pipefail

# The pinned sqlite3 3.7.0 hook rechecks this cached DLL before loading it.
expected=98b4be674137b85ec111a7a29223e87aa41c3e964d61f73602471ddd7b9c56ce
cache=".dart_tool/hooks_runner/shared/sqlite3/build/download-${expected:0:8}"
mkdir -p "$cache"
download=$(mktemp "$cache/sqlite3.XXXXXXXX")
trap 'rm -f "$download"' EXIT
curl --fail --location --silent --show-error --retry 2 --max-time 30 \
  --header 'Accept: application/octet-stream' \
  'https://api.github.com/repos/simolus3/sqlite3.dart/releases/assets/600689009' \
  --output "$download"
printf '%s  %s\n' "$expected" "$download" | sha256sum --check --status
mv -f "$download" "$cache/sqlite3.dll"
echo 'Verified SQLite 3.7.0 Windows x64 native asset'
