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
#                                                        (settle also SILENCES the node's alerts in
#                                                         Alertmanager; `up` expires the silence)
#   bash scripts/node-maintenance.sh up        <node>   # WoL (metal) → wait Ready → uncordon → wait Longhorn healthy
#   bash scripts/node-maintenance.sh upgrade   <node>   # preflight → settle → talosctl upgrade → wait
#                                                        Ready + Longhorn healthy → VERIFY version
#                                                        AND schematic against the declaration
#
# `upgrade` is the GATE and the QUEUE, not the upgrader: talosctl already cordons, drains
# (client-side, respecting PodDisruptionBudgets — probed 2026-09-18), installs, reboots, rejoins
# and uncordons. What this adds is everything talosctl does not know about — the Longhorn
# last-replica move, the fleet floor, WIP 1, the FU-033 gate, and the post-check that the node
# came back running the schematic it declares. The target image is READ FROM THE DECLARATION
# (`tofu output node_install_targets`), never typed: it must match on three axes — platform,
# schematic, version — or the node loses its identity (ADR-014, amended) or its extensions.
#
# `down` does as much as it can before it lets a drain block (operator direction 2026-09-09):
#   WAIT  a ride / Argo Workflow / coordinator pod / ARC runner with a job assigned, or a last
#         replica whose consumer is such a transient pod (Job, Workflow, bare Pod, anything in an agent namespace) — settle waits
#         for it to finish (≤ SETTLE_TIMEOUT, 3600 s), node cordoned so nothing new lands
#   MOVE  a last replica whose consumer is long-lived (StatefulSet/Deployment/DaemonSet) — settle
#         adds a replica elsewhere (numberOfReplicas+1), waits for the rebuild, deletes the one on
#         this node, restores the count (≤ MOVE_TIMEOUT, 1800 s per volume). A last replica that
#         transient pods keep re-holding (the coordinator's RWX transcripts volume: back-to-back
#         runs, 2026-09-09) is moved the same way once it has blocked for MOVE_AFTER (600 s).
#   bash scripts/node-maintenance.sh move <node> <volume>   # that move, by hand, for one volume
#   bash scripts/node-maintenance.sh silence-open  <node>   # declare the window by hand — BOTH the
#   bash scripts/node-maintenance.sh silence-close <node>   # Alertmanager silences (leg a) and the
#                                                             responder's declared-window record
#                                                             (leg b, agents/seat-window.sh, for the
#                                                             alert classes that carry no node /
#                                                             instance / pod label at all); expire
#                                                             both (all four are done for you by
#                                                             settle/down and up — FU-230);
#                                                             SILENCE=0 opts the whole window out
#   bash scripts/node-maintenance.sh power <node> [status|cycle]   # smart-plug draw (machines.yaml `plug:`);
#         `cycle` REFUSES a socket carrying load (FORCE=1 overrides) — 2026-09-09: crossed plug ids
#         let a "boot thinkcentre" cycle cut hp-01 (docs/incidents/2026-09-09-crossed-plug-hp01-outage.md)
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
#   WAIT  an Argo Workflow / agent ride / coordinator pod / busy ARC runner runs here (not a WARN:
#         settle waits — a drained busy runner is a cancelled CI job)
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
MOVE_AFTER="${MOVE_AFTER:-600}"          # s — a last replica still held by TRANSIENT pods after this long gets moved too
DRY="${DRY:-0}"                          # settle: report what it would wait on / move, change nothing
UPGRADE_DRAIN_TIMEOUT="${UPGRADE_DRAIN_TIMEOUT:-5m}"  # talosctl's own client-side drain
# Where the declared install targets come from. Default: the management box, which holds main's
# state (ADR-131/FU-012) and reads a COMMITTED ref — so the declaration is what master says, not
# what the working tree says. Override with a pre-fetched file for an offline/dry run.
INSTALL_TARGETS="${INSTALL_TARGETS:-}"   # path to a `tofu output -json node_install_targets` dump
TARGET_IMAGE="${TARGET_IMAGE:-}"         # last-resort explicit --image; skips the declaration read
ENDPOINT="${ENDPOINT:-}"                 # the CP the upgrade is endpointed at (pick_cp_endpoint)
AM="${NM_AM:-http://192.168.40.14:9093}" # Alertmanager API (same default as agents/meta-events.sh)
PROM="${NM_PROM:-http://192.168.40.13:9090}" # Prometheus (the Garage fleet floor reads it)
GARAGE_SYNC_TIMEOUT="${GARAGE_SYNC_TIMEOUT:-900}" # s — wait for cluster_healthy after a window
SILENCE_HOURS="${SILENCE_HOURS:-3}"      # window silence lifetime; `up` expires it early
SILENCE="${SILENCE:-1}"                  # 0 = do not touch Alertmanager at all
POD_GRACE_MIN="${POD_GRACE_MIN:-45}"     # the POD-scoped silence outlives the window on purpose

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
usage(){ sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }

cmd="${1:-}"; NODE="${2:-}"
[ -n "$cmd" ] || usage
# `order` ranks the whole fleet and takes no node argument.
[ -n "$NODE" ] || [ "$cmd" = order ] || usage
WARNS=0; FAILS=0

