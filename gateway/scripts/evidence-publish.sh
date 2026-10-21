#!/usr/bin/env bash
# Publish the reviewer's evidence pack (scripts/gateway-evidence.sh → allure-evidence/) to OUR
# storage — the `gateway-specs` Garage bucket — instead of a GitHub Actions artifact. The artifact
# (~7 MB × every gateway run, 14-day retention) was ~2.1 GB of held Actions storage against the
# org's 2 GB included quota and fired GithubStorageHeldHigh (2026-10-21); oracle-fleet's ruling is
# the same shape: evidence rides beside its specs site, PR evidence purged on PR close.
#
#   EVIDENCE_PREFIX=pr-<N>   (PR runs)   → evidence/pr-<N>/<EVIDENCE_SHA>.tar.gz   (purged on close by
#                                          scripts/specs-pr-purge.sh, with the site preview)
#   EVIDENCE_PREFIX=<branch> (push runs) → evidence/<branch>/<EVIDENCE_SHA>.tar.gz (the baseline)
#
# EVIDENCE_SHA is the PR HEAD sha (never the merge ref): the specs reviewer reads the pack by
# (prefix, head) — agents/specs-reviewer-session.sh evidence_fetch — anonymously through the
# bucket's web endpoint. One tarball, not a mirror: the reader needs one GET, and a pack is
# immutable per sha (re-runs overwrite it whole).
#
# Retention on write, bounded by COUNT (deterministic, no lifecycle rule): the newest
# EVIDENCE_KEEP_PR packs per PR prefix (5 — a shadow replay may judge an older head) and
# EVIDENCE_KEEP_BRANCH per branch (30 — the reviewer walks ≤30 first-parent commits for its
# baseline). Sizing: 30 × ~7 MB + open PRs × 5 × ~7 MB fits the bucket's 2Gi
# (argocd/resources/agent-gateway/garage-workspace.yaml). A listing failure fails the step loudly
# (oracle-fleet#529); the write is verified (scripts/lib/s3-publish.sh, oracle-fleet#318).
# Soft-skips without creds (local runs, forks) — the specs-publish.sh convention.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/lib/s3-publish.sh

PACK="${1:-allure-evidence}"
if [ -z "${GATEWAY_SPECS_S3_ACCESS_KEY_ID:-}" ] || [ -z "${GATEWAY_SPECS_S3_SECRET_ACCESS_KEY:-}" ]; then
  echo "evidence-publish: no S3 credentials in env (GATEWAY_SPECS_S3_*) — skipping (local run?)"
  exit 0
fi
: "${EVIDENCE_PREFIX:?EVIDENCE_PREFIX must be set (pr-<N> or the pushed branch)}"
: "${EVIDENCE_SHA:?EVIDENCE_SHA must be set (the PR head / pushed commit)}"
[[ "$EVIDENCE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::EVIDENCE_SHA must be a full sha, got '$EVIDENCE_SHA'"; exit 1; }
[ -s "$PACK/evidence.json" ] || { echo "::error::evidence-publish: $PACK/evidence.json missing — run gateway-evidence first"; exit 1; }
ENDPOINT="${GATEWAY_SPECS_S3_ENDPOINT:-https://s3.teststuff.net}"
case "$EVIDENCE_PREFIX" in
  pr-*) keep="${EVIDENCE_KEEP_PR:-5}" ;;
  *)    keep="${EVIDENCE_KEEP_BRANCH:-30}" ;;
esac
DIR="specs/gateway-specs/evidence/${EVIDENCE_PREFIX}"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -czf "$scratch/${EVIDENCE_SHA}.tar.gz" -C "$PACK" .
s3_publish_alias specs "$ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
s3_publish_put "$scratch/${EVIDENCE_SHA}.tar.gz" "$DIR/${EVIDENCE_SHA}.tar.gz"
echo "published: evidence/${EVIDENCE_PREFIX}/${EVIDENCE_SHA}.tar.gz ($(du -h "$scratch/${EVIDENCE_SHA}.tar.gz" | cut -f1))"

# Prune: keep the newest $keep by lastModified. The probe's exit is captured apart from its
# output — a failed listing must never read as "nothing to prune" (oracle-fleet#529).
listing=""
if ! listing="$(mc ls --json "$DIR/" 2>&1)"; then
  echo "::error::evidence-publish: mc ls probe failed for $DIR/: $listing" >&2
  exit 1
fi
mapfile -t old < <(printf '%s\n' "$listing" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.startswith("{")]
files = sorted((r for r in rows if r.get("type") == "file"), key=lambda r: r["lastModified"], reverse=True)
print("\n".join(r["key"] for r in files[int(sys.argv[1]):]))' "$keep" | grep . || true)
for k in "${old[@]}"; do
  mc rm --quiet "$DIR/$k"
done
echo "evidence-publish: kept newest $keep under evidence/${EVIDENCE_PREFIX}/, pruned ${#old[@]}"
