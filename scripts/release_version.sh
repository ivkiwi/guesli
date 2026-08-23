#!/usr/bin/env bash
set -euo pipefail

version="${MUESLI_RELEASE_VERSION:-}"
if [[ -z "$version" ]]; then
  version="0.0.0-beta.${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
fi

if [[ ${#version} -gt 64 || ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: release version must be 1-64 characters: ASCII letters, digits, dot, underscore, or hyphen." >&2
  exit 2
fi

printf '%s\n' "$version"
