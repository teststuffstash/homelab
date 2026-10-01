#!/usr/bin/env python3
"""Flow + ping probe for the router pair's failover drills (docs/router-move.md).

Run on a LAN host whose route to the fake ISP's server goes via the CARP trial VIP. For SECS
seconds it (1) holds ONE TCP connection to the fake ISP's stream (SERVER:9000) — never reconnecting,
so "the flow survived" means exactly that — and (2) sends a UDP-free ICMP-free liveness check: a
fresh TCP connect every 0.1 s to the same port (new flows = what a client opening a connection sees).
Prints one summary line per signal: the longest receive gap on the held flow + whether it died, and
the longest run of failed fresh connects.
"""
import socket, sys, threading, time
server, secs = sys.argv[1], float(sys.argv[2])
t_end = time.time() + secs
held = {'gap': 0.0, 'died': None, 'lines': 0, 'gaps': [], 'tail': 0.0}

def hold():
    try: s = socket.create_connection((server, 9000), timeout=5); s.settimeout(0.5)
    except OSError as e: held['died'] = 'never connected: %s' % e; return
    last, buf = time.time(), b''
    while time.time() < t_end:
        try:
            d = s.recv(4096)
            if not d: held['died'] = 'EOF %.2f' % (time.time() - t_end + secs); return
            now = time.time(); g = now - last
            if g > 0.3: held['gaps'].append((round(now - (t_end - secs) - g, 2), round(g, 2)))
            held['gap'] = max(held['gap'], g); last = now; held['lines'] += d.count(b'\n'); held['tail'] = 0.0
        except socket.timeout:
            held['tail'] = time.time() - last   # a stall still open at the end counts too
            continue
        except OSError as e: held['died'] = '%s at +%.2fs' % (e, time.time() - t_end + secs); return

threading.Thread(target=hold, daemon=True).start()
fails, run, worst, t0 = [], 0, 0, time.time()
while time.time() < t_end:
    t = time.time()
    try: socket.create_connection((server, 9000), timeout=0.25).close(); ok = True
    except OSError: ok = False
    if ok:
        if run: fails.append((round(t - t0 - run * 0.1, 2), round(run * 0.1, 1)))
        run = 0
    else: run += 1; worst = max(worst, run)
    time.sleep(max(0, 0.1 - (time.time() - t)))
time.sleep(0.6)
if run: fails.append((round(time.time() - t0 - run * 0.1, 2), round(run * 0.1, 1)))   # open at the end
stalled = held['tail'] > 1.0
print('held flow: %s, %d lines, longest gap %.2fs, gaps>0.3s %s' % (
    'DIED ' + held['died'] if held['died'] else ('STALLED at end (%.1fs)' % held['tail'] if stalled else 'SURVIVED'),
    held['lines'], max(held['gap'], held['tail']), held['gaps']))
print('fresh connects: longest outage %.1fs, outages %s%s' % (worst * 0.1, fails, ' (last still open)' if run else ''))
