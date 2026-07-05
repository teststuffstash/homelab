#!/usr/bin/env bash
# devbox-update.sh — bump ONE repo's devbox.lock (`devbox update`) and open an auto-merging PR.
#
# Part of the weekly `.github/workflows/devbox-update.yaml` job (FU-022). The point is ALIGNMENT: all
# repos keep `@latest` devbox pins, and one weekly pass re-resolves them together so the shared tools
# (gitleaks/kubectl/uv/gh/jq/python) land on the SAME version everywhere — which is what makes the
# in-cluster nix cache (ADR-083) and the `agent-base` baked toolchain hit instead of re-fetch. Pinning
# per-repo (the original FU-022 idea) drifts between updates; a synchronized bump doesn't.
#
# MAJOR bumps are human-gated (not pinned away): if any tool's leading version integer changed, the PR
# is labelled `major` and auto-merge is NOT armed — CI + the reviewer/coordinator pipeline still run
# (reviewer investigates the migration + comments what's needed), but a human makes the final merge
# call. Non-major bumps keep the `automerge` auto-merge path.
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

# Detect MAJOR version bumps by diffing the lock's per-package `version` (compare the leading integer,
# NOT the pin name — e.g. `awscli2` is a package name, its version is 2.x; only a real 2→3 counts).
# Key by the package BASE NAME (strip the `@pin`) so a pin CHANGE like `kubernetes-helm@3` → `@latest`
# is still seen as a 3.x → 4.x bump, not an add+remove (the lock key changes with the pin). Unparseable
# version changes fall back to "flag for human"; genuinely added/removed packages are ignored.
LOCK="devbox.lock"; [ "$DIR" = "." ] || LOCK="$DIR/devbox.lock"
OLD_LOCK="$(git show "HEAD:$LOCK" 2>/dev/null || echo '{}')"
NEW_LOCK="$(cat "$LOCK")"
MAJORS="$(jq -rn --argjson old "$OLD_LOCK" --argjson new "$NEW_LOCK" '
  def base: sub("@[^@]*$"; "");                            # "kubernetes-helm@3" -> "kubernetes-helm"
  def major(v): (v // "") | if test("^[0-9]+") then capture("^(?<n>[0-9]+)").n else null end;
  def vermap($p): ($p // {}) | to_entries | map({key: (.key|base), value: .value.version}) | from_entries;
  vermap($old.packages) as $op | vermap($new.packages)
  | to_entries[] | .key as $k | .value as $nv | ($op[$k]) as $ov
  | select($ov != null and $nv != null)                    # ignore added/removed packages
  | { k: $k, ov: $ov, nv: $nv, om: major($ov), nm: major($nv) }
  | select(.om != .nm or (.om == null and .ov != .nv))     # major changed, or unparseable + changed
  | "\(.k): \(.ov) → \(.nv)"
')"

git config user.name "homelab-renovate[bot]"
git config user.email "homelab-renovate[bot]@users.noreply.github.com"
git checkout -q -B "$BRANCH"
git add "$DIR/devbox.lock"
git commit -q -m "chore: devbox update — align the toolchain lock (FU-022)" \
  -m "Weekly synchronized devbox.lock bump so shared tools resolve to the same version across repos (nix cache + agent-base bake hits)."
git push -q --force origin "$BRANCH"

export GH_TOKEN # gh authenticates from this

# Ensure the labels exist (idempotent) so --label can't fail on a repo Renovate hasn't touched yet.
gh label create automerge    --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true
gh label create dependencies --repo "$REPO" --color ededed --force >/dev/null 2>&1 || true
gh label create major        --repo "$REPO" --color b60205 --force >/dev/null 2>&1 || true

BASE_BODY="Weekly synchronized \`devbox update\` (FU-022): keeps \`@latest\` pins but re-resolves the lock so shared tools stay on ONE version across repos → nix cache + agent-base bake hits."
if [ -n "$MAJORS" ]; then
  TITLE="chore: devbox update — MAJOR bump, human review (align toolchain lock)"
  LABELS="major,dependencies"
  BODY="$(printf '%s\n\n⚠️ **MAJOR version bump(s) — human-gated, auto-merge NOT armed:**\n\n%s\n\nCI + the reviewer/coordinator pipeline still run (and may fix breakage); the reviewer investigates the migration and comments what is needed, but the final merge is a human call (majors need a human — FU-022).' \
    "$BASE_BODY" "$(printf '%s\n' "$MAJORS" | sed 's/^/- /')")"
else
  TITLE="chore: devbox update (align toolchain lock)"
  LABELS="automerge,dependencies"
  BODY="$BASE_BODY CI-gated; auto-merges via the automerge label."
fi

PR="$(gh pr list --repo "$REPO" --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [ -z "$PR" ]; then
  PR="$(gh pr create --repo "$REPO" --base master --head "$BRANCH" \
    --label "$LABELS" --title "$TITLE" --body "$BODY" | grep -oE '[0-9]+$')"
else
  gh pr edit "$PR" --repo "$REPO" --title "$TITLE" --body "$BODY" --add-label "$LABELS" >/dev/null
  # keep the gate labels consistent if a re-run flips major<->non-major
  if [ -n "$MAJORS" ]; then gh pr edit "$PR" --repo "$REPO" --remove-label automerge >/dev/null 2>&1 || true
  else                      gh pr edit "$PR" --repo "$REPO" --remove-label major     >/dev/null 2>&1 || true; fi
fi

if [ -n "$MAJORS" ]; then
  # The major gate: DON'T arm auto-merge. FU-041's updater only touches auto-merge-armed PRs, so an
  # un-armed PR simply waits for a human — while CI + the reviewer/coordinator pipeline still run on it.
  echo "::warning::[$REPO] MAJOR bump on #$PR — left for a human (auto-merge NOT armed):"
  printf '%s\n' "$MAJORS" | sed 's/^/  /'
  echo "[$REPO] devbox-update PR #${PR} (labelled major, human-gated)"
else
  # ARM auto-merge — REQUIRED for non-major bumps: the FU-041 updater only touches auto-merge-armed PRs
  # (require_auto_merge_enabled) and GitHub only completes an armed merge. `gh pr merge --auto` is the
  # clean way (no raw GraphQL). Harmless if already armed.
  gh pr merge "$PR" --repo "$REPO" --auto --squash \
    || echo "::warning::[$REPO] could not arm auto-merge on #$PR"
  echo "[$REPO] devbox-update PR #${PR} (labelled + armed)"
fi
