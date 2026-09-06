#!/usr/bin/env bash
# Single-node maintenance window for a Talos WORKER (metal or VM): the deterministic
# cordon → drain → shutdown path, with the storage checks that make "safe to pull the
# plug" a computed answer instead of a k9s glance — and the reverse (wake → Ready →
# uncordon → Longhorn healthy again).
#
#   bash scripts/node-maintenance.sh preflight <node>   # read-only: is the node safe to take down?
#   bash scripts/node-maintenance.sh down      <node>   # preflight → cordon → drain → talosctl shutdown
#   bash scripts/node-maintenance.sh up        <node>   # WoL (metal) → wait Ready → uncordon → wait Longhorn healthy
#
# What preflight refuses on (exit 2 — pass FORCE=1 to override a WARN-class one):
#   FAIL  node missing / not Ready / Talos API unreachable
#   FAIL  a Longhorn volume is ATTACHED to this node and this node holds its only replica
#   FAIL  a Longhorn replica on this node is its volume's LAST running replica anywhere
#         (Longhorn's `node-drain-policy=block-if-contains-last-replica` would block the drain
#         too — we say WHICH volume, up front)
#   FAIL  any attached Longhorn volume cluster-wide is already degraded (a second outage on
#         top of a rebuild is how a 2-replica volume loses data)
#   WARN  a StatefulSet pod runs here (it moves, but that is a service interruption)
#   WARN  an Argo Workflow / agent ride pod runs here (drain kills the ride; let it finish)
#   WARN  a Deployment pod runs here with replicas==1 (drain = downtime for that service)
#
# This is a WORKER recipe. cp-01 is the only control plane — its window is the Proxmox
# full-stop in docs/runbook.md §Proxmox host maintenance window, not this script.
# Not tofu/Ansible: the whole thing is live-state orchestration with waits; tofu manages the
# node's existence, not its power state (the `talosctl shutdown` → WoL pair is the runbook's
# tested recipe for metal). The MAC for WoL comes from the one DHCP source of truth,
# opnsense/dnsmasq-dhcp.py, and the magic packet is sent from pve (same L2; the jail is NAT'd).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO/tofu/kubeconfig}"
TALOSCONFIG="${TALOSCONFIG:-$REPO/tofu/talosconfig}"
PVE_SSH_KEY="${PVE_SSH_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
PVE_HOST="${PVE_HOST:-root@192.168.2.3}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-600s}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"     # s — a metal box that PXE-times-out first takes ~5 min
HEALTHY_TIMEOUT="${HEALTHY_TIMEOUT:-1800}" # s — Longhorn replica re-sync after the node returns
FORCE="${FORCE:-0}"

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
usage(){ sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }

cmd="${1:-}"; NODE="${2:-}"
[ -n "$cmd" ] && [ -n "$NODE" ] || usage
WARNS=0; FAILS=0

