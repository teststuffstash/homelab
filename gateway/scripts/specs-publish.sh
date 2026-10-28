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
# report/ stays out of the mirror (never uploaded without its headers) and is put below; rclone
# sync never deletes dest keys its filters exclude, and the put after the mirror lands the report
# either way. Filters are anchored ('/…/**') so they match only the top-level directories.
if [ -n "$PREFIX" ]; then
  # A PR prefix is wholly owned by its PR: --remove keeps it an exact mirror of this build.
  s3_publish_mirror --remove --exclude '/report/**' specs-site/ "$DEST"
else
  # NEVER --remove on the root: we own the root, not the pr-*/ directories PR runs write.
  s3_publish_mirror --exclude '/pr-*/**' --exclude '/report/**' specs-site/ "$DEST"
fi
if [ -f specs-site/report/index.html ]; then
  echo "== upload: the run's Allure report (gzipped single-file) → report/index.html =="
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  mkdir -p "$scratch/report"
  gzip -9 -c specs-site/report/index.html > "$scratch/report/index.html"
  echo "   $(stat --format=%s specs-site/report/index.html) bytes → $(stat --format=%s "$scratch/report/index.html") bytes gzipped"
  # Plain "gzip": the "aws-chunked,gzip" prefix (oracle-fleet PR #551) was an mc artefact — mc
  # signed with Garage's STREAMING signature, which required it. rclone sends a plain signed PUT,
  # and Garage stores + serves Content-Encoding: gzip as given (live round-trip, 2026-10-28).
  s3_publish_put --header "Content-Encoding: gzip" --header "Content-Type: text/html" \
    "$scratch/report/index.html" "$DEST/report/index.html"
else
  echo "specs-publish: no Allure report in this build (no allure-results/) — report/ left as is"
fi
echo "published: $SITE_BASE_URL/  (bucket $BUCKET${PREFIX:+/$PREFIX} via $ENDPOINT; report: $REPORT_URL)"
