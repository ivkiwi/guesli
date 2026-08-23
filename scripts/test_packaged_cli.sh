#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIG="${1:-debug}"
INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/muesli-packaging-test.XXXXXX")"
APP_BUNDLE_NAME="GuesliPackagingTest.app"
APP_PATH="$INSTALL_ROOT/$APP_BUNDLE_NAME"
APP_BIN="$APP_PATH/Contents/MacOS/Guesli"
CLI_BIN="$APP_PATH/Contents/MacOS/muesli-cli"
GIGAAM_HELPER="$APP_PATH/Contents/MacOS/onnx-gigaam-helper"
NOTICE_FILE="$APP_PATH/Contents/Resources/NOTICE"
QWEN_LICENSE="$APP_PATH/Contents/Resources/Qwen3ASR-LICENSE-Apache-2.0"
SPEC_OUTPUT="$INSTALL_ROOT/muesli-cli-spec.json"

cleanup() {
  rm -rf "$INSTALL_ROOT"
}
trap cleanup EXIT

echo "Building isolated app bundle in $INSTALL_ROOT"
MUESLI_INSTALL_DIR="$INSTALL_ROOT" \
MUESLI_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
MUESLI_SKIP_SIGN=1 \
"$ROOT/scripts/build_native_app.sh" "$BUILD_CONFIG"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected packaged app at $APP_PATH" >&2
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Missing app executable at $APP_BIN" >&2
  exit 1
fi

if [[ ! -x "$CLI_BIN" ]]; then
  echo "Missing CLI executable at $CLI_BIN" >&2
  exit 1
fi

if [[ ! -x "$GIGAAM_HELPER" ]]; then
  echo "Missing ONNX GigaAM helper at $GIGAAM_HELPER" >&2
  exit 1
fi
find "$APP_PATH/Contents/MacOS" -maxdepth 1 -name 'libonnxruntime*.dylib' -type f | grep -q . || {
  echo "Missing ONNX Runtime dylib" >&2
  exit 1
}
[[ -s "$NOTICE_FILE" ]] || { echo "Missing bundled NOTICE" >&2; exit 1; }
[[ -s "$QWEN_LICENSE" ]] || { echo "Missing bundled Qwen3 Apache license" >&2; exit 1; }

"$CLI_BIN" spec > "$SPEC_OUTPUT"

if ! grep -q '"command" : "muesli-cli spec"' "$SPEC_OUTPUT"; then
  echo "Packaged CLI did not return the expected spec payload." >&2
  cat "$SPEC_OUTPUT" >&2
  exit 1
fi

echo "Packaged CLI smoke test passed."
echo "Verified:"
echo "  - $APP_BIN"
echo "  - $CLI_BIN"
echo "  - $GIGAAM_HELPER"
echo "  - bundled notices"