node_ip() { kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
node_mac() { grep -oE "\"host\": \"$NODE\", \"hwaddr\": \"[0-9a-f:]+\"" "$REPO/opnsense/dnsmasq-dhcp.py" | grep -oE '[0-9a-f:]{17}' | tr -d ':'; }
node_ready() { kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }

# ---------------------------------------------------------------- preflight
preflight() {
  echo "preflight: $NODE"
  local ip ready
  if ! ready="$(node_ready)" || [ -z "$ready" ]; then fail "node $NODE not found"; return; fi
  ip="$(node_ip)"
  if [ "$ready" = True ]; then ok "node Ready ($ip)"; else fail "node not Ready ($ready)"; fi
  if talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ip" version --short >/dev/null 2>&1; then
    ok "Talos API reachable at $ip"; else fail "Talos API unreachable at $ip (shutdown would not be possible)"; fi
  if kubectl get node "$NODE" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' | grep -q .; then
    fail "control-plane node — use the Proxmox full-stop window (runbook), not this script"; fi

  # --- Longhorn: the whole point ---------------------------------------------------------
  local vols reps
  vols="$(kubectl -n longhorn-system get volumes.longhorn.io -o json)"
  reps="$(kubectl -n longhorn-system get replicas.longhorn.io -o json)"

  # degraded ATTACHED volumes anywhere (detached volumes read "unknown" — that's normal)
  local degraded
  degraded="$(jq -r '.items[]|select(.status.state=="attached" and .status.robustness!="healthy")|"\(.metadata.name) \(.status.robustness) on \(.status.currentNodeID)"' <<<"$vols")"
  if [ -z "$degraded" ]; then ok "Longhorn: no degraded attached volume cluster-wide"; else fail "Longhorn degraded attached volume(s):"$'\n'"$degraded"; fi

  # replicas living on this node: each volume must keep ≥1 RUNNING replica elsewhere
  local here n others v state
  here="$(jq -r --arg n "$NODE" '.items[]|select(.spec.nodeID==$n)|.spec.volumeName' <<<"$reps" | sort -u)"
  n=0
  for v in $here; do
    n=$((n+1))
    others="$(jq -r --arg n "$NODE" --arg v "$v" '[.items[]|select(.spec.volumeName==$v and .spec.nodeID!=$n and .status.currentState=="running")]|length' <<<"$reps")"
    if [ "$others" -lt 1 ]; then
      fail "volume $v ($(pvc_of "$v")): its ONLY running replica is on $NODE — drain would be blocked and the data offline"
    fi
  done
  [ "$n" -gt 0 ] && ok "Longhorn: $n replica(s) on $NODE, each volume keeps a running replica elsewhere (they go degraded for the window; rebuild timer $(kubectl -n longhorn-system get settings.longhorn.io replica-replenishment-wait-interval -o jsonpath='{.value}')s)"
  [ "$n" -eq 0 ] && ok "Longhorn: no replicas on $NODE"
  printf '%s\n' $here | sed '/^$/d' | while read -r v; do printf '         %s  %s\n' "$v" "$(pvc_of "$v")"; done

  # volumes attached to (i.e. a workload consuming them on) this node
  local attached
  attached="$(jq -r --arg n "$NODE" '.items[]|select(.status.currentNodeID==$n)|.metadata.name' <<<"$vols")"
  if [ -z "$attached" ]; then ok "Longhorn: no volume attached on $NODE"; else
    warn "Longhorn: volume(s) attached on $NODE (their pods move with the drain):"; for v in $attached; do printf '         %s  %s\n' "$v" "$(pvc_of "$v")"; done; fi

  # --- workloads --------------------------------------------------------------------------
  local pods
  pods="$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o json)"
  local sts rides single
  sts="$(jq -r '.items[]|select(.metadata.ownerReferences[0].kind=="StatefulSet")|"\(.metadata.namespace)/\(.metadata.name)"' <<<"$pods")"
  [ -z "$sts" ] && ok "no StatefulSet pod on $NODE" || warn "StatefulSet pod(s) on $NODE — a service interruption while they move:"$'\n'"$(sed 's/^/         /' <<<"$sts")"
  rides="$(jq -r '.items[]|select((.metadata.ownerReferences[0].kind=="Workflow") or (.metadata.labels["workflows.argoproj.io/workflow"]!=null) or (.metadata.namespace|test("^agent-")))|"\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"' <<<"$pods")"
  [ -z "$rides" ] && ok "no Argo Workflow / agent ride pod on $NODE" || warn "ride pod(s) on $NODE — the drain kills them mid-flight:"$'\n'"$(sed 's/^/         /' <<<"$rides")"
  single="$(jq -r '.items[]|select(.metadata.ownerReferences[0].kind=="ReplicaSet")|"\(.metadata.namespace) \(.metadata.name)"' <<<"$pods" | while read -r ns p; do
      d="$(kubectl -n "$ns" get pod "$p" -o jsonpath='{.metadata.ownerReferences[0].name}' | sed 's/-[a-z0-9]*$//')"
      r="$(kubectl -n "$ns" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
      printf '%s/%s (deploy %s, replicas=%s)\n' "$ns" "$p" "$d" "$r"; done)"
  if [ -n "$single" ]; then
    if grep -q 'replicas=1)' <<<"$single"; then warn "Deployment pod(s) on $NODE, some single-replica — downtime while they reschedule:"$'\n'"$(sed 's/^/         /' <<<"$single")"
    else ok "Deployment pod(s) on $NODE all have replicas>1:"$'\n'"$(sed 's/^/         /' <<<"$single")"; fi
  fi
  local ds; ds="$(jq -r '[.items[]|select(.metadata.ownerReferences[0].kind=="DaemonSet")]|length' <<<"$pods")"
  ok "$ds DaemonSet pod(s) (ignored by the drain)"

  echo
  if [ "$FAILS" -gt 0 ]; then echo "preflight: $FAILS FAIL, $WARNS WARN — NOT safe"; return 2; fi
  if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $WARNS WARN — re-run with FORCE=1 to accept them"; return 2; fi
  echo "preflight: safe to take $NODE down"
}
pvc_of() { kubectl get pvc -A -o json | jq -r --arg v "$1" '.items[]|select(.spec.volumeName==$v)|"\(.metadata.namespace)/\(.metadata.name)"' | head -1; }

