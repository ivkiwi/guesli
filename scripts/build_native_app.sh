#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_spm_cache.sh"
PACKAGE_DIR="$ROOT/native/MuesliNative"
DIST_DIR="$ROOT/dist-native"
INSTALL_DIR="${MUESLI_INSTALL_DIR:-/Applications}"
BUILD_CONFIG="${1:-release}"
APP_BINARY="MuesliNativeApp"
CLI_BINARY="muesli-cli"
APP_NAME="${MUESLI_APP_NAME:-Guesli}"
APP_DISPLAY_NAME="${MUESLI_DISPLAY_NAME:-$APP_NAME}"
APP_BUNDLE_NAME="${MUESLI_APP_BUNDLE_NAME:-$APP_NAME.app}"
APP_EXECUTABLE_NAME="${MUESLI_EXECUTABLE_NAME:-Guesli}"
APP_SUPPORT_DIR_NAME="${MUESLI_SUPPORT_DIR_NAME:-Guesli}"
BUNDLE_ID="${MUESLI_BUNDLE_ID:-com.guesli.app}"
DEFAULT_APP_VERSION="0.7.1.7"
APP_VERSION="${MUESLI_BUILD_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUNDLE_VERSION="${MUESLI_BUNDLE_VERSION:-$APP_VERSION}"
APP_SHORT_VERSION="${MUESLI_SHORT_VERSION:-$APP_VERSION}"
SPARKLE_FEED_URL="${MUESLI_SPARKLE_FEED_URL-}"
SPARKLE_EDKEY="${MUESLI_SPARKLE_EDKEY-ok9CQBJ3f0MJ2GXuGBubc6VyeWyb5exmqP2b9DceqH4=}"
STAGED_APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME"
APP_DIR="$INSTALL_DIR/$APP_BUNDLE_NAME"
MLX_SWIFT_METALLIB_REVISION="e23ae6b2cf96737bbd31a34ed304123162f8c409"
DEFAULT_SIGN_IDENTITY="Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
SKIP_SIGN="${MUESLI_SKIP_SIGN:-0}"
PROVISIONING_PROFILE="${MUESLI_PROVISIONING_PROFILE:-}"
CODESIGN_TIMESTAMP="${MUESLI_CODESIGN_TIMESTAMP:---timestamp}"
if [[ "$CODESIGN_TIMESTAMP" == "none" ]]; then
  CODESIGN_TIMESTAMP="--timestamp=none"
fi

SWIFT_BUILD_ARGS=(--package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG")
if ! muesli_spm_scratch_disabled; then
  DEFAULT_SCRATCH_CHANNEL="release"
  if [[ "$BUILD_CONFIG" == "debug" ]]; then
    DEFAULT_SCRATCH_CHANNEL="$(muesli_worktree_spm_scratch_channel dev "$ROOT")"
  fi
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path "$DEFAULT_SCRATCH_CHANNEL")"
  mkdir -p "$SWIFTPM_SCRATCH_PATH"
  SWIFT_BUILD_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  echo "Using SwiftPM scratch path: $SWIFTPM_SCRATCH_PATH"
fi

mkdir -p "$DIST_DIR"

