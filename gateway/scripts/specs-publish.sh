#!/usr/bin/env bash
# Publish the browsable specs site (scripts/specs-build.sh) to the `gateway-specs` bucket, served by
# the homelab gateway (ADR-092 subdomain delegation — argocd/resources/homelab-gateway/):
#
#   master runs (SITE_PREFIX empty) → bucket root → https://gateway-specs.homelab.teststuff.net
#   PR runs   (SITE_PREFIX=pr-<N>)  → pr-<N>/     → https://gateway-specs.homelab.teststuff.net/pr-<N>/
#     (by path under the SAME route — it rewrites only the Host and passes the path through, and
#      Garage serves an index on any sub-prefix; the prefix is purged on PR close by
#      scripts/specs-pr-purge.sh via .github/workflows/gateway-specs-pr-purge.yaml)
#
# The oracle-fleet scripts/specs-publish.sh shape, minus the Allure report leg (this island's
# evidence is markdown fragments rendered INTO the pages). Infra: bucket + writer key in
# argocd/resources/agent-gateway/garage-workspace.yaml (connection Secret gateway-specs-s3 in
# agent-egress → GitHub Actions secrets GATEWAY_SPECS_S3_* via scripts/github-secrets-sync.sh).
# Soft-skips when creds are absent (local runs, forks) — the oracle convention.
set -euo pipefail
cd "$(dirname "$0")/.."
# The mirror helper verifies its own write (oracle-fleet#318: a bucket over quota 403'd every
# PUT for a week while `mc mirror --quiet` stayed green): mc error events or a missing/stale
# index.html at the destination fail the step. specs-build.sh gives every directory an
# index.html, so the site root's is the sentinel.
# shellcheck disable=SC1091
source scripts/lib/s3-publish.sh

if [ -z "${GATEWAY_SPECS_S3_ACCESS_KEY_ID:-}" ] || [ -z "${GATEWAY_SPECS_S3_SECRET_ACCESS_KEY:-}" ]; then
  echo "specs-publish: no S3 credentials in env (GATEWAY_SPECS_S3_*) — skipping (local run?)"
  exit 0
fi
ENDPOINT="${GATEWAY_SPECS_S3_ENDPOINT:-https://s3.teststuff.net}"
BUCKET=gateway-specs
PREFIX="${SITE_PREFIX:-}"
SITE_URL="https://gateway-specs.homelab.teststuff.net"

bash scripts/specs-build.sh

echo "== upload =="
s3_publish_alias specs "$ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
if [ -n "$PREFIX" ]; then
  # A PR prefix is wholly owned by its PR: --remove keeps it an exact mirror of this build.
  s3_publish_mirror --overwrite --remove specs-site/ "specs/$BUCKET/$PREFIX/"
  echo "published: $SITE_URL/${PREFIX}/  (bucket $BUCKET/$PREFIX via $ENDPOINT)"
else
  # NEVER --remove on the root: we own the root, not the pr-*/ directories PR runs write.
  s3_publish_mirror --overwrite --exclude 'pr-*' specs-site/ "specs/$BUCKET/"
  echo "published: $SITE_URL/  (bucket $BUCKET via $ENDPOINT)"
fi
