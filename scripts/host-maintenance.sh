#!/usr/bin/env bash
# host-maintenance — take a whole Proxmox hypervisor down cleanly and bring it back. A COMPOSER over
# the verbs that already own each guest class; it adds only the ORDER and the host-level gates.
#
#   bash scripts/host-maintenance.sh preflight <nx-02|pve>            # READ-ONLY: safe to take the host down?
#   bash scripts/host-maintenance.sh down <nx-02|pve> [--reboot]      # preflight → guests down in order → poweroff
#   bash scripts/host-maintenance.sh up   <nx-02|pve>                 # power on → guests back → whole again
#   DRY=1 bash scripts/host-maintenance.sh down <host>                # preflight + the exact ordered plan, no act
#   (devbox run host-maint -- <verb> <host>)
#
# The guest set is read LIVE (`qm list` / `pct list` on the host), never listed here, and each guest
# is classified by NAME; an unclassified running guest is a refusal, never a guess:
#   ci-runner-*          runner   scripts/runner-maintenance.sh drain → qm shutdown   (up: undrain + verify)
#   opnsense-test|-drill test     qm shutdown                                          (onboot 0: stays down)
#   wk-*                 worker   scripts/node-maintenance.sh down|up, one at a time
#   cp-*                 cp       node-maintenance.sh down|up → controlplane-upgrade.sh (three Ready CPs,
#                                 odd healthy etcd, cilium clean, snapshot, leadership forfeit)
#   backup-garage (LXC)  backup   pct shutdown — refused while a Longhorn backup is InProgress
#   matchbox (LXC)       lxc      pct shutdown (PXE provisioning is offline for the window)
#   opnsense-<nx02|pve>  router   LAST: if it holds .1 (CARP MASTER), `carp-maintenance enter` first and the
#                                 partner must read MASTER before the VM stops (docs/router-move.md); up:
#                                 `check <node>` green, then `carp-maintenance leave` (advskew preempts back)
# DOWN order: window → runners → test VMs → workers → CP → LXCs → router → host poweroff (--reboot: reboot);
#             after a worker went down, each next Talos leg first waits for Longhorn healthy (the worker's
#             shutdown degrades its volumes, and node-maintenance's preflight refuses ANY degraded one).
# UP order:   power on (nx-02: BMC via the wallet entry nx-02-bmc-password, else the manual step; pve:
#             by hand) → onboot guests self-start (a host that did NOT reboot: started here, in order)
#             → workers up → CP up → runners undrain + verify → router check + leave → window closed.
#
# The WINDOW is the host's own, beside the per-node ones node-maintenance opens: an Alertmanager
# silence on instance=~ the host + its non-Talos guests' addresses, and a declared window
# (agents/seat-window.sh --node <host> --by host-maintenance.sh) naming HOST_ALERTS. `up` closes both;
# a failed `down` leaves them. SILENCE=0 opts out of both.
#
# ATTENDED today — the shape scripts/runner-maintenance.sh and scripts/helm-release-evidence.sh took
# (docs/management-box.md §"Hypervisor: the host verb"); no box wiring. Run it from the jail: it
# needs the pve ssh key, the wallet (router API, BMC) and the runner App key.
# Exit: 0 ok · 2 refused, nothing touched · 1 error / failed after acting (state is printed) · 64 usage.
# Env: FORCE=1 (accept WARNs, passed to node-maintenance), DRY=1, SILENCE=0, SILENCE_HOURS (4),
#      GUEST_TIMEOUT (600 s, per guest stop/start), HOST_TIMEOUT (900 s, host back on ssh),
#      VERIFY_TIMEOUT (900 s, runner/router green after boot), LONGHORN_TIMEOUT (1800 s, Longhorn healthy
#      between Talos legs = the 600 s replica-replenishment wait + a rebuild), HOST_ALERTS, NM_AM, PVE_SSH_KEY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
TALOSCONFIG="${TALOSCONFIG:-$ROOT/tofu/talosconfig}"
[ -f "$KUBECONFIG" ] || { [ -f /var/lib/mgmt/kubeconfig ] && export KUBECONFIG=/var/lib/mgmt/kubeconfig; }
[ -f "$TALOSCONFIG" ] || { [ -f /var/lib/mgmt/talosconfig ] && TALOSCONFIG=/var/lib/mgmt/talosconfig; }
export TALOSCONFIG
KEY="${PVE_SSH_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
KDB="$HOME/.claude/homelab-keepass/homelab.kdbx"; KEYX="$HOME/.claude/homelab-keepass/homelab.keyx"
AM="${NM_AM:-http://192.168.40.14:9093}"
DRY="${DRY:-0}"; FORCE="${FORCE:-0}"; SILENCE="${SILENCE:-1}"; SILENCE_HOURS="${SILENCE_HOURS:-4}"
GUEST_TIMEOUT="${GUEST_TIMEOUT:-600}"; HOST_TIMEOUT="${HOST_TIMEOUT:-900}"; VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-900}"
LONGHORN_TIMEOUT="${LONGHORN_TIMEOUT:-1800}"
HOST_ALERTS="${HOST_ALERTS:-TargetDown,PveMetricsAbsent,PveMetricsStale,CiRunnerNodeExporterDown,RouterPairMasterCount,RouterWanGateSilent,LonghornBackupTargetDown,KubeNodeUnreachable,KubeNodeNotReady,KubeDaemonSetRolloutStuck,KubeDaemonSetMisScheduled,CiliumUnreachableNodes}"
BY=host-maintenance.sh
export FORCE

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
info() { printf '  \033[36mINFO\033[0m %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS+1)); }
usage(){ sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 64; }

cmd="${1:-}"; HOST="${2:-}"; REBOOT=0
[ "${3:-}" = --reboot ] && REBOOT=1
case "$HOST" in
  nx-02) HIP=192.168.2.59 RNODE=nx02 PARTNER=pve  BMC=192.168.2.173 ;;
  pve)   HIP=192.168.2.3  RNODE=pve  PARTNER=nx02 BMC="" ;;
  *) usage ;;
