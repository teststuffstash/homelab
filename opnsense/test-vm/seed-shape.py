#!/usr/bin/env python3
"""Reshape a rendered test-VM seed config.xml for the ROUTER REHEARSAL (FU-297).

    python3 opnsense/test-vm/seed-shape.py SEED.xml [--router --wan-mac MAC] \
        [--carry-from PROD.xml --carry trust,acme,api-users[,wireguard]]

Edits SEED.xml in place (mode kept). Called by scripts/opnsense-test-vm-bootstrap.sh `render`
when OPN_TEST_SHAPE=router and/or OPN_TEST_CARRY_FROM is set; docs/opnsense-test-vm.md §The router
rehearsal has the why.

--router   the seed's shape becomes the future router's: `wan` = igb0 (the passed-through NIC,
           DHCP, MAC spoofed to the old router's WAN NIC — the ISP lease follows the MAC), and the
           seed's vmbr0 interface (vtnet1, static, the prod router as gateway) moves to `opt9`
           "MGMT" — the rehearsal's management path + egress, which the real router will not
           have. `opt9`, not `opt1`: prod's opt1..3 are its spare card ports, and the score
           aligns interfaces by key. Every rule/gateway that named `wan` follows to `opt9`.
--carry    copy router IDENTITY from a decrypted prod config.xml (the FU-013 backup) so what the
           consumers hold keeps working on the new box — never anything the playbooks own:
             trust      every <cert> + <ca> (refids intact — HAProxy binds certs by refid) and
                        the web GUI's ssl-certref
             acme       OPNsense/AcmeClient whole: the REGISTERED account (so no re-register —
                        FU-298's 404 never runs) + the certificate rows bound to those refids
             api-users  the non-root users of group_vars opnsense_api_users (backup-puller,
                        automation) with their API keys (hashed), and root's prod API key lines
                        appended to the seed's own — so every consumer's key authenticates
             wireguard  OPNsense/wireguard whole: the server keypair (so the road-warrior
                        clients need no re-issue — operator ruling 2026-09-30) + its peers
The input holds every router secret: never print a value. Output = the seed, which the bootstrap
burns onto a 0600 ISO on nx-02 and deletes after the first boot.
"""
import argparse, os, re, sys
import xml.etree.ElementTree as ET

ap = argparse.ArgumentParser()
ap.add_argument("seed")
ap.add_argument("--router", action="store_true")
ap.add_argument("--wan-mac", default="")
ap.add_argument("--carry-from")
ap.add_argument("--carry", default="")
ap.add_argument("--api-users", default="backup-puller,automation")
a = ap.parse_args()

tree = ET.parse(a.seed)
root = tree.getroot()


def die(msg):
    sys.exit("seed-shape: " + msg)


if a.router:
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", a.wan_mac or ""):
        die("--router needs --wan-mac aa:bb:cc:dd:ee:ff (lowercase)")
    ifs = root.find("interfaces")
    wan = ifs.find("wan")
    if wan is None or wan.findtext("if") != "vtnet1":
        die("the seed's wan is not vtnet1 — not the template this expects")
    wan.tag = "opt9"
    wan.find("descr").text = "MGMT"
    new = ET.Element("wan")
    for tag, text in (("enable", "1"), ("if", "igb0"), ("spoofmac", a.wan_mac), ("ipaddr", "dhcp"),
                      ("gateway", "WAN_GW"), ("blockpriv", "1"), ("blockbogons", "1")):
        ET.SubElement(new, tag).text = text
    ifs.insert(0, new)
    gws = root.find("gateways")
    for gw in gws.findall("gateway_item"):
        if gw.findtext("interface") == "wan":
            gw.find("interface").text = "opt9"
            gw.find("name").text = "MGMT_GW"
            # Both gateways are "default"; the lowest priority that has an address wins, and the
            # WAN's dynamic one has none while uncabled — so egress stays on MGMT.
            ET.SubElement(gw, "priority").text = "1"
    # The WAN's gateway as prod has it: dynamic (DHCP), default, unmonitored.
    wgw = ET.SubElement(gws, "gateway_item")
    for tag, text in (("interface", "wan"), ("gateway", "dynamic"), ("name", "WAN_GW"),
                      ("weight", "1"), ("ipprotocol", "inet"), ("priority", "255"),
                      ("defaultgw", "1"), ("monitor_disable", "1"), ("descr", "WAN Gateway")):
        ET.SubElement(wgw, tag).text = text
    for iface in (ifs.find("opt9"),):
        g = iface.find("gateway")
        if g is not None and g.text == "WAN_GW":
            g.text = "MGMT_GW"
    for rule in root.iter("rule"):
        i = rule.find("interface")
        if i is not None and i.text == "wan":
            i.text = "opt9"
        for n in rule.iter("network"):
            if n.text == "wanip":
                n.text = "opt9ip"

