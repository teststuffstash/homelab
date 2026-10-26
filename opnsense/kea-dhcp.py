#!/usr/bin/env python3
"""Configure OPNsense Kea DHCPv4 as the LAN DHCP server (config-as-code) — ADR-145.

The router pair's DHCP: Kea replaces dnsmasq at the cutover (docs/router-move.md §The two
windows). Kea's HA hook (hot-standby, lease sync between the nodes) is what lets a second node
join and the first stop without a client noticing; dnsmasq has no CARP awareness.

The LAN data — pool, lease time, gateway/DNS, the static reservations — is NOT restated here: it
is read from opnsense/dnsmasq-dhcp.py (RANGE / OPTIONS / HOSTS), its one home while prod still
serves from dnsmasq (node-maintenance.sh, the drill and the mgmt box parse that file). It moves
when dnsmasq retires.

Idempotent: clears and rebuilds the subnet + reservations (the Kea API has no upsert), sets
general + HA + the control agent, applies. Leases live in Kea's local memfile — no database.

Run:
    export OPN_API_KEY=...  OPN_API_SECRET=...  OPN_HOST=<node>
    python3 opnsense/kea-dhcp.py
Env:
    OPN_DHCP_SERVER     kea (the default since window 1 — defined in dnsmasq-dhcp.py) = serve from
                        Kea; dnsmasq (Big Data, the fallback) = Kea converges OFF and empty
    OPN_DHCP_ENABLE=0   the STANDBY profile — config converges, the server stays off
    OPN_DHCP_REMAP      test boxes only (see dnsmasq-dhcp.py); refused against the router
    OPN_KEA_HA          unset = HA off (a node serving alone). Else "<this-name>;<peers>" with
                        <peers> = "name=url=role,..." — e.g.
                        "opnsense-nx02;opnsense-nx02=http://192.168.2.70:8001/=primary,opnsense-pve=http://192.168.2.71:8001/=standby"
                        Each URL is that node's OWN address on a port other than the control
                        agent's (8000); the peer list is identical on both nodes.
    OPN_CHECK=1         READ-ONLY: print each difference + an ansible-shaped recap line, write
                        nothing (dnsmasq-dhcp.py's contract — the box applier's --check)
"""
import base64, json, os, runpy, ssl, sys, urllib.error, urllib.request

HOST = os.environ.get("OPN_HOST", "192.168.2.1")
ENABLE = os.environ.get("OPN_DHCP_ENABLE", "1")
KEY = os.environ["OPN_API_KEY"]
SEC = os.environ["OPN_API_SECRET"]
HA = os.environ.get("OPN_KEA_HA", "")
BASE = f"https://{HOST}/api/kea"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
AUTH = "Basic " + base64.b64encode(f"{KEY}:{SEC}".encode()).decode()

# The LAN data, remapped by the same OPN_DHCP_REMAP rule (and refusal) as dnsmasq's run.
_lan = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "dnsmasq-dhcp.py"),
                      run_name="kea-dhcp")
RANGE, OPTIONS, HOSTS, SERVER = _lan["RANGE"], _lan["OPTIONS"], _lan["HOSTS"], _lan["SERVER"]
INTERFACE = RANGE["interface"]
OPT = {o["option"]: o["value"] for o in OPTIONS}          # 3 = router, 6 = DNS
_net = RANGE["start_addr"].rsplit(".", 1)[0]
SUBNET = {
    "subnet": f"{_net}.0/24",
    "pools": f"{RANGE['start_addr']}-{RANGE['end_addr']}",
    "valid_lifetime": RANGE["lease_time"],
    # Autocollect OFF: it takes the first interface address inside the subnet — on a router
    # node that is the node's own .70/.71, not the CARP VIP every client must use.
    "option_data_autocollect": "0",
    "option_data": {"routers": OPT["3"], "domain_name_servers": OPT["6"],
                    "domain_name": RANGE["domain"]},
    # Ping before offering: at the cutover Kea starts with no lease history while clients
    # still hold dnsmasq's leases — an address in use answers and is not handed out twice.
    "ping_check": "1",
    "description": RANGE["description"],
}


