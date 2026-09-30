#!/usr/bin/env bash
# Upgrade one Talos control-plane node through the same guarded maintenance verb as workers,
# with the control-plane-only invariants added here: healthy odd etcd quorum, another healthy
# API endpoint, an etcd snapshot before the drain, and the Cilium apiserver-backend gate either
# side of it. Run from the management box checkout:
#
#   devbox run cp-upgrade -- cp-01
#   bash scripts/controlplane-upgrade.sh cp-01 down|up   # a CP maintenance window (hardware on its
#                                                        host): what `node-maintenance.sh down|up
#                                                        <cp>` hands off to
#
# `down` runs the SAME pre-gates as an upgrade (three Ready CPs, odd healthy etcd, another API
# endpoint, clean Cilium, a snapshot), moves etcd leadership off the target if it holds it, then
# the shared `down`. `up` runs the shared `up`, then the post-checks (etcd membership whole again,
# the Cilium backend read + the one sanctioned ds/cilium roll). A CP window is otherwise the
# shared verb's: drain, silences, declared window, shutdown.
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
NODE="${1:-}"; VERB="${2:-upgrade}"
[ -n "$NODE" ] || { echo "usage: $0 <control-plane-node> [upgrade|down|up]" >&2; exit 64; }
case "$VERB" in upgrade|down|up) ;; *) echo "usage: $0 <control-plane-node> [upgrade|down|up]" >&2; exit 64 ;; esac

export KUBECONFIG="${KUBECONFIG:-$REPO/tofu/kubeconfig}"
export TALOSCONFIG="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
# ON THE MANAGEMENT BOX the client configs live in /var/lib/mgmt/, not in the checkout, and
# `devbox run` exports devbox.json's KUBECONFIG/TALOSCONFIG=$PWD/tofu/* regardless — a path that
# does not exist there. kubectl then fell back to localhost:8080 and every box-side run of the
# upgrade verbs failed (found 2026-09-21; the only box run before was the LAB=1 rehearsal, which
# passed explicit paths). So a configured path that does not exist yields to the box's copy.
# Same three lines in node-maintenance.sh, controlplane-upgrade.sh, maintenance-window.sh.
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }
[ -f "$TALOSCONFIG" ] || { [ -f /var/lib/mgmt/talosconfig ] && TALOSCONFIG=/var/lib/mgmt/talosconfig; }
export TALOSCONFIG
LAB="${LAB:-0}"
SNAPSHOT_DIR="${CP_SNAPSHOT_DIR:-/var/lib/mgmt/etcd-snapshots}"
if [ ! -d /var/lib/mgmt ]; then SNAPSHOT_DIR="${CP_SNAPSHOT_DIR:-/tmp/controlplane-upgrade-snapshots}"; fi

# EXIT CODES — the same contract as `node-maintenance.sh upgrade`, because the box's reconciler
# (mgmt/scripts/mgmt-reconcile.sh) calls this verb for a control plane and maps them identically:
#   2  REFUSED — a gate said no BEFORE anything was touched (quorum, endpoint, etcd health, cilium,
#      the snapshot, or the shared verb's own preflight/floors); a later attempt may pass
#   4  IMPOSSIBLE — the declared version path (the shared verb's cross-minor downgrade / skipped
#      minor); no retry passes it
#   1  FAILED AFTER TOUCHING — the shared verb failed mid-window, or a post-install check (etcd
#      membership, the cilium repair) failed on a node that was already upgraded; read it by hand
# `die` is phase-aware: a refusal (2) until the shared verb has run, a post-install failure (1)
# after it (PHASE=after). The shared verb's own exit is passed through unchanged (set -e exits with
# its status). Reads that fail before the snapshot are refusals too — nothing was touched.
PHASE=before
die() {
  if [ "$PHASE" = after ]; then echo "FAIL (after the install): $*" >&2; exit 1; fi
  echo "FAIL: $*" >&2; exit 2
}
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

role="$(kubectl get node "$NODE" -o json | jq -r '.metadata.labels | has("node-role.kubernetes.io/control-plane")')" \
  || die "cannot read $NODE from the API"
[ "$role" = true ] || die "$NODE is not a control-plane node"
ip="$(node_ip)" || ip=""; [ -n "$ip" ] || die "cannot resolve $NODE's InternalIP"

if [ "$LAB" = 1 ]; then
  [ "$KUBECONFIG" != "$REPO/tofu/kubeconfig" ] || die "LAB=1 refuses homelab's kubeconfig"
  [ -n "${INSTALL_TARGETS:-}" ] && [ -n "${ENDPOINT:-}" ] || die "LAB=1 requires INSTALL_TARGETS and ENDPOINT"
