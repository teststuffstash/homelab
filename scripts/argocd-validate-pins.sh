#!/usr/bin/env bash
# argocd-validate-pins.sh — homelab CI gate. For every ArgoCD Application that pins an OCI Helm chart,
# prove the pinned version actually RENDERS with the values in this repo. Catches a deploy-pin bump to a
# chart version whose new REQUIRED value isn't set here — otherwise that deploy PR auto-merges and ArgoCD
# only fails at sync. Mirrors sleep-iac/scripts/ci.sh. Needs helm + yq (both in homelab's devbox.json).
#
#   devbox run argocd-validate-pins
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

checked=0
# every Application manifest under argocd/
while IFS= read -r f; do
  # emit one TSV line per OCI Helm source: repoURL \t chart \t targetRevision \t valueFiles(csv)
  while IFS=$'\t' read -r repo chart ver vfiles; do
    [ -n "${chart:-}" ] || continue
    checked=$((checked + 1))
    # oci URL: repoURL may already start with oci://, else it's a bare registry path
    case "$repo" in oci://*) url="${repo}/${chart}";; *) url="oci://${repo}/${chart}";; esac
    echo "==> ${f}: ${url}:${ver}"
    [ -n "${ver:-}" ] && [ "$ver" != "null" ] || { echo "   ✗ no targetRevision"; exit 1; }

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    helm pull "$url" --version "$ver" --destination "$tmp" >/dev/null 2>&1 \
      || { echo "   ✗ chart ${url}:${ver} not pullable (published?)"; exit 1; }

    # resolve $values/<path> valueFiles → repo-relative -f flags (sleep-ingester-style multi-source)
    set --
    if [ -n "${vfiles:-}" ]; then
      IFS=',' read -ra VF <<< "$vfiles"
      for v in "${VF[@]}"; do v="${v#\$values/}"; [ -f "$v" ] && set -- "$@" -f "$v"; done
    fi
    helm template validate "$tmp"/*.tgz "$@" >/dev/null \
      || { echo "   ✗ render FAILED — a required value is likely missing from this repo's values"; exit 1; }
    echo "   ✓ renders"
    rm -rf "$tmp"; trap - EXIT
  done < <(yq -r '
      [ (.spec.source // empty) ] + (.spec.sources // [])
      | map(select(.chart != null and (.repoURL | test("ghcr.io/|^oci://"))))
      | .[] | [.repoURL, .chart, .targetRevision, ((.helm.valueFiles // []) | join(","))] | @tsv
    ' "$f" 2>/dev/null)
done < <(grep -rl 'kind: Application' argocd --include='*.yaml' --include='*.yml' 2>/dev/null || true)

echo "✓ argocd-validate-pins: ${checked} OCI-chart pin(s) render cleanly"
