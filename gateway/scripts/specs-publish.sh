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
# The oracle-fleet scripts/specs-publish.sh shape, report leg included: the run's single-file
# Allure report (scripts/allure-report.sh, staged by specs-build.sh at specs-site/report/index.html)
# rides beside the site at <prefix>/report/index.html — the URL the joined spec tables link into
# (scripts/lib/site.sh REPORT_URL) — GZIPPED (oracle-fleet#547: ~22 MiB → ~3 MiB there) and put
# apart from the mirror, because Content-Encoding is a per-object header a mirror cannot set. One copy
# per site, overwritten by every publish. Infra: bucket + writer key in
# argocd/resources/agent-gateway/garage-workspace.yaml (connection Secret gateway-specs-s3 in
# agent-egress → GitHub Actions secrets GATEWAY_SPECS_S3_* via scripts/github-secrets-sync.sh).
# Soft-skips when creds are absent (local runs, forks) — the oracle convention.
set -euo pipefail
cd "$(dirname "$0")/.."
# The mirror helper verifies its own write (oracle-fleet#318: a bucket over quota 403'd every
# PUT for a week while `mc mirror --quiet` stayed green): rclone errors or a missing/stale
# index.html at the destination fail the step. specs-build.sh gives every directory an
# index.html, so the site root's is the sentinel.
# shellcheck disable=SC1091
source scripts/lib/s3-publish.sh

if [ -z "${GATEWAY_SPECS_S3_ACCESS_KEY_ID:-}" ] || [ -z "${GATEWAY_SPECS_S3_SECRET_ACCESS_KEY:-}" ]; then
  echo "specs-publish: no S3 credentials in env (GATEWAY_SPECS_S3_*) — skipping (local run?)"
  exit 0
fi
# shellcheck disable=SC1091
source scripts/lib/site.sh
ENDPOINT="${GATEWAY_SPECS_S3_ENDPOINT:-https://s3.teststuff.net}"
BUCKET=gateway-specs
PREFIX="$SITE_PREFIX"
DEST="specs:$BUCKET${PREFIX:+/$PREFIX}"

bash scripts/specs-build.sh

echo "== upload =="
s3_publish_remote specs "$ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
# The mirror, then the gzipped report apart from it (site_upload, scripts/lib/site-build.sh).
# shellcheck disable=SC1091
source scripts/lib/site-build.sh
site_upload "$DEST" "$PREFIX"
echo "published: $SITE_BASE_URL/  (bucket $BUCKET${PREFIX:+/$PREFIX} via $ENDPOINT; report: $REPORT_URL)"