esac
BMC_ENTRY=nx-02-bmc-password
WARNS=0; FAILS=0

hv() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 "root@$HIP" "$@"; }
nm()     { bash "$ROOT/scripts/node-maintenance.sh" "$@"; }
runner() { bash "$ROOT/scripts/runner-maintenance.sh" "$@"; }
router() { bash "$ROOT/scripts/opnsense-router-node.sh" "$@"; }
kp() { keepassxc-cli show -q --no-password -k "$KEYX" -a "$2" "$KDB" "$1" 2>/dev/null; }
mip() { yq -r ".machines[] | select(.name == \"$1\") | .ip // \"\"" machines/machines.yaml; }

# ---------------------------------------------------------------- guests
classify() { # <qm|pct> <name>
  case "$1:$2" in
    qm:ci-runner-*) echo runner ;;
    qm:opnsense-test|qm:opnsense-drill) echo test ;;
    "qm:opnsense-$RNODE") echo router ;;
    qm:wk-*) echo worker ;;
    qm:cp-*) echo cp ;;
    pct:backup-garage) echo backup ;;
    pct:matchbox) echo lxc ;;
    *) echo unknown ;;
  esac
}
GUESTS=""   # one line per guest: <qm|pct> <id> <name> <status> <class> <onboot>
discover() {
  local q p ob
  q="$(hv 'qm list')" || { fail "ssh root@$HIP qm list failed"; return 1; }
  p="$(hv 'pct list')" || { fail "ssh root@$HIP pct list failed"; return 1; }
  ob="$(hv 'for v in $(qm list | awk "NR>1{print \$1}"); do echo "qm $v $(qm config $v | sed -n "s/^onboot: //p")"; done
            for c in $(pct list | awk "NR>1{print \$1}"); do echo "pct $c $(pct config $c | sed -n "s/^onboot: //p")"; done')" \
    || { fail "ssh root@$HIP: reading the guests' onboot flags failed"; return 1; }
  GUESTS="$( { awk 'NR>1 && NF {print "qm", $1, $2, $3}' <<<"$q"; awk 'NR>1 && NF {print "pct", $1, $NF, $2}' <<<"$p"; } \
    | while read -r k id name st; do
        printf '%s %s %s %s %s %s\n' "$k" "$id" "$name" "$st" "$(classify "$k" "$name")" \
          "$(awk -v k="$k" -v i="$id" '$1==k && $2==i {print ($3=="" ? 0 : $3)}' <<<"$ob")"; done)"
}
of() { awk -v c="$1" -v s="${2:-}" '$5==c && (s=="" || $4==s)' <<<"$GUESTS"; }   # <class> [status]
gstatus() { hv "$1 status $2" | awk '{print $2}'; }
wait_status() { # <qm|pct> <id> <name> <stopped|running>
  local t=0 s
  while :; do
    s="$(gstatus "$1" "$2")" || s=unreadable
    [ "$s" = "$4" ] && { ok "$3 ($2) $4"; return 0; }
    [ $t -ge "$GUEST_TIMEOUT" ] && { fail "$3 ($2) reads '$s' after ${GUEST_TIMEOUT}s (want $4)"; return 1; }
    sleep 5; t=$((t+5))
  done
}

