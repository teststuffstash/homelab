#!/usr/bin/env bash
# agents-registration-lint — the stale-registration gate (TICK-LOG meta-session 1: FIVE of six
# reflex gaps in one day were this class — a repo in the stack registry missing from some
# per-identity token list). Deterministic check: every repo in agents/stacks.json appears in the
# coordinator-git AND reviewer-git `repositories:` lists. Interim until the AgentStack XRD (FU-048)
# renders all of these from one claim; runs in CI next to argocd-validate-pins.
#
#   devbox run agents-registration-lint
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# The token YAMLs are shaped `repositories:\n    - name  # comment` — extract the bare names.
list_repos() { # <file>
  awk '
    /^[[:space:]]+repositories:/ { f=1; next }
    f && /^[[:space:]]+-[[:space:]]/ {
      line=$0; sub(/#.*/,"",line); sub(/^[[:space:]]+-[[:space:]]*/,"",line)
      gsub(/[[:space:]]/,"",line); if (line != "") print line; next
    }
    f { exit }
  ' "$1"
}

stack_repos="$(jq -r '.stacks[].repos[]' "$HERE/agents/stacks.json" | sort -u)"
fail=0
for target in agents/coordinator/git-token.yaml agents/coordinator/reviewer-git.yaml; do
  have="$(list_repos "$HERE/$target")"
  for repo in $stack_repos; do
    if ! printf '%s\n' "$have" | grep -qx "$repo"; then
      echo "MISSING: $repo (in agents/stacks.json) not in $target repositories: list" >&2
      fail=1
    fi
  done
done
if [ "$fail" -ne 0 ]; then
  echo "agents-registration-lint: FAILED — a stack repo is invisible to the coordinator/reviewer" >&2
  echo "token (the stale-registration class; add it to the list AND verify docs/github-apps.md" >&2
  echo "covers it, or ESO token generation 422s)." >&2
  exit 1
fi
echo "agents-registration-lint: ok ($(printf '%s\n' "$stack_repos" | wc -l | tr -d ' ') stack repos covered in both token lists)"