def call(path, body=None, method="POST"):
    get = method == "GET"   # a GET with a JSON content-type is a 400 on OPNsense
    req = urllib.request.Request(f"{BASE}/{path}", data=None if get else json.dumps(body or {}).encode(),
        method=method, headers={"Authorization": AUTH, **({} if get else {"Content-Type": "application/json"})})
    with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
        return json.loads(r.read().decode())


def must(res, what):
    if res.get("result") != "saved":
        sys.exit(f"{what}: {json.dumps(res)}")
    return res


def wipe(item):
    for r in call(f"dhcpv4/search_{item}").get("rows", []):
        call(f"dhcpv4/del_{item}/{r['uuid']}")


def ha_config():
    if not HA:
        return {"enabled": "0", "this_server_name": ""}, []
    this, peers = HA.split(";", 1)
    rows = []
    for p in peers.split(","):
        name, rest = p.split("=", 1)
        url, role = rest.rsplit("=", 1)
        rows.append({"name": name, "url": url, "role": role})
    if this not in [r["name"] for r in rows]:
        sys.exit(f"OPN_KEA_HA: this node '{this}' is not in the peer list")
    return {"enabled": "1", "this_server_name": this}, rows


def off():
    """Kea not selected: converge to disabled and empty — a no-op where Kea was never touched
    (prod before the cutover; a fresh drill VM), so the drill scores no Kea rows against prod."""
    cur = call("dhcpv4/get", method="GET")["dhcpv4"]
    left = sum(len(call(f"dhcpv4/search_{i}").get("rows", [])) for i in ("subnet", "reservation", "peer"))
    if (cur["general"]["enabled"] == "0" and cur["ha"]["enabled"] == "0"
            and not cur["ha"]["this_server_name"] and not left):
        print(f"Kea not selected (OPN_DHCP_SERVER={SERVER}) and untouched on {HOST} — nothing to do")
        return
    print(f"Kea not selected (OPN_DHCP_SERVER={SERVER}) — clearing {left} rows, disabling")
    wipe("reservation"); wipe("subnet"); wipe("peer")
    must(call("dhcpv4/set", {"dhcpv4": {"general": {"enabled": "0"}, "ha": {"enabled": "0", "this_server_name": ""}}}), "general")
    must(call("ctrl_agent/set", {"ctrlagent": {"general": {"enabled": "0"}}}), "ctrl_agent")
    print("apply:", call("service/reconfigure").get("status"))


CHECK = os.environ.get("OPN_CHECK", "0") == "1"   # READ-ONLY: diff + recap line (dnsmasq-dhcp.py's contract)