# ---------------------------------------------------------------- the host window
silence_re() { # the host + its non-Talos guests (the Talos ones are node-maintenance's)
  local ips="$HIP" n ip
  for n in $(awk '$5!="worker" && $5!="cp" {print $3}' <<<"$GUESTS"); do ip="$(mip "$n")"; [ -n "$ip" ] && ips="$ips|$ip"; done
  printf '(%s)(:[0-9]+)?' "${ips//./\\.}"
}
silence_ids() { curl -sf -m 10 "$AM/api/v2/silences" 2>/dev/null | jq -r --arg by "$BY/$HOST" '.[]|select(.createdBy==$by and .status.state!="expired")|.id' 2>/dev/null || true; }
window_open() {
  [ "$SILENCE" = 1 ] || { log "SILENCE=0 — no host silence, no declared window"; return 0; }
  if [ -n "$(silence_ids)" ]; then log "host silence already active"; else
    local body id
    body="$(jq -cn --arg re "$(silence_re)" --arg by "$BY/$HOST" --arg s "$((SILENCE_HOURS*3600))" \
      --arg c "host-maintenance window on $HOST ($(date -u +%FT%TZ)) — expired by \`host-maintenance.sh up $HOST\`" \
      '{matchers:[{name:"instance",value:$re,isRegex:true,isEqual:true}], startsAt:(now|todate),
        endsAt:((now+($s|tonumber))|todate), createdBy:$by, comment:$c}')"
    id="$(curl -sf -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "$AM/api/v2/silences" | jq -r '.silenceID // empty')" || id=""
    [ -n "$id" ] && ok "host silence $id instance=~$(silence_re)" || warn "could not open the host silence — alerts will fire"
  fi
  bash agents/seat-window.sh has --node "$HOST" --by "$BY" 2>/dev/null && { log "declared window for $HOST already open"; return 0; }
  SEAT_WINDOW_BY="$BY" SEAT_WINDOW_HOURS="$SILENCE_HOURS" bash agents/seat-window.sh open \
    --reason "host-maintenance window on $HOST — guests down in order, host power-off" --node "$HOST" \
    --alerts "$HOST_ALERTS" --note "closed by \`host-maintenance.sh up $HOST\`" \
    || warn "could not declare the window to the responder"
}
window_close() {
  [ "$SILENCE" = 1 ] || return 0
  local id; for id in $(silence_ids); do
    curl -sf -m 10 -X DELETE "$AM/api/v2/silence/$id" >/dev/null && ok "expired host silence $id" || warn "could not expire silence $id (self-expires)"; done
  bash agents/seat-window.sh close --node "$HOST" --by "$BY" || warn "could not close the declared window (self-expires)"
}

# ---------------------------------------------------------------- probes
ROLE=""   # this host's router node: MASTER | BACKUP | "" (no running router guest)
router_role() { router carp-maintenance "$1" status 2>/dev/null | grep -o '\.1=[A-Z]*' | cut -d= -f2; }
backups_in_progress() { # prints the count; non-zero exit if unreadable
  kubectl -n longhorn-system get backups.longhorn.io -o json | jq -er '[.items[]|select(.status.state=="InProgress")]|length'
}
cp_gate() { # <cp> — what controlplane-upgrade.sh down will demand, read-only
  local n ip ep m cnt ips st rows
  n="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq '[.items[]|select(.spec.unschedulable!=true)|select(any(.status.conditions[];.type=="Ready" and .status=="True"))]|length')" \
    || { fail "cannot read the control planes"; return; }
  [ "$n" -ge 3 ] && ok "$n Ready schedulable control planes" || fail "$n Ready control planes — a CP down needs 3"
  ip="$(kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')" || ip=""
  ep="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r --arg n "$1" '[.items[]|select(.metadata.name!=$n)|.status.addresses[]|select(.type=="InternalIP")|.address][0] // ""')" || ep=""
  [ -n "$ip" ] && [ -n "$ep" ] || { fail "cannot resolve $1's address or another CP endpoint"; return; }
  m="$(talosctl --talosconfig "$TALOSCONFIG" -n "$ip" -e "$ep" etcd members 2>/dev/null)" || { fail "etcd members unreadable via $ep"; return; }
  cnt="$(awk 'NR>1 && NF {n++} END{print n+0}' <<<"$m")"
  ips="$(awk 'NR>1 && NF {gsub("https://","",$5); sub(":2379$","",$5); print $5}' <<<"$m" | paste -sd, -)"
  st="$(talosctl --talosconfig "$TALOSCONFIG" -n "$ips" -e "$ep" etcd status 2>/dev/null)" || { fail "etcd status unreadable ($ips)"; return; }
  rows="$(awk 'NR>1 && NF {n++} END{print n+0}' <<<"$st")"
  if [ "$cnt" -ge 3 ] && [ $((cnt % 2)) = 1 ] && [ "$rows" = "$cnt" ] && awk 'NR>1 && NF>14 {exit 1}' <<<"$st"; then
    ok "etcd: $cnt members, $rows answering, no member error"
  else fail "etcd: $cnt members, $rows answering (or a member error) — a CP down needs an odd quorum ≥3, all healthy"; fi
  local c=0; bash scripts/maintenance-window.sh cilium-check >/dev/null 2>&1 || c=$?
  [ "$c" = 0 ] && ok "cilium holds the apiserver backend" || fail "cilium-check verdict $c (controlplane-upgrade refuses on it)"
}

# ---------------------------------------------------------------- preflight
# node-maintenance's refusal (2) is a FAIL when it carries a FAIL line, else its WARNs un-FORCEd:
# a WARN here too, so one FORCE=1 accepts both (it is passed through to node-maintenance).
nm_verdict() { # <class> <node> <output>
  if grep -q 'FAIL' <<<"$3"; then fail "$1 $2: $(tail -1 <<<"$3")"; else warn "$1 $2: $(tail -1 <<<"$3")"; fi
  grep -E '^ +.*(FAIL|WARN)' <<<"$3" | sed 's/^ */         /' || true
}
preflight() {
  echo "preflight: $HOST ($HIP)"
  if ! hv true 2>/dev/null; then fail "ssh root@$HIP unreachable — nothing else is readable"; return 2; fi
  ok "ssh root@$HIP ($(hv 'pveversion' 2>/dev/null | cut -d/ -f1-2 || echo 'pveversion unreadable'))"
  discover || return 2
  local k id name st cls ob
  while read -r k id name st cls ob; do
    [ -n "$k" ] || continue
    case "$cls:$st" in
      unknown:running) fail "$k $id $name running and UNCLASSIFIED — teach classify() its class before a host window" ;;
      unknown:*) warn "$k $id $name ($st) unclassified — left alone" ;;
      *) ok "$(printf '%-6s %-5s %-15s %-8s onboot=%s' "$cls" "$id" "$name" "$st" "$ob")" ;;
    esac
  done <<<"$GUESTS"
  hv '[ -f /var/run/reboot-required ]' 2>/dev/null && info "reboot-required is set on $HOST" || true

  local name rc out
  for name in $(of runner running | awk '{print $3}'); do
    if runner verify "$name" >/dev/null 2>&1; then ok "runner $name: verify green (drain has a clean read)"
    else warn "runner $name: verify not green or unreadable — \`runner-maint -- verify $name\`"; fi
  done
  for name in $(of worker running | awk '{print $3}'); do
    rc=0; out="$(nm preflight "$name" 2>&1)" || rc=$?
    case "$rc" in
      0) ok "worker $name: $(tail -1 <<<"$out")" ;;
      3) ok "worker $name: $(tail -1 <<<"$out") (node-maintenance down settles them)" ;;
      *) nm_verdict worker "$name" "$out" ;;
    esac
  done
  for name in $(of cp running | awk '{print $3}'); do
    rc=0; out="$(CONTROLPLANE_GUARDED=1 nm preflight "$name" 2>&1)" || rc=$?
    case "$rc" in 0|3) ok "cp $name: $(tail -1 <<<"$out")" ;;
      *) nm_verdict cp "$name" "$out" ;; esac
    cp_gate "$name"
  done
  if [ -n "$(of backup running)" ]; then
    local bip; if bip="$(backups_in_progress)"; then
      [ "$bip" = 0 ] && ok "Longhorn: no backup InProgress (backup-garage may stop)" || fail "Longhorn: $bip backup(s) InProgress — wait them out"
    else fail "cannot read backups.longhorn.io — refusing"; fi
  fi
  [ -n "$(of lxc running)" ] && info "matchbox stops: PXE provisioning is offline for the window"
  if [ -n "$(of router running)" ]; then
    ROLE="$(router_role "$RNODE" || true)"
    case "$ROLE" in
      MASTER) if router check "$PARTNER" >/dev/null 2>&1; then ok "router opnsense-$RNODE holds .1 (MASTER); partner $PARTNER check green — down runs carp-maintenance enter first"
              else fail "router opnsense-$RNODE holds .1 and partner $PARTNER is NOT green (\`router-node.sh check $PARTNER\`) — no router left"; fi ;;
      BACKUP) ok "router opnsense-$RNODE is BACKUP — the partner holds .1, plain shutdown" ;;
      *) fail "router opnsense-$RNODE: CARP role unreadable ('$ROLE')" ;;
    esac
  fi
  if [ -n "$BMC" ] && [ "$REBOOT" = 0 ]; then
    if [ -n "$(kp "$BMC_ENTRY" Password)" ]; then ok "BMC $BMC: wallet entry $BMC_ENTRY present — up powers it on"
    else info "no wallet entry $BMC_ENTRY — \`up\` prints the manual ipmitool power-on step"; fi
  fi
  [ -n "$BMC" ] || [ "$REBOOT" = 1 ] || info "$HOST has no BMC — after a poweroff, power it on by hand"
  if [ "$SILENCE" = 1 ]; then curl -sf -m 10 "$AM/api/v2/status" >/dev/null && ok "Alertmanager reachable (window silences)" || warn "Alertmanager unreachable at $AM — the window opens no silence"; fi
  echo
  if [ "$FAILS" -gt 0 ]; then echo "preflight: $FAILS FAIL, $WARNS WARN — NOT safe"; return 2; fi
  if [ "$WARNS" -gt 0 ] && [ "$FORCE" != 1 ]; then echo "preflight: $WARNS WARN — re-run with FORCE=1 to accept them"; return 2; fi
  echo "preflight: safe to take $HOST down"
}

# ---------------------------------------------------------------- the step runner
STEP=0; ACTED=0
show() {
  case "$1" in
    hv) printf 'ssh root@%s %s' "$HIP" "${*:2}" ;;
    nm) printf 'bash scripts/node-maintenance.sh %s' "${*:2}" ;;
    runner) printf 'bash scripts/runner-maintenance.sh %s' "${*:2}" ;;
    router) printf 'bash scripts/opnsense-router-node.sh %s' "${*:2}" ;;
    wait_status) printf 'wait until `%s status %s` (%s) reads %s (≤%ss)' "$2" "$3" "$4" "$5" "$GUEST_TIMEOUT" ;;
    window_open) printf 'open the host window: Alertmanager silence instance=~"%s" (%sh) + agents/seat-window.sh open --node %s --by %s' "$(silence_re)" "$SILENCE_HOURS" "$HOST" "$BY" ;;
    window_close) printf 'close the host window (expire the silence, seat-window.sh close --node %s --by %s)' "$HOST" "$BY" ;;
    assert_no_backup) printf 'refuse unless backups.longhorn.io has 0 InProgress' ;;
    assert_partner_master) printf 'wait until opnsense-%s reads .1=MASTER (≤60s)' "$PARTNER" ;;
    assert_all_stopped) printf 'refuse unless every guest on %s reads stopped' "$HOST" ;;
    wait_green) printf 'poll `%s` until it exits 0 (≤%ss)' "$(show "${@:2}")" "$VERIFY_TIMEOUT" ;;
    longhorn_healthy) printf 'wait until no attached Longhorn volume reads non-healthy (≤%ss; Longhorn self-heals, nothing is touched)' "$LONGHORN_TIMEOUT" ;;
    host_power) printf 'ssh root@%s systemctl %s, then wait until ssh stops answering (≤300s)' "$HIP" "$2" ;;
    *) printf '%s' "$*" ;;
  esac
}
run() {
  STEP=$((STEP+1))
  if [ "$DRY" = 1 ]; then printf '  %2d. %s\n' "$STEP" "$(show "$@")"; return 0; fi
  log "step $STEP: $(show "$@")"
  local rc=0; "$@" </dev/null || rc=$?   # stdin closed: the callers loop over here-strings, ssh would eat them
  [ "$rc" = 0 ] && { [ "$1" = window_open ] || ACTED=1; return 0; }
  if [ "$ACTED" = 0 ] && [ "$rc" = 2 ]; then log "REFUSED at step $STEP before anything was touched"; [ "$cmd" = down ] && window_close; exit 2; fi
  log "FAILED at step $STEP (rc $rc): $(show "$@") — steps 1..$((STEP-1)) are done; the window stays open."
  log "Read the state: $0 preflight $HOST. Restore what is down: $0 up $HOST"
  exit 1
}
assert_no_backup() { local n; n="$(backups_in_progress)" || { log "backups unreadable"; return 2; }; [ "$n" = 0 ] || { log "$n backup(s) InProgress"; return 2; }; }
assert_partner_master() {
  local i; for i in $(seq 12); do [ "$(router_role "$PARTNER" || true)" = MASTER ] && { ok "opnsense-$PARTNER holds .1"; return 0; }; sleep 5; done
  log "opnsense-$PARTNER did not take .1 — leaving maintenance on opnsense-$RNODE"; router carp-maintenance "$RNODE" leave || true; return 1
}
assert_all_stopped() {
  local up; up="$( { hv 'qm list'; hv 'pct list'; } | awk 'NR>1 && / running /')" || return 1
  [ -z "$up" ] || { log "still running on $HOST:"; sed 's/^/  /' <<<"$up" >&2; return 1; }
}
longhorn_healthy() { # wait only — the replica rebuild is Longhorn's own (replenishment wait, then a rebuild); never hand-act
  local t=0 last=-60 v e bad prev=""
  while :; do
    if v="$(kubectl -n longhorn-system get volumes.longhorn.io -o json 2>/dev/null)" \
       && bad="$(jq -r '.items[]|select(.status.state=="attached" and .status.robustness!="healthy")|"\(.metadata.name) \(.status.robustness)"' <<<"$v")"; then
      [ -z "$bad" ] && { ok "Longhorn: 0 degraded attached volumes${prev:+ (after ${t}s)}"; return 0; }
      [ -n "$prev" ] || { log "Longhorn degraded attached volume(s) — waiting for the self-heal:"; sed 's/^/  /' <<<"$bad" >&2; }
      prev="$bad"
      if [ $((t-last)) -ge 60 ]; then last=$t
        e="$(kubectl -n longhorn-system get engines.longhorn.io -o json 2>/dev/null | jq -r '[.items[]|select(.status.rebuildStatus!=null and (.status.rebuildStatus|length)>0)
              |"\(.spec.volumeName) " + ([.status.rebuildStatus[]|"\(.progress)%"]|join(","))]|join("; ")' 2>/dev/null)" || e=""
        log "Longhorn: $(wc -l <<<"$bad") degraded after ${t}s${e:+ — rebuilding: $e}"
      fi
    else
      prev="${prev:-unreadable}"; log "Longhorn volumes unreadable after ${t}s — counts as not healthy"
    fi
    [ $t -ge "$LONGHORN_TIMEOUT" ] && { log "TIMEOUT: Longhorn not healthy after ${LONGHORN_TIMEOUT}s:"; sed 's/^/  /' <<<"$prev" >&2; return 1; }
    sleep 15; t=$((t+15))
  done
}
host_power() { # poweroff|reboot — the ssh session drops with the host
  hv "systemctl $1" || true
  local t=0; while hv true 2>/dev/null; do sleep 5; t=$((t+5)); [ $t -ge 300 ] && { log "$HOST still answers ssh after 300s"; return 1; }; done
  ok "$HOST went away ($1)"
}

# ---------------------------------------------------------------- down
down() {
  local rc=0; preflight || rc=$?
  if [ "$rc" != 0 ]; then [ "$DRY" = 1 ] || return 2; echo "(preflight REFUSED — a real run stops here; the plan anyway:)"; fi
  echo; echo "plan: down $HOST$([ "$REBOOT" = 1 ] && echo ' --reboot')"
  run window_open
  local k id name st c ob cls
  while read -r k id name st c ob; do [ -n "$k" ] || continue
    run runner drain "$name"; run hv qm shutdown "$id" --timeout "$GUEST_TIMEOUT"; run wait_status qm "$id" "$name" stopped
  done <<<"$(of runner running)"
  while read -r k id name st c ob; do [ -n "$k" ] || continue
    run hv qm shutdown "$id" --timeout "$GUEST_TIMEOUT"; run wait_status qm "$id" "$name" stopped
  done <<<"$(of test running)"
  local wk=0   # a worker went down this run: its volumes degrade, and the next Talos leg's preflight refuses that
  for cls in worker cp; do
    while read -r k id name st c ob; do [ -n "$k" ] || continue
      [ "$wk" = 1 ] && run longhorn_healthy
      run nm down "$name"; run wait_status qm "$id" "$name" stopped
      [ "$cls" = worker ] && wk=1
    done <<<"$(of "$cls" running)"
  done
  for cls in backup lxc; do
    while read -r k id name st c ob; do [ -n "$k" ] || continue
      [ "$c" = backup ] && run assert_no_backup
      run hv pct shutdown "$id" --timeout "$GUEST_TIMEOUT"; run wait_status pct "$id" "$name" stopped
    done <<<"$(of "$cls" running)"
  done
  while read -r k id name st c ob; do [ -n "$k" ] || continue
    if [ "$ROLE" = MASTER ]; then run router carp-maintenance "$RNODE" enter; run assert_partner_master; fi
    run hv qm shutdown "$id" --timeout "$GUEST_TIMEOUT"; run wait_status qm "$id" "$name" stopped
  done <<<"$(of router running)"
  run assert_all_stopped
  run host_power "$([ "$REBOOT" = 1 ] && echo reboot || echo poweroff)"
  if [ "$DRY" = 1 ]; then echo; echo "DRY=1: $STEP step(s) planned, nothing touched"; return "$rc"; fi
  log "$HOST is down. Bring it back with: $0 up $HOST (the window stays open until then)"
}

# ---------------------------------------------------------------- up
power_on() {
  if [ -z "$BMC" ]; then log "$HOST has no BMC — power it on by hand; waiting for ssh (≤${HOST_TIMEOUT}s)"; return 0; fi
  local u p; u="$(kp "$BMC_ENTRY" UserName || true)"; p="$(kp "$BMC_ENTRY" Password || true)"
  if [ -z "$p" ] || [ -z "$u" ]; then
    log "no wallet entry $BMC_ENTRY — power on by hand: ipmitool -I lanplus -H $BMC -U <$BMC_ENTRY user> -P <$BMC_ENTRY password> chassis power on"
    return 0
  fi
  IPMI_PASSWORD="$p" ipmitool -I lanplus -H "$BMC" -U "$u" -E chassis power on || log "ipmitool power on failed — press the button; still waiting"
}
up() {
  local booted=0 t=0
  if hv true 2>/dev/null; then
    [ "$(hv 'cut -d. -f1 /proc/uptime' 2>/dev/null || echo 0)" -lt "$GUEST_TIMEOUT" ] && booted=1
    log "$HOST answers ssh$([ $booted = 1 ] && echo ' (just booted: onboot guests self-start)')"
  else
    [ "$DRY" = 1 ] && { echo "DRY=1: $HOST is off — up would power it on and wait; nothing touched"; return 0; }
    power_on; booted=1
    until hv true 2>/dev/null; do sleep 10; t=$((t+10)); [ $t -ge "$HOST_TIMEOUT" ] && { fail "$HOST not on ssh after ${HOST_TIMEOUT}s"; return 1; }; done
    ok "$HOST on ssh after ~${t}s"
  fi
  discover || return 1
  local k id name st c ob cls
  for cls in router backup lxc cp worker runner test; do
    while read -r k id name st c ob; do [ -n "$k" ] || continue
      if [ "$ob" != 1 ]; then [ "$st" = running ] || warn "$name ($id) onboot=$ob stays stopped — \`ssh root@$HIP $k start $id\` if wanted"; continue; fi
      [ "$booted" = 1 ] || [ "$st" = running ] || run hv "$k" start "$id"
      run wait_status "$k" "$id" "$name" running
    done <<<"$(of "$cls")"
  done
  for cls in worker cp; do
    while read -r k id name st c ob; do [ -n "$k" ] || continue; run nm up "$name"; done <<<"$(of "$cls" | awk '$6==1')"
  done
  while read -r k id name st c ob; do [ -n "$k" ] || continue
    run runner undrain "$name"; run wait_green runner verify "$name"
  done <<<"$(of runner | awk '$6==1')"
  while read -r k id name st c ob; do [ -n "$k" ] || continue
    run wait_green router check "$RNODE"; run router carp-maintenance "$RNODE" leave
    [ "$DRY" = 1 ] || ok "router: $(router carp-maintenance "$RNODE" status 2>&1 </dev/null)"
  done <<<"$(of router)"
  run window_close
  [ "$DRY" = 1 ] && { echo "DRY=1: $STEP step(s) planned, nothing touched"; return 0; }
  if [ "$FAILS" -gt 0 ]; then echo "up: $FAILS FAIL, $WARNS WARN — read them"; return 1; fi
  echo "up: $HOST whole again ($WARNS WARN)"
}
wait_green() { # <fn> <args…> — poll a read-only verb until exit 0
  local t=0; until "$@" >/dev/null 2>&1; do sleep 15; t=$((t+15)); [ $t -ge "$VERIFY_TIMEOUT" ] && { log "not green after ${VERIFY_TIMEOUT}s: $(show "$@")"; "$@" || true; return 1; }; done
  ok "green: $(show "$@")"
}

case "$cmd" in
  preflight) preflight ;;
  down) down ;;
  up) up ;;
  *) usage ;;
esac
