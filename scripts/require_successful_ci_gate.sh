#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
sha="${GITHUB_SHA:?GITHUB_SHA is required}"
gh_bin="${MUESLI_GH_BIN:-gh}"

if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: invalid GITHUB_REPOSITORY: $repo" >&2
  exit 2
fi
if [[ ! "$sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR: invalid GITHUB_SHA: $sha" >&2
  exit 2
fi

runs="$("$gh_bin" api \
  "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$sha&status=completed&per_page=100" \
  --jq '.workflow_runs[] | select(.conclusion == "success") | [.id, .head_sha] | @tsv')"

while IFS=$'\t' read -r run_id head_sha; do
  [[ -n "$run_id" && "$head_sha" == "$sha" ]] || continue
  gate_jobs="$("$gh_bin" api \
    "repos/$repo/actions/runs/$run_id/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | select(.name == "ci-gate" and .conclusion == "success") | .id')"
  if [[ -n "$gate_jobs" ]]; then
    echo "CI ci-gate passed for $sha in run $run_id."
    exit 0
  fi
done <<< "$runs"

echo "ERROR: no successful CI ci-gate found for commit $sha." >&2
exit 1
