#!/bin/sh
# Managed by ansible/roles/pve-router-killswitch — edit there. Run by router-killswitch@<vmid>.
#
# The standing router node's kill switch (docs/router-move.md §Building a standing node, step 1):
# tcpdump on the node's LAN tap, INBOUND only (-Q in = every frame the VM emits, whatever its
# source MAC — a CARP address speaks from the virtual MAC 00:00:5e:00:01:<vhid>, never the NIC's),
# waits for ONE frame that would mean the node is not inert — an ARP claiming 192.168.2.1 or any
# 192.168.3.x (prod's HAProxy VIPs), a DHCP server reply (udp sport 67), a BGP SYN (tcp dport
# 179), anything sourced from .1 or 3.0/24, an IPv6 router advertisement — then stops the VM and
# LATCHES (onboot 0, so a host reboot does not boot it back into the LAN). The latch is drift
# against tofu's on_boot = true: re-enabling the node is a reviewed `mgmt-tf apply`, never
# automatic. The tap is net0's, the LAN NIC tofu gives the VM.
#
# No exemptions (ADR-088 as amended 2026-09-30): the nodes' LAN is a /24, so no 192.168.3.x address
# is ever legitimate on the LAN from a node — the HAProxy VIPs live on lo0 and are reached via .1.
# The CARP trial VIP is the reserved 192.168.2.72, which no rule here matches.
set -u
vmid="$1"; logf="/var/log/router-killswitch/$vmid.log"; tap="tap${vmid}i0"
qm config "$vmid" | grep -q '^net0: virtio=' || { echo "vm $vmid: no virtio net0 — refusing to arm" >&2; exit 1; }
filt="(arp and (arp[14:4] = 0xc0a80201 or (arp[14:2] = 0xc0a8 and arp[16] = 3))) or (udp src port 67) or (tcp dst port 179 and tcp[13] & 2 != 0) or (ip src host 192.168.2.1) or (ip src net 192.168.3.0/24) or (icmp6 and ip6[40] = 134)"
echo "$(date -u +%FT%TZ) armed for vm $vmid on $tap (inbound)" >> "$logf"
while :; do
  while [ ! -e "/sys/class/net/$tap" ]; do sleep 0.2; done
  if tcpdump -Q in -l -n -e -c 1 -i "$tap" "$filt" >> "$logf" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) TRIPPED - qm stop $vmid; qm set $vmid --onboot 0" >> "$logf"
    qm stop "$vmid" --skiplock 1 >> "$logf" 2>&1   # stop FIRST: the latch's config write costs ~2 s
    qm set "$vmid" --onboot 0 >> "$logf" 2>&1
    exit 0
  fi
  sleep 0.2   # tcpdump lost the tap (VM stopped/restarted) — wait for it to come back
done
