#!/usr/bin/env bash
# Build and check a STANDING router node of the CARP pair (ADR-144, docs/router-move.md §The
# standing nodes) — a from-git OPNsense VM on the real LAN at its own address, INERT until the
# cutover window. Jail only (the wallet + the FU-013 backup).
#
#   bash scripts/opnsense-router-node.sh build    <node>   # killswitch → seed+first boot → converge → check
#   bash scripts/opnsense-router-node.sh converge <node>   # every router play + the API scripts (standby or LIVE)
#   bash scripts/opnsense-router-node.sh check    <node>   # READ-ONLY: standby = the inert rules + prod unharmed;
#                                                          #            LIVE = the serving rules (ADR-145 window 1)
#   bash scripts/opnsense-router-node.sh killswitch-arm|killswitch-disarm|killswitch-status <node>
#   bash scripts/opnsense-router-node.sh carp-maintenance <node> enter|leave|status   # planned failover (demotion-aware)
#   bash scripts/opnsense-router-node.sh fakeisp up|down|log     # PAIR: the WAN drills' fake ISP (nx-02 netns)
#   bash scripts/opnsense-router-node.sh probe <secs>            # PAIR: held flow + fresh connects via the trial VIP
#
# <node>: nx02 | pve. The hardware is tofu's (tofu/opnsense-router.tf), the
# host + standby flag ansible/router-nodes/inventory.yml's. A node with `opnsense_standby: false` is
# LIVE (ADR-145): `converge` refuses it while its kill switch is armed or enabled (retire it first:
# `pve_router_live_vmids` + ansible/pve-router-killswitch.yml), then serves DHCP from Kea.
#
# THE KILL SWITCH. Armed before the first boot, on the hypervisor itself (it keeps working when
# the LAN does not): the `router-killswitch@<vmid>` unit (ansible/pve-router-killswitch.yml — the
# watch itself, its filter and the trip latch are documented in that role's router-killswitch.sh)
# stops the VM on ONE frame that would mean the node is not inert, and sets onboot 0 so a host
# reboot does not bring it back. Enabled at every host boot, ordered before pve-guests. These
# verbs start/stop/read the unit; the play installs it.
#
# Inert BY CONSTRUCTION, the switch is the belt: the seed's standing shape (DHCP off, ACME
# auto-renewal off, no WAN rules — opnsense/test-vm/seed-shape.py --standing) and every play run
# with `opnsense_standby: true` from its first write.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
log() { echo "[router-node] $*" >&2; }
die() { log "FAIL: $*"; exit 1; }
cmd="${1:-}"; NODE="${2:-}"

# ---- PAIR verbs (no <node>): the WAN drills' fake ISP + probe (docs/router-move.md, **WAN follows
# the master**). The fake ISP lives in a netns on nx-02 joined to vmbr3 — the operator's cable
# (nx-02 eno2 <-> pve enp6s0) makes both nodes' WANs one segment. Runtime-only: `down` removes all.
if [ "$cmd" = fakeisp ] || [ "$cmd" = probe ]; then
  K="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
  hyp() { ssh -i "$K" -o BatchMode=yes -o ConnectTimeout=10 "root@$1" "${@:2}"; }
  WANMAC="$(yq -r '.machines[] | select(.name == "opnsense") | .wan_mac' machines/machines.yaml)"
  case "$cmd:$NODE" in
    fakeisp:up)
      hyp 192.168.2.59 "cat > /root/fakeisp.py" < opnsense/router-node/fakeisp.py
      hyp 192.168.2.59 "sh -s $WANMAC" <<'SH'
