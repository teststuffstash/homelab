#!/usr/bin/env bash
# Pre-warm the LAN ghcr pull-through mirror with one image's blobs (#80): fetch the manifest +
# config + every layer THROUGH the mirror once, so the node herd that follows a pin flip hits
# a warm cache — pure reads, instead of N nodes concurrently streaming the same multi-GB layer
# into N `_uploads/` staging dirs (the #80 ENOSPC storm). Consumed by the homelab `ci` gate on
# runner-image pin PRs (.github/workflows/ci.yaml); plain curl+jq so it runs on the ARC runner
# image and via devbox alike.
#
#   warm-registry-mirror.sh ghcr.io/<org>/<repo>:<tag> [mirror-base]
set -euo pipefail
REF="${1:?usage: warm-registry-mirror.sh ghcr.io/<org>/<repo>:<tag> [mirror-base]}"
MIRROR="${2:-http://192.168.40.21}"

REF="${REF#ghcr.io/}"
REPO="${REF%:*}"
TAG="${REF#*:}"
ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

manifest="$(curl -fsS --max-time 120 -H "Accept: $ACCEPT" "$MIRROR/v2/$REPO/manifests/$TAG")"
# An index (multi-arch / attestations) nests the real manifest one level down — the runner
# image is built --provenance=false single-arch, but stay robust.
child="$(jq -r '.manifests[0].digest // empty' <<<"$manifest")"
if [ -n "$child" ]; then
  manifest="$(curl -fsS --max-time 120 -H "Accept: $ACCEPT" "$MIRROR/v2/$REPO/manifests/$child")"
fi

total=0
for digest in $(jq -r '[.config.digest] + [.layers[].digest] | .[]' <<<"$manifest"); do
  # --retry-all-errors: a multi-GB pull-through from upstream can drop mid-stream (curl 56);
  # each retry re-drives the mirror's own fetch, which resumes from its cache when it can.
  size="$(curl -fsS --max-time 1800 --retry 4 --retry-delay 10 --retry-all-errors \
          -o /dev/null -w '%{size_download}' "$MIRROR/v2/$REPO/blobs/$digest")"
  total=$((total + size))
  echo "warmed $digest ($((size / 1048576)) MiB)"
done
echo "mirror warm complete: $REPO:$TAG — $((total / 1048576)) MiB pulled through $MIRROR"
