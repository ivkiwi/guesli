#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/scripts/classify_changed_files.sh"

assert_output() {
  local paths="$1" expected="$2"
  local actual
  actual="$(printf '%s\n' "$paths" | "$CLASSIFIER")"
  grep -Fqx "$expected" <<< "$actual" || {
    echo "Missing '$expected' for: $paths" >&2
    echo "$actual" >&2
    exit 1
  }
}

assert_output "docs/readme.md" "native_or_packaging=false"
assert_output "browser-extension/muesli-meet-speaker/content.js" "browser_extension=true"
assert_output "scripts/build_onnx_gigaam_helper.sh" "release_update=true"
assert_output "docs/appcast-guesli.xml" "release_update=true"
assert_output "native/MuesliNative/Sources/MuesliNativeApp/AppDelegate.swift" "native_or_packaging=true"
assert_output "NOTICE" "release_update=true"

echo "Changed-file classifier tests passed."
