#!/usr/bin/env bash
# agents-registration-lint — the stale-registration gate (TICK-LOG meta-session 1: FIVE of six
# reflex gaps in one day were this class — a repo in the stack registry missing from some
# per-identity token list). Deterministic check: every repo in agents/stacks.json appears in the
# coordinator-git AND reviewer-git `repositories:` lists. stacks.json is the committed MIRROR of
# the AgentStack claims (FU-048; CI has no cluster access — the ADR-085 build-time question), so
# this lint doubles as the mirror's freshness incentive; runs in CI next to argocd-validate-pins.
#
#   devbox run agents-registration-lint
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# The token YAMLs are shaped `repositories:\n    - name  # comment` — extract the bare names.
# ⚠ Reads the file ONCE into memory and runs both the extraction and the raw item count on that
# single buffer, then asserts they AGREE (homelab#168): on 2026-08-08 CI reported circles-iac
# MISSING from a tree that verifiably contained it — a one-shot flake whose shape (one adjacent
# entry dropped) smelled like a truncated read. Rule #6: a broken probe must fail as PROBE-FAIL,
# never report false content. A real missing entry changes BOTH counts equally, so the invariant
# only trips when the parse and the raw view of the SAME bytes disagree.
list_repos() { # <file>
  local buf extracted raw n_ex n_raw
  buf="$(cat "$1")"
  extracted="$(printf '%s\n' "$buf" | awk '
    /^[[:space:]]+repositories:/ { f=1; next }
    f && /^[[:space:]]+-[[:space:]]/ {
      line=$0; sub(/#.*/,"",line); sub(/^[[:space:]]+-[[:space:]]*/,"",line)
      gsub(/[[:space:]]/,"",line); if (line != "") print line; next
    }
    f { exit }
  ')"
  raw="$(printf '%s\n' "$buf" | awk '
    /^[[:space:]]+repositories:/ { f=1; next }
    f && /^[[:space:]]+-[[:space:]]/ { n++; next }
    f { exit }
    END { print n+0 }
  ')"
  n_ex="$(printf '%s\n' "$extracted" | grep -c . || true)"
  n_raw="${raw:-0}"
  if [ "$n_ex" -ne "$n_raw" ]; then
    echo "agents-registration-lint: PROBE-FAIL — extraction/raw mismatch on $1 (${n_ex} extracted vs ${n_raw} raw '- ' items in the repositories block). The parse is broken or the read was torn; refusing to report MISSING from a probe that disagrees with itself (homelab#168)." >&2
    exit 3
  fi
  printf '%s\n' "$extracted"
}

# --self-test: prove the PROBE-FAIL path fires on a torn/parse-hostile fixture, and the normal
# path still extracts. Runs on EVERY invocation (cheap, <10ms) so the probe proves itself in the
# same CI run whose verdict depends on it — a self-test that only runs by hand is decoration.
registration_lint_self_test() {
  local d; d="$(mktemp -d)"
  # Positive control: 2 entries, one with a comment → extracts 2.
  printf '  repositories:\n    - alpha  # c\n    - beta\n  other:\n' > "$d/ok.yaml"
  [ "$(list_repos "$d/ok.yaml" | tr '\n' ' ')" = "alpha beta " ] \
    || { echo "agents-registration-lint: SELF-TEST FAILED — positive control broke" >&2; rm -rf "$d"; exit 3; }
  # Negative control: an item line the extractor drops but the raw count sees (comment-only value)
  # → the two views of one buffer disagree → PROBE-FAIL (exit 3) is REQUIRED.
  printf '  repositories:\n    - alpha\n    - # torn\n' > "$d/torn.yaml"
  if ( list_repos "$d/torn.yaml" >/dev/null 2>&1 ); then
    echo "agents-registration-lint: SELF-TEST FAILED — torn fixture did not PROBE-FAIL" >&2
    rm -rf "$d"; exit 3
  fi
  rm -rf "$d"
}
registration_lint_self_test

stack_repos="$(jq -r '.stacks[].repos[]' "$HERE/agents/stacks.json" | sort -u)"
fail=0
# TOKEN-LIST exemptions: stack repos the homelab-agents/-reviewer Apps DON'T cover yet — adding
# them to the lists before the App install 422s the ESO generator and kills the LIVE token for
# every repo. Each entry is a pending OPERATOR install click; remove the entry (and add the repo
# to both lists) the moment the install lands (the exporter /apps page confirms). Empty today.
TOKEN_EXEMPT=""
for target in agents/coordinator/git-token.yaml agents/coordinator/reviewer-git.yaml; do
  have="$(list_repos "$HERE/$target")"
  for repo in $stack_repos; do
    case " $TOKEN_EXEMPT " in *" $repo "*)
      echo "agents-registration-lint: ${repo} token-list check SKIPPED (App install pending — see TOKEN_EXEMPT)" >&2
      continue;;
    esac
    if ! printf '%s\n' "$have" | grep -qx "$repo"; then
      echo "MISSING: $repo (in agents/stacks.json) not in $target repositories: list" >&2
      fail=1
    fi
  done
done
# v2 (2026-07-10): merge-path CALLERS check — oracle-fleet ran with no update-pr-branch caller and
# an armed PR deadlocked BEHIND (TICK-LOG meta-3). Every stack repo must carry the caller.
# v3 (2026-08-26): the update-pr-branch caller REQUIREMENT RETIRED with the callers themselves —
# ADR-111 moved the updater in-cluster (homelab#745), so only renovate-approve remains checkable.
# (ci's homelab-scoped token SKIPs this whole block on foreign repos, so the stale requirement
# only ever redded authenticated jail runs — found at the oracle-chainless mirror edit.)
# Requires gh (CI has it); skipped loudly when absent so the lint stays runnable offline.
# -iac repos are CI-gated deploy TARGETS (require_approval=false; FU-052 excludes them from the
# fixer flow) — their pin PRs merge on CI alone, so the armed-PR-stall class doesn't apply.
CALLERS_EXEMPT="oracle-iac sleep-iac circles-iac"
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
    for wf in renovate-approve; do
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
  echo "token (the stale-registration class; add it to the list AND verify the exporter /apps page" >&2
  echo "covers it, or ESO token generation 422s)." >&2
  exit 1
fi
echo "agents-registration-lint: ok ($(printf '%s\n' "$stack_repos" | wc -l | tr -d ' ') stack repos covered in both token lists)"
