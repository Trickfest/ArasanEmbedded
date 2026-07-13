#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="ci.yml"

usage() {
  cat <<'EOF'
Usage: Scripts/run-github-ci.sh [branch-or-tag]

Manually dispatch the optional ArasanEmbedded GitHub Actions workflow.
The ref must already exist on GitHub and contain the workflow_dispatch trigger.
When omitted, the current local branch is used; a detached checkout falls back
to the repository's default branch.

This helper does not commit or push local changes.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (( $# > 1 )); then
  usage >&2
  exit 2
fi

for command_name in git gh; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command is not installed: %s\n' "$command_name" >&2
    exit 1
  fi
done

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  printf 'GitHub CLI is not authenticated for github.com. Run: gh auth login\n' >&2
  exit 1
fi

cd "$ROOT_DIR"

if ! repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" ||
   [[ -z "$repository" ]]; then
  printf 'Could not resolve the GitHub repository from %s.\n' "$ROOT_DIR" >&2
  exit 1
fi

current_branch="$(git branch --show-current)"
ref="${1:-}"
if [[ -z "$ref" ]]; then
  ref="$current_branch"
fi
if [[ -z "$ref" ]]; then
  if ! ref="$(gh repo view "$repository" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)" ||
     [[ -z "$ref" ]]; then
    printf 'Could not determine a branch or tag to dispatch. Pass one explicitly.\n' >&2
    exit 1
  fi
fi

if ! workflow_yaml="$(gh workflow view "$WORKFLOW" --repo "$repository" --ref "$ref" --yaml 2>/dev/null)"; then
  printf 'Remote ref %s does not exist or does not contain %s in %s.\n' \
    "$ref" "$WORKFLOW" "$repository" >&2
  printf 'Publish the ref separately, then rerun this helper. It will not push for you.\n' >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]+workflow_dispatch:[[:space:]]*($|#)' <<<"$workflow_yaml"; then
  printf 'Remote workflow %s at ref %s is not configured for manual dispatch.\n' \
    "$WORKFLOW" "$ref" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  printf 'Warning: local uncommitted changes are not included in this run.\n' >&2
  printf 'The workflow will use the files already present on GitHub at %s.\n' \
    "$ref" >&2
fi
if [[ -n "$current_branch" && "$current_branch" == "$ref" ]]; then
  if remote_sha="$(
    git ls-remote --exit-code origin "refs/heads/$ref" 2>/dev/null |
      awk 'NR == 1 { print $1 }'
  )" && [[ -n "$remote_sha" ]]; then
    local_sha="$(git rev-parse HEAD)"
    if [[ "$local_sha" != "$remote_sha" ]]; then
      printf 'Warning: local HEAD %s differs from origin/%s at %s.\n' \
        "$local_sha" "$ref" "$remote_sha" >&2
      printf '%s\n' \
        'The workflow will run the remote commit; this helper will not push local commits.' >&2
    fi
  else
    printf 'Warning: could not compare local HEAD with origin/%s.\n' "$ref" >&2
  fi
fi

printf 'Dispatching %s for %s at %s...\n' "$WORKFLOW" "$repository" "$ref"
if ! dispatch_output="$(gh workflow run "$WORKFLOW" --repo "$repository" --ref "$ref" 2>&1)"; then
  printf 'GitHub rejected the workflow dispatch:\n%s\n' "$dispatch_output" >&2
  exit 1
fi

printf 'Dispatch accepted.\n'
if [[ -n "$dispatch_output" ]]; then
  printf '%s\n' "$dispatch_output"
fi
printf 'Workflow runs: https://github.com/%s/actions/workflows/%s\n' \
  "$repository" "$WORKFLOW"
printf 'Inspect recent manual runs with:\n'
printf '  gh run list --repo %s --workflow %s --event workflow_dispatch --limit 5\n' \
  "$repository" "$WORKFLOW"
