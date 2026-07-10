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
# v2 (2026-07-10): merge-path CALLERS check — oracle-fleet ran with no update-pr-branch caller and
# an armed PR deadlocked BEHIND (TICK-LOG meta-3). Every stack repo must carry both callers.
# Requires gh (CI has it); skipped loudly when absent so the lint stays runnable offline.
# -iac repos are CI-gated deploy TARGETS (require_approval=false; FU-052 excludes them from the
# fixer flow) — their pin PRs merge on CI alone, so the armed-PR-stall class doesn't apply.
CALLERS_EXEMPT="oracle-iac sleep-iac"
if command -v gh >/dev/null 2>&1; then
  for repo in $stack_repos; do
    case " $CALLERS_EXEMPT " in *" $repo "*) continue;; esac
    # PROBE first, per rule #6: in homelab CI the Actions token is HOMELAB-scoped, so reads of the
    # other (private) repos 404 — that is "cannot see", never "missing" (it failed INTO six false
    # MISSINGs and blocked the deploy-pin auto-merge on PR #21, 2026-07-10). Authenticated contexts
    # (jail, coordinator) still enforce the real check.
    if ! gh api "repos/${ORG:-teststuffstash}/${repo}" --jq .name >/dev/null 2>&1; then
      echo "agents-registration-lint: cannot read ${repo} with this token — callers check SKIPPED for it (probe failure ≠ missing)" >&2
      continue
    fi
    for wf in update-pr-branch renovate-approve; do
      if ! gh api "repos/${ORG:-teststuffstash}/${repo}/contents/.github/workflows/${wf}.yml" --jq .name >/dev/null 2>&1 \
         && ! gh api "repos/${ORG:-teststuffstash}/${repo}/contents/.github/workflows/${wf}.yaml" --jq .name >/dev/null 2>&1; then
        echo "MISSING: ${repo} has no .github/workflows/${wf}.y(a)ml (merge-path caller — armed PRs stall without it)" >&2
        fail=1
      fi
    done
  done
else
  echo "agents-registration-lint: gh unavailable — merge-path callers check SKIPPED (not a pass)" >&2
fi

if [ "$fail" -ne 0 ]; then
  echo "agents-registration-lint: FAILED — a stack repo is invisible to the coordinator/reviewer" >&2
  echo "token (the stale-registration class; add it to the list AND verify docs/github-apps.md" >&2
  echo "covers it, or ESO token generation 422s)." >&2
  exit 1
fi
echo "agents-registration-lint: ok ($(printf '%s\n' "$stack_repos" | wc -l | tr -d ' ') stack repos covered in both token lists)"
