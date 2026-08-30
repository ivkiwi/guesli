#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/localvqe_runtime.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/guesli-localvqe-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/otool" <<'SH'
#!/usr/bin/env bash
printf '%s:\n' "${@: -1}"
SH
chmod +x "$TMP/bin/otool"
export PATH="$TMP/bin:$PATH"

touch "$TMP/liblocalvqe.dylib" "$TMP/libggml.dylib" "$TMP/libggml-base.dylib"
muesli_localvqe_runtime_is_complete "$TMP"

rm "$TMP/libggml-base.dylib"
if muesli_localvqe_runtime_is_complete "$TMP" >/dev/null 2>&1; then
  echo "Incomplete LocalVQE runtime was accepted" >&2
  exit 1
fi

echo "LocalVQE runtime validation tests passed."