set -e
pgrep -f "[p]ython3 /root/fakeisp.py" >/dev/null && { echo "fakeisp already up"; exit 0; }
ip link del fisp-h 2>/dev/null || true; ip netns del fakeisp 2>/dev/null || true   # a half-torn-down run
ip netns add fakeisp
ip link add fisp-h type veth peer name fisp-n
ip link set fisp-n netns fakeisp
ip link set fisp-h master vmbr3 up
ip netns exec fakeisp ip link set lo up
ip netns exec fakeisp ip addr add 100.64.0.1/24 dev fisp-n
ip netns exec fakeisp ip link set fisp-n up
setsid nohup ip netns exec fakeisp python3 /root/fakeisp.py --mac "$1" > /root/fakeisp.log 2>&1 < /dev/null &
sleep 1; tail -1 /root/fakeisp.log
SH
      ;;
    fakeisp:down)
      hyp 192.168.2.59 'pkill -f "[p]ython3 /root/fakeisp.py"; ip link del fisp-h 2>/dev/null; ip netns del fakeisp 2>/dev/null; echo "fakeisp down (log kept: /root/fakeisp.log)"' ;;
    fakeisp:log) hyp 192.168.2.59 "tail -n ${3:-30} /root/fakeisp.log" ;;
    probe:*)   # probe <secs> — from the pve HOST, 100.64.0.1 routed via the trial VIP for the run
      VIP="$(yq -r '.router_carp_vips[0].address | sub("/.*$"; "")' ansible/router-nodes/group_vars/opnsense.yml)"
      hyp 192.168.2.3 "cat > /root/flowprobe.py" < opnsense/router-node/flowprobe.py
      hyp 192.168.2.3 "ip route replace 100.64.0.1/32 via $VIP; python3 /root/flowprobe.py 100.64.0.1 ${NODE:-30}; ip route del 100.64.0.1/32" ;;
    *) sed -n '5,13p' "$0" >&2; exit 2 ;;
  esac
  exit 0
fi

case "$NODE" in
  nx02) VMID=9170 VMNAME=opnsense-nx02 PVE=192.168.2.59 WAN_BRIDGE=vmbr3 LAN_MAC=02:00:c0:a8:02:46 INV_HOST=opnsense-nx02 ;;
  pve)  VMID=9171 VMNAME=opnsense-pve  PVE=192.168.2.3  WAN_BRIDGE=vmbr3 LAN_MAC=02:00:c0:a8:02:47 INV_HOST=opnsense-pve ;;
  *) sed -n '5,13p' "$0" >&2; exit 2 ;;