node_ip() { kubectl get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
node_mac() { grep -oE "\"host\": \"$NODE\", \"hwaddr\": \"[0-9a-f:]+\"" "$REPO/opnsense/dnsmasq-dhcp.py" | grep -oE '[0-9a-f:]{17}' | tr -d ':'; }
node_ready() { kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
# Is the box answering on the network? ping is NOT available in the jail container (no iputils in
# devbox, none in the image — 2026-09-12: the silent `ping` failure made `up` fire WoL at a box
# that was already booting, and the ssh hop then aborted the whole wake). bash /dev/tcp needs no
# tool: Talos apid (50000) answers as soon as the machine is up, long before Ready.
host_up() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/50000" 2>/dev/null; }

# Volumes whose LAST usable replica sits on $NODE, one per line:
#   <volume> <attached|detached> <ns/pvc> <consumer> <dataLocality>
# dataLocality=strict-local is a ZONE volume by design (ADR-114: Garage's data lives on that node,
# replicated by the app across zones) — it can neither be moved nor should be: the pod evicts with
# the drain, the volume detaches, the other zones serve. WARN, never MOVE (2026-09-09, garage-0).
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
    | "\($v) \($state) \($vol.status.kubernetesStatus.namespace)/\($vol.status.kubernetesStatus.pvcName) \(if $w then ((if $w.workloadType=="" then "Pod" else $w.workloadType end)+":"+$w.podName) else "-" end) \($vol.spec.dataLocality // "disabled")"'
  rm -f "$tv" "$tr"
}
# Transient consumers/pods: settle WAITS for them. Long-lived ones hold their volume until the
# drain moves the pod — a last replica under one of those must be MOVED instead.
transient_kind() { case "$1" in Pod|Job|CronJob|Workflow|-) return 0;; *) return 1;; esac; }
# Ride / Argo Workflow / coordinator pods on $NODE still running: "<ns>/<pod> <phase>". ANY bare
# pod (no controller) counts: worker rides live in the STACK namespace (oracle-fleet/agent-…-r2,
# app=agent-session), not only in the agent namespaces — 2026-09-09 the drain refused one
# ("cannot delete Pods that declare no controller") after settle had reported no ride.
rides_running() {
  kubectl get pods --field-selector "spec.nodeName=$NODE" -A -o json | jq -r '.items[]
    | select(.status.phase=="Running" or .status.phase=="Pending")
    | select((.metadata.ownerReferences[0].kind=="Workflow") or (.metadata.labels["workflows.argoproj.io/workflow"]!=null)
             or ((.metadata.ownerReferences // [])|length==0)
             or ((.metadata.namespace|test("^agent-|-agents$")) and ((.metadata.ownerReferences[0].kind // "Pod")|IN("Pod","Job","Workflow"))))
    | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"'
  # ARC ephemeral runners with a JOB ASSIGNED: the EphemeralRunner (same name as its pod) carries
  # status.workflowRunId/jobRepositoryName only while a job runs — an idle warm runner has neither
  # and is safe to evict (ARC re-creates it). The runner pod is controller-owned, so the drain
  # deletes it without a word and the job dies as "The operation was canceled" (oracle-fleet run
  # 34829496525, the wk-03 window of 2026-09-14) — so a busy runner is a ride: settle waits.
  local busy; busy="$(kubectl get ephemeralrunners -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.workflowRunId != null) | "\(.metadata.namespace)/\(.metadata.name) \(.status.jobRepositoryName // "?")#\(.status.workflowRunId)"')"
  [ -n "$busy" ] && kubectl get pods --field-selector "spec.nodeName=$NODE" -A -o json | jq -r --arg busy "$busy" '
    ($busy | split("\n") | map(select(length>0) | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $b
    | .items[] | select(.status.phase=="Running") | "\(.metadata.namespace)/\(.metadata.name)" as $k
    | select($b[$k] != null) | "\($k) Running ARC-job:\($b[$k])"'
  return 0
}

# ------------------------------------------------------- the window silence (FU-230 leg a)
# A maintenance window is invisible to the alert path, and the responder then diagnoses OUR OWN
# work: 2026-09-09's three thinkcentre windows cost ≥8 of the 12 daily triage sessions, and on
# 2026-09-12 m70s's planned reboot became a careful "cannot determine crash vs power-loss" writeup
# (homelab#261). So `settle`/`down` open a silence and `up` expires it.
#
# ⚠ WHICH LABEL: alerts do NOT reliably carry `node`. NodeRebooted fires on
# node_boot_time_seconds, whose only node identifier is `instance=<ip>:9100` — a hand-issued
# node=m70s silence matched nothing on 2026-09-12. The window therefore silences BOTH keys, and
# for a zone node the instance-keyed Garage health alerts too (their `instance` is the blackbox
# target, not this box). Capacity/quota/GC alerts stay LIVE on purpose: a full disk during a
# window is still a full disk.
# ⚠ THE POD CLASS has no node key at all. Every pod the window kills produces alerts keyed only by
# namespace/pod/container — PodSigkilled's `instance` is KUBE-STATE-METRICS' own pod IP — so the
# fourth silence matches the node's pod names, captured before the drain. It deliberately OUTLIVES
# the window (POD_GRACE_MIN, default 45m): PodSigkilled is `increase(...[30m])`, so it fires up to
# half an hour after the kill — on 2026-09-12 it fired 19 min after the SIGKILL and 10 min after the
# node was back Ready (homelab#1600), which no window-length silence could have caught. The cost is
# bounded and named: a StatefulSet pod returns under the SAME name, so a genuine alert about one of
# these pods stays suppressed until the grace expires. `up` leaves it running; SILENCE_CLOSE_PODS=1
# expires it too.
# ⚠ DURABILITY: silences live on Alertmanager's emptyDir (FU-195) — a monitoring restart mid-window
# drops them and alerts resume, i.e. back to the old behaviour. Best-effort by construction: an
# unreachable Alertmanager logs and never fails the window.
SILENCE_OWNER() { printf 'node-maintenance.sh/%s%s' "$NODE" "${1:-}"; }

has_zone_volume() { last_replicas 2>/dev/null | grep -q 'strict-local'; }

silence_open() {
  [ "$SILENCE" = 1 ] || { log "SILENCE=0 — not touching Alertmanager"; return 0; }
  local ip existing
  existing="$(silence_ids)"
  if [ -n "$existing" ]; then log "window silence already active for $NODE: $(tr '\n' ' ' <<<"$existing")"; return 0; fi
  ip="$(node_ip)"
  local matchers garage
  matchers="$(jq -cn --arg ip "$ip" --arg n "$NODE" '[
      {name:"instance", value:($ip+"(:[0-9]+)?"), isRegex:true,  isEqual:true},
      {name:"node",     value:$n,                 isRegex:false, isEqual:true}]')"
  if has_zone_volume; then
    garage='Garage(ClusterDegraded|ClusterFlapping|PeerRpcTimeouts|QuorumMembersRestarted|AdminMetricsAbsent|TableEmpty|S3ServerErrors)'
    log "$NODE carries a strict-local zone volume — also silencing the Garage health alerts"
  fi
  local m
  while read -r m; do
    [ -n "$m" ] || continue
    post_silence "$m" || warn "could not open a window silence (matcher $m) — alerts will fire for this window"
  done <<EOF
$(jq -cn --argjson ms "$matchers" '$ms[] | [.]')
$( [ -n "${garage:-}" ] && jq -cn --arg re "$garage" '[{name:"alertname", value:$re, isRegex:true, isEqual:true}]')
EOF
  # The pods this window is about to kill, by name — captured BEFORE the drain, DaemonSet pods
  # included (they are not drained, they die with the power-off: engine-image, alloy, kmsg-reader
  # and the prepull holds were four of the five PodSigkilled alerts on 2026-09-12).
  local pods podre
  # same pipefail shape as silence_ids: a failing read must not abort the window, only skip the silence
  pods="$(kubectl get pods -A --field-selector "spec.nodeName=$NODE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u || true)"
  if [ -n "$pods" ]; then
    podre="($(paste -sd'|' - <<<"$pods"))"
    if post_silence "$(jq -cn --arg re "$podre" '[{name:"pod", value:$re, isRegex:true, isEqual:true}]')" '#pods' "$((POD_GRACE_MIN*60))"; then
      log "pod-scoped silence covers $(wc -l <<<"$pods") pod name(s) for ${POD_GRACE_MIN}m"
    else
      warn "could not open the pod-scoped silence — PodSigkilled et al. will fire for this window"
    fi
  fi
}

# One silence per matcher set: Alertmanager ANDs the matchers inside a silence, and `instance` and
# `node` never appear on the same alert.
post_silence() {
  local body id scope="${2:-}" secs="${3:-$((SILENCE_HOURS*3600))}"
  body="$(jq -cn --argjson matchers "$1" --arg by "$(SILENCE_OWNER "$scope")" --arg s "$secs" \
    --arg c "node-maintenance window on $NODE ($(date -u +%FT%TZ)) — planned cordon/drain/shutdown. Expired by \`node-maintenance.sh up $NODE\`${scope:+ (the pod-name silence self-expires later — PodSigkilled looks back 30m)}." \
    '{matchers:$matchers, startsAt:(now|todate), endsAt:((now + ($s|tonumber))|todate), createdBy:$by, comment:$c}')"
  id="$(curl -sf -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "$AM/api/v2/silences" | jq -r '.silenceID // empty')"
  [ -n "$id" ] || return 1
  ok "window silence $id  $(jq -r 'map("\(.name)\(if .isRegex then "=~" else "=" end)\(.value)")|join(" ")' <<<"$1")"
}

# `|| true` is load-bearing: under this script's `set -euo pipefail` an unreachable Alertmanager
# makes `curl -sf` fail, pipefail propagates it, and the PLAIN assignments at the call sites
# (`existing=$(silence_ids)`, `ids=$(silence_ids)`) would abort the whole window right after the
# cordon — the opposite of the best-effort promise above (bot review, PR#1601).
silence_ids() {
  curl -sf -m 10 "$AM/api/v2/silences" 2>/dev/null \
    | jq -r --arg by "$(SILENCE_OWNER "${1:-}")" '.[]|select(.createdBy==$by and .status.state!="expired")|.id' 2>/dev/null || true
}

silence_close() {
  [ "$SILENCE" = 1 ] || return 0
  local ids id n=0
  ids="$(silence_ids)"
  if [ "${SILENCE_CLOSE_PODS:-0}" = 1 ]; then ids="$ids
$(silence_ids '#pods')"
  elif [ -n "$(silence_ids '#pods')" ]; then
    log "leaving the pod-scoped silence to self-expire (≤${POD_GRACE_MIN}m) — PodSigkilled fires up to 30m after the kill; SILENCE_CLOSE_PODS=1 to expire it now"
  fi
  [ -n "$ids" ] || { log "no window silence to expire for $NODE"; return 0; }
  for id in $ids; do
    if curl -sf -m 10 -X DELETE "$AM/api/v2/silence/$id" >/dev/null; then n=$((n+1)); else warn "could not expire silence $id — it self-expires in ≤${SILENCE_HOURS}h"; fi
  done
  ok "expired $n window silence(s) for $NODE"
}

# ------------------------------------------------------- the DECLARED window (FU-230 leg b)
# The silences above cover every alert that carries `node`, `instance` or one of this node's pod
# names. One class is beyond ALL of them, structurally: a rollout alert labelled by namespace +
# daemonset carries none of those keys, and the pod that goes Pending is minted AFTER the silence.
# 2026-09-16 proved it twice in a day — an nx-01 reinstall leaked `KubeDaemonSetRolloutStuck` with
# all four matchers armed, and wk-03's shutdown leaked CiliumUnreachableNodes ×11, DaemonSet
# rollout/misschedule ×8, KubeNodeUnreachable, KubeletInstanceUnreachable and KubePodNotReady ×4,
# which the seat then silenced by hand for 8 h. Enumerating `daemonset=~…` arms per alert name is
# the losing game that sighting demonstrates.
#
# So the window DECLARES those names to the responder instead (agents/seat-window.sh → a ConfigMap
# the triage reads). It suppresses only the LLM triage: the alerts still fire, still reach Home
# Assistant and Grafana, and a person still sees them. The list is the classes a node-maintenance
# window structurally produces and the label taxonomy structurally cannot reach.
DECLARED_ALERTS="${DECLARED_ALERTS:-KubeDaemonSetRolloutStuck,KubeDaemonSetMisScheduled,KubeNodeUnreachable,KubeletInstanceUnreachable,KubeNodeNotReady,KubePodNotReady,CiliumUnreachableNodes,CiliumAgentScrapeDown,TargetDown}"

declare_open() {
  [ "$SILENCE" = 1 ] || return 0
  SEAT_WINDOW_BY="node-maintenance.sh" SEAT_WINDOW_HOURS="$SILENCE_HOURS" \
    bash "$(dirname "$0")/../agents/seat-window.sh" open \
      --reason "node-maintenance window on $NODE — planned cordon/drain/shutdown" \
      --node "$NODE" --alerts "$DECLARED_ALERTS" \
      --note "closed by \`node-maintenance.sh up $NODE\`; the Alertmanager silences cover the node/instance/pod-keyed alerts, this record covers the classes that carry none of those labels" \
    || warn "could not declare the window to the responder — those alert classes will draw a triage session (FU-230 leg b)"
}

declare_close() {
  [ "$SILENCE" = 1 ] || return 0
  bash "$(dirname "$0")/../agents/seat-window.sh" close --node "$NODE" \
    || warn "could not close the declared window — it self-expires at its \`until\` (${SILENCE_HOURS}h)"
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
  local here n lr v state pvc consumer settle_fails=0
  here="$(jq -r --arg n "$NODE" '.items[]|select(.spec.nodeID==$n)|.spec.volumeName' <<<"$reps" | sort -u)"
  n="$(printf '%s\n' $here | sed '/^$/d' | wc -l)"
  lr="$(last_replicas)"
  while read -r v state pvc consumer locality; do
    [ -z "$v" ] && continue
    if [ "$locality" = strict-local ]; then
      warn "volume $v ($pvc): strict-local zone volume (${state}, held by $consumer) — pinned here by design; its pod evicts with the drain and the data is offline for the window (the app's other zones serve)"
    elif [ "$state" = attached ]; then
      settle_fails=$((settle_fails+1))
      if transient_kind "${consumer%%:*}"; then
        fail "volume $v ($pvc): attached, its ONLY running replica is on $NODE, held by $consumer — the drain would block; \`settle\` waits for that pod to finish (moves it after MOVE_AFTER=${MOVE_AFTER}s)"
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
    if [ "$settle_fails" -gt 0 ] && [ "$FAILS" -eq "$settle_fails" ]; then
      if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $FAILS FAIL (all last-replica — \`settle\` handles them), $WARNS WARN — re-run with FORCE=1 to accept the WARNs"; return 2; fi
      echo "preflight: $FAILS FAIL (all last-replica — \`settle\` handles them), $WARNS WARN — NOT safe yet"; return 3; fi
    echo "preflight: $FAILS FAIL, $WARNS WARN — NOT safe"; return 2; fi
  if [ -n "$rides" ]; then echo "preflight: ride pod(s) running, $WARNS WARN — \`settle\` waits for the rides"; [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ] && return 2; return 3; fi
  if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $WARNS WARN — re-run with FORCE=1 to accept them"; return 2; fi
  echo "preflight: safe to take $NODE down"
}
pvc_of() { kubectl get pvc -A -o json | jq -r --arg v "$1" '.items[]|select(.spec.volumeName==$v)|"\(.metadata.namespace)/\(.metadata.name)"' | head -1; }

# ---------------------------------------------------------------- power
# The plug is the box's own testimony: read the DRAW before believing a label or a switch state.
HA_URL="${HA_URL:-https://homeassistant.teststuff.net}"
ha_token() { [ -n "${HA_TOKEN:-}" ] && { printf '%s' "$HA_TOKEN"; return; }
  command -v keepassxc-cli >/dev/null 2>&1 || PATH="$REPO/.devbox/nix/profile/default/bin:$PATH"
  keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$HOME/.claude/homelab-keepass/homelab.kdbx" ha-access-token 2>/dev/null; }
ha_state() { curl -fsS -m 10 -H "Authorization: Bearer $(ha_token)" "$HA_URL/api/states/$1" | jq -r '.state'; }
ha_call()  { curl -fsS -m 10 -o /dev/null -X POST -H "Authorization: Bearer $(ha_token)" -H 'Content-Type: application/json' -d "{\"entity_id\":\"$2\"}" "$HA_URL/api/services/switch/$1"; }
plug_sensor() { yq -r ".machines[] | select(.name==\"$NODE\") | .plug // \"\"" "$REPO/machines/machines.yaml"; }
power() {
  local sensor sw draw
  sensor="$(plug_sensor)"
  [ -n "$sensor" ] || { log "$NODE has no plug in machines.yaml (plug: null) — no remote power read"; return 1; }
  sw="switch.tuyalocal_${sensor#sensor.plug_}"; sw="${sw%_power}"
  draw="$(ha_state "$sensor")"
  log "$NODE plug: $sensor = ${draw} W, $sw = $(ha_state "$sw")"
  [ "${1:-status}" = cycle ] || return 0
  # Fail CLOSED: a non-numeric reading (unavailable/unknown/null — real states for these Tuya
  # plugs) is "cannot tell", which is the same reason to refuse as "carrying load" (reviewer, PR#1568).
  case "$draw" in
    ''|*[!0-9.]*) [ "$FORCE" = 1 ] || { log "REFUSED: plug reading is '${draw}', not a number — cannot tell whether the box is running. FORCE=1 to cycle anyway."; return 2; } ;;
    *) if [ "${draw%.*}" -ge 3 ] 2>/dev/null && [ "$FORCE" != 1 ]; then
         log "REFUSED: that socket is carrying ${draw} W — a running box (or the wrong socket). FORCE=1 to cycle anyway."; return 2; fi ;;
  esac
  log "cycling $sw (off → 8 s → on)"; ha_call turn_off "$sw"; sleep 8; ha_call turn_on "$sw"; sleep 5
  log "$NODE plug after: $(ha_state "$sensor") W, $sw = $(ha_state "$sw")"
}

# ---------------------------------------------------------------- settle
# Move ONE volume's last replica off $NODE while it stays attached: +1 replica (Longhorn rebuilds
# it elsewhere — the node is cordoned, so never here), wait healthy, delete the replica on $NODE,
# restore the count. Longhorn has no "move replica"; this is the UI's add-then-delete, scripted.
move_replica() {
  local v="$1" n t=0 elsewhere robust r state
  state="$(kubectl -n longhorn-system get volumes.longhorn.io "$v" -o jsonpath='{.status.state}')"
  # a DETACHED volume has no engine, so Longhorn cannot rebuild it: +1 would sit forever (the
  # 2026-09-09 oracle transcripts move timed out exactly so) — and it does not block a drain
  [ "$state" = attached ] || { log "move $v: volume is $state, not attached — nothing to move (a stopped last replica does not block the drain)"; return 0; }
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
  local t=0 lr rides moved="" seen="" since v state pvc consumer kind blocking last_report=-1000
  if [ "$DRY" = 1 ]; then log "DRY=1: reporting only, no cordon / move / silence"; else
    log "cordon $NODE (nothing new lands here while we wait; Longhorn follows the cordon)"; kubectl cordon "$NODE" >/dev/null
    silence_open; declare_open; fi
  while :; do
    lr="$(last_replicas)"; rides="$(rides_running)"
    while read -r v state pvc consumer locality; do
      [ -z "$v" ] || [ "$state" != attached ] || [ "$locality" = strict-local ] && continue
      kind="${consumer%%:*}"
      grep -q " $v=" <<<" $seen " || seen="$seen $v=$t"
      since=$(( t - $(sed -n "s/.* $v=\([0-9]*\).*/\1/p" <<<" $seen ") ))
      if ! grep -q " $v " <<<" $moved " && { ! transient_kind "$kind" || [ "$since" -ge "$MOVE_AFTER" ]; }; then
        if [ "$DRY" = 1 ]; then log "would MOVE $v ($pvc) — held by $consumer"; else
          [ "$since" -ge "$MOVE_AFTER" ] && log "$v ($pvc): still held by transient pods after ${since}s (MOVE_AFTER=$MOVE_AFTER) — moving instead of waiting"
          move_replica "$v" || return 1; fi
        moved="$moved $v"
      fi
    done <<<"$lr"
    blocking="$(awk '$2=="attached" && $5!="strict-local"' <<<"$lr" | while read -r v state pvc consumer locality; do
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
  # DRY=1 previews the whole window: settle reported what it would wait on / move — stop here,
  # never a real drain or power-off under a dry-run flag (reviewer, PR#1564).
  [ "$DRY" = 1 ] && { log "DRY=1: would now cordon (if not yet), drain $NODE and talosctl shutdown — stopping"; return 0; }
  # --force is what lets the drain delete bare (controller-less) pods; it is safe ONLY because
  # settle just verified no running bare pod is left — what remains are finished ride pods.
  log "drain $NODE (timeout $DRAIN_TIMEOUT; --force for the finished bare pods settle waited on)"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout="$DRAIN_TIMEOUT"
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

# ------------------------------------------------- storage is back (shared by up + upgrade)
# Ready is NOT enough for a volume to come back: the Longhorn CSI plugin registers on the node
# SECONDS-to-MINUTES after Ready, and until it does every attach fails with "CSINode <node> does
# not contain driver driver.longhorn.io". The healthy test below cannot see that — a strict-local
# zone volume is DETACHED while its pod cannot attach, so "0 degraded ATTACHED volumes" is
# vacuously true and the window reads closed with garage-1 still down (2026-09-12, m70s: closed
# at 13:30:22, attach kept failing until the plugin registered ~13:32).
wait_storage_back() {
  log "waiting for the Longhorn CSI driver to register on $NODE (≤300s)"
  local t=0
  until kubectl get csinode "$NODE" -o jsonpath='{.spec.drivers[*].name}' 2>/dev/null | grep -q 'driver.longhorn.io'; do
    sleep 10; t=$((t+10))
    [ $t -ge 300 ] && { log "TIMEOUT: driver.longhorn.io not registered on $NODE after 300s — attaches will fail"; return 1; }
  done
  ok "Longhorn CSI driver registered on $NODE"
  log "waiting for Longhorn: node Schedulable + every attached volume healthy (≤${HEALTHY_TIMEOUT}s)"
  local bad sched; t=0
  while :; do
    sched="$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Schedulable")].status}' 2>/dev/null)"
    bad="$(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '[.items[]|select(.status.state=="attached" and .status.robustness!="healthy")]|length')"
    [ "$sched" = True ] && [ "$bad" = 0 ] && break
    sleep 15; t=$((t+15)); [ $t -ge "$HEALTHY_TIMEOUT" ] && { log "TIMEOUT: longhorn schedulable=$sched degraded=$bad after ${HEALTHY_TIMEOUT}s"; return 1; }
  done
  ok "Longhorn: $NODE schedulable, 0 degraded attached volumes"
}

# ---------------------------------------------------------------- up
up() {
  local ip; ip="$(node_ip)"
  if [ "$(node_ready)" = True ]; then log "$NODE already Ready"; else
    if host_up "$ip"; then log "$ip answers on :50000 — booting, no WoL needed"; else
      power status || true   # the plug's draw, before we believe anything about the box's state
      local mac; mac="$(node_mac || true)"
      if [ -z "$mac" ]; then log "no MAC for $NODE in opnsense/dnsmasq-dhcp.py (a VM? start it on pve) — waiting for Ready anyway"; else
        log "WoL $NODE ($mac) via $PVE_HOST"
        ssh -i "$PVE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$PVE_HOST" \
          "python3 -c \"import socket; m=bytes.fromhex('$mac'); p=b'\\xff'*6+m*16; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.setsockopt(1,6,1); s.sendto(p,('255.255.255.255',9))\"" \
          || log "WoL hop to $PVE_HOST failed (host key? key file?) — no magic packet sent; still waiting for Ready in case the box is already on"
      fi
    fi
    log "waiting for Ready (≤${READY_TIMEOUT}s)"
    local t=0; until [ "$(node_ready)" = True ]; do
      sleep 10; t=$((t+10))
      # WoL only works from S5 on standby power: a box that was UNPLUGGED (cable swap, RAM…) has
      # no armed NIC until it has booted once — 2026-09-06, wk-metal-04 needed the button.
      [ $t -eq 120 ] && ! host_up "$ip" && log "no answer on :50000 after 120s — if the box lost AC power, WoL cannot wake it: press the power button (the wait continues)"
      [ $t -ge "$READY_TIMEOUT" ] && { log "TIMEOUT: $NODE not Ready after ${READY_TIMEOUT}s"; return 1; }
    done
    log "$NODE Ready after ~${t}s"
  fi
  log "uncordon $NODE"; kubectl uncordon "$NODE"
  # Ready is NOT enough for a volume to come back: the Longhorn CSI plugin registers on the node
  # SECONDS-to-MINUTES after Ready, and until it does every attach fails with "CSINode <node> does
  # not contain driver driver.longhorn.io". The healthy test below cannot see that — a strict-local
  # zone volume is DETACHED while its pod cannot attach, so "0 degraded ATTACHED volumes" is
  # vacuously true and the window reads closed with garage-1 still down (2026-09-12, m70s: closed
  # at 13:30:22, attach kept failing until the plugin registered ~13:32).
  wait_storage_back || return 1
  log "Window closed."
  silence_close
  declare_close
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

# ---------------------------------------------------------------- upgrade
# The DECLARED install target for a node: tofu's node_install_targets output (tofu/outputs.tf).
# Read from the management box by default, because that is where main's state lives and it reads a
# COMMITTED ref — so "declared" means what master says, not what this working tree says.
TARGETS_JSON=""
load_targets() {
  [ -n "$TARGETS_JSON" ] && return 0
  if [ -n "$INSTALL_TARGETS" ]; then
    TARGETS_JSON="$(cat "$INSTALL_TARGETS")"
  else
    log "reading the declared install targets from the management box (mgmt-tf output)"
    TARGETS_JSON="$(bash "$REPO/scripts/mgmt-tf.sh" output -json node_install_targets)" || {
      fail "could not read node_install_targets from the box — is the output on master yet?"
      fail "  INSTALL_TARGETS=<file> $0 upgrade $NODE  to use a pre-fetched dump instead"
      return 1; }
  fi
  jq -e . >/dev/null 2>&1 <<<"$TARGETS_JSON" || { fail "node_install_targets is not JSON"; return 1; }
}
declared() { jq -r --arg n "$NODE" --arg f "$1" '.[$n][$f] // ""' <<<"$TARGETS_JSON"; }

# talosctl performs the drain CLIENT-side and fetches kubeconfig over MachineService/Kubeconfig,
# which is control-plane only — so a worker upgrade MUST be endpointed at a control plane. Never
# at one that is itself mid-window: pick a Ready, uncordoned CP that is not the target.
pick_cp_endpoint() {
  local cp
  cp="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json \
        | jq -r --arg n "$NODE" '.items[]
            | select(.metadata.name != $n)
            | select(.spec.unschedulable != true)
            | select(any(.status.conditions[]; .type=="Ready" and .status=="True"))
            | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)"
  [ -n "$cp" ] || { fail "no healthy control plane to endpoint the upgrade at"; return 1; }
  printf '%s' "$cp"
}

live_version() { kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null | sed -n 's/.*(\(v[0-9.]*\)).*/\1/p'; }
vminor() { printf '%s' "${1#v}" | cut -d. -f1,2; }

# WIP 1 (ADR-132 §4): never a second window before the first node is back. Any other node
# NotReady or cordoned means one is open — including one somebody opened by hand.
assert_wip1() {
  local busy
  busy="$(kubectl get nodes -o json | jq -r --arg n "$NODE" '.items[]
            | select(.metadata.name != $n)
            | select(.spec.unschedulable == true or (any(.status.conditions[]; .type=="Ready" and .status=="True") | not))
            | .metadata.name')"
  [ -z "$busy" ] && { ok "WIP 1: no other node cordoned or NotReady"; return 0; }
  fail "WIP 1: another window looks open — $(tr '\n' ' ' <<<"$busy")"; return 1
}

# The fleet floor (ADR-132 §4): no window while the storage fabric is already down one leg.
# Longhorn's degraded check is preflight's; this is the Garage half, and pod-Ready is NOT the
# right test. rf=3 over three physical zones, quorum 2: with one zone down every partition it
# holds sits at 2/3 — available, but the NEXT zone down takes those partitions to 1/3 and writes
# fail. So the binding condition is Garage's own `cluster_healthy`, which is exactly "every
# partition has ALL of its replica nodes up" (`cluster_available` is the weaker quorum-only
# twin). Both are scraped from the admin port already; neither had a consumer before this.
prom() { curl -sS --max-time 15 --data-urlencode "query=$1" "$PROM/api/v1/query"; }
prom_min() {  # min value of a metric across every garage instance; "" if the query fails
  local r; r="$(prom "$1")" || return 1
  jq -e '.status=="success"' >/dev/null 2>&1 <<<"$r" || return 1
  jq -r '[.data.result[].value[1]|tonumber]|min // empty' <<<"$r"
}
garage_zone_node() {  # is $NODE one of the Garage zones? the zone label IS the node name
  local r; r="$(prom "count by (role_zone) (cluster_layout_node_connected)")" || return 1
  jq -e --arg n "$NODE" '[.data.result[].metric.role_zone] | index($n) != null' >/dev/null <<<"$r"
}
assert_fleet_floor() {
  local notready healthy
  notready="$(kubectl -n garage get pods -l 'app.kubernetes.io/name=garage,garage.teststuff.net/serve-s3=true' -o json \
              | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Ready" and .status=="True") | not) | .metadata.name')"
  [ -n "$notready" ] && { fail "fleet floor: Garage pod(s) not Ready — $(tr '\n' ' ' <<<"$notready")"; return 1; }
  # Rule #6: an unreadable gate is a REFUSAL, never a pass — we must not fail into a window.
  healthy="$(prom_min 'cluster_healthy')" || { fail "fleet floor: Prometheus at $PROM unreadable — refusing"; return 1; }
  [ -n "$healthy" ] || { fail "fleet floor: cluster_healthy returned no series — refusing"; return 1; }
  if [ "$healthy" != "1" ]; then
    fail "fleet floor: Garage cluster_healthy=$healthy — a partition is missing a replica, so a"
    fail "  second zone down would drop it below quorum. Wait for the previous node to rejoin."
    return 1
  fi
  ok "fleet floor: Garage cluster_healthy=1 (every partition has all replicas up), queue $(prom_min 'block_resync_queue_length')"
}

# The CNPG half of the same idea. Every cluster here is 2 instances, and infisical-pg and
# grafana-pg each keep one on hp-01 and one on m70s — the two heaviest nodes. WIP 1 stops them
# going down together, but nothing stopped the SECOND node starting before the first instance had
# rejoined and caught up, which is the Garage mistake in another fabric. readyInstances == instances
# is the condition; an unreadable answer refuses (rule #6).
cnpg_unhealthy() {
  kubectl get clusters.postgresql.cnpg.io -A -o json \
    | jq -r '.items[] | select((.status.readyInstances // 0) < .spec.instances)
             | "\(.metadata.namespace)/\(.metadata.name) \(.status.readyInstances // 0)/\(.spec.instances)"'
}
assert_cnpg_floor() {
  local bad
  bad="$(cnpg_unhealthy)" || { fail "fleet floor: cannot read CNPG clusters — refusing"; return 1; }
  [ -z "$bad" ] && { ok "fleet floor: every CNPG cluster at full instances"; return 0; }
  fail "fleet floor: CNPG cluster(s) short an instance — $(tr '\n' ' ' <<<"$bad")"
  fail "  a second node down could take the last healthy instance with it. Wait for the rejoin."
  return 1
}
wait_cnpg_back() {
  log "waiting for every CNPG cluster back to full instances (≤${GARAGE_SYNC_TIMEOUT}s)"
  local t=0 bad
  while :; do
    bad="$(cnpg_unhealthy || true)"
    [ -z "$bad" ] && break
    sleep 15; t=$((t+15))
    [ $t -ge "$GARAGE_SYNC_TIMEOUT" ] && { fail "TIMEOUT: CNPG still short — $(tr '\n' ' ' <<<"$bad")"; return 1; }
  done
  ok "CNPG: every cluster at full instances after ~${t}s"
}

# After the window: membership whole again. This is the gate that lets the NEXT node start, which
# is why it belongs to the upgrade and not to the operator's patience. The resync queue is
# reported but not blocked on — it never reaches zero in steady state (a background scrubber keeps
# ~40 queued here), so an absolute-zero gate would deadlock; cluster_healthy is the real signal.
wait_garage_back() {
  garage_zone_node || { log "$NODE holds no Garage zone — no sync gate"; return 0; }
  log "waiting for Garage cluster_healthy=1 (≤${GARAGE_SYNC_TIMEOUT}s)"
  local t=0 h
  while :; do
    h="$(prom_min 'cluster_healthy' || true)"
    [ "$h" = "1" ] && break
    sleep 15; t=$((t+15))
    [ $t -ge "$GARAGE_SYNC_TIMEOUT" ] && { fail "TIMEOUT: Garage cluster_healthy=${h:-?} after ${t}s"; return 1; }
  done
  ok "Garage cluster_healthy=1 after ~${t}s (resync queue $(prom_min 'block_resync_queue_length'), errored $(prom_min 'block_resync_errored_blocks'))"
}

# Version sanity + the gates that are written down rather than computable.
assert_upgrade_sane() {
  local from to fmin tmin
  from="$(live_version)"; to="$1"
  [ -n "$from" ] || { fail "cannot read $NODE's running Talos version"; return 1; }
  [ "$from" = "$to" ] && { warn "$NODE already runs $to — the upgrade will reinstall the same version"; }
  fmin="$(vminor "$from")"; tmin="$(vminor "$to")"
  # Refuse a downgrade outright: Talos has no downgrade path.
  if [ "$(printf '%s\n%s\n' "${from#v}" "${to#v}" | sort -V | tail -1)" = "${from#v}" ] && [ "$from" != "$to" ]; then
    fail "$to is OLDER than $from — Talos does not downgrade"; return 1
  fi
  # One minor at a time: config migrations are only tested between adjacent minors.
  if [ "$fmin" != "$tmin" ]; then
    local fm tm; fm="${fmin#*.}"; tm="${tmin#*.}"
    [ $((tm - fm)) -gt 1 ] && { fail "$from -> $to skips a minor; go one minor at a time"; return 1; }
    # FU-033: 1.14+ mounts EPHEMERAL noexec, which kills Longhorn v1's instance-manager.
    if [ "$tm" -eq "$tm" ] && [ "$tm" -ge 14 ]; then
      local mc; mc="$(talosctl --talosconfig "$TALOSCONFIG" -n "$(node_ip)" -e "$ENDPOINT" get machineconfig -o yaml 2>/dev/null)"
      if ! grep -q 'kind: VolumeConfig' <<<"$mc" || ! grep -qE 'secure: *false' <<<"$mc"; then
        fail "FU-033 gate: $NODE has no EPHEMERAL VolumeConfig with mount.secure=false, and $to mounts /var noexec"
        fail "  -> Longhorn v1's instance-manager cannot exec its engine binaries. Land the patch on EVERY node first (tofu/longhorn.tf)."
        return 1
      fi
      ok "FU-033 gate: EPHEMERAL VolumeConfig secure=false present"
    fi
  fi
  ok "version path $from -> $to"
}

# The post-check that matters as much as the version: did the node come back running the
# SCHEMATIC it declares? A wrong --image silently strips extensions (2026-09-18, wk-03).
verify_installed() {
  local want_v="$1" want_s="$2" got_v got_s
  got_v="$(live_version)"
  got_s="$(talosctl --talosconfig "$TALOSCONFIG" -n "$(node_ip)" -e "$ENDPOINT" get extensions 2>/dev/null | awk '$6=="schematic"{print $7}')"
  [ "$got_v" = "$want_v" ] && ok "version $got_v" || fail "version is $got_v, declared $want_v"
  [ "$got_s" = "$want_s" ] && ok "schematic $got_s" || fail "schematic is ${got_s:-<none>}, declared $want_s"
  [ "$got_v" = "$want_v" ] && [ "$got_s" = "$want_s" ]
}

upgrade() {
  load_targets || return 2
  local image version schematic class
  if [ -n "$TARGET_IMAGE" ]; then
    image="$TARGET_IMAGE"; version=""; schematic=""; class="$(declared class)"
    warn "TARGET_IMAGE set — using $image and SKIPPING the declaration check"
  else
    image="$(declared installer)"; version="$(declared version)"
    schematic="$(declared schematic)"; class="$(declared class)"
    [ -n "$image" ] || { fail "no declared install target for $NODE in node_install_targets"; return 2; }
    # The gates below judge $version; talosctl installs $image. One output produces both, so a
    # mismatch means the declaration is malformed — refuse rather than gate one thing and install
    # another.
    [ "${image##*:}" = "$version" ] || {
      fail "declaration inconsistent: installer tag '${image##*:}' != version '$version'"; return 2; }
  fi
  ENDPOINT="$(pick_cp_endpoint)" || return 2
  log "$NODE ($class) -> $version, endpoint $ENDPOINT"
  log "  image: $image"
  [ "$class" = vm ] && log "  NOTE: a nocloud VM upgrades in place ONLY with this image (ADR-014 as amended 2026-09-18);
           proven same-version on wk-03 — a cross-version VM upgrade is not yet proven."

  local rc=0; preflight || rc=$?
  [ "$rc" = 2 ] && [ "$FORCE" != 1 ] && { fail "preflight refused"; return 2; }
  assert_wip1   || [ "$FORCE" = 1 ] || return 2
  assert_fleet_floor || [ "$FORCE" = 1 ] || return 2
  assert_cnpg_floor  || [ "$FORCE" = 1 ] || return 2
  # NOT FORCE-able, deliberately: a downgrade is impossible, a skipped minor is untested config
  # migration, and the FU-033 gate is "storage dies on the post-upgrade reboot". FORCE exists for
  # preflight's WARN class and the two operational gates above, not for these.
  if [ -n "$version" ]; then assert_upgrade_sane "$version" || return 2; fi

  settle || return $?
  [ "$DRY" = 1 ] && { log "DRY=1: would now run talosctl upgrade --image $image — stopping"; return 0; }

  silence_open; declare_open
  log "talosctl upgrade $NODE ($(node_ip)) — talosctl does the cordon+drain (PDB-respecting) and the reboot"
  if ! talosctl --talosconfig "$TALOSCONFIG" -n "$(node_ip)" -e "$ENDPOINT" \
        upgrade --image "$image" --drain-timeout="$UPGRADE_DRAIN_TIMEOUT"; then
    fail "talosctl upgrade returned non-zero — a blocked drain fails CLOSED (the node did NOT reboot)."
    fail "  check what refused eviction, clear it (settle / move), and re-run. Window left OPEN."
    return 1
  fi
  log "waiting for Ready (≤${READY_TIMEOUT}s)"
  local t=0; until [ "$(node_ready)" = True ]; do
    sleep 10; t=$((t+10))
    [ $t -ge "$READY_TIMEOUT" ] && { fail "TIMEOUT: $NODE not Ready after ${READY_TIMEOUT}s — window left OPEN"; return 1; }
  done
  ok "$NODE Ready after ~${t}s"
  # Talos uncordons itself on rejoin; make sure, because a half-finished window is invisible.
  [ "$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')" = true ] && kubectl uncordon "$NODE"
  wait_storage_back || return 1
  wait_garage_back  || return 1
  wait_cnpg_back    || return 1
  if [ -n "$version" ]; then
    log "verifying the node came back as DECLARED"
    verify_installed "$version" "$schematic" || { fail "post-check FAILED — window left OPEN"; return 1; }
  fi
  log "Window closed."
  silence_close; declare_close
  kubectl get node "$NODE" -o wide
}

# ---------------------------------------------------------------- order
# Which node to upgrade NEXT — COMPUTED, never a list. A hard-coded order is correct exactly once:
# it rots the moment a workload is rescheduled, a Garage zone moves, or a node joins. This ranks
# every node that is not at its declared version/schematic by what draining it would actually cost,
# from live placement, so the answer follows the fleet instead of the other way round.
#
#   SOLO   workloads whose every running pod is on this node -> they go down for the window
#   QUORUM workloads where the survivors would fall below majority -> not degraded, BROKEN
#   GARAGE this node is a Garage zone -> rf=3 of 3 zones, the sync gate applies
#   LH     Longhorn replicas living here -> `settle` has work to do before the drain
#
# A PDB changes SOLO/QUORUM from an outage into a serialized roll (Talos honours them), so the
# counts are an upper bound on harm, not a prediction — read them as "how much this node is load
# bearing", which is what an ordering wants.
order() {
  # A report must not hard-fail on the declaration read: without it the DECLARED column is blank
  # and every other number — which is what the ranking is actually made of — is still true.
  load_targets || { warn "no declared targets (box unreachable?) — DECLARED column will be blank"; TARGETS_JSON='{}'; }
  # The dumps are megabytes — they go through FILES, never argv (a --argjson of the pod list is an
  # "Argument list too long" the moment the cluster is real).
  local d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  local zones
  log "ranking the fleet by what a drain would cost (live placement)"
  kubectl get pods -A -o json > "$d/p.json"
  kubectl get replicasets -A -o json > "$d/r.json"
  kubectl -n longhorn-system get replicas.longhorn.io -o json 2>/dev/null > "$d/lh.json" || echo '{"items":[]}' > "$d/lh.json"
  kubectl get nodes -o json > "$d/n.json"
  printf '%s' "$TARGETS_JSON" > "$d/t.json"
  zones="$(prom 'count by (role_zone) (cluster_layout_node_connected)' 2>/dev/null \
           | jq -c '[.data.result[].metric.role_zone]' 2>/dev/null)" || zones='[]'
  [ -n "$zones" ] || zones='[]'
  printf '%s' "$zones" > "$d/z.json"

  jq -rn --slurpfile P "$d/p.json" --slurpfile R "$d/r.json" --slurpfile Z "$d/z.json" \
         --slurpfile LH "$d/lh.json" --slurpfile N "$d/n.json" --slurpfile T "$d/t.json" '
    ($P[0]) as $p | ($R[0]) as $r | ($Z[0]) as $z | ($LH[0]) as $lh | ($N[0]) as $n | ($T[0]) as $t |
    ($r.items | map({key:(.metadata.namespace+"/"+.metadata.name),
                     value:((.metadata.ownerReferences//[])[0].name // "")}) | from_entries) as $own
    | [ $p.items[]
        | select(.status.phase=="Running" and .spec.nodeName != null)
        | . as $pod | (($pod.metadata.ownerReferences // [])[0] // null) as $o
        | select($o != null and (($o.kind // "") | test("DaemonSet|Job|Workflow") | not))
        | { name: (if $o.kind=="ReplicaSet"
                   then ($own[$pod.metadata.namespace+"/"+$o.name] // "") else ($o.name // "") end),
            ns: $pod.metadata.namespace, kind: $o.kind, node: $pod.spec.nodeName } ]
      | map(select(.name != ""))
      | group_by(.kind+"|"+.ns+"|"+.name)
      | map({ total: length,
              nodes: (group_by(.node) | map({key: .[0].node, value: length}) | from_entries) }) as $w
    | ($lh.items | map(.spec.nodeID) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $lhn
    | [ $n.items[] | .metadata.name ] as $allnodes
    | $allnodes
      | map( . as $nd
        | ($t[$nd] // null) as $decl
        | ([ $p.items[] | select(.spec.nodeName==$nd) ] | length) as $podcount
        | { node: $nd,
            declared: ($decl.version // "-"),
            solo:   ([ $w[] | select((.nodes[$nd] // 0) > 0 and .total == (.nodes[$nd] // 0)) ] | length),
            quorum: ([ $w[] | select(.total >= 3 and (.nodes[$nd] // 0) > 0
                                      and ((.total - (.nodes[$nd] // 0)) < ((.total/2|floor)+1))) ] | length),
            garage: (if ($z | index($nd)) then 1 else 0 end),
            lh:     ($lhn[$nd] // 0) } )
      | map(. + { risk: (.solo*2 + .quorum*10 + .garage*3 + (if .lh>0 then 2 else 0 end)) })
      | sort_by(.risk, .node)
      | .[]
      | [ .risk, .node, .declared, .solo, .quorum, (if .garage==1 then "yes" else "-" end), .lh ]
      | @tsv' | awk -F'\t' '
        BEGIN{printf "%-5s %-14s %-10s %5s %7s %7s %4s\n","RISK","NODE","DECLARED","SOLO","QUORUM","GARAGE","LH"}
        {printf "%-5s %-14s %-10s %5s %7s %7s %4s\n",$1,$2,$3,$4,$5,$6,$7}'
  echo
  log "lowest risk first. A node already at its declared version is still listed — 'behind or not'"
  log "is the verb's own check (it refuses a same-version reinstall with a WARN, not this ranking)."
}

case "$cmd" in
  preflight) preflight ;;
  settle) settle ;;
  move) [ -n "${3:-}" ] || usage; move_replica "$3" ;;
  power) power "${3:-status}" ;;
  down) down ;;
  up) up ;;
  upgrade) upgrade ;;
  order) order ;;
  silence-open) silence_open; declare_open ;;
  silence-close) silence_close; declare_close ;;
  *) usage ;;
esac
