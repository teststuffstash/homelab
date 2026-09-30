#!/bin/sh
# Managed by ansible/roles/pve-router-killswitch — edit there. Run by router-killswitch@<vmid>.
#
# The standing router node's kill switch (docs/router-move.md §Building a standing node, step 1):
# tcpdump on the node's LAN tap (every frame its LAN NIC emits — a capture on vmbr0 would miss
# unicast ARP replies between other ports) waits for ONE frame that would mean the node is not
# inert — an ARP claiming 192.168.2.1 or any 192.168.3.x (prod's HAProxy VIPs), a DHCP server
# reply (udp sport 67), a BGP SYN (tcp dport 179), anything sourced from .1 or 3.0/24, an IPv6
# router advertisement — then LATCHES (onboot 0, so a host reboot does not boot it back into the
# LAN) and stops the VM. The latch is drift against tofu's on_boot = true: re-enabling the node
# is a reviewed `mgmt-tf apply`, never automatic. The watched MAC is read from net0 (tofu's), so
# the switch cannot watch a different NIC than the one the VM has.
set -u
vmid="$1"; logf="/var/log/router-killswitch/$vmid.log"; tap="tap${vmid}i0"
mac="$(qm config "$vmid" | sed -n 's/^net0: virtio=\([0-9A-Fa-f:]*\),.*/\1/p' | tr 'A-F' 'a-f')"
[ -n "$mac" ] || { echo "vm $vmid: no virtio net0 MAC — refusing to arm" >&2; exit 1; }
filt="ether src $mac and ( (arp and (arp[14:4] = 0xc0a80201 or (arp[14:2] = 0xc0a8 and arp[16] = 3))) or (udp src port 67) or (tcp dst port 179 and tcp[13] & 2 != 0) or (ip src 192.168.2.1) or (ip src net 192.168.3.0/24) or (icmp6 and ip6[40] = 134) )"
echo "$(date -u +%FT%TZ) armed for vm $vmid on $tap ($mac)" >> "$logf"
while :; do
  while [ ! -e "/sys/class/net/$tap" ]; do sleep 0.2; done
  if tcpdump -l -n -e -c 1 -i "$tap" "$filt" >> "$logf" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) TRIPPED - qm set $vmid --onboot 0; qm stop $vmid" >> "$logf"
    qm set "$vmid" --onboot 0 >> "$logf" 2>&1
    qm stop "$vmid" --skiplock 1 >> "$logf" 2>&1
    exit 0
  fi
  sleep 0.2   # tcpdump lost the tap (VM stopped/restarted) — wait for it to come back
done
