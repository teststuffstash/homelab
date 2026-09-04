#!/usr/bin/env bash
# pin-only-lint — the deterministic gate that replaces a code owner on two carved-out files.
#
#   devbox run pin-only-lint [<base-ref>]      (default: origin/master)
#
# 2026-08-05: `argocd/platform/openrouter-operator.yaml` joins them. The CODEOWNERS flip made the
# CHART-deploy lane (ADR-084) wait on a human for a one-line targetRevision bump, exactly as it had
# for the runner-image lane — homelab#104 and #105 both sat BLOCKED with CI green. `agents/images.env`
# was already carved out, so the agent-base half of the same lane flowed while the chart half did
# not. Same ruling, same mechanism: ownership REPLACED by a rule, not dropped.
#
# WHY. `argocd/platform/arc-runners.yaml` and `agents/coordinator/reflexes-argo.yaml` are owned
# paths (tier 2 and tier 3), and the arc-runner auto-bump commits BOTH — so the CODEOWNERS flip
# would have made a mechanical tag bump wait for a human on every runner-image build. Operator
# ruling 2026-08-04: keep it hands-off. Un-owning the files buys that back, but reflexes-argo.yaml
# is the reflex machinery — the governor an agent must never edit unreviewed — so the ownership is
# replaced rather than dropped: via a PR these files may receive PIN BUMPS ONLY.
#
# That is strictly stronger than the human it replaces. The bump is three identical lines
#   image: ghcr.io/teststuffstash/homelab/arc-runner:<tag>
# and a regex cannot be talked past, skim a diff at 23:00, or approve a smuggled fourth line.
#
# ESCAPE HATCH for a real edit: push it to master directly. That is the documented operator path
# in this repo (CLAUDE.md §"How changes land"), it is not a PR, and this check does not run on it.
# The rule constrains the AUTOMATED lane, which is the only lane that got un-gated.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-origin/master}"
GUARDED='argocd/platform/arc-runners\.yaml|agents/coordinator/reflexes-argo\.yaml|agents/coordinator/sentinel-argo\.yaml|argocd/platform/openrouter-operator\.yaml'
# Two pin shapes, one rule. The arc-runner bump writes an `image:` line; the chart-deploy lane
# writes a `targetRevision:` line (CalVer + -g<sha>, ADR-084). Anything else in a guarded file is
# still refused, so widening the FILE set does not widen what may be written to it.
PIN_LINE='^[-+][[:space:]]*(image:[[:space:]]*ghcr\.io/teststuffstash/homelab/arc-runner:[A-Za-z0-9._-]+|targetRevision:[[:space:]]*[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}-g[0-9a-f]+)$'

# Refuse to pass when the diff cannot be computed. A check that green-lights because it could not
# see is the failure class this repo keeps paying for (FU-125/FU-108/FU-131) — and one I shipped
# twice in labels-handoff.sh before catching it.
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "pin-only-lint: FAIL — base ref '$BASE' not resolvable; refusing to report success." >&2
  echo "  In CI, fetch the base first: git fetch --no-tags --depth=1 origin \$GITHUB_BASE_REF" >&2
  exit 2
fi

changed="$(git diff --name-only "$BASE" HEAD | grep -E "$GUARDED" || true)"
if [ -z "$changed" ]; then
  echo "pin-only-lint: OK — no guarded file touched."
  exit 0
fi

echo "pin-only-lint: guarded files in this diff:"
printf '  %s\n' $changed

rc=0
for f in $changed; do
  # Content lines only: strip the +++/--- headers, keep real additions/removals.
  offending="$(git diff -U0 "$BASE" HEAD -- "$f" \
    | grep -E '^[-+][^-+]' \
    | grep -Ev "$PIN_LINE" || true)"
  if [ -n "$offending" ]; then
    echo "pin-only-lint: FAIL — $f may only receive PIN lines via a PR (arc-runner image: / chart targetRevision:):" >&2
    printf '  %s\n' "$offending" >&2
    rc=1
  fi
done

if [ "$rc" != 0 ]; then
  cat >&2 <<'EOF'

  These two files are UNOWNED in CODEOWNERS so the arc-runner auto-bump stays hands-off; this rule
  is what stands in for the code owner. A legitimate edit is not blocked — push it to master
  directly (the operator path, CLAUDE.md §"How changes land"), or re-own the file in CODEOWNERS if
  it should need review again.
EOF
  exit 1
fi
echo "pin-only-lint: OK — every change is an arc-runner pin line."