esac
INV=ansible/router-nodes/inventory.yml
HOST="$(yq -r ".all.children.opnsense.hosts[\"$INV_HOST\"].ansible_host" "$INV")"
STANDBY="$(yq -r ".all.children.opnsense.hosts[\"$INV_HOST\"].opnsense_standby" "$INV")"
case "$HOST" in 192.168.2.1|''|null) die "$INV_HOST's ansible_host is '$HOST' — a node never holds .1" ;; esac
PVE_KEY="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
pve() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE" "$@"; }
node_ssh() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$HOST" "$@"; }   # the seed's root key = the pve key
KDB="$HOME/.claude/homelab-keepass/homelab.kdbx"
kp() { keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$KDB" "$1" 2>/dev/null; }
TAP="tap${VMID}i0"
KS_UNIT="router-killswitch@$VMID.service"; KS_LOG="/var/log/router-killswitch/$VMID.log"
# The node's CARP VIP list: its host var (window 1 puts `.1` on nx-02 alone) wins over the group's.
carp_vips() {
  local v; v="$(yq -o=json ".all.children.opnsense.hosts[\"$INV_HOST\"].router_carp_vips" "$INV")"
  [ "$v" != null ] || v="$(yq -o=json '.router_carp_vips' ansible/router-nodes/group_vars/opnsense.yml)"
  printf '%s' "$v"
}

killswitch_arm() {
  pve "systemctl cat $KS_UNIT >/dev/null 2>&1" \
    || die "$KS_UNIT is not installed on $PVE — run: devbox run -- ansible-playbook ansible/pve-router-killswitch.yml"
  pve "systemctl is-enabled -q $KS_UNIT" || die "$KS_UNIT is not enabled — is $VMID in $PVE's host_vars pve_router_killswitch_vmids?"
  if pve "systemctl is-active -q $KS_UNIT"; then log "kill switch already armed"; return 0; fi
  # a fresh log per arming: `check` counts THIS arming's trips
  pve "[ ! -f $KS_LOG ] || mv $KS_LOG $KS_LOG.prev; systemctl start $KS_UNIT; sleep 1; systemctl is-active -q $KS_UNIT" \
    && log "kill switch armed ($KS_UNIT), log $KS_LOG" || die "$KS_UNIT did not start"
}
# CARP maintenance (docs/router-move.md §Window 2 step 4, the planned-failover lever): the node's
# demotion goes +240 so the other node preempts; `leave` clears it and this node (if the lower
# skew) takes the VIP back. ⚠ The API verb `diagnostics/interface/carp_status/maintenance` is a
# TOGGLE (carp_set_status.php: in maintenance → leave, else enter) and `carp_status/enable` does
# NOT leave maintenance — it only re-enables CARP. The 2026-10-08 failover proof called `enable`
# to come back, nx-02 stayed demoted and pve (no WAN cable) held `.1` for nine hours
# (docs/router-move.md §Status, 2026-10-09). So: read the demotion FIRST, act only
# when the state differs from the goal, and verify the VIP afterwards.
carp_demotion() { node_ssh sysctl -n net.inet.carp.demotion 2>/dev/null; }
# THE DEAD-MAN (FU-308): `enter` arms a sleeper ON THE NODE that leaves maintenance by itself after
# DEADMAN seconds (default 900) if nobody did — the 2026-10-08 proof cut the seat's own WAN path
# (the jail rides `.1`) and sat latched for nine hours. Runs on the node, not the jail: it must fire
# when the jail is blind. Conditional (demotion still >= 240 → the same toggle the verb uses), so a
# completed `leave` makes it a no-op; `leave` also kills it. `status` shows whether one is armed.
DEADMAN_SH=/tmp/carp-deadman.sh
deadman_arm() {
  local secs="${DEADMAN:-900}"
  printf '%s\n' '#!/bin/sh' \
    "# armed $(date -u +%FT%TZ) by scripts/opnsense-router-node.sh carp-maintenance enter (FU-308)" \
    "sleep $secs" \
    'if [ "$(sysctl -n net.inet.carp.demotion)" -ge 240 ]; then' \
    '  echo "$(date -u +%FT%TZ) DEADMAN fired after '"$secs"'s: leaving CARP maintenance" >> /tmp/carp-deadman.log' \
    '  /usr/local/bin/php /usr/local/opnsense/scripts/interfaces/carp_set_status.php maintenance >> /tmp/carp-deadman.log 2>&1; echo >> /tmp/carp-deadman.log' \
    'else echo "$(date -u +%FT%TZ) deadman: not in maintenance, nothing to do" >> /tmp/carp-deadman.log; fi' \
    | node_ssh "cat > $DEADMAN_SH && chmod +x $DEADMAN_SH && pkill -f $DEADMAN_SH 2>/dev/null; nohup $DEADMAN_SH >/dev/null 2>&1 </dev/null & sleep 0.3; pgrep -qf $DEADMAN_SH && echo armed" \
    | grep -qx armed || die "dead-man did not arm on $HOST — not entering maintenance"
  log "dead-man armed on $INV_HOST: leaves maintenance by itself in ${secs}s (DEADMAN=<s> to change)"
}
deadman_disarm() { node_ssh "pkill -f $DEADMAN_SH 2>/dev/null && echo 'dead-man disarmed' || echo 'no dead-man was armed'"; }
deadman_status() { node_ssh "pgrep -qf $DEADMAN_SH && echo 'dead-man ARMED' || echo 'no dead-man'; tail -n 2 /tmp/carp-deadman.log 2>/dev/null"; }
carp_vip1() { api diagnostics/interface/get_vip_status 2>/dev/null | jq -r '[.rows[]? | select(.subnet=="192.168.2.1") | .status] | join(",")'; }
carp_maintenance() {   # $1 = enter|leave|status
  local dem r i; [ -n "$API_CURL" ] || api_setup
  dem="$(carp_demotion)"; [ -n "$dem" ] || die "cannot read net.inet.carp.demotion on $HOST"
  case "$1" in
    status) echo "$INV_HOST ($HOST): demotion=$dem .1=$(carp_vip1) $( [ "$dem" -ge 240 ] && echo 'IN maintenance' || echo 'not in maintenance'); $(deadman_status | tr '\n' ' ')"; return 0 ;;
    enter)
      [ "$dem" -ge 240 ] && { log "$INV_HOST already in maintenance (demotion $dem) — not toggling"; return 0; }
      deadman_arm
      r="$(curl -sk -K "$API_CURL" --max-time 15 -X POST "https://$HOST/api/diagnostics/interface/carp_status/maintenance")"
      grep -q enter_maintenance <<<"$r" || die "unexpected answer: $r" ;;
    leave)
      [ "$dem" -ge 240 ] || { log "$INV_HOST not in maintenance (demotion $dem) — not toggling"; return 0; }
      r="$(curl -sk -K "$API_CURL" --max-time 15 -X POST "https://$HOST/api/diagnostics/interface/carp_status/maintenance")"
      grep -q leave_maintenance <<<"$r" || die "unexpected answer: $r" ;;
    *) die "carp-maintenance enter|leave|status" ;;
  esac
  for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; dem="$(carp_demotion)"; [ "$1" = enter ] && [ "$dem" -ge 240 ] && break; [ "$1" = leave ] && [ "$dem" = 0 ] && break; done
  log "$1: demotion=$dem .1 on $INV_HOST = $(carp_vip1)"
  case "$1:$dem" in enter:240|enter:24[1-9]|enter:2[5-9][0-9]) ;; leave:0) log "$(deadman_disarm)" ;; *) die "demotion did not settle ($dem)";; esac
}

