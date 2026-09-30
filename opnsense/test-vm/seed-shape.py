#!/usr/bin/env python3
"""Reshape a rendered test-VM seed config.xml for the ROUTER REHEARSAL (FU-297).

    python3 opnsense/test-vm/seed-shape.py SEED.xml [--router --wan-mac MAC] \
        [--standing --wan-mac MAC --lan-ip A.B.C.D/NN --lan-gw A.B.C.D] \
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
--standing a STANDING router node (ADR-144, docs/router-move.md §The standing nodes): vtnet0 on
           vmbr0 is the node's LAN at its own address (--lan-ip, prod's /22) and its management
           path; vtnet1 on the host WAN bridge is the WAN (DHCP, spoofed MAC, prod's blockpriv/
           bogons). Its own egress while standing: a LAN gateway to prod's .1 (priority 1, beats
           the dark WAN's dynamic gateway). INERT AT BIRTH: dnsmasq (DHCP) off, the test
           template's WAN rules (the management pass rules + the BGP block) dropped, and a carried
           ACME client's auto-renewal OFF — the plays then converge the standby profile.
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
# The WAN's FreeBSD interface: igb0 = the passed-through I350 port; vtnet2 = the bridged shape
# (virtio on a host bridge over the same port — docs/router-move.md, operator 2026-09-30).
ap.add_argument("--wan-if", default="igb0", choices=["igb0", "vtnet2"])
ap.add_argument("--standing", action="store_true")
ap.add_argument("--lan-ip", default="")
ap.add_argument("--lan-gw", default="")
ap.add_argument("--carry-from")
ap.add_argument("--carry", default="")
ap.add_argument("--api-users", default="backup-puller,automation")
a = ap.parse_args()

tree = ET.parse(a.seed)
root = tree.getroot()


def die(msg):
    sys.exit("seed-shape: " + msg)


if a.router and a.standing:
    die("--router and --standing are different shapes")

if a.standing:
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", a.wan_mac or ""):
        die("--standing needs --wan-mac aa:bb:cc:dd:ee:ff (lowercase)")
    m = re.fullmatch(r"(\d+\.\d+\.\d+\.\d+)/(\d+)", a.lan_ip or "")
    if not m or not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", a.lan_gw or ""):
        die("--standing needs --lan-ip A.B.C.D/NN and --lan-gw A.B.C.D")
    if m.group(1) in ("192.168.2.1", a.lan_gw):
        die("--lan-ip %s is the prod router's address — a standing node never holds it" % m.group(1))
    ifs = root.find("interfaces")
    wan, lan = ifs.find("wan"), ifs.find("lan")
    if wan is None or wan.findtext("if") != "vtnet1" or lan is None or lan.findtext("if") != "vtnet0":
        die("the seed is not the template's wan=vtnet1 / lan=vtnet0 shape")
    # NO <gateway> on the lan interface: an interface gateway makes pf add `reply-to` to its
    # pass rules, so the API's SYN-ACK to a same-subnet client would leave via prod's .1 (the
    # template's disablereplyto lesson). The LAN_GW item below still carries the default route.
    for tag, text in (("ipaddr", m.group(1)), ("subnet", m.group(2))):
        el = lan.find(tag)
        if el is None:
            el = ET.SubElement(lan, tag)
        el.text = text
    ifs.remove(wan)
    new = ET.Element("wan")
    for tag, text in (("enable", "1"), ("if", "vtnet1"), ("descr", "WAN"), ("spoofmac", a.wan_mac),
                      ("ipaddr", "dhcp"), ("gateway", "WAN_GW"), ("blockpriv", "1"), ("blockbogons", "1")):
        ET.SubElement(new, tag).text = text
    ifs.insert(0, new)
    gws = root.find("gateways")
    for gw in list(gws.findall("gateway_item")):
        gws.remove(gw)
    for spec in ((("interface", "lan"), ("gateway", a.lan_gw), ("name", "LAN_GW"), ("weight", "1"),
                  ("ipprotocol", "inet"), ("priority", "1"), ("defaultgw", "1"),
                  ("descr", "standing: egress via the live router until the cutover")),
                 (("interface", "wan"), ("gateway", "dynamic"), ("name", "WAN_GW"), ("weight", "1"),
                  ("ipprotocol", "inet"), ("priority", "255"), ("defaultgw", "1"),
                  ("monitor_disable", "1"), ("descr", "WAN Gateway"))):
        g = ET.SubElement(gws, "gateway_item")
        for tag, text in spec:
            ET.SubElement(g, tag).text = text
    flt = root.find("filter")
    for rule in [r for r in flt.findall("rule") if r.findtext("interface") == "wan"]:
        flt.remove(rule)
    dm = root.find("dnsmasq")
    dm.find("enable").text = "0"

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
    for tag, text in (("enable", "1"), ("if", a.wan_if), ("spoofmac", a.wan_mac), ("ipaddr", "dhcp"),
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
        if a.standing:  # never renew FROM a standing node — prod's own renewal would be raced
            st = root.find("OPNsense/AcmeClient/settings")
            ar = st.find("autoRenewal") if st is not None else None
            if ar is None:
                die("carried AcmeClient has no settings/autoRenewal — cannot make it inert")
            ar.text = "0"
            carried.append("acme autoRenewal → 0 (standing)")
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
        # A seed line whose KEY prod already holds (a standing node seeds with prod's own pair)
        # gives way to prod's line: one entry per key, exactly prod's.
        prod_ids = {l.split("|", 1)[0] for l in prod_lines}
        seed_lines = [l for l in (pk.text or "").splitlines() if l.strip() and l.split("|", 1)[0] not in prod_ids]
        pk.text = "\n".join(seed_lines + prod_lines)
        carried.append("users %s + %d root key line(s)" % (",".join(names), len(prod_lines)))
    print("seed-shape: carried " + "; ".join(carried), file=sys.stderr)

if a.standing:
    print("seed-shape: standing shape — lan=vtnet0 %s (LAN_GW %s), wan=vtnet1 dhcp spoofmac, DHCP off" % (a.lan_ip, a.lan_gw), file=sys.stderr)
if a.router:
    print("seed-shape: router shape — wan=igb0 dhcp spoofmac, vtnet1 → opt9 MGMT", file=sys.stderr)

tree.write(a.seed, encoding="unicode", xml_declaration=True)
