#!/usr/bin/env bash
# Single-node maintenance window for a Talos WORKER (metal or VM): the deterministic
# cordon → drain → shutdown path, with the storage checks that make "safe to pull the
# plug" a computed answer instead of a k9s glance — and the reverse (wake → Ready →
# uncordon → Longhorn healthy again).
#
#   bash scripts/node-maintenance.sh preflight <node>   # read-only: is the node safe to take down?
#   bash scripts/node-maintenance.sh settle    <node>   # cordon, then DO what preflight only reports:
#                                                        wait out rides/transient consumers, MOVE the
#                                                        last replicas long-lived pods hold (DRY=1: report)
#   bash scripts/node-maintenance.sh down      <node>   # preflight → settle → drain → talosctl shutdown
#   bash scripts/node-maintenance.sh up        <node>   # WoL (metal) → wait Ready → uncordon → wait Longhorn healthy
#
# `down` does as much as it can before it lets a drain block (operator direction 2026-09-09):
#   WAIT  a ride / Argo Workflow / coordinator pod, or a last replica whose consumer is such a
#         transient pod (Job, Workflow, bare Pod, anything in an agent namespace) — settle waits
#         for it to finish (≤ SETTLE_TIMEOUT, 3600 s), node cordoned so nothing new lands
#   MOVE  a last replica whose consumer is long-lived (StatefulSet/Deployment/DaemonSet) — settle
#         adds a replica elsewhere (numberOfReplicas+1), waits for the rebuild, deletes the one on
#         this node, restores the count (≤ MOVE_TIMEOUT, 1800 s per volume)
#
# What preflight refuses on (exit 2 — pass FORCE=1 to override a WARN-class one):
#   FAIL  node missing / not Ready / Talos API unreachable
#   FAIL  an ATTACHED Longhorn volume's only running replica is on this node (the drain would
#         block on Longhorn's instance-manager PDB) — `settle` waits it out or moves it, see below
#   WARN  a DETACHED volume's last replica is stopped on this node — offline for the window, back
#         with the disk (the cluster runs node-drain-policy=allow-if-replica-is-stopped, so the
#         drain proceeds; replica-1 classes longhorn-single/-fast/-scratch are replica-1 BY DESIGN)
#   FAIL  any attached Longhorn volume cluster-wide is already degraded (a second outage on
#         top of a rebuild is how a 2-replica volume loses data)
#   WARN  a StatefulSet pod runs here (it moves, but that is a service interruption)
#   WAIT  an Argo Workflow / agent ride / coordinator pod runs here (not a WARN: settle waits)
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
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-3600}" # s — rides / transient consumers to finish (node cordoned meanwhile)
MOVE_TIMEOUT="${MOVE_TIMEOUT:-1800}"     # s — per volume: the extra replica's rebuild elsewhere
DRY="${DRY:-0}"                          # settle: report what it would wait on / move, change nothing

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

