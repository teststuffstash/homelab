#!/usr/bin/env python3
"""Configure OPNsense dnsmasq as the LAN DHCP server (config-as-code).

Replaces the deprecated ISC dhcpd (which has no settings API) with dnsmasq, which
DOES expose a clean API. dnsmasq here is DHCP-only (port=0) so Unbound keeps :53.
Idempotent: clears and rebuilds the DHCP arrays, then sets general + applies.

PXE/iPXE is intentionally NOT configured here — OPNsense's dnsmasq plugin doesn't
expose pxe-service and won't emit the bootfile. PXE boot is delivered by a dnsmasq
proxy-DHCP on the Matchbox LXC instead (see ansible/matchbox-proxydhcp.yml).

Run:
    export OPN_API_KEY=...  OPN_API_SECRET=...      # same creds as ansible/opnsense-*.yml
    python3 opnsense/dnsmasq-dhcp.py

Reboot-safety: ISC dhcpd must also be DISABLED. There is no API for it — uncheck
Services > ISC DHCPv4 > [LAN] > Enable in the OPNsense UI (one-time manual step).
"""
import base64, json, os, ssl, sys, urllib.request

HOST = os.environ.get("OPN_HOST", "192.168.2.1")
KEY = os.environ["OPN_API_KEY"]
SEC = os.environ["OPN_API_SECRET"]
BASE = f"https://{HOST}/api/dnsmasq"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
AUTH = "Basic " + base64.b64encode(f"{KEY}:{SEC}".encode()).decode()

# --- LAN DHCP definition (mirrors the migrated-from ISC dhcpd config) -----------
INTERFACE = "lan"
RANGE = {"interface": INTERFACE, "start_addr": "192.168.2.10", "end_addr": "192.168.2.245",
         "subnet_mask": "255.255.255.0", "lease_time": "7200", "domain_type": "range",
         "domain": "teststuff.net", "description": "LAN pool"}
OPTIONS = [  # explicit router + DNS so clients get the gateway / Unbound resolver
    {"type": "set", "option": "3", "interface": INTERFACE, "value": "192.168.2.1"},
    {"type": "set", "option": "6", "interface": INTERFACE, "value": "192.168.2.1"},
]
HOSTS = [  # static reservations preserved from ISC
    {"host": "netboot", "hwaddr": "00:1e:37:8c:a2:8f", "ip": "192.168.2.2"},
    {"host": "pve", "hwaddr": "22:24:4d:07:03:76", "ip": "192.168.2.3"},
    {"host": "BRN_8D63B8", "hwaddr": "00:80:77:8d:63:b8", "ip": "192.168.2.4"},
    # bare-metal Talos worker (ThinkPad X240) — pinned so the maintenance-mode IP
    # == the ongoing node IP (clean tofu apply target).
    {"host": "wk-metal-01", "hwaddr": "50:7b:9d:01:b3:54", "ip": "192.168.2.182"},
    # ThinkCentre Edge — reserved for later (flaky PXE firmware; onboard via USB ISO).
    {"host": "thinkcentre", "hwaddr": "8c:89:a5:23:49:da", "ip": "192.168.2.53"},
    # HP desktop — bare-metal Talos worker (storage-tier candidate).
    {"host": "hp-01", "hwaddr": "b4:b5:2f:df:01:bc", "ip": "192.168.2.54"},
    # Droplet ESP32 plant-waterer — pin its canonical .245 (was a bare dynamic lease
    # under ISC; drifted to .19 after the dnsmasq migration, which broke HA's ESPHome
    # integration that's addressed at .245). Any HA/integration device referenced by a
    # fixed IP needs a reservation here.
    {"host": "droplettest", "hwaddr": "30:c6:f7:22:a8:fc", "ip": "192.168.2.245"},
]


def call(path, body=None):
    req = urllib.request.Request(f"{BASE}/{path}", data=json.dumps(body or {}).encode(),
        method="POST", headers={"Authorization": AUTH, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=CTX, timeout=20) as r:
        return json.loads(r.read().decode())


def rebuild(item, key, rows):
    for r in call(f"settings/search{item}").get("rows", []):
        call(f"settings/del{item}/{r['uuid']}")
    for obj in rows:
        res = call(f"settings/add{item}", {key: obj}).get("result")
        print(f"  + {item}: {res}")


def main():
    print("Rebuilding dnsmasq DHCP config...")
    rebuild("Range", "range", [RANGE])
    rebuild("Option", "option", OPTIONS)
    rebuild("Host", "host", HOSTS)
    print("set general (enable, DNS off, bind LAN):",
          call("settings/set", {"dnsmasq": {"enable": "1", "port": "0", "interface": INTERFACE}}).get("result"))
    print("apply:", call("service/reconfigure").get("status"))
    print("\nDone. Remember: disable ISC DHCPv4 in the OPNsense UI for reboot-safety.")


if __name__ == "__main__":
    if not (KEY and SEC):
        sys.exit("set OPN_API_KEY and OPN_API_SECRET")
    main()
