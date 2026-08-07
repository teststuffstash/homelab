#!/usr/bin/env python3
"""Fence the Tuya devices off the internet (config-as-code). FU-038.

They are LAN-only by design since 2026-08-07: `tuya_local` polls them over TCP 6668 and the Tuya
cloud is needed ONLY for pairing and local_key extraction. Blocking egress is what turns
"cloud-capable" into "cloud-denied" — and it is what would have made the nine-day Tuya cloud
freeze a non-event instead of an outage.

WHY FENCED BY ADDRESS AND NOT BY VLAN/SSID — two independent reasons:
  1. A device must reach the cloud ONCE, during pairing. A permanently-blocked IoT SSID could
     never onboard one.
  2. Moving them to a new SSID/VLAN now would force a re-pair, and re-pairing ROTATES every
     local_key — invalidating the material in the wallet (`tuya-local`/devices.json). That cost
     did not exist before the keys were extracted; it does now.
So they stay on the LAN and are fenced by address: block <tuya_devices> -> NOT <rfc1918>.
Internet dies; Home Assistant keeps polling them on the LAN, and they can still reach the router
for DNS/NTP (some Tuya firmware sulks without NTP).

⚠ The fence is only as strong as the DHCP pins in opnsense/dnsmasq-dhcp.py. If a device gets a new
address it silently leaves the fence — which is the same failure that would break tuya_local, so
both depend on those reservations.

TO PAIR A NEW DEVICE (or re-extract a rotated local_key): remove its IP from HOSTS below and
re-run, pair/extract, then put it back and re-run. Re-extraction needs the cloud too, so it is the
same door for both.

Why python and not the ansible opnsense role: the `oxlorg.opnsense.raw` module fails
`missing required arguments: firewall` on the firewall/* endpoints in the pinned collection
(25.7.8) regardless of module/controller/command or url form, while the same REST calls work
directly. This follows dnsmasq-dhcp.py, the established pattern for OPNsense config-as-code here.

Run:
    export OPN_API_KEY=...  OPN_API_SECRET=...      # same creds as ansible/opnsense-*.yml
    python3 opnsense/tuya-egress.py                 # idempotent
    python3 opnsense/tuya-egress.py --status        # show state, change nothing
"""
import base64, json, os, ssl, sys, urllib.request

HOST = os.environ.get("OPN_HOST", "192.168.2.1")
KEY = os.environ["OPN_API_KEY"]
SEC = os.environ["OPN_API_SECRET"]
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
AUTH = "Basic " + base64.b64encode(f"{KEY}:{SEC}".encode()).decode()

# The 7 devices, by their DHCP-reserved addresses (opnsense/dnsmasq-dhcp.py).
HOSTS = [
    ("192.168.2.215", "K&M black 1  -> pve"),
    ("192.168.2.16",  "Smart plug 2 -> opnsense"),
    ("192.168.2.209", "Smart plug 3 -> laptop3 / wk-metal-01"),
    ("192.168.2.130", "Smart plug 4 -> laptop4 / wk-metal-02"),
    ("192.168.2.139", "NOUS A1      -> aquarium"),
    ("192.168.2.80",  "NOUS A1      -> konditsioneer"),
    ("192.168.2.243", "Temp-5       -> gaas"),
]
ALIASES = [
    {"name": "rfc1918", "type": "network",
     "description": "private networks (RFC1918) - inverted to mean 'the internet' in egress fences",
     "content": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]},
    {"name": "tuya_devices", "type": "host",
     "description": "Tuya plugs/sensors - LAN-only (FU-038)",
     "content": [ip for ip, _ in HOSTS]},
]
RULE_DESC = "tuya: LAN-only, no internet egress (FU-038)"
RULE = {
    "enabled": "1", "sequence": "50", "action": "block", "quick": "1",
    "interface": "lan", "direction": "in", "ipprotocol": "inet", "protocol": "any",
    "source_net": "tuya_devices",
    "destination_net": "rfc1918", "destination_not": "1",   # i.e. destination == the internet
    "log": "1",              # so "it stopped working" can be checked against real drops
    "description": RULE_DESC,
}


def call(path, body=None):
    req = urllib.request.Request(f"https://{HOST}/api/{path}", data=json.dumps(body or {}).encode(),
        method="POST", headers={"Authorization": AUTH, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=25) as r:
        return json.loads(r.read().decode())


def status():
    al = {r["name"]: r for r in call("firewall/alias/searchItem").get("rows", [])}
    print("aliases:")
    for a in ALIASES:
        row = al.get(a["name"])
        print(f"  {a['name']:14} {'present' if row else 'MISSING'}")
    rules = [r for r in call("firewall/filter/searchRule").get("rows", [])
             if r.get("description") == RULE_DESC]
    print(f"rule: {'present, enabled=' + str(rules[0].get('enabled')) if rules else 'MISSING'}")
    return bool(rules)


def main():
    if "--status" in sys.argv:
        status(); return
    print("Applying the Tuya egress fence...")
    live = {r["name"]: r for r in call("firewall/alias/searchItem").get("rows", [])}
    for a in ALIASES:
        body = {"alias": {"enabled": "1", "name": a["name"], "type": a["type"],
                          "content": "\n".join(a["content"]), "description": a["description"]}}
        if a["name"] in live:
            # setItem, not addItem: content drifts when a device is added/removed and addItem
            # will not correct an existing alias.
            res = call(f"firewall/alias/setItem/{live[a['name']]['uuid']}", body)
            print(f"  ~ alias {a['name']}: {res.get('result')}")
        else:
            res = call("firewall/alias/addItem", body)
            print(f"  + alias {a['name']}: {res.get('result')}")
    print("  apply aliases:", call("firewall/alias/reconfigure").get("status"))

    have = [r for r in call("firewall/filter/searchRule").get("rows", [])
            if r.get("description") == RULE_DESC]
    if have:
        print(f"  = rule already present ({len(have)})")
    else:
        print("  + rule:", call("firewall/filter/addRule", {"rule": RULE}).get("result"))
    print("  apply firewall:", call("firewall/filter/apply").get("status"))
    print()
    status()


if __name__ == "__main__":
    main()