if a.carry_from:
    items = {x for x in a.carry.split(",") if x}
    unknown = items - {"trust", "acme", "api-users", "wireguard"}
    if unknown or not items:
        die("--carry takes trust,acme,api-users,wireguard (got %r)" % a.carry)
    prod = ET.parse(a.carry_from).getroot()
    if prod.tag != "opnsense":
        die("--carry-from is not an OPNsense config.xml")
    carried = []

    def put_section(path):  # replace (or add) OPNsense/<name> with prod's copy
        parent_path, name = path.rsplit("/", 1)
        src = prod.find(path)
        if src is None:
            die("prod has no %s" % path)
        parent = root.find(parent_path)
        if parent is None:
            parent = ET.SubElement(root, parent_path)
        old = parent.find(name)
        if old is not None:
            parent.remove(old)
        parent.append(src)
        carried.append("%s (%d children)" % (path, len(src)))

    if "trust" in items:
        for tag in ("ca", "cert"):
            for old in root.findall(tag):
                root.remove(old)
            for el in prod.findall(tag):
                root.append(el)
            carried.append("%d <%s>" % (len(prod.findall(tag)), tag))
        ref = prod.findtext("system/webgui/ssl-certref")
        if ref:
            web = root.find("system/webgui")
            el = web.find("ssl-certref")
            if el is None:
                el = ET.SubElement(web, "ssl-certref")
            el.text = ref
            carried.append("webgui ssl-certref")
    if "acme" in items:
        if "trust" not in items:
            die("acme without trust leaves the certificate rows pointing at refids that do not exist")
        put_section("OPNsense/AcmeClient")
    if "wireguard" in items:
        put_section("OPNsense/wireguard")
    if "api-users" in items:
        system = root.find("system")
        names = [n for n in a.api_users.split(",") if n]
        uids = [0]
        for n in names:
            src = next((u for u in prod.findall("system/user") if u.findtext("name") == n), None)
            if src is None:
                die("prod has no user %s" % n)
            for old in [u for u in system.findall("user") if u.findtext("name") == n]:
                system.remove(old)
            system.append(src)
            uids.append(int(src.findtext("uid") or 0))
        nxt = system.find("nextuid")
        if nxt is None:
            nxt = ET.SubElement(system, "nextuid")
        nxt.text = str(max(int(nxt.text or 0), max(uids) + 1, 2000))
        # root: the seed's own (throwaway) pair stays first — the harness uses it — and prod's
        # key lines follow, so a consumer holding root's prod key authenticates here too.
        seed_root = next(u for u in system.findall("user") if u.findtext("name") == "root")
        prod_root = next(u for u in prod.findall("system/user") if u.findtext("name") == "root")
        pk = seed_root.find("apikeys")
        prod_keys = prod_root.find("apikeys")
        if prod_keys is not None and len(prod_keys):  # the 26.x <item><key/><secret/></item> form
            die("prod root apikeys are in the item form — extend this carry before using it")
        prod_lines = [l for l in (prod_root.findtext("apikeys") or "").splitlines() if l.strip()]
        pk.text = "\n".join([l for l in (pk.text or "").splitlines() if l.strip()] + prod_lines)
        carried.append("users %s + %d root key line(s)" % (",".join(names), len(prod_lines)))
    print("seed-shape: carried " + "; ".join(carried), file=sys.stderr)

if a.router:
    print("seed-shape: router shape — wan=igb0 dhcp spoofmac, vtnet1 → opt9 MGMT", file=sys.stderr)

tree.write(a.seed, encoding="unicode", xml_declaration=True)