killswitch_disarm() { pve "systemctl stop $KS_UNIT; echo \"\$(date -u +%FT%TZ) disarmed\" >> $KS_LOG; echo 'disarmed (still enabled: re-arms at the next host boot)'"; }
killswitch_status() { pve "systemctl is-active -q $KS_UNIT && echo armed || echo NOT-ARMED; c=\$(grep -c TRIPPED $KS_LOG 2>/dev/null); echo \${c:-0}"; }

API_CURL=''
api_setup() {  # prod's wallet pair — carried to the node, so it authenticates there too
  API_CURL="$(mktemp)"; chmod 600 "$API_CURL"
  printf 'user = "%s:%s"\n' "$(kp opnsense-api-key)" "$(kp opnsense-api-secret)" > "$API_CURL"
}
api() { curl -sfk -K "$API_CURL" --max-time 30 "https://$HOST/api/$1"; }

# The Kea HA peer set for a LIVE node (opnsense/kea-dhcp.py OPN_KEA_HA) when the inventory holds
# more than one live node: "<this>;<name>=http://<ip>:8001/=<role>,…" — primary = the lowest CARP
# advskew (the MASTER), every other live node standby (hot-standby: it answers only in partner-down).
# One live node (window 1's shape) → empty = HA off, Kea serving alone.
kea_ha_env() {
  local rows n
  rows="$(yq -r '.all.children.opnsense.hosts | to_entries[] | select(.value.opnsense_standby == false) | "\(.key) \(.value.ansible_host) \(.value.router_carp_advskew // 0)"' "$INV" | sort -k3,3n -k1,1)"
  n="$(printf '%s\n' "$rows" | grep -c .)"
  [ "$n" -ge 2 ] || return 0
  printf '%s;' "$INV_HOST"
  printf '%s\n' "$rows" | awk 'NR==1{r="primary"} NR>1{r="standby"} {printf "%s%s=http://%s:8001/=%s", (NR>1?",":""), $1, $2, r}'
}

converge() {
  local dhcp_enable=0 dhcp_server=kea kea_ha=''   # Kea's config converges on every node; only a LIVE one serves
  if [ "$STANDBY" != true ]; then   # LIVE (ADR-145): the kill switch would trip on the first converge
    pve "systemctl is-active -q $KS_UNIT || systemctl is-enabled -q $KS_UNIT" \
      && die "$INV_HOST is LIVE but $KS_UNIT is still armed/enabled on $PVE — retire it first: $VMID in pve_router_live_vmids, then ansible/pve-router-killswitch.yml"
    dhcp_enable=1
    kea_ha="$(kea_ha_env)"
    [ -z "$kea_ha" ] || log "Kea HA peers: $kea_ha"
  fi
  local p rest plays='opnsense-acme.yml opnsense-bgp.yml opnsense-unbound.yml opnsense-haproxy.yml'
  # opnsense-users.yml is NOT run: a node's users + keys are carried from prod (seed-shape
  # --carry api-users); the play mints keys into the wallet for users that lack one.
  rest="$(cd ansible && ls opnsense-*.yml | grep -vxF -e opnsense-users.yml $(printf -- '-e %s ' $plays))"
  for p in $plays $rest; do
    log "play $p → $INV_HOST ($HOST), $( [ "$STANDBY" = true ] && echo standby || echo LIVE)"
    if [ "$p" = opnsense-ddclient.yml ]; then ACME_CF_TOKEN="$(kp cloudflare-acme-token)"; export ACME_CF_TOKEN; fi
    if [ "$p" = opnsense-carp.yml ]; then OPN_CARP_PASSWORD="$(kp opnsense-carp-password)"; export OPN_CARP_PASSWORD; fi
    bash scripts/opnsense-playbook.sh "ansible/$p" -i "$INV" --limit "$INV_HOST" >"$WORK/play-${p%.yml}.log" 2>&1 \
      || { tail -25 "$WORK/play-${p%.yml}.log" >&2; unset ACME_CF_TOKEN OPN_CARP_PASSWORD; die "play $p failed"; }
    unset ACME_CF_TOKEN OPN_CARP_PASSWORD
    grep -E '^(opnsense-nx02|PLAY RECAP)|ok=' "$WORK/play-${p%.yml}.log" | tail -1 >&2
  done
  # Both DHCP scripts: OPN_DHCP_SERVER (dnsmasq-dhcp.py) picks the one that serves, the other
  # converges off — under the standby profile neither serves; a LIVE node serves from Kea (ADR-145).
  for py in dnsmasq-dhcp kea-dhcp tuya-egress; do
    log "opnsense/$py.py → $HOST$(case $py in *-dhcp) echo " (OPN_DHCP_SERVER=$dhcp_server OPN_DHCP_ENABLE=$dhcp_enable)";; esac)"
    OPN_HOST="$HOST" OPN_API_KEY="$(kp opnsense-api-key)" OPN_API_SECRET="$(kp opnsense-api-secret)" \
      OPN_DHCP_ENABLE=$dhcp_enable OPN_DHCP_SERVER=$dhcp_server OPN_KEA_HA="$kea_ha" \
      python3 "opnsense/$py.py" > "$WORK/$py.log" 2>&1 || { tail -15 "$WORK/$py.log" >&2; die "$py.py failed"; }
  done
  # Flush to disk: the nano image's UFS (soft-updates) lost ~1 min of config writes to a hard stop
  # (the kill switch's qm stop, 2026-09-30) — a node that dies right after a converge must not
  # come back without it.
  node_ssh sync || die "sync on $HOST failed"
}

# READ-ONLY. One line per rule; exit 1 if any fails or cannot be read. A standing node is read
# against the inert rules, a LIVE one (opnsense_standby: false, ADR-145) against their inverse.
check() {
  local bad=0 v live=0 on=0
  ok() { echo "  ok    $*"; }; no() { echo "  FAIL  $*"; bad=1; }
  # expect_on <value-read> <label> — standby wants 0 (off), live wants 1 (on)
  expect_on() { [ "$1" = "$on" ] && ok "$2 $( [ "$on" = 1 ] && echo on || echo off)" || no "$2 = '${1:-unread}' (want $on)"; }
  [ "$STANDBY" = true ] || { live=1 on=1; }
  [ -n "$API_CURL" ] || api_setup
  echo "== $VMNAME ($HOST) — $( [ $live = 1 ] && echo 'LIVE: the serving rules' || echo 'the inert rules')"
  v="$(api interfaces/overview/interfaces_info 2>/dev/null | jq -r '.rows[]? | select(.identifier=="lan") | .addr4' || true)"
  [ "${v%%/*}" = "$HOST" ] && ok "LAN address $v" || no "LAN address '${v:-unread}' (want $HOST)"
  v="$(api interfaces/vip_settings/search_item 2>/dev/null | jq -r '[.rows[] | select(.descr|startswith("haproxy-")) | .interface] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' || true)"
  case "$v" in lo0=*) [ "${v#lo0=}" -gt 0 ] && ok "HAProxy VIPs: $v" || no "HAProxy VIPs: $v";; *) no "HAProxy VIPs: '${v:-unread}' (want all on lo0)";; esac
  v="$(api quagga/bgp/search_neighbor 2>/dev/null | jq -r '[.rows[] | .enabled] | unique | join(",")' || true)"
  expect_on "$v" "BGP neighbours (all)"
  v="$(api dnsmasq/settings/get 2>/dev/null | jq -r '.dnsmasq.enable' || true)"; [ "$v" = 0 ] && ok "dnsmasq (DHCP) off" || no "dnsmasq enable='${v:-unread}'"
  # Kea is read on EVERY node, not only a live one: a standby node with Kea on answers as `.1` the
  # moment its config holds the subnet (pve's node did, 2026-10-02 17:14Z, while this check read
  # only dnsmasq and called it green). Standby wants the server AND its HA hook off — a hot-standby
  # peer serves in partner-down, which is the same rogue lease by another path.
  v="$(api kea/dhcpv4/get 2>/dev/null | jq -r '.dhcpv4.general.enabled' || true)"; expect_on "$v" "Kea DHCPv4"
  v="$(api kea/dhcpv4/get 2>/dev/null | jq -r '.dhcpv4.ha.enabled' || true)"
  if [ $live = 0 ] || [ -z "$(kea_ha_env)" ]; then [ "$v" = 0 ] && ok "Kea HA hook off" || no "Kea HA hook enabled='${v:-unread}' (want 0: standby, or a lone live node)"
  else [ "$v" = 1 ] && ok "Kea HA hook on (pair)" || no "Kea HA hook enabled='${v:-unread}' (want 1: a live node of the pair)"; fi
  if [ $live = 1 ]; then   # egress via its own WAN: the standing LAN_GW (default route to .1) is gone
    v="$(api routing/settings/search_gateway 2>/dev/null | jq -r '[.rows[] | select(.name=="LAN_GW")] | length' || true)"
    [ "$v" = 0 ] && ok "no LAN_GW (default route = WAN_GW)" || no "LAN_GW still present ('${v:-unread}') — its default route is its own .1"
  fi
  v="$(api dyndns/settings/get 2>/dev/null | jq -r '.ddclient.general.enabled' || true)"; expect_on "$v" "ddclient"
  v="$(api acmeclient/settings/get 2>/dev/null | jq -r '.acmeclient.settings.autoRenewal' || true)"; expect_on "$v" "ACME auto-renewal"
  if [ $live = 1 ]; then   # the kill switch is RETIRED on a live node (pve_router_live_vmids)
    v="$(pve "systemctl is-active $KS_UNIT; systemctl is-enabled $KS_UNIT; qm config $VMID | sed -n 's/^onboot: //p'" | tr '\n' ' ' || true)"
    [ "$v" = "inactive disabled 1 " ] && ok "kill switch retired, onboot 1" \
      || no "kill switch/onboot '$v' (want 'inactive disabled 1' — pve_router_live_vmids + ansible/pve-router-killswitch.yml; tofu on_boot)"
  else
    v="$(killswitch_status | tr '\n' ' ')"; case "$v" in "armed 0 ") ok "kill switch armed, never tripped";; *) no "kill switch: $v";; esac
    v="$(pve "systemctl is-enabled $KS_UNIT; qm config $VMID | sed -n 's/^onboot: //p'" | tr '\n' ' ' || true)"
    [ "$v" = "enabled 1 " ] && ok "survives a host reboot (switch enabled, onboot 1)" \
      || no "host reboot: switch/onboot '$v' (want 'enabled 1' — the play + tofu on_boot; onboot 0 after a trip is the latch)"
  fi
  # CARP (`router_carp_vips` — the node's host var, else the router-nodes group list): each VIP
  # present on LAN, and in a live state — MASTER or BACKUP; INIT/DISABLED/absent is a fail. A
  # LIVE node holding `.1` alone must be its MASTER (window 1 — nobody else can be).
  local want gone vips; vips="$(carp_vips)"
  want="$(printf '%s' "$vips" | jq -r '.[]? | select(.state == null) | .address | sub("/.*$"; "")')"
  gone="$(printf '%s' "$vips" | jq -r '.[]? | select(.state == "absent") | .address | sub("/.*$"; "")')"
  for a in $gone; do
    v="$(api diagnostics/interface/get_vip_status 2>/dev/null | jq -r --arg a "$a" '[.rows[] | select(.subnet==$a)] | length' || true)"
    [ "$v" = 0 ] && ok "CARP $a retired (absent)" || no "CARP $a: still configured ('${v:-unread}' rows; want absent)"
  done
  for a in $want; do
    v="$(api diagnostics/interface/get_vip_status 2>/dev/null | jq -r --arg a "$a" '[.rows[] | select(.subnet==$a and .mode=="carp") | "\(.interface | ascii_downcase)/\(.status)"] | join(",")' || true)"
    case "$live:$a:$v" in
      1:192.168.2.1:lan/MASTER|0:*:lan/MASTER|*:lan/BACKUP) ok "CARP $a $v";;
      *) no "CARP $a: '${v:-absent}' (want lan/MASTER or lan/BACKUP; a live node's .1 MASTER)";;
    esac
  done
  if [ -n "$want$gone" ]; then   # pfsync rides with CARP: LAN, unicast to the OTHER node, the pinned version
    local peer; peer="$(yq -r "[.all.children.opnsense.hosts | to_entries[] | select(.key != \"$INV_HOST\") | .value.ansible_host][0]" "$INV")"
    v="$(api core/hasync/get 2>/dev/null | jq -r '.hasync | [(.pfsyncinterface | to_entries[] | select(.value.selected==1) | .key), .pfsyncpeerip, (.pfsyncversion | to_entries[] | select(.value.selected==1) | .key)] | join(" ")' || true)"
    [ "$v" = "lan $peer 1400" ] && ok "pfsync lan → $peer (v1400)" || no "pfsync: '${v:-unread}' (want 'lan $peer 1400')"
    # the WAN gate (router-wangate@<vmid>, hypervisor): running, and the WAN tap UP iff CARP MASTER
    local role; role="$(api diagnostics/interface/get_vip_status 2>/dev/null | jq -r '[.rows[] | select(.mode=="carp") | .status] | first // "none"' || true)"
    v="$(pve "systemctl is-active router-wangate@$VMID; ip -br link show tap${VMID}i1 | awk '{print \$2}'" | tr '\n' ' ' || true)"
    case "$role:$v" in
      "MASTER:active UP "|"MASTER:active UNKNOWN "|"BACKUP:active DOWN "|"none:active DOWN ") ok "WAN gate: $role → WAN tap ${v#active }";;
      *) no "WAN gate: CARP $role, gate/tap '$v' (want active, UP iff MASTER)";;
    esac
  fi
  echo "== $( [ $live = 1 ] && echo 'the router serves (.1)' || echo 'prod unharmed')"
  v="$(pve "ping -c1 -W1 192.168.2.1 >/dev/null; ip neigh show 192.168.2.1 | awk '{print \$5}'" || true)"
  if [ $live = 1 ]; then   # vhid 1's virtual MAC — the CARP VIP, not the node's own LAN MAC
    [ "$v" = 00:00:5e:00:01:01 ] && ok ".1 is at $v (CARP vhid 1)" || no ".1 resolves to '${v:-nothing}' (want 00:00:5e:00:01:01)"
  else
    [ -n "$v" ] && [ "$v" != "$LAN_MAC" ] && ok ".1 is at $v (not the node)" || no ".1 resolves to '${v:-nothing}'"
  fi
  v="$(dig +short +time=2 +tries=2 @192.168.2.1 opnsense.teststuff.net A | tail -1 || true)"
  [ -n "$v" ] && ok "Unbound @.1 answers (opnsense.teststuff.net → $v)" || no "Unbound @.1 did not answer"
  v="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://grafana.teststuff.net/api/health || true)"
  [ "$v" = 200 ] && ok "HAProxy path (grafana /api/health 200)" || no "grafana via HAProxy: HTTP ${v:-none}"
  return $bad
}