# ---------------------------------------------------------------- down
down() {
  preflight || return $?
  local ip; ip="$(node_ip)"
  log "cordon $NODE"; kubectl cordon "$NODE"
  log "drain $NODE (timeout $DRAIN_TIMEOUT)"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT"
  local left
  left="$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o json | jq -r '.items[]|select(.metadata.ownerReferences[0].kind!="DaemonSet")|"\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"')"
  if [ -n "$left" ]; then log "non-DaemonSet pods still on $NODE after drain:"; sed 's/^/  /' <<<"$left" >&2; fi
  # Longhorn's own view: scheduling off on a cordoned node is automatic; confirm before power-off.
  kubectl -n longhorn-system get nodes.longhorn.io "$NODE" -o jsonpath='longhorn node: allowScheduling={.spec.allowScheduling} schedulable={.status.conditions[?(@.type=="Schedulable")].status}{"\n"}' >&2
  log "talosctl shutdown $NODE ($ip)"
  talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ip" shutdown || log "shutdown returned non-zero (the API often drops mid-call) — verifying"
  local i=0
  until [ "$(node_ready)" != True ] || [ $i -ge 120 ]; do sleep 5; i=$((i+1)); done
  log "node condition Ready=$(node_ready) — pull the power when the box is dark. Wake with: $0 up $NODE"
}

# ---------------------------------------------------------------- up
up() {
  local ip; ip="$(node_ip)"
  if [ "$(node_ready)" = True ]; then log "$NODE already Ready"; else
    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then log "$ip answers ping — booting, no WoL needed"; else
      local mac; mac="$(node_mac || true)"
      if [ -z "$mac" ]; then log "no MAC for $NODE in opnsense/dnsmasq-dhcp.py (a VM? start it on pve) — waiting for Ready anyway"; else
        log "WoL $NODE ($mac) via $PVE_HOST"
        ssh -i "$PVE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes "$PVE_HOST" \
          "python3 -c \"import socket; m=bytes.fromhex('$mac'); p=b'\\xff'*6+m*16; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(1,6,1); s.sendto(p,('255.255.255.255',9))\""
      fi
    fi
    log "waiting for Ready (≤${READY_TIMEOUT}s)"
    local t=0; until [ "$(node_ready)" = True ]; do sleep 10; t=$((t+10)); [ $t -ge "$READY_TIMEOUT" ] && { log "TIMEOUT: $NODE not Ready after ${READY_TIMEOUT}s"; return 1; }; done
    log "$NODE Ready after ~${t}s"
  fi
  log "uncordon $NODE"; kubectl uncordon "$NODE"
  log "waiting for Longhorn: node Schedulable + every attached volume healthy (≤${HEALTHY_TIMEOUT}s)"
  local t=0 bad sched
  while :; do
    sched="$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Schedulable")].status}' 2>/dev/null)"
    bad="$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '[.items[]|select(.status.state=="attached" and .status.robustness!="healthy")]|length')"
    [ "$sched" = True ] && [ "$bad" = 0 ] && break
    sleep 15; t=$((t+15)); [ $t -ge "$HEALTHY_TIMEOUT" ] && { log "TIMEOUT: longhorn schedulable=$sched degraded=$bad after ${HEALTHY_TIMEOUT}s"; return 1; }
  done
  log "Longhorn: $NODE schedulable, 0 degraded attached volumes. Window closed."
  kubectl get node "$NODE" -o wide
}

case "$cmd" in
  preflight) preflight ;;
  down) down ;;
  up) up ;;
  *) usage ;;
esac
