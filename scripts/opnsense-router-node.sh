#!/usr/bin/env bash
# Build and check a STANDING router node of the CARP pair (ADR-144, docs/router-move.md §The
# standing nodes) — a from-git OPNsense VM on the real LAN at its own address, INERT until the
# cutover window. Jail only (the wallet + the FU-013 backup).
#
#   bash scripts/opnsense-router-node.sh build    <node>   # killswitch → seed+first boot → converge → check
#   bash scripts/opnsense-router-node.sh converge <node>   # every router play + the two API scripts, standby
#   bash scripts/opnsense-router-node.sh check    <node>   # READ-ONLY: the inert rules + prod unharmed
#   bash scripts/opnsense-router-node.sh killswitch-arm|killswitch-disarm|killswitch-status <node>
#
# <node>: nx02 | pve. The hardware is tofu's (tofu/opnsense-router.tf), the
# host + standby flag ansible/router-nodes/inventory.yml's.
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

case "$NODE" in
  nx02) VMID=9170 VMNAME=opnsense-nx02 PVE=192.168.2.59 WAN_BRIDGE=vmbr3 LAN_MAC=02:00:c0:a8:02:46 INV_HOST=opnsense-nx02 ;;
  pve)  VMID=9171 VMNAME=opnsense-pve  PVE=192.168.2.3  WAN_BRIDGE=vmbr3 LAN_MAC=02:00:c0:a8:02:47 INV_HOST=opnsense-pve ;;
  *) sed -n '5,11p' "$0" >&2; exit 2 ;;
