#!/usr/bin/env bash
# specs-pr-purge.sh <pr-number> — close-time cleanup of a homelab PR's gateway-specs preview:
# remove the pr-<N>/ prefix that PR's CI wrote into the `gateway-specs` bucket, and its reviewer
# evidence packs under evidence/pr-<N>/ (scripts/evidence-publish.sh) — the oracle-fleet
# scripts/specs-pr-purge.sh shape; invoked by .github/workflows/gateway-specs-pr-purge.yaml.
#
# Previews are served BY PATH under the master route (argocd/resources/homelab-gateway/
# httproute-gateway-specs.yaml): https://gateway-specs.homelab.teststuff.net/pr-<N>/ → bucket
# gateway-specs, prefix pr-<N>/. The prefix is the whole preview, so purging it is the whole
# teardown. Lessons carried over verbatim from oracle-fleet:
#   * oracle-fleet#517 — logic lives HERE (thin-workflow convention), with no error-swallow: a
#     purge that starts but fails fails the step.
#   * oracle-fleet#529 — the `mc ls` probe's exit status is captured SEPARATELY from its output: a
#     failing probe (auth hiccup, network blip) must NOT read as "prefix empty" and skip silently.
#   * Precondition, NOT an error-swallow: removal is attempted only when the prefix holds objects —
#     a PR whose CI never published (no gateway/ change) must not turn a close into a failure.
#
# Env: GATEWAY_SPECS_S3_ENDPOINT, GATEWAY_SPECS_S3_ACCESS_KEY_ID, GATEWAY_SPECS_S3_SECRET_ACCESS_KEY
# (the writer key, argocd/resources/agent-gateway/garage-workspace.yaml). A preview published AFTER
# the close (the CI-run-vs-close race oracle audited 2026-10-09) is left behind by design — FU-270
# tracks a nightly sweep if the orphans ever matter at this bucket's size.
set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:?usage: specs-pr-purge.sh <pr-number>}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "::error::pr-number must be numeric, got '$N'"; exit 1; }
: "${GATEWAY_SPECS_S3_ENDPOINT:?GATEWAY_SPECS_S3_ENDPOINT must be set for the close-time prefix purge}"
: "${GATEWAY_SPECS_S3_ACCESS_KEY_ID:?GATEWAY_SPECS_S3_ACCESS_KEY_ID must be set for the close-time prefix purge}"
: "${GATEWAY_SPECS_S3_SECRET_ACCESS_KEY:?GATEWAY_SPECS_S3_SECRET_ACCESS_KEY must be set for the close-time prefix purge}"

# shellcheck disable=SC1091
source scripts/lib/s3-publish.sh
s3_publish_alias specs "$GATEWAY_SPECS_S3_ENDPOINT" "$GATEWAY_SPECS_S3_ACCESS_KEY_ID" "$GATEWAY_SPECS_S3_SECRET_ACCESS_KEY"
for PREFIX in "specs/gateway-specs/pr-${N}/" "specs/gateway-specs/evidence/pr-${N}/"; do
  listing=""
  if ! listing="$(mc ls --recursive "$PREFIX" 2>&1)"; then
    echo "::error::mc ls probe failed for ${PREFIX}: $listing" >&2
    exit 1
  fi
  if [ -n "$listing" ]; then
    echo "purging ${PREFIX} (close-time cleanup)"
    mc rm --recursive --force "$PREFIX"
  else
    echo "no objects under ${PREFIX} — nothing to purge"
  fi
done