# Volumes whose LAST usable replica sits on $NODE, one per line:
#   <volume> <attached|detached> <ns/pvc> <consumer>
# consumer = <Kind>:<pod> of the live (Running/Pending) pod holding it, or "-" (Longhorn's
# kubernetesStatus.workloadsStatus; a bare pod — the coordinator's shape — reports Kind "Pod").
# ATTACHED: no RUNNING sibling elsewhere. DETACHED: no HEALTHY (failedAt empty) sibling elsewhere —
# a detached volume has no running replica ANYWHERE, which is why the running-only test used to
# flag every detached volume on the node (2026-09-09, three false FAILs on thinkcentre).
last_replicas() {
  local tv tr; tv="$(mktemp)"; tr="$(mktemp)"
  kubectl -n longhorn-system get volumes.longhorn.io -o json >"$tv"
  kubectl -n longhorn-system get replicas.longhorn.io -o json >"$tr"
  jq -rn --arg n "$NODE" --slurpfile V "$tv" --slurpfile R "$tr" '
    ($R[0].items) as $reps | ($V[0].items) as $vols
    | ([$reps[]|select(.spec.nodeID==$n)|.spec.volumeName]|unique[]) as $v
    | ($vols[]|select(.metadata.name==$v)) as $vol
    | $vol.status.state as $state
    | (if $state=="attached"
       then [$reps[]|select(.spec.volumeName==$v and .spec.nodeID!=$n and .status.currentState=="running")]|length
       else [$reps[]|select(.spec.volumeName==$v and .spec.nodeID!=$n and .spec.failedAt=="")]|length end) as $others
    | select($others<1)
    | ([$vol.status.kubernetesStatus.workloadsStatus[]?|select(.podStatus=="Running" or .podStatus=="Pending")]|first) as $w
    | "\($v) \($state) \($vol.status.kubernetesStatus.namespace)/\($vol.status.kubernetesStatus.pvcName) \(if $w then ((if $w.workloadType=="" then "Pod" else $w.workloadType end)+":"+$w.podName) else "-" end)"'
  rm -f "$tv" "$tr"
}
# Transient consumers/pods: settle WAITS for them. Long-lived ones hold their volume until the
# drain moves the pod — a last replica under one of those must be MOVED instead.
transient_kind() { case "$1" in Pod|Job|CronJob|Workflow|-) return 0;; *) return 1;; esac; }
# Ride / Argo Workflow / coordinator pods on $NODE still running: "<ns>/<pod> <phase>"
rides_running() {
  kubectl get pods --field-selector "spec.nodeName=$NODE" -A -o json | jq -r '.items[]
    | select(.status.phase=="Running" or .status.phase=="Pending")
    | select((.metadata.ownerReferences[0].kind=="Workflow") or (.metadata.labels["workflows.argoproj.io/workflow"]!=null)
             or ((.metadata.namespace|test("^agent-|-agents$")) and ((.metadata.ownerReferences[0].kind // "Pod")|IN("Pod","Job","Workflow"))))
    | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
}

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

  # replicas living on this node — the last-replica cases come from last_replicas() (see it for
  # the attached/detached distinction; the rest keep a sibling elsewhere and merely go degraded)
  local here n lr v state pvc consumer
  here="$(jq -r --arg n "$NODE" '.items[]|select(.spec.nodeID==$n)|.spec.volumeName' <<<"$reps" | sort -u)"
  n="$(printf '%s\n' $here | sed '/^$/d' | wc -l)"
  lr="$(last_replicas)"
  while read -r v state pvc consumer; do
    [ -z "$v" ] && continue
    if [ "$state" = attached ]; then
      if transient_kind "${consumer%%:*}"; then
        fail "volume $v ($pvc): attached, its ONLY running replica is on $NODE, held by $consumer — the drain would block; \`settle\` waits for that pod to finish"
      else
        fail "volume $v ($pvc): attached, its ONLY running replica is on $NODE, held by $consumer — the drain would block; \`settle\` moves the replica (numberOfReplicas+1 → rebuild → drop this one)"
      fi
    else
      warn "volume $v ($pvc): detached, its last replica is stopped on $NODE — offline for the window (drain allowed: node-drain-policy=allow-if-replica-is-stopped); keep that disk in the box"
    fi
  done <<<"$lr"
  if [ "$n" -gt 0 ]; then
    if [ -n "$lr" ]; then log "Longhorn: $n replica(s) on $NODE (the rest keep a healthy sibling elsewhere; rebuild timer $(kubectl -n longhorn-system get settings.longhorn.io replica-replenishment-wait-interval -o jsonpath='{.value}')s):"
    else ok "Longhorn: $n replica(s) on $NODE, each volume keeps a running replica elsewhere (they go degraded for the window; rebuild timer $(kubectl -n longhorn-system get settings.longhorn.io replica-replenishment-wait-interval -o jsonpath='{.value}')s)"; fi
  else ok "Longhorn: no replicas on $NODE"; fi
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
  rides="$(rides_running)"
  [ -z "$rides" ] && ok "no Argo Workflow / agent ride / coordinator pod on $NODE" || printf '  \033[36mWAIT\033[0m ride pod(s) on %s — \`settle\` waits for them (a drain would kill them mid-flight):\n%s\n' "$NODE" "$(sed 's/^/         /' <<<"$rides")"
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
  if [ "$FAILS" -gt 0 ]; then
    if [ -n "$lr" ] && [ "$FAILS" -eq "$(grep -c ' attached ' <<<"$lr")" ]; then
      if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $FAILS FAIL (all last-replica — \`settle\` handles them), $WARNS WARN — re-run with FORCE=1 to accept the WARNs"; return 2; fi
      echo "preflight: $FAILS FAIL (all last-replica — \`settle\` handles them), $WARNS WARN — NOT safe yet"; return 3; fi
    echo "preflight: $FAILS FAIL, $WARNS WARN — NOT safe"; return 2; fi
  if [ -n "$rides" ]; then echo "preflight: ride pod(s) running, $WARNS WARN — \`settle\` waits for the rides"; [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ] && return 2; return 3; fi
  if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $WARNS WARN — re-run with FORCE=1 to accept them"; return 2; fi
  echo "preflight: safe to take $NODE down"
}
pvc_of() { kubectl get pvc -A -o json | jq -r --arg v "$1" '.items[]|select(.spec.volumeName==$v)|"\(.metadata.namespace)/\(.metadata.name)"' | head -1; }

# ---------------------------------------------------------------- settle
# Move ONE volume's last replica off $NODE while it stays attached: +1 replica (Longhorn rebuilds
# it elsewhere — the node is cordoned, so never here), wait healthy, delete the replica on $NODE,
# restore the count. Longhorn has no "move replica"; this is the UI's add-then-delete, scripted.
move_replica() {
  local v="$1" n t=0 elsewhere robust r
  n="$(kubectl -n longhorn-system get volumes.longhorn.io "$v" -o jsonpath='{.spec.numberOfReplicas}')"
  log "move $v: numberOfReplicas $n → $((n+1)), rebuilding off $NODE (≤${MOVE_TIMEOUT}s)"
  kubectl -n longhorn-system patch volumes.longhorn.io "$v" --type=merge -p "{\"spec\":{\"numberOfReplicas\":$((n+1))}}" >/dev/null
  while :; do
    elsewhere="$(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg v "$v" --arg n "$NODE" '[.items[]|select(.spec.volumeName==$v and .spec.nodeID!=$n and .status.currentState=="running" and .spec.failedAt=="")]|length')"
    robust="$(kubectl -n longhorn-system get volumes.longhorn.io "$v" -o jsonpath='{.status.robustness}')"
    [ "$elsewhere" -ge "$n" ] && [ "$robust" = healthy ] && break
    sleep 15; t=$((t+15))
    [ $t -ge "$MOVE_TIMEOUT" ] && { log "TIMEOUT: $v — $elsewhere running elsewhere, robustness=$robust; count left at $((n+1)), nothing deleted"; return 1; }
  done
  for r in $(kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg v "$v" --arg n "$NODE" '.items[]|select(.spec.volumeName==$v and .spec.nodeID==$n)|.metadata.name'); do
    log "move $v: deleting replica $r on $NODE"; kubectl -n longhorn-system delete replicas.longhorn.io "$r" >/dev/null; done
  kubectl -n longhorn-system patch volumes.longhorn.io "$v" --type=merge -p "{\"spec\":{\"numberOfReplicas\":$n}}" >/dev/null
  log "move $v: done — $n replica(s), none on $NODE"
}

settle() {
  local t=0 lr rides moved="" v state pvc consumer kind blocking last_report=-1000
  if [ "$DRY" = 1 ]; then log "DRY=1: reporting only, no cordon / move"; else
    log "cordon $NODE (nothing new lands here while we wait; Longhorn follows the cordon)"; kubectl cordon "$NODE" >/dev/null; fi
  while :; do
    lr="$(last_replicas)"; rides="$(rides_running)"
    while read -r v state pvc consumer; do
      [ -z "$v" ] || [ "$state" != attached ] && continue
      kind="${consumer%%:*}"
      if ! transient_kind "$kind" && ! grep -q " $v " <<<" $moved "; then
        if [ "$DRY" = 1 ]; then log "would MOVE $v ($pvc) — held by $consumer"; else move_replica "$v" || return 1; fi
        moved="$moved $v"
      fi
    done <<<"$lr"
    blocking="$(awk '$2=="attached"' <<<"$lr" | while read -r v state pvc consumer; do
      kind="${consumer%%:*}"; if transient_kind "$kind" || [ "$DRY" = 1 ]; then printf '  last replica %s (%s) held by %s\n' "$v" "$pvc" "$consumer"; fi; done)"
    [ -z "$blocking" ] && [ -z "$rides" ] && { log "settled: no attached last replica, no ride pod on $NODE"; return 0; }
    if [ "$DRY" = 1 ]; then log "would WAIT on:"; printf '%s\n' "$blocking" | sed '/^$/d' >&2; sed 's/^/  ride /;/^  ride $/d' <<<"$rides" >&2; return 0; fi
    if [ $((t - last_report)) -ge 300 ]; then
      log "waiting (${t}s/${SETTLE_TIMEOUT}s) on:"; printf '%s\n' "$blocking" | sed '/^$/d' >&2; sed 's/^/  ride /;/^  ride $/d' <<<"$rides" >&2; last_report=$t; fi
    [ $t -ge "$SETTLE_TIMEOUT" ] && { log "TIMEOUT: still blocked after ${SETTLE_TIMEOUT}s — node stays cordoned; \`kubectl uncordon $NODE\` to give up"; return 1; }
    sleep 30; t=$((t+30))
  done
}

# ---------------------------------------------------------------- down
down() {
  local rc=0; preflight || rc=$?
  # 2 = hard FAIL or un-FORCEd WARN → stop. 3 = only settle-able findings (last replicas, rides).
  [ "$rc" = 2 ] && return 2
  local ip; ip="$(node_ip)"
  settle || return $?
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
    local t=0; until [ "$(node_ready)" = True ]; do
      sleep 10; t=$((t+10))
      # WoL only works from S5 on standby power: a box that was UNPLUGGED (cable swap, RAM…) has
      # no armed NIC until it has booted once — 2026-09-06, wk-metal-04 needed the button.
      [ $t -eq 120 ] && ! ping -c1 -W1 "$ip" >/dev/null 2>&1 && log "no ping after 120s — if the box lost AC power, WoL cannot wake it: press the power button (the wait continues)"
      [ $t -ge "$READY_TIMEOUT" ] && { log "TIMEOUT: $NODE not Ready after ${READY_TIMEOUT}s"; return 1; }
    done
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
  # Replicas that failed during the window get REPLACED (rebuilt elsewhere after
  # replica-replenishment-wait-interval); their directories stay on the returning disk as
  # orphans and still count as used space — 2026-09-06 a 141G stale Garage copy blocked the
  # Garage volume's own rebuild onto this very disk. `orphan-resource-auto-deletion` removes
  # them after a grace period when set (tofu/longhorn.tf); list them here regardless, and
  # delete with DELETE_ORPHANS=1 (safe now: every attached volume is healthy again).
  local orphans
  orphans="$(kubectl -n longhorn-system get orphans.longhorn.io -o json | jq -r --arg n "$NODE" '.items[]|select(.spec.nodeID==$n)|"\(.metadata.name) \(.spec.parameters.DataName)"')"
  if [ -n "$orphans" ]; then
    log "orphaned replica dir(s) left on $NODE:"; awk '{print "  "$2}' <<<"$orphans" >&2
    if [ "${DELETE_ORPHANS:-0}" = 1 ]; then
      awk '{print $1}' <<<"$orphans" | xargs -r -n1 kubectl -n longhorn-system delete orphans.longhorn.io
    else
      log "left in place — Longhorn auto-deletes them after its grace period if orphan-resource-auto-deletion is on; DELETE_ORPHANS=1 $0 up $NODE removes them now"
    fi
  else
    log "no orphaned replica dirs on $NODE"
  fi
}

case "$cmd" in
  preflight) preflight ;;
  settle) settle ;;
  down) down ;;
  up) up ;;
  *) usage ;;
esac
