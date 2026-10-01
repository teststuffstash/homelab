#!/bin/sh
# Managed by ansible/roles/pve-router-killswitch — edit there. Run by router-wangate@<vmid>.
#
# The router node's WAN GATE (docs/router-move.md, **WAN follows the master**): the ISP gives ONE
# lease to ONE MAC and both nodes wear it, so only the CARP MASTER may be on the WAN. The authority
# sits here, OUTSIDE the guest: a guest-side CARP hook was proven insufficient in the 2026-09-30
# drills (W3: a node booting as BACKUP re-raised its WAN in boot's later interface setup and took
# the lease beside the master; W3c/d: a hook-driven reconfigure never started dhclient).
#
# Rule: the VM's WAN NIC (net1) has LINK iff the guest emitted a CARP advertisement (IP proto 112)
# on its LAN tap within HOLD seconds — only a MASTER advertises. The lever is QEMU's `set_link`
# over the VM's QMP socket (~ms): to the guest it is a cable unplugged/replugged, and OPNsense's
# stock link-down/link-up handling does the DHCP — no guest code. The host WAN tap follows too
# (a belt for the instant before QMP answers at VM start). Forced down the moment the VM's taps
# appear: a booting node is never MASTER yet. QMP only on change + a re-assert every REASSERT s
# (Proxmox's own QMP clients share the socket).
#
# HOLD > the node's advert interval, advbase + advskew/256 (nx-02 at skew 100 = 1.39 s — 1.5 s
# flapped a MASTER's WAN in the drill). 3 s = CARP's own master-down time (3 x advbase).
set -u
vmid="$1"; lan="tap${vmid}i0"; wan="tap${vmid}i1"; qmp="/var/run/qemu-server/$vmid.qmp"
# The pair's belt reads what this gate SEES (argocd/resources/pve-metrics/, group router-pair):
# CARP master (an advert within HOLD), the WAN link it set, and a heartbeat — node_exporter's
# textfile collector on this hypervisor. A host-side observer, independent of the guest's API.
prom="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}/router-wangate-$vmid.prom"
hold="${HOLD:-3}"; reassert="${REASSERT:-30}"
logf="/var/log/router-killswitch/$vmid-wangate.log"; state=""; last=0
say() { echo "$(date -u +%FT%T.%3NZ) $*" >> "$logf"; }
qmp_link() {   # $1 = true|false. Success = BOTH commands returned {} (capabilities alone matching
  # hid a set_link that never ran — drill W1, 2026-09-30); up to 3 tries (the socket is shared).
  for try in 1 2 3; do
    n=$(printf '%s\n' '{"execute":"qmp_capabilities"}' \
      "{\"execute\":\"set_link\",\"arguments\":{\"name\":\"net1\",\"up\":$1}}" \
      | socat -t2 - "UNIX-CONNECT:$qmp" 2>/dev/null | grep -c '"return": {}')
    [ "$n" = 2 ] && return 0
    sleep 0.3
  done
  return 1
}
set_wan() {   # $1 = up|down, $2 = why
  now=$(date +%s)
  [ "$1" != "$state" ] || [ $((now - last)) -ge "$reassert" ] || return 0
  if [ "$1" = up ]; then ip link set "$wan" up 2>/dev/null; qmp_link true; rc=$?
  else qmp_link false; rc=$?; ip link set "$wan" down 2>/dev/null; fi
  [ "$1" = "$state" ] || say "WAN $1${2:+ ($2)}$([ $rc = 0 ] || echo ' — QMP set_link FAILED')"
  [ $rc = 0 ] && { state="$1"; last=$now; }
}
write_prom() {   # $1 = master 0|1
  [ -d "${prom%/*}" ] || return 0
  { echo "# HELP router_node_carp_master 1 if the VM emitted a CARP advert within the gate's hold (only a MASTER advertises)."
    echo "# TYPE router_node_carp_master gauge"
    echo "router_node_carp_master{vmid=\"$vmid\"} $1"
    echo "# HELP router_node_wan_link 1 if the gate last set the VM's WAN link up."
    echo "# TYPE router_node_wan_link gauge"
    echo "router_node_wan_link{vmid=\"$vmid\"} $([ "$state" = up ] && echo 1 || echo 0)"
    echo "# HELP router_node_wangate_heartbeat_seconds Unix time of the gate's last cycle."
    echo "# TYPE router_node_wangate_heartbeat_seconds gauge"
    echo "router_node_wangate_heartbeat_seconds{vmid=\"$vmid\"} $(date +%s)"
  } > "$prom.tmp" && mv "$prom.tmp" "$prom"
}
say "started for vm $vmid (hold ${hold}s)"
while :; do
  if [ ! -e "/sys/class/net/$wan" ] || [ ! -e "/sys/class/net/$lan" ]; then
    state=""; write_prom 0; sleep 0.5; continue   # VM down: not a master, gate alive
  fi
  [ -n "$state" ] || set_wan down "taps appeared"
  if timeout "$hold" tcpdump -Q in -n -c 1 -i "$lan" 'ip proto 112' >/dev/null 2>&1; then
    set_wan up "CARP advert = MASTER"; write_prom 1
  else
    set_wan down "no advert in ${hold}s"; write_prom 0
  fi
done
