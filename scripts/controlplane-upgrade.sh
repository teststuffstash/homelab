#!/usr/bin/env bash
# Upgrade one Talos control-plane node through the same guarded maintenance verb as workers,
# with the control-plane-only invariants added here: healthy odd etcd quorum, another healthy
# API endpoint, an etcd snapshot before the drain, and the Cilium apiserver-backend gate either
# side of it. Run from the management box checkout:
#
#   devbox run cp-upgrade -- cp-01
#
# THE CILIUM GATE. Upgrading a control plane restarts an apiserver, and on this fleet every
# apiserver restart leaves Cilium with NO backend for 10.96.0.1:443 on most or all nodes, with
# no re-sync: pods get "connection refused" to the API while every node still reads Ready and
# kubectl from outside works fine. Reproduced twice on 2026-09-20 (FU-258,
# docs/spikes/cilium-apiserver-restart-backend-loss.md); the fix is a ds/cilium restart and
# nothing else was ever needed. So this verb refuses to START on a fleet already missing the
# backend, and after the rejoin it looks again and rolls ds/cilium ONLY when an agent is
# genuinely missing it — never on a reading that failed, which is a blind roll during exactly
# the apiserver instability that makes the read flaky. The reading and its three-way verdict
# live in scripts/maintenance-window.sh (`cilium-check`), shared rather than copied.
# Run this verb INSIDE a declared window (the /maintenance-window skill): node-maintenance's
# own silences close with the node's rejoin, so the ds/cilium roll that may follow lands
# outside them and would otherwise hand the responder a CiliumAgentScrapeDown to triage.
#
# LAB=1 is only for the disposable, separately bootstrapped one-node rehearsal cluster. It
# requires explicit KUBECONFIG, TALOSCONFIG, INSTALL_TARGETS and ENDPOINT and cannot use homelab's
# kubeconfig. It relaxes the three-member/other-endpoint rules and the Cilium gate (that cluster
# is not this fleet), never the snapshot or post-check.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NODE="${1:-}"
[ -n "$NODE" ] || { echo "usage: $0 <control-plane-node>" >&2; exit 64; }

export KUBECONFIG="${KUBECONFIG:-$REPO/tofu/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
LAB="${LAB:-0}"
SNAPSHOT_DIR="${CP_SNAPSHOT_DIR:-/var/lib/mgmt/etcd-snapshots}"
if [ ! -d /var/lib/mgmt ]; then SNAPSHOT_DIR="${CP_SNAPSHOT_DIR:-/tmp/controlplane-upgrade-snapshots}"; fi

die() { echo "FAIL: $*" >&2; exit 2; }
# 0 = every responsive agent holds the apiserver backend, 2 = one genuinely does not,
# 3 = the reading answered nothing. The contract is maintenance-window.sh's; do not re-derive it.
cilium_check() { bash "$REPO/scripts/maintenance-window.sh" cilium-check; }
node_ip() { kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
ready_cps() {
  kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r '
    [.items[] | select(.spec.unschedulable != true)
     | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))] | length'
}
etcd_members() {
  talosctl --talosconfig "$TALOSCONFIG" -n "$1" -e "$2" etcd members 2>/dev/null
}
assert_etcd_status() {
  local table="$1" expected="$2" ips status rows
  ips="$(printf '%s\n' "$table" | awk 'NR>1 && NF {gsub("https://", "", $5); sub(":2379$", "", $5); print $5}' | paste -sd, -)"
  [ -n "$ips" ] || die "cannot derive etcd member addresses"
  status="$(talosctl --talosconfig "$TALOSCONFIG" -n "$ips" -e "$ENDPOINT" etcd status 2>/dev/null)" \
    || die "cannot read every etcd member's status"
  rows="$(printf '%s\n' "$status" | awk 'NR>1 && NF {n++} END{print n+0}')"
  [ "$rows" -eq "$expected" ] || die "etcd status returned $rows of $expected members"
  # With an empty ERRORS column the current table has 14 whitespace fields. Any member error is
  # appended after STORAGE; fail closed rather than beginning a CP window with an etcd alarm.
  printf '%s\n' "$status" | awk 'NR>1 && NF>14 {exit 1}' \
    || die "etcd reports a member error"
}

role="$(kubectl get node "$NODE" -o json | jq -r '.metadata.labels | has("node-role.kubernetes.io/control-plane")')"
[ "$role" = true ] || die "$NODE is not a control-plane node"
ip="$(node_ip)"; [ -n "$ip" ] || die "cannot resolve $NODE's InternalIP"

