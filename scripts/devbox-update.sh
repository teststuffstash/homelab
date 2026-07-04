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
# Needs: devbox (on PATH — the workflow sets up single-user Nix), git, curl, jq.
set -euo pipefail

REPO="${REPO:?set REPO=owner/name}"
DIR="${DEVBOX_DIR:-.}"
: "${GH_TOKEN:?set GH_TOKEN}"
BRANCH="devbox-update"
OWNER="${REPO%%/*}"
API="https://api.github.com/repos/${REPO}"

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

hdr=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json")
PR="$(curl -sS "${hdr[@]}" "${API}/pulls?head=${OWNER}:${BRANCH}&state=open" | jq -r '.[0].number // empty')"
if [ -z "$PR" ]; then
  PR="$(curl -sS -X POST "${hdr[@]}" "${API}/pulls" \
    -d "$(jq -nc --arg h "$BRANCH" '{title:"chore: devbox update (align toolchain lock)", head:$h, base:"master", body:"Weekly synchronized `devbox update` (FU-022): keeps `@latest` pins but re-resolves the lock so shared tools stay on ONE version across repos → nix cache + agent-base bake hits. CI-gated; auto-merges via the `automerge` label."}')" \
    | jq -r '.number')"
fi
curl -sS -X POST "${hdr[@]}" "${API}/issues/${PR}/labels" -d '{"labels":["automerge","dependencies"]}' >/dev/null
echo "[$REPO] devbox-update PR #${PR} (labelled automerge)"
