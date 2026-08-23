#!/usr/bin/env bash

[[ -n "${_MUESLI_LOCALVQE_RUNTIME_LOADED:-}" ]] && return 0
_MUESLI_LOCALVQE_RUNTIME_LOADED=1

muesli_collect_localvqe_runtime() {
  local dir="$1"
  local listing=""
  local -a found=()
  if [[ -d "$dir" ]]; then
    if ! listing="$(find "$dir" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) \( -type f -o -type l \))"; then
      echo "Could not enumerate LocalVQE runtime in $dir" >&2
      return 1
    fi
    while IFS= read -r library; do
      [[ -n "$library" ]] || continue
      found+=("$library")
    done <<< "$listing"
  fi
  printf '%s\n' "${found[@]+"${found[@]}"}" | sort
}

muesli_localvqe_runtime_is_complete() {
  local dir="$1"
  local primary=""
  local ggml_umbrella=""
  local listing=""
  local -a libraries=()

  listing="$(muesli_collect_localvqe_runtime "$dir")" || return 1
  while IFS= read -r library; do
    [[ -n "$library" ]] && libraries+=("$library")
  done <<< "$listing"

  for name in liblocalvqe.dylib liblocalvqe.0.1.0.dylib liblocalvqe.0.dylib liblocalvqe_shared.dylib; do
    if [[ -e "$dir/$name" ]]; then
      primary="$dir/$name"
      break
    fi
  done
  [[ -n "$primary" ]] || { echo "LocalVQE primary library missing in $dir" >&2; return 1; }

  for library in "${libraries[@]}"; do
    case "$(basename "$library")" in
      libggml.dylib|libggml.[0-9]*.dylib)
        ggml_umbrella="$library"
        break
        ;;
    esac
  done
  [[ -n "$ggml_umbrella" ]] || { echo "LocalVQE runtime incomplete: libggml umbrella dylib missing in $dir" >&2; return 1; }
  find "$dir" -maxdepth 1 -name 'libggml-base*.dylib' \( -type f -o -type l \) | grep -q . || {
    echo "LocalVQE runtime incomplete: libggml-base*.dylib missing in $dir" >&2
    return 1
  }

  if command -v otool >/dev/null 2>&1; then
    local inspection line dependency base
    for library in "${libraries[@]}"; do
      inspection="$(otool -L "$library" 2>/dev/null)" || {
        echo "LocalVQE runtime incomplete: otool could not inspect $(basename "$library")" >&2
        return 1
      }
      [[ -n "$inspection" ]] || return 1
      while IFS= read -r line; do
        [[ "$line" == [[:space:]]* ]] || continue
        dependency="${line#"${line%%[![:space:]]*}"}"
        dependency="${dependency%% *}"
        base="$(basename "$dependency")"
        case "$base" in
          liblocalvqe*|libggml*)
            [[ -e "$dir/$base" ]] || {
              echo "LocalVQE runtime incomplete: $base missing (required by $(basename "$library"))" >&2
              return 1
            }
            ;;
        esac
      done <<< "$inspection"
    done
  fi
}