resolve_mlx_swift_dir() {
  local candidate
  local candidates=()
  if [[ -n "${SWIFTPM_SCRATCH_PATH:-}" ]]; then
    candidates+=("$SWIFTPM_SCRATCH_PATH/checkouts/mlx-swift")
  fi
  candidates+=(
    "$PACKAGE_DIR/.build/checkouts/mlx-swift"
    "$ROOT/.build/checkouts/mlx-swift"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate/Source/Cmlx/mlx-generated/metal" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

package_resolved_revision() {
  local identity="$1"
  awk -v identity="$identity" '
    $0 ~ "\"identity\" : \"" identity "\"" { in_pin = 1; next }
    in_pin && $0 ~ "\"identity\" : " { exit }
    in_pin && $0 ~ "\"revision\" : " {
      line = $0
      sub(/^.*"revision" : "/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$PACKAGE_DIR/Package.resolved"
}

verify_mlx_swift_revision() {
  local mlx_swift_dir="$1"
  local resolved_revision
  local checkout_revision
  resolved_revision="$(package_resolved_revision "mlx-swift")"

  if [[ -z "$resolved_revision" ]]; then
    echo "ERROR: mlx-swift revision is missing from $PACKAGE_DIR/Package.resolved." >&2
    exit 1
  fi
  if [[ "$resolved_revision" != "$MLX_SWIFT_METALLIB_REVISION" ]]; then
    echo "ERROR: mlx-swift resolved at $resolved_revision, expected $MLX_SWIFT_METALLIB_REVISION." >&2
    echo "ERROR: Update the MLX metallib compatibility guard before changing mlx-swift." >&2
    exit 1
  fi

  checkout_revision="$(git -C "$mlx_swift_dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$checkout_revision" && "$checkout_revision" != "$resolved_revision" ]]; then
    echo "ERROR: mlx-swift checkout is $checkout_revision, but Package.resolved pins $resolved_revision." >&2
    exit 1
  fi
}

resolve_metal_tool() {
  local env_name="$1"
  local tool_name="$2"
  local env_value="${!env_name:-}"
  local candidate

  if [[ -n "$env_value" ]]; then
    if [[ -x "$env_value" ]]; then
      printf '%s\n' "$env_value"
      return 0
    fi
    echo "ERROR: $env_name points to a non-executable path: $env_value" >&2
    return 1
  fi

  candidate="/Volumes/MetalToolchainCryptex/Metal.xctoolchain/usr/bin/$tool_name"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(xcrun -sdk macosx --find "$tool_name" 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

bundle_mlx_metallib() {
  local mlx_swift_dir
  local metal_dir
  local metal_bin
  local metallib_bin
  local tmp_dir
  local source
  local target
  local air
  local air_files=()

  if ! grep -Fq '"mlx-swift"' "$PACKAGE_DIR/Package.resolved" 2>/dev/null; then
    return 0
  fi

  if ! mlx_swift_dir="$(resolve_mlx_swift_dir)"; then
    echo "ERROR: mlx-swift checkout not found; cannot bundle mlx.metallib." >&2
    exit 1
  fi
  verify_mlx_swift_revision "$mlx_swift_dir"
  metal_dir="$mlx_swift_dir/Source/Cmlx/mlx-generated/metal"

  if ! metal_bin="$(resolve_metal_tool MUESLI_METAL_BIN metal)"; then
    echo "ERROR: Metal compiler not found. Run 'xcodebuild -downloadComponent MetalToolchain' or set MUESLI_METAL_BIN." >&2
    exit 1
  fi
  if ! metallib_bin="$(resolve_metal_tool MUESLI_METALLIB_BIN metallib)"; then
    echo "ERROR: Metal library linker not found. Run 'xcodebuild -downloadComponent MetalToolchain' or set MUESLI_METALLIB_BIN." >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/muesli-mlx-metallib.XXXXXX")"
  while IFS= read -r source; do
    target="$(basename "$source" .metal)"
    air="$tmp_dir/$target.air"
    if ! "$metal_bin" \
      -x metal \
      -Wall \
      -Wextra \
      -fno-fast-math \
      -Wno-c++17-extensions \
      -Wno-c++20-extensions \
      -mmacosx-version-min=14.2 \
      -I"$metal_dir" \
      -c "$source" \
      -o "$air"; then
      echo "ERROR: Metal compile failed for $source" >&2
      rm -rf "$tmp_dir"
      exit 1
    fi
    air_files+=("$air")
  done < <(find "$metal_dir" -maxdepth 1 -type f -name "*.metal" | sort)

  if [[ ${#air_files[@]} -eq 0 ]]; then
    echo "ERROR: mlx-swift checkout has no generated Metal sources at $metal_dir." >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  if ! "$metallib_bin" "${air_files[@]}" -o "$STAGED_APP_DIR/Contents/MacOS/mlx.metallib"; then
    echo "ERROR: Metal library link failed for $STAGED_APP_DIR/Contents/MacOS/mlx.metallib" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi
  rm -rf "$tmp_dir"
  echo "Bundled mlx.metallib from $metal_dir"
}

set +e
swift build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift build failed." >&2
  exit $status
fi

set +e
swift build "${SWIFT_BUILD_ARGS[@]}" --product "$CLI_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift CLI build failed." >&2
  exit $status
fi

BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_BINARY"
CLI_BIN="$BIN_DIR/$CLI_BINARY"

rm -rf "$STAGED_APP_DIR"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"

cp "$APP_BIN" "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
cp "$CLI_BIN" "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"

# Bundle SwiftPM-linked frameworks (rpath is @loader_path, so they go next to the binary)
for framework in "$BIN_DIR"/*.framework; do
  [[ -d "$framework" ]] || continue
  ditto "$framework" "$STAGED_APP_DIR/Contents/MacOS/$(basename "$framework")"
done

# Bundle SPM resource bundles (CoreML models, privacy manifests, etc.)
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$STAGED_APP_DIR/Contents/Resources/$(basename "$bundle")"
done

# Bundle optional LocalVQE runtime if it has been built for local AEC testing.
LOCALVQE_LIB_DIR="${MUESLI_LOCALVQE_LIB_DIR:-$ROOT/native/MuesliNative/LocalVQE/lib}"
if [[ -d "$LOCALVQE_LIB_DIR" ]]; then
  find "$LOCALVQE_LIB_DIR" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) \( -type f -o -type l \) | while read -r dylib; do
    cp -P "$dylib" "$STAGED_APP_DIR/Contents/MacOS/$(basename "$dylib")"
  done
fi
LOCALVQE_MODEL_PATH="${MUESLI_LOCALVQE_MODEL_PATH:-$ROOT/native/MuesliNative/LocalVQE/models/localvqe-v1.2-1.3M-f32.gguf}"
if [[ -f "$LOCALVQE_MODEL_PATH" ]]; then
  mkdir -p "$STAGED_APP_DIR/Contents/Resources/Models/localvqe"
  cp "$LOCALVQE_MODEL_PATH" "$STAGED_APP_DIR/Contents/Resources/Models/localvqe/localvqe-v1.2-1.3M-f32.gguf"
fi

bundle_mlx_metallib

# Bundle assets
cp "$ROOT/assets/menu_m_template.png" "$STAGED_APP_DIR/Contents/Resources/menu_m_template.png"
cp "$ROOT/assets/muesli.icns" "$STAGED_APP_DIR/Contents/Resources/muesli.icns"
cp "$ROOT/assets/zoom-app.png" "$STAGED_APP_DIR/Contents/Resources/zoom-app.png"
cp "$ROOT/assets/Google_Meet_icon_(2020).svg.png" "$STAGED_APP_DIR/Contents/Resources/google-meet.png"
cp "$ROOT/assets/Microsoft_Office_Teams_(2025–present).svg.png" "$STAGED_APP_DIR/Contents/Resources/teams.png"
cp "$ROOT/assets/Slack_icon_2019.svg.png" "$STAGED_APP_DIR/Contents/Resources/slack.png"
cp "$ROOT/assets/Nvidia_logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/nvidia-logo.png"
cp "$ROOT/assets/OpenAI_Logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/openai-logo.png"
cp "$ROOT/assets/cohere.png" "$STAGED_APP_DIR/Contents/Resources/cohere-logo.png"
cp "$ROOT/assets/Qwen_logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/qwen-logo.png"
if [[ -d "$ROOT/assets/fonts" ]]; then
  ditto "$ROOT/assets/fonts" "$STAGED_APP_DIR/Contents/Resources/fonts"
fi
if [[ -d "$ROOT/assets/audio" ]]; then
  ditto "$ROOT/assets/audio" "$STAGED_APP_DIR/Contents/Resources/audio"
fi

cat > "$STAGED_APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUNDLE_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_SHORT_VERSION</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>muesli.icns</string>
  <key>MuesliSupportDirectoryName</key>
  <string>$APP_SUPPORT_DIR_NAME</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.2</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>$APP_DISPLAY_NAME records microphone audio for dictation.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>$APP_DISPLAY_NAME monitors keyboard events to trigger push-to-talk dictation.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>$APP_DISPLAY_NAME captures system audio from other applications during meeting recordings.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>$APP_DISPLAY_NAME captures screen content for meeting context.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>$APP_DISPLAY_NAME reads calendar events to help with meeting recordings.</string>
PLIST

if [[ -n "$SPARKLE_FEED_URL" ]]; then
  cat >> "$STAGED_APP_DIR/Contents/Info.plist" <<PLIST
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_EDKEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
PLIST
fi

cat >> "$STAGED_APP_DIR/Contents/Info.plist" <<'PLIST'
</dict>
</plist>
PLIST

# Replace existing app (no prompt — that's what this script is for)
if [[ -d "$APP_DIR" ]]; then
  echo "Replacing $APP_DIR"
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
ditto "$STAGED_APP_DIR" "$APP_DIR"

if [[ "$SKIP_SIGN" != "1" ]]; then
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "Signing identity not found: $SIGN_IDENTITY" >&2
    echo "For local contributor builds without this certificate, run: MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh" >&2
    exit 1
  fi

  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
      echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
      exit 1
    fi
    cp "$PROVISIONING_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
  fi

  # Sign all bundled frameworks, including nested Sparkle executables.
  find "$APP_DIR/Contents/MacOS" -maxdepth 1 -name "*.framework" -type d | while read -r framework; do
    if [[ "$(basename "$framework")" == "Sparkle.framework" ]]; then
      find "$framework" -type f -perm +111 | while read -r binary; do
        if file "$binary" | grep -q "Mach-O"; then
          codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
            --sign "$SIGN_IDENTITY" "$binary"
        fi
      done
      find "$framework" -name "*.xpc" -type d | while read -r xpc; do
        codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
          --sign "$SIGN_IDENTITY" "$xpc"
      done
      find "$framework" -name "*.app" -type d | while read -r app; do
        codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
          --sign "$SIGN_IDENTITY" "$app"
      done
    fi

    codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
      --sign "$SIGN_IDENTITY" \
      "$framework"
  done

  # Sign loose native runtime libraries loaded via dlopen. Hardened runtime
  # library validation requires these to have the same Team ID as the app.
  find "$APP_DIR/Contents/MacOS" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) -type f | while read -r library; do
    if file "$library" | grep -q "Mach-O"; then
      codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
        --sign "$SIGN_IDENTITY" \
        "$library"
    fi
  done

  find "$APP_DIR/Contents/MacOS" -maxdepth 1 -name "*.metallib" -type f | while read -r library; do
    codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
      --sign "$SIGN_IDENTITY" \
      "$library"
  done

  codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/muesli-cli"

  # Sign the app bundle with hardened runtime, secure timestamp, and entitlements
  ENTITLEMENTS="${MUESLI_ENTITLEMENTS:-$ROOT/scripts/Muesli.entitlements}"
  CODESIGN_ENTITLEMENTS="$ENTITLEMENTS"
  TEMP_ENTITLEMENTS=""
  APS_ENVIRONMENT="${MUESLI_APS_ENVIRONMENT:-}"
  ICLOUD_CONTAINER_ENVIRONMENT="${MUESLI_ICLOUD_CONTAINER_ENVIRONMENT:-}"
  PROFILE_PLIST=""
  SIGN_TEMP_FILES=()
  cleanup_sign_temp_files() {
    local temp_file
    for temp_file in "${SIGN_TEMP_FILES[@]:-}"; do
      [[ -n "$temp_file" ]] && rm -f "$temp_file"
    done
  }
  trap cleanup_sign_temp_files EXIT
  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/muesli-profile.XXXXXX")"
    SIGN_TEMP_FILES+=("$PROFILE_PLIST")
    if ! security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
      echo "ERROR: could not decode provisioning profile: $PROVISIONING_PROFILE" >&2
      exit 1
    fi

    PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    if [[ -z "$PROFILE_APP_IDENTIFIER" ]]; then
      PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    fi
    if [[ -n "$PROFILE_APP_IDENTIFIER" ]]; then
      PROFILE_BUNDLE_ID="${PROFILE_APP_IDENTIFIER#*.}"
      # shellcheck disable=SC2053 # Intentionally glob-match wildcard App IDs such as com.guesli.*.
      if [[ "$BUNDLE_ID" != $PROFILE_BUNDLE_ID ]]; then
        echo "ERROR: provisioning profile app identifier '$PROFILE_APP_IDENTIFIER' does not match bundle ID '$BUNDLE_ID'." >&2
        exit 1
      fi
      echo "Using provisioning profile app identifier: $PROFILE_APP_IDENTIFIER"
    fi

    if [[ -z "$APS_ENVIRONMENT" ]]; then
      APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$PROFILE_PLIST" 2>/dev/null || true)"
      if [[ -z "$APS_ENVIRONMENT" ]]; then
        APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$PROFILE_PLIST" 2>/dev/null || true)"
      fi
    fi
  fi

  if [[ -n "$APS_ENVIRONMENT" || -n "$PROFILE_PLIST" ]]; then
    TEMP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/muesli-entitlements.XXXXXX")"
    SIGN_TEMP_FILES+=("$TEMP_ENTITLEMENTS")
    cp "$ENTITLEMENTS" "$TEMP_ENTITLEMENTS"
    copy_profile_string_entitlement() {
      local key="$1"
      local value
      [[ -n "$PROFILE_PLIST" ]] || return 0
      value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$PROFILE_PLIST" 2>/dev/null || true)"
      [[ -n "$value" ]] || return 0
      if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$TEMP_ENTITLEMENTS" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$TEMP_ENTITLEMENTS"
      fi
    }
    copy_explicit_icloud_container_environment_entitlement() {
      local key="$1"
      local value
      [[ -n "$PROFILE_PLIST" ]] || return 0
      [[ -n "$ICLOUD_CONTAINER_ENVIRONMENT" ]] || return 0
      /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$PROFILE_PLIST" >/dev/null 2>&1 || return 0
      value="$(printf '%s' "$ICLOUD_CONTAINER_ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
      if [[ "$value" != "development" && "$value" != "production" ]]; then
        echo "ERROR: unsupported iCloud container environment '$value'. Expected development or production." >&2
        exit 1
      fi
      /usr/libexec/PlistBuddy -c "Delete :$key" "$TEMP_ENTITLEMENTS" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :$key string $value" "$TEMP_ENTITLEMENTS"
      echo "Using iCloud entitlement: $key=$value"
    }
    copy_profile_string_entitlement "com.apple.application-identifier"
    copy_profile_string_entitlement "application-identifier"
    copy_profile_string_entitlement "com.apple.developer.team-identifier"
    # Do not copy this profile entitlement by default: Apple profiles may store
    # it as an array, while CloudKit expects a single lowercase runtime value.
    copy_explicit_icloud_container_environment_entitlement "com.apple.developer.icloud-container-environment"
    if [[ -n "$APS_ENVIRONMENT" ]]; then
      if ! /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment $APS_ENVIRONMENT" "$TEMP_ENTITLEMENTS" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.aps-environment string $APS_ENVIRONMENT" "$TEMP_ENTITLEMENTS"
      fi
    fi
    CODESIGN_ENTITLEMENTS="$TEMP_ENTITLEMENTS"
    if [[ -n "$APS_ENVIRONMENT" ]]; then
      echo "Using APNs entitlement: com.apple.developer.aps-environment=$APS_ENVIRONMENT"
    fi
  fi
  codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
    --entitlements "$CODESIGN_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"
  if [[ -n "$PROFILE_PLIST" ]]; then
    rm -f "$PROFILE_PLIST"
  fi
  if [[ -n "$TEMP_ENTITLEMENTS" ]]; then
    rm -f "$TEMP_ENTITLEMENTS"
  fi
  trap - EXIT

  # Deep-verify entire bundle — fail fast if any component has an invalid signature
  echo "Verifying deep signature..."
  if ! codesign --verify --deep --strict "$APP_DIR" 2>&1; then
    echo "ERROR: Deep signature verification failed" >&2
    exit 1
  fi
  echo "  Deep signature valid."
else
  # No Developer ID certificate: ad-hoc sign for local dev instead of leaving the
  # bundle with SwiftPM's incoherent per-binary signature. An ad-hoc *bundle* signature
  # binds Info.plist and adopts the bundle's CFBundleIdentifier (com.guesli.*) as the
  # signing identity, which macOS TCC needs to attribute Accessibility / Input-Monitoring
  # grants to the running process. Without it, AXIsProcessTrusted()/CGPreflightListenEventAccess()
  # keep returning false even after the user grants permission, so onboarding stalls.
  #
  # Note: ad-hoc signatures have no stable designated requirement, so the cdhash changes on
  # every rebuild and macOS privacy grants must be re-approved after each dev build. For grants
  # that persist across rebuilds, create a self-signed code-signing certificate and pass its name
  # via MUESLI_SIGN_IDENTITY. No hardened runtime here: ad-hoc has no Team ID, so library
  # validation would block dlopen of the bundled frameworks/dylibs.
  LOCAL_SIGN_IDENTITY="-"
  if [[ -n "${MUESLI_SIGN_IDENTITY:-}" ]]; then
    LOCAL_SIGN_IDENTITY="$MUESLI_SIGN_IDENTITY"
    if ! security find-identity -v -p codesigning | grep -Fq "$LOCAL_SIGN_IDENTITY"; then
      echo "Signing identity not found: $LOCAL_SIGN_IDENTITY" >&2
      exit 1
    fi
    echo "Local signing with MUESLI_SIGN_IDENTITY=$LOCAL_SIGN_IDENTITY (MUESLI_SKIP_SIGN=1)..."
  else
    echo "Ad-hoc signing for local dev (MUESLI_SKIP_SIGN=1; no Developer ID)..."
  fi
  ENTITLEMENTS="${MUESLI_ENTITLEMENTS:-$ROOT/scripts/MuesliLocalOnly.entitlements}"

  find "$APP_DIR/Contents/MacOS" -maxdepth 1 -name "*.framework" -type d | while read -r framework; do
    # Sign every nested standalone Mach-O (e.g. Sparkle's Versions/B/Autoupdate),
    # then nested .xpc/.app bundles, then the framework itself — mirroring the
    # Developer-ID path so `codesign --verify --deep --strict` cannot fail on a
    # nested executable the framework-level sign doesn't reseal.
    find "$framework" -type f -perm +111 | while read -r binary; do
      if file "$binary" | grep -q "Mach-O"; then
          codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$binary"
      fi
    done
    find "$framework" \( -name "*.xpc" -o -name "*.app" \) -type d | while read -r nested; do
      codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$nested"
    done
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$framework"
  done

  find "$APP_DIR/Contents/MacOS" -maxdepth 1 \( -name "*.dylib" -o -name "*.so" \) -type f | while read -r library; do
    if file "$library" | grep -q "Mach-O"; then
      codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$library"
    fi
  done

  find "$APP_DIR/Contents/MacOS" -maxdepth 1 -name "*.metallib" -type f | while read -r library; do
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$library"
  done

  if [[ -f "$APP_DIR/Contents/MacOS/muesli-cli" ]]; then
    codesign --force --sign "$LOCAL_SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/muesli-cli"
  fi

  # Sign the bundle last so the Info.plist binding / identity stick.
  codesign --force --sign "$LOCAL_SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"

  echo "Verifying ad-hoc signature..."
  if ! codesign --verify --deep --strict "$APP_DIR" 2>&1; then
    echo "ERROR: ad-hoc signature verification failed" >&2
    exit 1
  fi
  echo "  Local signature valid. Re-approve macOS privacy permissions if prompted after ad-hoc rebuilds."
fi

rm -rf "$STAGED_APP_DIR"

echo "Installed $APP_DIR ($(du -sh "$APP_DIR" | cut -f1))"