if [ "$LAB" = 1 ]; then
  [ "$KUBECONFIG" != "$REPO/tofu/kubeconfig" ] || die "LAB=1 refuses homelab's kubeconfig"
  [ -n "${INSTALL_TARGETS:-}" ] && [ -n "${ENDPOINT:-}" ] || die "LAB=1 requires INSTALL_TARGETS and ENDPOINT"
else
  [ "$(ready_cps)" -ge 3 ] || die "need at least three Ready, schedulable control planes before a CP upgrade"
  [ -n "${ENDPOINT:-}" ] || ENDPOINT="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r --arg n "$NODE" '.items[] | select(.metadata.name != $n) | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)"
  [ -n "$ENDPOINT" ] || die "no other healthy control plane endpoint"
  [ "$ENDPOINT" != "$ip" ] || die "a production CP upgrade may not endpoint the target itself"
fi
export ENDPOINT

members="$(etcd_members "$ip" "$ENDPOINT")" || die "cannot read etcd membership"
member_count="$(printf '%s\n' "$members" | awk 'NR>1 && NF {n++} END{print n+0}')"
if [ "$LAB" = 1 ]; then
  [ "$member_count" -eq 1 ] || die "lab cluster must have exactly one etcd member (got $member_count)"
else
  [ "$member_count" -ge 3 ] && [ $((member_count % 2)) -eq 1 ] || die "etcd membership must be odd and >=3 (got $member_count)"
fi
assert_etcd_status "$members" "$member_count"

# BEFORE: a fleet that already cannot reach the API through the ClusterIP is not a fleet to
# reboot a control plane on — and it would also make the post-rejoin reading unattributable.
if [ "$LAB" = 1 ]; then
  echo "LAB=1: skipping the cilium backend gate (the rehearsal cluster is not this fleet)"
else
  crc=0; cilium_check || crc=$?
  [ "$crc" -eq 0 ] || die "cilium apiserver backend is not clean BEFORE the upgrade (verdict $crc) — fix it first (kubectl -n kube-system rollout restart ds/cilium), re-run 'devbox run maint cilium-check', then start the window"
fi

mkdir -p "$SNAPSHOT_DIR"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot="$SNAPSHOT_DIR/${NODE}-${stamp}.snapshot"
echo "Snapshotting etcd to $snapshot"
talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ENDPOINT" etcd snapshot "$snapshot"
[ -s "$snapshot" ] || die "snapshot was not created"

if [ "$LAB" = 1 ]; then
  export FORCE=1 SILENCE=0
fi
# This is deliberately set only after the CP-specific endpoint, quorum, health, and snapshot
# gates above have all passed. The shared maintenance preflight otherwise refuses CP nodes.
export CONTROLPLANE_GUARDED=1
bash "$REPO/scripts/node-maintenance.sh" upgrade "$NODE"
if [ "${DRY:-0}" = 1 ]; then
  echo "OK: dry run complete; no control-plane upgrade was attempted"
  exit 0
fi

post="$(etcd_members "$ip" "$ENDPOINT")" || die "post-upgrade etcd membership unreadable"
post_count="$(printf '%s\n' "$post" | awk 'NR>1 && NF {n++} END{print n+0}')"
[ "$post_count" -eq "$member_count" ] || die "etcd member count changed: $member_count -> $post_count"
assert_etcd_status "$post" "$post_count"

# AFTER: the apiserver restarted, so assume the backend is gone until the agents say otherwise.
# Roll ONCE, on verdict 2 only, and re-read — a second empty reading is not this bug and must
# not be papered over with another restart.
if [ "$LAB" = 1 ]; then
  echo "LAB=1: skipping the post-rejoin cilium backend check"
else
  crc=0; cilium_check || crc=$?
  if [ "$crc" -eq 2 ]; then
    echo "Rolling ds/cilium: agents lost the 10.96.0.1:443 backend — the known apiserver-restart signature (FU-258)"
    kubectl -n kube-system rollout restart ds/cilium
    kubectl -n kube-system rollout status ds/cilium --timeout="${CILIUM_ROLLOUT_TIMEOUT:-10m}" \
      || die "ds/cilium rollout did not complete — the API path is still broken for in-cluster clients"
    crc=0; cilium_check || crc=$?
    [ "$crc" -eq 0 ] || die "cilium STILL has no usable backend reading after a ds/cilium restart (verdict $crc) — that is NOT the known signature; investigate before upgrading another control plane"
  elif [ "$crc" -ne 0 ]; then
    die "cilium backend state UNREADABLE after the rejoin — refusing to roll ds/cilium on a read nobody could take; re-run 'devbox run maint cilium-check' and act on what it says"
  fi
fi

echo "OK: $NODE upgraded; etcd membership is whole ($post_count members); cilium holds the apiserver backend; snapshot: $snapshot"
