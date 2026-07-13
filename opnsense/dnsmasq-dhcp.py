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
# DHCP pool starts at .100 so .2-.99 is a generous STATIC range (cluster LAN VIPs,
# infrastructure, reservations). Was .10-.245 (only .2-.9 static, which filled up).
# Devices that were leased below .100 are pinned via HOSTS below so they don't
# renumber; new dynamic clients land in .100-.245 (146 addrs, ample).
RANGE = {"interface": INTERFACE, "start_addr": "192.168.2.100", "end_addr": "192.168.2.245",
         "subnet_mask": "255.255.255.0", "lease_time": "7200", "domain_type": "range",
         "domain": "teststuff.net", "description": "LAN pool"}
OPTIONS = [  # explicit router + DNS so clients get the gateway / Unbound resolver
    {"type": "set", "option": "3", "interface": INTERFACE, "value": "192.168.2.1"},
    {"type": "set", "option": "6", "interface": INTERFACE, "value": "192.168.2.1"},
]
HOSTS = [  # static reservations preserved from ISC
    {"host": "pve", "hwaddr": "22:24:4d:07:03:76", "ip": "192.168.2.3"},
    {"host": "BRN_8D63B8", "hwaddr": "00:80:77:8d:63:b8", "ip": "192.168.2.4"},
    # bare-metal Talos worker (ThinkPad X240) — pinned so the maintenance-mode IP
    # == the ongoing node IP (clean tofu apply target).
    {"host": "wk-metal-01", "hwaddr": "50:7b:9d:01:b3:54", "ip": "192.168.2.182"},
    # bare-metal Talos worker (ThinkPad X250) — same maintenance==node pinning, adjacent .183.
    {"host": "wk-metal-02", "hwaddr": "68:f7:28:80:84:09", "ip": "192.168.2.183"},
    {"host": "wk-metal-03", "hwaddr": "c8:5b:76:fa:8e:fb", "ip": "192.168.2.184"},  # kata spike laptop
    # ThinkCentre Edge — storage-tier worker (its "flaky PXE" was a bad NIC cable, fixed 2026-06-11;
    # PXE-onboards fine now).
    {"host": "thinkcentre", "hwaddr": "8c:89:a5:23:49:da", "ip": "192.168.2.53"},
    # HP desktop — bare-metal Talos worker (storage-tier candidate).
    {"host": "hp-01", "hwaddr": "b4:b5:2f:df:01:bc", "ip": "192.168.2.54"},
    # Droplet ESP32 plant-waterer — pin its canonical .245 (was a bare dynamic lease
    # under ISC; drifted to .19 after the dnsmasq migration, which broke HA's ESPHome
    # integration that's addressed at .245). Any HA/integration device referenced by a
    # fixed IP needs a reservation here.
    {"host": "office-plants-irrigation", "hwaddr": "30:c6:f7:22:a8:fc", "ip": "192.168.2.245"},
    # --- pinned so they survive the .10->.100 pool move (were dynamic leases <.100) ---
    # UniFi network backbone — keep the switch + APs at stable IPs.
    {"host": "USW-Lite-8-PoE", "hwaddr": "68:d7:9a:5d:bb:48", "ip": "192.168.2.11"},
    {"host": "U6Lite2ndfloor", "hwaddr": "f4:92:bf:aa:1b:08", "ip": "192.168.2.12"},
    {"host": "UAP-AC-LiteOffice", "hwaddr": "e0:63:da:70:2e:28", "ip": "192.168.2.14"},
    {"host": "U6LiteBasement", "hwaddr": "f4:92:bf:aa:1e:10", "ip": "192.168.2.63"},
    # named leaf devices referenced by IP elsewhere / worth keeping stable.
    {"host": "lwip0", "hwaddr": "c0:f8:53:db:62:80", "ip": "192.168.2.16"},
    {"host": "rockrobo", "hwaddr": "7c:49:eb:9f:bf:f4", "ip": "192.168.2.26"},
    {"host": "ESP-1CF343", "hwaddr": "c4:dd:57:1c:f3:43", "ip": "192.168.2.80"},
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
