#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/release-macos-app.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guesli-release-security.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

test "$(MUESLI_RELEASE_VERSION='0.8.0-beta.2' GITHUB_RUN_NUMBER=41 "$ROOT/scripts/release_version.sh")" = '0.8.0-beta.2'
test "$(MUESLI_RELEASE_VERSION='' GITHUB_RUN_NUMBER=41 "$ROOT/scripts/release_version.sh")" = '0.0.0-beta.41'
payload="\$(touch $TMP/injected)"
if MUESLI_RELEASE_VERSION="$payload" GITHUB_RUN_NUMBER=41 \
  "$ROOT/scripts/release_version.sh" >/dev/null 2>&1; then
  echo "Unsafe release version was accepted" >&2
  exit 1
fi
test ! -e "$TMP/injected"

cat > "$TMP/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  */actions/workflows/ci.yml/runs*)
    printf '%s\t%s\n' 101 "${FAKE_RUN_SHA:-$GITHUB_SHA}"
    ;;
  */actions/runs/101/jobs*)
    if [[ "${FAKE_GATE_RESULT:-success}" == "success" ]]; then
      printf '%s\n' 202
    fi
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod +x "$TMP/gh"

SHA='0123456789abcdef0123456789abcdef01234567'
GITHUB_REPOSITORY=ivkiwi/guesli GITHUB_SHA="$SHA" MUESLI_GH_BIN="$TMP/gh" \
  "$ROOT/scripts/require_successful_ci_gate.sh" >/dev/null
if GITHUB_REPOSITORY=ivkiwi/guesli GITHUB_SHA="$SHA" MUESLI_GH_BIN="$TMP/gh" \
  FAKE_GATE_RESULT=failure "$ROOT/scripts/require_successful_ci_gate.sh" >/dev/null 2>&1; then
  echo "Release gate accepted a CI run without successful ci-gate" >&2
  exit 1
fi
if GITHUB_REPOSITORY=ivkiwi/guesli GITHUB_SHA="$SHA" MUESLI_GH_BIN="$TMP/gh" \
  FAKE_RUN_SHA=ffffffffffffffffffffffffffffffffffffffff \
  "$ROOT/scripts/require_successful_ci_gate.sh" >/dev/null 2>&1; then
  echo "Release gate accepted CI from a different commit" >&2
  exit 1
fi

grep -Fq 'needs: authorize' "$WORKFLOW"
grep -Fq 'actions: read' "$WORKFLOW"
grep -Fq 'contents: write' "$WORKFLOW"
grep -Fq 'MUESLI_RELEASE_VERSION: ${{ inputs.version }}' "$WORKFLOW"
test "$(grep -Fc '${{ inputs.version }}' "$WORKFLOW")" -eq 1
if grep -Fq '${{ github.event.inputs.version }}' "$WORKFLOW"; then
  echo "Release input is still interpolated into shell source" >&2
  exit 1
fi

echo "Release workflow security tests passed."
