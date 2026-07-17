#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/native/ONNXGigaAMHelper/main.cpp"
OUTPUT_DIR="${1:?usage: build_onnx_gigaam_helper.sh OUTPUT_DIR}"

ORT_VERSION="1.27.1"
ORT_ARCHIVE="onnxruntime-osx-arm64-$ORT_VERSION.tgz"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/$ORT_ARCHIVE"
ORT_SHA256="e42b77a7281cc6e55141bf44fcfbac2c782b823a491bbb6ac33c781dd991f8a6"
ORT_CACHE="${MUESLI_ONNX_RUNTIME_CACHE_DIR:-$HOME/Library/Caches/muesli-onnxruntime}"
ORT_ROOT="${MUESLI_ONNX_RUNTIME_ROOT:-$ORT_CACHE/onnxruntime-osx-arm64-$ORT_VERSION}"
ARCHIVE_PATH="$ORT_CACHE/$ORT_ARCHIVE"

if [[ ! -f "$ORT_ROOT/include/onnxruntime_cxx_api.h" || ! -f "$ORT_ROOT/lib/libonnxruntime.$ORT_VERSION.dylib" ]]; then
  if [[ -n "${MUESLI_ONNX_RUNTIME_ROOT:-}" ]]; then
    echo "Invalid MUESLI_ONNX_RUNTIME_ROOT: $ORT_ROOT" >&2
    exit 1
  fi
  mkdir -p "$ORT_CACHE"
  if [[ ! -f "$ARCHIVE_PATH" ]]; then
    curl -fsSL "$ORT_URL" -o "$ARCHIVE_PATH.tmp"
    mv "$ARCHIVE_PATH.tmp" "$ARCHIVE_PATH"
  fi
  printf '%s  %s\n' "$ORT_SHA256" "$ARCHIVE_PATH" | shasum -a 256 -c -
  rm -rf "$ORT_ROOT"
  tar -xzf "$ARCHIVE_PATH" -C "$ORT_CACHE"
fi

mkdir -p "$OUTPUT_DIR"
xcrun clang++ \
  -std=c++17 \
  -O3 \
  -DNDEBUG \
  -arch arm64 \
  -mmacosx-version-min=14.2 \
  -I "$ORT_ROOT/include" \
  "$SOURCE" \
  -L "$ORT_ROOT/lib" \
  -lonnxruntime \
  -Wl,-rpath,@loader_path \
  -o "$OUTPUT_DIR/onnx-gigaam-helper"

cp "$ORT_ROOT/lib/libonnxruntime.$ORT_VERSION.dylib" \
  "$OUTPUT_DIR/libonnxruntime.$ORT_VERSION.dylib"
xcrun install_name_tool \
  -change @rpath/libonnxruntime.1.dylib \
  @loader_path/libonnxruntime.$ORT_VERSION.dylib \
  "$OUTPUT_DIR/onnx-gigaam-helper"
chmod +x "$OUTPUT_DIR/onnx-gigaam-helper"

otool -L "$OUTPUT_DIR/onnx-gigaam-helper" | grep -Fq \
  "@loader_path/libonnxruntime.$ORT_VERSION.dylib"