esac
INV=ansible/router-nodes/inventory.yml
HOST="$(yq -r ".all.children.opnsense.hosts[\"$INV_HOST\"].ansible_host" "$INV")"
STANDBY="$(yq -r ".all.children.opnsense.hosts[\"$INV_HOST\"].opnsense_standby" "$INV")"
case "$HOST" in 192.168.2.1|''|null) die "$INV_HOST's ansible_host is '$HOST' — a node never holds .1" ;; esac
PVE_KEY="${OPN_TEST_PVE_KEY:-$HOME/.claude/homelab-pve-ssh/id_ed25519}"
pve() { ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE" "$@"; }
KDB="$HOME/.claude/homelab-keepass/homelab.kdbx"
kp() { keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password "$KDB" "$1" 2>/dev/null; }
TAP="tap${VMID}i0"
KS_UNIT="router-killswitch@$VMID.service"; KS_LOG="/var/log/router-killswitch/$VMID.log"

killswitch_arm() {
  pve "systemctl cat $KS_UNIT >/dev/null 2>&1" \
    || die "$KS_UNIT is not installed on $PVE — run: devbox run -- ansible-playbook ansible/pve-router-killswitch.yml"
  pve "systemctl is-enabled -q $KS_UNIT" || die "$KS_UNIT is not enabled — is $VMID in $PVE's host_vars pve_router_killswitch_vmids?"
  if pve "systemctl is-active -q $KS_UNIT"; then log "kill switch already armed"; return 0; fi
  # a fresh log per arming: `check` counts THIS arming's trips
  pve "[ ! -f $KS_LOG ] || mv $KS_LOG $KS_LOG.prev; systemctl start $KS_UNIT; sleep 1; systemctl is-active -q $KS_UNIT" \
    && log "kill switch armed ($KS_UNIT), log $KS_LOG" || die "$KS_UNIT did not start"
}
killswitch_disarm() { pve "systemctl stop $KS_UNIT; echo \"\$(date -u +%FT%TZ) disarmed\" >> $KS_LOG; echo 'disarmed (still enabled: re-arms at the next host boot)'"; }
killswitch_status() { pve "systemctl is-active -q $KS_UNIT && echo armed || echo NOT-ARMED; c=\$(grep -c TRIPPED $KS_LOG 2>/dev/null); echo \${c:-0}"; }

API_CURL=''
api_setup() {  # prod's wallet pair — carried to the node, so it authenticates there too
  API_CURL="$(mktemp)"; chmod 600 "$API_CURL"
  printf 'user = "%s:%s"\n' "$(kp opnsense-api-key)" "$(kp opnsense-api-secret)" > "$API_CURL"
}
api() { curl -sfk -K "$API_CURL" --max-time 30 "https://$HOST/api/$1"; }

converge() {
  [ "$STANDBY" = true ] || die "$INV_HOST is not opnsense_standby: true in $INV — the cutover converges it, not this verb"
  local p rest plays='opnsense-acme.yml opnsense-bgp.yml opnsense-unbound.yml opnsense-haproxy.yml'
  # opnsense-users.yml is NOT run: a node's users + keys are carried from prod (seed-shape
  # --carry api-users); the play mints keys into the wallet for users that lack one.
  rest="$(cd ansible && ls opnsense-*.yml | grep -vxF -e opnsense-users.yml $(printf -- '-e %s ' $plays))"
  for p in $plays $rest; do
    log "play $p → $INV_HOST ($HOST), standby"
    if [ "$p" = opnsense-ddclient.yml ]; then ACME_CF_TOKEN="$(kp cloudflare-acme-token)"; export ACME_CF_TOKEN; fi
    bash scripts/opnsense-playbook.sh "ansible/$p" -i "$INV" --limit "$INV_HOST" >"$WORK/play-${p%.yml}.log" 2>&1 \
      || { tail -25 "$WORK/play-${p%.yml}.log" >&2; unset ACME_CF_TOKEN; die "play $p failed"; }
    unset ACME_CF_TOKEN
    grep -E '^(opnsense-nx02|PLAY RECAP)|ok=' "$WORK/play-${p%.yml}.log" | tail -1 >&2
  done
  for py in dnsmasq-dhcp tuya-egress; do
    log "opnsense/$py.py → $HOST$([ "$py" = dnsmasq-dhcp ] && echo ' (OPN_DHCP_ENABLE=0)')"
    OPN_HOST="$HOST" OPN_API_KEY="$(kp opnsense-api-key)" OPN_API_SECRET="$(kp opnsense-api-secret)" OPN_DHCP_ENABLE=0 \
      python3 "opnsense/$py.py" > "$WORK/$py.log" 2>&1 || { tail -15 "$WORK/$py.log" >&2; die "$py.py failed"; }
  done
}

# READ-ONLY. One line per rule; exit 1 if any fails or cannot be read.
check() {
  local bad=0 v
  ok() { echo "  ok    $*"; }; no() { echo "  FAIL  $*"; bad=1; }
  [ -n "$API_CURL" ] || api_setup
  echo "== $VMNAME ($HOST) — the inert rules"
  v="$(api interfaces/overview/interfaces_info 2>/dev/null | jq -r '.rows[]? | select(.identifier=="lan") | .addr4' || true)"
  [ "${v%%/*}" = "$HOST" ] && ok "LAN address $v" || no "LAN address '${v:-unread}' (want $HOST)"
  v="$(api interfaces/vip_settings/search_item 2>/dev/null | jq -r '[.rows[] | select(.descr|startswith("haproxy-")) | .interface] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' || true)"
  case "$v" in lo0=*) [ "${v#lo0=}" -gt 0 ] && ok "HAProxy VIPs: $v" || no "HAProxy VIPs: $v";; *) no "HAProxy VIPs: '${v:-unread}' (want all on lo0)";; esac
  v="$(api quagga/bgp/search_neighbor 2>/dev/null | jq -r '[.rows[] | .enabled] | unique | join(",")' || true)"
  [ "$v" = 0 ] && ok "BGP neighbours all disabled" || no "BGP neighbours enabled: '${v:-unread}' (want 0 only)"
  v="$(api dnsmasq/settings/get 2>/dev/null | jq -r '.dnsmasq.enable' || true)"; [ "$v" = 0 ] && ok "dnsmasq (DHCP) off" || no "dnsmasq enable='${v:-unread}'"
  v="$(api dyndns/settings/get 2>/dev/null | jq -r '.ddclient.general.enabled' || true)"; [ "$v" = 0 ] && ok "ddclient off" || no "ddclient enabled='${v:-unread}'"
  v="$(api acmeclient/settings/get 2>/dev/null | jq -r '.acmeclient.settings.autoRenewal' || true)"; [ "$v" = 0 ] && ok "ACME auto-renewal off" || no "ACME autoRenewal='${v:-unread}'"
  v="$(killswitch_status | tr '\n' ' ')"; case "$v" in "armed 0 ") ok "kill switch armed, never tripped";; *) no "kill switch: $v";; esac
  v="$(pve "systemctl is-enabled $KS_UNIT; qm config $VMID | sed -n 's/^onboot: //p'" | tr '\n' ' ' || true)"
  [ "$v" = "enabled 1 " ] && ok "survives a host reboot (switch enabled, onboot 1)" \
    || no "host reboot: switch/onboot '$v' (want 'enabled 1' — the play + tofu on_boot; onboot 0 after a trip is the latch)"
  echo "== prod unharmed"
  v="$(pve "ping -c1 -W1 192.168.2.1 >/dev/null; ip neigh show 192.168.2.1 | awk '{print \$5}'" || true)"
  [ -n "$v" ] && [ "$v" != "$LAN_MAC" ] && ok ".1 is at $v (not the node)" || no ".1 resolves to '${v:-nothing}'"
  v="$(dig +short +time=2 +tries=2 @192.168.2.1 opnsense.teststuff.net A | tail -1 || true)"
  [ -n "$v" ] && ok "prod Unbound answers (opnsense.teststuff.net → $v)" || no "prod Unbound did not answer"
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
  OPN_TEST_SHAPE=standing OPN_TEST_VMID=$VMID OPN_TEST_VM_NAME=$VMNAME OPN_TEST_HOST=$HOST OPN_TEST_WAN_BITS=22 \
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
  *) sed -n '5,11p' "$0" >&2; exit 2 ;;
esac
