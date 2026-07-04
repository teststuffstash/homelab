#!/usr/bin/env bash
# devbox-update.sh — bump ONE repo's devbox.lock (`devbox update`) and open an auto-merging PR.
#
# Part of the weekly `.github/workflows/devbox-update.yaml` job (FU-022). The point is ALIGNMENT: all
# repos keep `@latest` devbox pins, and one weekly pass re-resolves them together so the shared tools
# (gitleaks/kubectl/uv/gh/jq/python) land on the SAME version everywhere — which is what makes the
# in-cluster nix cache (ADR-083) and the `agent-base` baked toolchain hit instead of re-fetch. Pinning
# per-repo (the original FU-022 idea) drifts between updates; a synchronized bump doesn't.
#
# Env: GH_TOKEN (contents + pull_requests write on $REPO — a homelab-renovate App token),
#      REPO (owner/name), DEVBOX_DIR (subdir holding devbox.json; default ".", agent-runtime = "agent-base").
# Needs: devbox (on PATH — the workflow sets up single-user Nix), git, gh (the workflow adds it via
#        `devbox global add gh`; gh's built-in --jq means no standalone jq).
set -euo pipefail

REPO="${REPO:?set REPO=owner/name}"
DIR="${DEVBOX_DIR:-.}"
: "${GH_TOKEN:?set GH_TOKEN}"
BRANCH="devbox-update"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
git clone --quiet --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "$WORK/r"
cd "$WORK/r"

echo "[$REPO] devbox update ($DIR)…"
( cd "$DIR" && devbox update )

if git diff --quiet -- "$DIR/devbox.lock"; then
  echo "[$REPO] devbox.lock already current — nothing to do"; exit 0
fi

git config user.name "homelab-renovate[bot]"
git config user.email "homelab-renovate[bot]@users.noreply.github.com"
git checkout -q -B "$BRANCH"
git add "$DIR/devbox.lock"
git commit -q -m "chore: devbox update — align the toolchain lock (FU-022)" \
  -m "Weekly synchronized devbox.lock bump so shared tools resolve to the same version across repos (nix cache + agent-base bake hits)."
git push -q --force origin "$BRANCH"

export GH_TOKEN # gh authenticates from this

# Ensure the labels exist (idempotent) so --label can't fail on a repo Renovate hasn't touched yet.
for L in automerge dependencies; do gh label create "$L" --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true; done

PR="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [ -z "$PR" ]; then
  PR="$(gh pr create --repo "$REPO" --base master --head "$BRANCH" \
    --label "automerge,dependencies" \
    --title "chore: devbox update (align toolchain lock)" \
    --body "Weekly synchronized \`devbox update\` (FU-022): keeps \`@latest\` pins but re-resolves the lock so shared tools stay on ONE version across repos → nix cache + agent-base bake hits. CI-gated; auto-merges via the automerge label." \
    | grep -oE '[0-9]+$')"
else
  gh pr edit "$PR" --repo "$REPO" --add-label "automerge,dependencies" >/dev/null
fi

# ARM auto-merge — REQUIRED, not optional: the FU-041 updater only touches auto-merge-armed PRs
# (require_auto_merge_enabled) and GitHub only completes an armed merge. Same rule as the worker /
# Renovate / deploy; `gh pr merge --auto` is the clean way (no raw GraphQL). Harmless if already armed.
gh pr merge "$PR" --repo "$REPO" --auto --squash \
  || echo "::warning::[$REPO] could not arm auto-merge on #$PR"
echo "[$REPO] devbox-update PR #${PR} (labelled + armed)"