WORK="$(mktemp -d)"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"; [ -z "$API_CURL" ] || rm -f "$API_CURL"' EXIT

build() {
  [ "$STANDBY" = true ] || die "$INV_HOST must be opnsense_standby: true to be built"
  pve "qm config $VMID" | grep -q "^name: $VMNAME$" || die "vm $VMID is not $VMNAME on $PVE — apply tofu/opnsense-router.tf first"
  pve "qm config $VMID" | grep -qi "^net0:.*=${LAN_MAC}," || die "vm $VMID's net0 MAC is not $LAN_MAC (the kill switch watches that MAC)"
  pve "ping -c2 -W1 $HOST >/dev/null 2>&1" && die "$HOST already answers on the LAN — address taken"
  killswitch_arm
  local M="$ROOT/machines/machines.yaml" wan_mac
  wan_mac="$(yq -r '.machines[] | select(.name == "opnsense") | .wan_mac' "$M")"
  log "fetching the identity carry (newest FU-013 backup)"
  bash scripts/opnsense-backup-fetch.sh "$WORK/carry.xml"
  log "seed + first boot ($VMNAME, standing shape)"
  OPN_TEST_SHAPE=standing OPN_TEST_VMID=$VMID OPN_TEST_VM_NAME=$VMNAME OPN_TEST_HOST=$HOST OPN_TEST_WAN_BITS=24 \
  OPN_TEST_PVE=$PVE OPN_TEST_WAN_MAC="$wan_mac" OPN_TEST_WAN_BRIDGE=$WAN_BRIDGE \
  OPN_TEST_CARRY_FROM="$WORK/carry.xml" OPN_TEST_CARRY=trust,acme,api-users,wireguard \
  OPN_TEST_ROOT_PASSWORD="$(kp opnsense-root-password)" OPN_TEST_API_KEY="$(kp opnsense-api-key)" \
  OPN_TEST_API_SECRET="$(kp opnsense-api-secret)" \
    bash scripts/opnsense-test-vm-bootstrap.sh bootstrap
  rm -f "$WORK/carry.xml"
  converge
  check
}

case "$cmd" in
  build) build ;;
  converge) converge ;;
  check) check ;;
  killswitch-arm) killswitch_arm ;;
  killswitch-disarm) killswitch_disarm ;;
  killswitch-status) killswitch_status ;;
  carp-maintenance) carp_maintenance "${3:?enter|leave|status}" ;;
  *) sed -n '5,13p' "$0" >&2; exit 2 ;;
esac
