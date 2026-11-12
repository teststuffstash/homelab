#!/usr/bin/env bash
# argocd-validate-pins.sh — homelab CI gate. For every ArgoCD Application that pins one of OUR OWN OCI
# Helm charts (ghcr.io/teststuffstash/charts — the deploy-pin targets),
# prove the pinned version actually RENDERS with the values in this repo. Catches a deploy-pin bump to a
# chart version whose new REQUIRED value isn't set here — otherwise that deploy PR auto-merges and ArgoCD
# only fails at sync. Mirrors sleep-iac/scripts/ci.sh. Needs helm + yq (both in homelab's devbox.json).
# Second leg (bottom): version-set pairs declared by the `homelab.teststuff.net/app-version-of`
# annotation must pin charts that ship ONE appVersion (gap G16).
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
  done < <(yq -o=json "$f" | jq -r '
      select(.kind == "Application")
      | [ (.spec.source // empty) ] + (.spec.sources // [])
      | map(select(.chart != null and (.repoURL | test("ghcr.io/teststuffstash/charts"))))
      | .[] | [.repoURL, .chart, .targetRevision, ((.helm.valueFiles // []) | join(","))] | @tsv
    ')
done < <(grep -rl 'kind: Application' argocd --include='*.yaml' --include='*.yml' 2>/dev/null || true)

echo "✓ argocd-validate-pins: ${checked} OCI-chart pin(s) render cleanly"

# ── version-set leg (gap G16, docs/dependency-upgrades.md §Version SETS) ─────────────────────────
# An Application annotated `homelab.teststuff.net/app-version-of: <chart>` declares that its own
# chart's appVersion must EQUAL the appVersion of <chart> as pinned elsewhere under argocd/ — the
# prometheus-operator-crds chart against kube-prometheus-stack (both ship one operator version; the
# box belt `kps_crds_verdict` FAILs on any inequality after the sync). Renovate cannot hold that
# relation: it picks each member's newest release on its own, so a grouped branch can carry two
# appVersions (#3280: CRDs v0.95.0 against a v0.94.2 stack). The relation lives on the member, so a
# new set is one annotation, never an edit here. appVersion comes from each pinned chart's own
# Chart.yaml (`helm show chart`), never from a comment.
helm_srcs="$(grep -rl 'kind: Application' argocd --include='*.yaml' --include='*.yml' 2>/dev/null \
  | while IFS= read -r f; do yq -o=json "$f" | jq -c --arg f "$f" '
      select(.kind == "Application")
      | {f: $f, of: (.metadata.annotations["homelab.teststuff.net/app-version-of"] // null),
         src: ([ (.spec.source // empty) ] + (.spec.sources // []) | map(select(.chart != null)))}'; done)"
app_version() { # repoURL chart version → appVersion without a leading v
  local out
  case "$1" in
    oci://*|ghcr.io/*) out="$(helm show chart "oci://${1#oci://}/$2" --version "$3" 2>/dev/null)" ;;
    *) out="$(helm show chart --repo "$1" "$2" --version "$3" 2>/dev/null)" ;;
  esac || return 1
  printf '%s' "$out" | yq -r '.appVersion // ""' | sed 's/^v//'
}
sets=0
while IFS=$'\t' read -r f partner repo chart ver; do
  [ -n "${partner:-}" ] || continue
  sets=$((sets + 1))
  echo "==> ${f}: ${chart}@${ver} must ship the appVersion of ${partner}"
  pins="$(printf '%s\n' "$helm_srcs" | jq -r --arg c "$partner" '.src[] | select(.chart == $c) | [.repoURL, .targetRevision] | @tsv' | sort -u)"
  [ "$(printf '%s' "$pins" | grep -c .)" = 1 ] \
    || { echo "   ✗ ${partner}: expected exactly one pin under argocd/, found: ${pins:-none}"; exit 1; }
  IFS=$'\t' read -r prepo pver <<< "$pins"
  mine="$(app_version "$repo" "$chart" "$ver")" && [ -n "$mine" ] \
    || { echo "   ✗ ${chart}@${ver}: no appVersion readable (published?)"; exit 1; }
  theirs="$(app_version "$prepo" "$partner" "$pver")" && [ -n "$theirs" ] \
    || { echo "   ✗ ${partner}@${pver}: no appVersion readable (published?)"; exit 1; }
  if [ "$mine" != "$theirs" ]; then
    echo "   ✗ version set split: ${chart}@${ver} ships v${mine}, ${partner}@${pver} ships v${theirs} — move the pair to one appVersion in one PR"
    exit 1
  fi
  echo "   ✓ both v${mine}"
done < <(printf '%s\n' "$helm_srcs" | jq -r 'select(.of != null) | .of as $o | .f as $f | .src[] | [$f, $o, .repoURL, .chart, .targetRevision] | @tsv')
[ "$sets" -gt 0 ] || { echo "   ✗ no app-version-of annotation found — the version-set leg asserted nothing"; exit 1; }
echo "✓ argocd-validate-pins: ${sets} version-set pair(s) ship one appVersion"
