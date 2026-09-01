#!/usr/bin/env bash
# governance-lint — ADR-106 (4): a WORKER-authored PR diff that touches governance paths is RED,
# mechanically. The reviewer-rubric PROSE belt failed on 3 of 12 goal-#278 merges that wrote
# governance paths outside their `Touches:` (spike goal-lane-v1.1-fu165-pilot.md finding 4); a
# regex cannot skim a diff at 23:00.
#
#   devbox run governance-lint [<base-ref>]     (default origin/master; PR_AUTHOR from env)
#
# THE SET is the fixer recipe's NEVER-TOUCH tier (.agents/fix.yaml — the doctrine home; the test
# is "does this take effect BEFORE a human approves?"): CI workflows and the scripts/devbox they
# invoke run from the PR's OWN branch, and `.agents/**` is what the next fix round reads from
# that branch. This lint is that tier as a machine check, scoped to the WORKER lane only:
#   - seat/operator PRs pass untouched (the human IS the gate there);
#   - renovate and other non-worker bots pass (renovate legitimately bumps devbox/workflow pins);
#   - the worker App's PRs go red on any governance-path write.
# SELF-GATING CAVEAT, stated not hidden: this script and ci.yaml are themselves governance paths
# executed from the PR branch, so a worker PR editing them could neuter the check — which is
# exactly why the paths sit in the NEVER-TOUCH tier, why this lint reddens the edit attempt, and
# why the whole-repo CODEOWNERS human gate on this repo stays underneath (ADR-106 leaves it).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-origin/master}"
# One greppable line, the pin-only-lint/guarded-set convention: other readers eval THIS line,
# never a second copy. Anchored patterns over the diff's repo-relative paths.
GOVERNANCE='^(\.github/|\.agents/|scripts/|policy/|devbox\.json$|devbox\.lock$|CODEOWNERS$)'
# The worker App's PR-author login. Event context shows "homelab-agents-1234[bot]" (the REST
# surface; GraphQL shows "app/homelab-agents-1234" — the known [bot]-suffix mismatch), so match
# on the App NAME prefix and neither suffix shape matters. Deliberately NOT "any [bot]":
# renovate[bot] must keep its update lane.
WORKER_PATTERN="${WORKER_PATTERN:-^(app/)?homelab-agents}"

author="${PR_AUTHOR:-}"
if [ -z "$author" ]; then
  # Local/manual run: there is no PR author to judge. Say so rather than inventing a verdict —
  # in CI the step always provides PR_AUTHOR, and an empty one there would mean the step is
  # miswired, which the fail-closed branch below catches via CI=true.
  if [ "${CI:-}" = "true" ]; then
    echo "governance-lint: FAIL — CI run with no PR_AUTHOR in env; refusing to report success." >&2
    exit 2
  fi
  echo "governance-lint: no PR_AUTHOR — nothing to judge (meaningful only on PR CI); ok."
  exit 0
fi

if ! printf '%s' "$author" | grep -qE "$WORKER_PATTERN"; then
  echo "governance-lint: author '$author' is not the worker lane — pass."
  exit 0
fi

# Fail-closed on an unresolvable base: a check that green-lights because it could not see is the
# FU-125/FU-108/FU-131 failure class (pin-only-lint's rule, copied deliberately).
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "governance-lint: FAIL — base ref '$BASE' not resolvable; refusing to report success." >&2
  echo "  In CI, fetch the base first: git fetch --no-tags --depth=1 origin \$GITHUB_BASE_REF" >&2
  exit 2
fi

hits="$(git diff --name-only "$BASE" HEAD | grep -E "$GOVERNANCE" || true)"

# ASSEMBLY-LANE ARM (homelab#1036, 2026-09-01). ADR-102's assembly PR is opened by the
# COORDINATOR, whose token is minted from the same App as the worker's — so a `goal/**` head
# aggregating a SEAT-authored governance file (the `.agents/probe.md` of #1030: fixer carve-out
# declined precisely so the seat would write it) reads as a worker diff and goes red on a step
# no lane in the loop can turn green (4 ci-red rides in ~2h, then agent/error; steps 18–32 never
# ran). The property that matters is "no WORKER-WRITTEN governance line lands before a human
# approves" — so on the assembly lane judge each hit by COMMIT authorship, not PR authorship.
# Lane test = the same strong link the scan's post-launch transition trusts: a goal/** head AND
# a line-anchored `Assembly-for: #<n>` trailer. Fails CLOSED on unreadable history.
if [ -n "$hits" ] && printf '%s' "${PR_HEAD_REF:-}" | grep -qE '^goal/' \
   && printf '%s\n' "${PR_BODY:-}" | grep -qE '^[[:space:]]*Assembly-for:[[:space:]]*#[0-9]+'; then
  base_sha="$(git rev-parse "$BASE")"
  # The CI checkout is depth 1 (the merge ref only) — fetch the goal branch's own history into a
  # private ref so `base..head -- <hit>` can name the committer of every governance line.
  # GOVLINT_REMOTE is a TEST seam (`.` = fetch a local branch); CI never sets it.
  if ! git fetch -q --no-tags --depth=500 "${GOVLINT_REMOTE:-origin}" "+refs/heads/${PR_HEAD_REF}:refs/govlint/head" 2>/dev/null; then
    echo "governance-lint: FAIL — assembly lane: could not fetch '${PR_HEAD_REF}' to read commit authorship; refusing to report success." >&2
    exit 2
  fi
  worker_hits=""
  for h in $hits; do
    authors="$(git log --format='%an' "${base_sha}..refs/govlint/head" -- "$h" 2>/dev/null)" || {
      echo "governance-lint: FAIL — assembly lane: git log unreadable for '$h'; refusing to report success." >&2
      exit 2; }
    if printf '%s\n' "$authors" | grep -qE "$WORKER_PATTERN"; then worker_hits="${worker_hits}${h}"$'\n'; fi
  done
  if [ -n "$worker_hits" ]; then
    echo "governance-lint: FAIL — assembly PR carries WORKER-authored commits on governance paths (ADR-106 (4)):" >&2
    printf '  %s\n' $worker_hits >&2
    exit 1
  fi
  echo "governance-lint: ok — assembly lane (goal/** head + Assembly-for: trailer): $(printf '%s\n' "$hits" | grep -c .) governance path(s) touched, every commit human/non-worker authored (homelab#1036)."
  exit 0
fi

if [ -n "$hits" ]; then
  echo "governance-lint: FAIL — worker-authored diff touches governance paths (ADR-106 (4);" >&2
  echo "  the .agents/fix.yaml NEVER-TOUCH tier — these take effect before a human approves):" >&2
  printf '  %s\n' $hits >&2
  echo "  Route this change to the operator lane (an issue naming the exact lines), never a worker PR." >&2
  exit 1
fi
echo "governance-lint: ok — worker diff touches no governance path."
