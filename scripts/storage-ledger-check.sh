#!/usr/bin/env bash
# storage-ledger-check — the FU-093 tier ledger, as a lint over the LIVE cluster (per-tier, never
# per-repo: per-repo accounting is what allowed the 2026-07-22 double-book; docs/storage-ledger.md).
#
# Tier v1 = the Garage bulk tier: committed = Σ max_size across every garage_bucket in every
# tf.upbound.io Workspace (the ADR-089 quota-as-contract caps, read from the CLUSTER so all repos'
# claims are covered without cross-repo checkouts); capacity = the garage data PVC. A claim that
# doesn't appear here doesn't exist. Thresholds: >80% WARN (exit 0, loud), >100% OVERCOMMIT
# (exit 1 — the iac-lane "mechanical" predicate must refuse).
#
#   devbox run storage-ledger        # from the jail; in-cluster callers pass no kubeconfig
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi
# same resolution as coordinator-scan.sh: PATH kubectl (in-cluster/devbox shell) → devbox profile
KUBECTL="${KUBECTL:-$(command -v kubectl || echo "${HERE}/../.devbox/nix/profile/default/bin/kubectl")}"

WORKSPACES="$($KUBECTL $KUBE get workspaces.tf.upbound.io -A -o json)" \
  || { echo "storage-ledger: PROBE FAILED — cannot read Workspaces (rule #6: failing loud, not open)"; exit 2; }

# Every `max_size = N` in every module, tagged with its workspace (one bucket per workspace today;
# a multi-bucket module still sums correctly — the ledger cares about the tier total).
LEDGER="$(printf '%s' "$WORKSPACES" | jq -r '
  .items[] | .metadata.name as $w | (.spec.forProvider.module // "")
  | [scan("max_size[ \\t]*=[ \\t]*([0-9]+)")] | flatten | .[] | "\($w) \(.)"')"
[ -n "$LEDGER" ] || { echo "storage-ledger: PROBE FAILED — zero max_size found across $(printf '%s' "$WORKSPACES" | jq '.items|length') workspaces (extraction broken, not an empty tier)"; exit 2; }

CAP_BYTES="$($KUBECTL $KUBE get pvc data-garage-0 -n garage -o jsonpath='{.status.capacity.storage}' \
  | awk '/Gi$/{printf "%.0f", $1 * 1073741824; found=1} END{if (!found) exit 1}' Gi="")" \
  || { echo "storage-ledger: PROBE FAILED — garage data PVC capacity unreadable/non-Gi"; exit 2; }

TOTAL=0
echo "── Garage bulk tier (capacity: data-garage-0) ──"
while read -r w n; do
  [ -n "$w" ] || continue
  printf '  %-32s %6.1f Gi\n' "$w" "$(awk "BEGIN{printf \"%.1f\", $n/1073741824}")"
  TOTAL=$((TOTAL + n))
done <<EOF
$LEDGER
EOF
PCT="$(awk "BEGIN{printf \"%.0f\", 100 * $TOTAL / $CAP_BYTES}")"
printf '  %-32s %6.1f Gi of %.0f Gi (%s%%)\n' "COMMITTED" \
  "$(awk "BEGIN{printf \"%.1f\", $TOTAL/1073741824}")" \
  "$(awk "BEGIN{printf \"%.0f\", $CAP_BYTES/1073741824}")" "$PCT"

if [ "$PCT" -gt 100 ]; then
  echo "✗ OVERCOMMIT: committed caps exceed the tier (${PCT}%) — the double-book class; refuse new claims until reconciled"
  exit 1
elif [ "$PCT" -gt 80 ]; then
  echo "⚠ WARN: tier >80% committed (${PCT}%) — next claim needs a capacity decision, not a rubber stamp"
else
  echo "✓ tier within budget (${PCT}%)"
fi