else
  if [ "$VERB" != up ]; then
    [ "$(ready_cps)" -ge 3 ] || die "need at least three Ready, schedulable control planes before a CP $VERB"
  fi
  [ -n "${ENDPOINT:-}" ] || ENDPOINT="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r --arg n "$NODE" '.items[] | select(.metadata.name != $n) | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)" \
    || die "cannot list the control planes"
  [ -n "$ENDPOINT" ] || die "no other healthy control plane endpoint"
  [ "$ENDPOINT" != "$ip" ] || die "a production CP upgrade may not endpoint the target itself"
fi
export ENDPOINT

if [ "$VERB" = up ]; then
  # The target is down: read membership through the other endpoint (the member list keeps it).
  members="$(etcd_members "$ENDPOINT" "$ENDPOINT")" || die "cannot read etcd membership"
  member_count="$(printf '%s\n' "$members" | awk 'NR>1 && NF {n++} END{print n+0}')"
else
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

  mkdir -p "$SNAPSHOT_DIR" || die "cannot create $SNAPSHOT_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  snapshot="$SNAPSHOT_DIR/${NODE}-${stamp}.snapshot"
  echo "Snapshotting etcd to $snapshot"
  talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ENDPOINT" etcd snapshot "$snapshot" \
    || die "etcd snapshot failed — nothing touched"
  [ -s "$snapshot" ] || die "snapshot was not created"

  # etcd leadership off the target before it goes dark (an upgrade reboots through the same
  # step): a leader loss costs an election; a forfeit is a clean handover. Read by member id.
  if [ "$VERB" = down ] && [ "$LAB" != 1 ] && [ "${DRY:-0}" != 1 ]; then
    # Leader = the row's MEMBER id appears again later in the row (the LEADER column). Matched by
    # value, not position: the column index moves with talosctl's layout ("287 MB" and
    # "86 MB (29.94%)" are several fields live; the self-test fixture's layout differs).
    # Under pipefail a failed talosctl fails the pipeline, so `|| tid=""` hands it to the die below.
    role_of() { talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ENDPOINT" etcd status 2>/dev/null \
                  | awk 'NR==2 { l = 0; for (i = 3; i <= NF; i++) if ($i == $2) l = 1; print l ? "leader" : "follower" }'; }
    tid="$(role_of)" || tid=""
    case "$tid" in leader|follower) ;; *) die "cannot read the target's etcd leadership — refusing" ;; esac
    if [ "$tid" = leader ]; then
      echo "$NODE is the etcd leader — forfeiting leadership"
      talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ENDPOINT" etcd forfeit-leadership || die "etcd forfeit-leadership failed — nothing touched"
      sleep 5
      tid="$(role_of)" || tid=""
      [ "$tid" = follower ] || die "$NODE still leads etcd after the forfeit ($tid) — refusing"
    fi
  fi
fi

if [ "$LAB" = 1 ]; then
  export FORCE=1 SILENCE=0
fi
# This is deliberately set only after the CP-specific endpoint, quorum, health, and snapshot
# gates above have all passed. The shared maintenance preflight otherwise refuses CP nodes.
export CONTROLPLANE_GUARDED=1
bash "$REPO/scripts/node-maintenance.sh" "$VERB" "$NODE"   # its 2/4/1 pass through (set -e)
PHASE=after   # from here every failure is on an upgraded node: exit 1, never a retryable 2
if [ "${DRY:-0}" = 1 ]; then
  echo "OK: dry run complete; no control-plane $VERB was attempted"
  exit 0
fi
if [ "$VERB" = down ]; then
  # The node is dark: no membership re-read (its member is down by design); the Cilium read
  # below still runs — an apiserver just left the endpoint set.
  post_count="$member_count"
else

post="$(etcd_members "$ip" "$ENDPOINT")" || die "post-$VERB etcd membership unreadable"
post_count="$(printf '%s\n' "$post" | awk 'NR>1 && NF {n++} END{print n+0}')"
[ "$post_count" -eq "$member_count" ] || die "etcd member count changed: $member_count -> $post_count"
assert_etcd_status "$post" "$post_count"
fi

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

echo "OK: $NODE $VERB done; etcd membership $([ "$VERB" = down ] && echo "$post_count (this one dark)" || echo "whole ($post_count members)"); cilium holds the apiserver backend${snapshot:+; snapshot: $snapshot}"
