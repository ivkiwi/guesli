#!/usr/bin/env bash
set -euo pipefail

native_or_packaging=false
browser_extension=false
release_update=false

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    native/*|assets/*|NOTICE|LICENSE|scripts/*.sh|scripts/*.py|.github/workflows/ci.yml)
      native_or_packaging=true
      ;;
  esac
  case "$path" in
    browser-extension/*)
      browser_extension=true
      native_or_packaging=true
      ;;
  esac
  case "$path" in
    .github/workflows/release-macos-app.yml|docs/appcast-guesli.xml|scripts/build_native_app.sh|scripts/build_localvqe.sh|scripts/build_onnx_gigaam_helper.sh|scripts/localvqe_runtime.sh|scripts/merge_appcast_item.py|scripts/test_merge_appcast_item.py|scripts/test_localvqe_runtime_validation.sh|scripts/test_packaged_cli.sh|scripts/verify_update_flow.sh|NOTICE|LICENSE|native/MuesliNative/Sources/MuesliCore/Qwen3ASR/LICENSE-Apache-2.0)
      release_update=true
      native_or_packaging=true
      ;;
  esac
done

echo "native_or_packaging=$native_or_packaging"
echo "browser_extension=$browser_extension"
echo "release_update=$release_update"
