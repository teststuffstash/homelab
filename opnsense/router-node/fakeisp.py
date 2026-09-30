#!/usr/bin/env python3
"""The fake ISP for the router pair's WAN drills (docs/router-move.md, **WAN follows the master**).

Runs INSIDE the `fakeisp` netns on a hypervisor, on the WAN segment the operator's cable joins
(nx-02 eno2 <-> pve enp6s0, both nodes' vmbr3). Stdlib only (the hypervisors carry no DHCP server):

  * DHCP: exactly ONE lease — the reserved MAC (Big Data's WAN MAC, which both nodes wear) gets
    LEASE_IP, like the real ISP's one lease; any other MAC is logged and ignored. The router
    option names SERVER_IP, as the real ISP names its gateway: OPNsense's automatic outbound NAT
    covers only interfaces WITH a gateway (without it the pair forwards un-NAT'd).
  * the "internet": a TCP server on SERVER_IP:9000 that streams `<seq> <epoch>` every 0.1 s to
    each client — a flow whose survival (NAT + pfsync + WAN handover) the client measures.

Every DHCP message is logged with its client MAC and time — the log IS the drill's evidence of
which node spoke on the WAN when.
"""
import argparse, socket, struct, sys, threading, time

p = argparse.ArgumentParser()
p.add_argument('--mac', required=True)                 # the one MAC that gets a lease
p.add_argument('--lease-ip', default='100.64.0.10')
p.add_argument('--server-ip', default='100.64.0.1')
p.add_argument('--lease-secs', type=int, default=120)
p.add_argument('--dev', default='fisp-n')              # the netns's WAN-side veth
a = p.parse_args()
MAC = bytes.fromhex(a.mac.replace(':', '').lower())

def log(*m):
    print(time.strftime('%H:%M:%S', time.gmtime()) + '.%03d' % (time.time() % 1 * 1000), *m, flush=True)

def opt(code, data): return bytes([code, len(data)]) + data

def dhcp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    # a limited broadcast needs an egress device: the netns has no default route
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, a.dev.encode())
    s.bind(('0.0.0.0', 67))
    while True:
        pkt, _ = s.recvfrom(2048)
        if len(pkt) < 240 or pkt[0] != 1: continue
        xid, chaddr = pkt[4:8], pkt[28:34]
        opts, i, mtype = pkt[240:], 0, None
        while i < len(opts) and opts[i] != 255:
            if opts[i] == 0: i += 1; continue
            if opts[i] == 53: mtype = opts[i + 2]
            i += 2 + opts[i + 1]
        name = {1: 'DISCOVER', 3: 'REQUEST', 7: 'RELEASE', 8: 'INFORM'}.get(mtype, str(mtype))
        log('dhcp', name, 'from', chaddr.hex(':'))
        if chaddr != MAC or mtype not in (1, 3): continue
        reply = 2 if mtype == 1 else 5           # OFFER / ACK
        hdr = bytearray(pkt[:240]); hdr[0] = 2
        hdr[16:20] = socket.inet_aton(a.lease_ip); hdr[20:24] = socket.inet_aton(a.server_ip)
        o = (opt(53, bytes([reply])) + opt(54, socket.inet_aton(a.server_ip))
             + opt(51, struct.pack('!I', a.lease_secs)) + opt(1, socket.inet_aton('255.255.255.0'))
             + opt(3, socket.inet_aton(a.server_ip))
             + bytes([255]))
        try:
            s.sendto(bytes(hdr) + o, ('255.255.255.255', 68))
            log('dhcp', 'OFFER' if reply == 2 else 'ACK', a.lease_ip, 'to', chaddr.hex(':'))
        except OSError as e:
            log('dhcp send failed:', e)

def stream(conn, peer):
    log('stream open', peer); n = 0
    try:
        while True:
            conn.sendall(b'%d %.3f\n' % (n, time.time())); n += 1; time.sleep(0.1)
    except OSError as e:
        log('stream closed', peer, 'after', n, 'lines:', e)

def server():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((a.server_ip, 9000)); s.listen(8)
    while True:
        c, peer = s.accept(); threading.Thread(target=stream, args=(c, peer), daemon=True).start()

threading.Thread(target=dhcp, daemon=True).start()
log('fakeisp up: lease', a.lease_ip, 'for', a.mac, 'lease', a.lease_secs, 's; stream on', a.server_ip + ':9000')
server()