def diff():
    """Live vs the data (selected=kea): one line per difference. READ-ONLY."""
    out = []
    cur = call("dhcpv4/get", method="GET")["dhcpv4"]
    ha, peers = ha_config()
    sel = lambda v: sorted(k for k, o in v.items() if isinstance(o, dict) and str(o.get("selected")) == "1" and k) \
        if isinstance(v, dict) else sorted(x for x in str(v or "").split(",") if x)
    if str(cur["general"].get("enabled")) != ENABLE:
        out.append(f"general enabled: live {cur['general'].get('enabled')!r} != {ENABLE!r}")
    if str(cur["general"].get("fwrules")) != "1":
        out.append(f"general fwrules: live {cur['general'].get('fwrules')!r} != '1'")
    if sel(cur["general"].get("interfaces")) != [INTERFACE]:
        out.append(f"general interfaces: live {sel(cur['general'].get('interfaces'))} != [{INTERFACE!r}]")
    for k in ("enabled", "this_server_name"):
        if str(cur["ha"].get(k, "")) != ha[k]:
            out.append(f"ha {k}: live {cur['ha'].get(k)!r} != {ha[k]!r}")
    subs = call("dhcpv4/search_subnet").get("rows", [])
    want = {"subnet": SUBNET["subnet"], "pools": SUBNET["pools"], "valid_lifetime": SUBNET["valid_lifetime"],
            "option_data_autocollect": "0", "option_data.routers": OPT["3"],
            "option_data.domain_name_servers": OPT["6"], "option_data.domain_name": RANGE["domain"],
            "ping_check": "1", "description": SUBNET["description"]}
    have = [{k: str(r.get(k, "")).strip() for k in want} for r in subs]
    if have != [want]:
        out.append(f"subnet: live {have} != [{want}]")
    have = {(r.get("hostname"), r.get("ip_address"), (r.get("hw_address") or "").lower(), r.get("description"))
            for r in call("dhcpv4/search_reservation").get("rows", [])}
    wantr = {(h["host"], h["ip"], h["hwaddr"].lower(), h["host"]) for h in HOSTS}
    for h in sorted(have - wantr):
        out.append(f"reservation {h[0]} {h[1]} {h[2]}: live only (or changed)")
    for h in sorted(wantr - have):
        out.append(f"reservation {h[0]} {h[1]} {h[2]}: missing on live (or changed)")
    have = sorted((r.get("name"), r.get("url"), r.get("role")) for r in call("dhcpv4/search_peer").get("rows", []))
    if have != sorted((p["name"], p["url"], p["role"]) for p in peers):
        out.append(f"peers: live {have} != {sorted((p['name'], p['url'], p['role']) for p in peers)}")
    ca = call("ctrl_agent/get", method="GET")["ctrlagent"]["general"]
    if str(ca.get("enabled")) != ("1" if peers else "0"):
        out.append(f"ctrl_agent enabled: live {ca.get('enabled')!r}")
    return out


def recap(changed, unreachable=0, failed=0):
    print("\nPLAY RECAP *********")
    print(f"{HOST} : ok=1 changed={changed} unreachable={unreachable} failed={failed}")


def main():
    if SERVER != "kea":
        if CHECK:
            sys.exit("OPN_CHECK covers the selected server (kea) only")
        return off()
    try:
        d = diff()
    except (urllib.error.URLError, OSError) as e:
        print(f"fatal: [{HOST}]: Unable to connect {BASE}: {e}")
        recap(0, unreachable=1)
        sys.exit(4)
    for line in d:
        print(f"  ~ {line}")
    if CHECK:
        print(f"Kea on {HOST}: {len(d)} difference(s) — check mode, nothing written")
        recap(len(d))
        return
    ha, peers = ha_config()
    print(f"Rebuilding Kea DHCPv4 on {HOST} (enable={ENABLE}, ha={'on' if peers else 'off'})...")
    wipe("reservation"); wipe("subnet"); wipe("peer")      # reservations reference the subnet
    sub = must(call("dhcpv4/add_subnet", {"subnet4": SUBNET}), "subnet")["uuid"]
    print(f"  + subnet {SUBNET['subnet']} pool {SUBNET['pools']}")
    for h in HOSTS:
        must(call("dhcpv4/add_reservation", {"reservation": {
            "subnet": sub, "ip_address": h["ip"], "hw_address": h["hwaddr"],
            "hostname": h["host"], "description": h["host"]}}), f"reservation {h['host']}")
    print(f"  + {len(HOSTS)} reservations")
    for p in peers:
        must(call("dhcpv4/add_peer", {"peer": p}), f"peer {p['name']}")
        print(f"  + peer {p['name']} {p['role']} {p['url']}")
    must(call("dhcpv4/set", {"dhcpv4": {"general": {
        "enabled": ENABLE, "interfaces": INTERFACE, "fwrules": "1"}, "ha": ha}}), "general")
    # The HA hook is driven through the control agent (OPNsense's Kea docs); localhost only.
    must(call("ctrl_agent/set", {"ctrlagent": {"general": {
        "enabled": "1" if peers else "0", "http_host": "127.0.0.1", "http_port": "8000"}}}), "ctrl_agent")
    print("apply:", call("service/reconfigure").get("status"))
    recap(len(d))


if __name__ == "__main__":
    if ENABLE not in ("0", "1"):
        sys.exit("OPN_DHCP_ENABLE must be 0 or 1")
    main()
