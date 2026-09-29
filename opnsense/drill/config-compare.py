#!/usr/bin/env python3
"""Score a from-git OPNsense build against prod: config.xml compared section by section (FU-297).

    python3 opnsense/drill/config-compare.py PROD.xml DRILL.xml [--map opnsense/drill/compare-map.txt]
        [--report FILE.md] [--prom FILE.prom] [--detail FILE] [--json FILE]

Every difference between the two documents becomes a ROW, and every row lands in one bucket:

  clickops   (a) on prod and not in code (or in code and not on prod) — the REALISM SCORE is the
                 number of these rows; nothing in the map matched
  env        (b) environment-parametrized: addresses, hostnames, keys, the WAN — a `env` or
                 `remap` line in the map matched
  accepted   (c) certs, generated ids, timestamps, revision history — an `accepted` line matched

The map (opnsense/drill/compare-map.txt) is the committed, reviewable list of (b) and (c); its
header documents the syntax. Anything it does not name is (a).

How the two trees are aligned (docs/opnsense-test-vm.md §The rebuild drill):
  - A singleton child is matched by tag. A REPEATED child (or any MVC item carrying a `uuid`
    attribute) is matched by a NATURAL KEY — its name/description/address/... (KEYS below) —
    because uuids are minted per box and never agree between prod and a rebuild.
  - A field whose value is a uuid (or a comma list of them — HAProxy's linkedBackend, a route
    map reference) is compared as the KEY of the item it points to, in its own document.
  - A leaf missing on one side equals an empty leaf; a subtree missing on one side is compared
    leaf by leaf against nothing (a singleton) or counted as ONE row (a keyed item).

SECRETS: prod's config.xml holds private keys, password hashes, API key hashes and tokens. This
tool never prints, writes or exports a leaf VALUE — only paths, row kinds and counts. The
--report/--prom outputs go further and redact item keys too (`frontend[*]`); --detail keeps the
keys (hostnames, descriptions — still no values) for the operator's local triage and is written
mode 0600. Keep the inputs in memory or a 0600 tmpfile and delete them after use.
"""
import argparse, collections, hashlib, json, os, re, sys
import xml.etree.ElementTree as ET

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

# Natural keys, by the item's tag (then its parent's tag to disambiguate). Each entry is a list of
# field names joined with ':'; the first entry whose fields are not all empty wins. An item with
# no usable key falls back to a hash of its content, so a changed field shows as a remove + add.
KEYS = {
    ("opnsense", "cert"): [["descr"]], ("opnsense", "ca"): [["descr"]],
    ("sysctl", "item"): [["tunable"]],
    ("system", "group"): [["name"]], ("system", "user"): [["name"]],
    ("hosts", "host"): [["hostname", "domain", "rr"]],             # unbound overrides
    ("dnsmasq", "hosts"): [["host"], ["hwaddr"]],
    ("dnsmasq", "dhcp_ranges"): [["interface", "description"], ["interface"]],
    ("dnsmasq", "dhcp_options"): [["type", "option", "option6", "interface", "tag"]],
    ("dnsmasq", "domainoverrides"): [["domain"]],
    ("neighbors", "neighbor"): [["address"]],
    ("routemaps", "routemap"): [["name", "id"]],
    ("virtualip", "vip"): [["subnet"]],
    ("Gateways", "gateway_item"): [["name"]],
    ("jobs", "job"): [["description"], ["command"]],
    ("monit", "alert"): [["recipient"]],
    ("dnsbl", "blocklist"): [["description"], ["type"]],
    ("nat", "rule"): [["descr"]], ("filter", "rule"): [["descr"]],
    ("rules", "rule"): [["description"]],
}
GENERIC_KEYS = [["name"], ["description"], ["descr"], ["hostname"], ["host"], ["address"], ["subnet"]]


def text(e):
    return (e.text or "").strip() if e is not None else ""


def safe(k):  # a key must not contain the path separator or the glob's metacharacters
    return k.replace("/", "%2F").replace("[", "%5B").replace("]", "%5D")


def content_hash(e):
    parts = []
    for x in e.iter():
        if len(x) == 0:
            parts.append(f"{x.tag}={text(x)}")
    return "h:" + hashlib.sha256("\n".join(sorted(parts)).encode()).hexdigest()[:10]


def natural_key(parent_tag, e):
    for spec in KEYS.get((parent_tag, e.tag), []) + GENERIC_KEYS:
        vals = [text(e.find(f)) for f in spec]
        if any(vals):
            return safe(":".join(vals))
    return content_hash(e)


def is_keyed(parent, tag):
    kids = [c for c in parent if c.tag == tag]
    return len(kids) > 1 or any("uuid" in c.attrib for c in kids) or (parent.tag, tag) in KEYS


def keyed_children(parent, tag):
    out, seen = {}, collections.Counter()
    for c in parent:
        if c.tag != tag:
            continue
        k = natural_key(parent.tag, c)
        seen[k] += 1
        out[k if seen[k] == 1 else f"{k}#{seen[k]}"] = c
    return out


def uuid_index(root):
    """uuid -> '<item path>' in its own document, for comparing references by what they name."""
    idx = {}

    def walk(e, path):
        for tag in dict.fromkeys(c.tag for c in e):
            if is_keyed(e, tag):
                for k, c in keyed_children(e, tag).items():
                    p = f"{path}/{tag}[{k}]"
                    if "uuid" in c.attrib:
                        idx[c.attrib["uuid"]] = p
                    walk(c, p)
            else:
                for c in e:
                    if c.tag == tag:
                        walk(c, f"{path}/{tag}")
    walk(root, "")
    return idx


def deref(v, idx):
    parts = [p.strip() for p in v.split(",")] if v else []
    if parts and all(UUID_RE.match(p) for p in parts):
        return ",".join(sorted("ref:" + idx.get(p, "?dangling") for p in parts))
    return v


class Map:
    """opnsense/drill/compare-map.txt — see its header for the syntax."""

    def __init__(self, path):
        self.rules = []
        for n, line in enumerate(open(path), 1):
            line = line.strip()
            if not line or line.startswith("#"):   # whole-line comments only: keys may hold '#'
                continue
            f = line.split(None, 2)
            bucket = f[0]
            if bucket == "remap":
                f = line.split()
                if len(f) != 4:
                    sys.exit(f"{path}:{n}: remap <path-glob> <drill-prefix> <prod-prefix>")
                self.rules.append(("remap", "*", self._re(f[1]), f[2], f[3], n))
            elif bucket in ("env", "accepted"):
                if len(f) != 3 or f[1] not in ("*", "value", "prod-only", "drill-only"):
                    sys.exit(f"{path}:{n}: {bucket} <kind: *|value|prod-only|drill-only> <path-glob>")
                self.rules.append((bucket, f[1], self._re(f[2]), None, None, n))
            else:
                sys.exit(f"{path}:{n}: unknown bucket {bucket!r} (env | accepted | remap)")
        self.hits = collections.Counter()

    @staticmethod
    def _re(glob):  # `**` = anything, `*` = anything but '/', everything else literal
        out, i = "", 0
        while i < len(glob):
            if glob.startswith("**", i):
                out += ".*"; i += 2
            elif glob[i] == "*":
                out += "[^/]*"; i += 1
            else:
                out += re.escape(glob[i]); i += 1
        return re.compile("^" + out + "$")

    def remap(self, path, drill_value):
        for b, _, rx, frm, to, n in self.rules:
            if b == "remap" and rx.match(path) and frm in drill_value:
                return drill_value.replace(frm, to), n
        return drill_value, None

    def classify(self, path, kind):
        for b, k, rx, _, _, n in self.rules:
            if b in ("env", "accepted") and (k == "*" or k == kind) and rx.match(path):
                self.hits[n] += 1
                return {"env": "env", "accepted": "accepted"}[b], n
        return "clickops", None


def compare(prod, drill, cmap):
    pidx, didx = uuid_index(prod), uuid_index(drill)
    rows = []

    def leaves(e, path):
        if len(e) == 0:
            yield path, text(e)
            return
        for tag in dict.fromkeys(c.tag for c in e):
            if is_keyed(e, tag):
                for k, c in keyed_children(e, tag).items():
                    yield f"{path}/{tag}[{k}]", None      # a keyed item = one unit
            else:
                for c in e:
                    if c.tag == tag:
                        yield from leaves(c, f"{path}/{tag}")

    def one_sided(e, path, kind):
        for p, v in leaves(e, path):
            if v is None or v != "":
                rows.append((p.lstrip("/"), kind))

    def walk(p, d, path):
        if len(p) == 0 and len(d) == 0:
            pv, dv = deref(text(p), pidx), deref(text(d), didx)
            if pv != dv:
                dv2, rn = cmap.remap(path.lstrip("/"), dv)
                if dv2 == pv and rn is not None:
                    cmap.hits[rn] += 1
                    rows.append((path.lstrip("/"), "value", "env", rn))
                else:
                    rows.append((path.lstrip("/"), "value"))
            return
        tags = list(dict.fromkeys([c.tag for c in p] + [c.tag for c in d]))
        for tag in tags:
            if is_keyed(p, tag) or is_keyed(d, tag):
                pk, dk = keyed_children(p, tag), keyed_children(d, tag)
                for k in list(dict.fromkeys(list(pk) + list(dk))):
                    sub = f"{path}/{tag}[{k}]"
                    if k in pk and k in dk:
                        walk(pk[k], dk[k], sub)
                    elif not any(v is None or v != "" for _, v in leaves(pk.get(k, dk.get(k)), sub)):
                        continue                                  # an all-empty item = absent
                    elif k in pk:
                        rows.append((sub.lstrip("/"), "prod-only"))
                    else:
                        rows.append((sub.lstrip("/"), "drill-only"))
            else:
                pc, dc = p.find(tag), d.find(tag)
                if pc is not None and dc is not None:
                    walk(pc, dc, f"{path}/{tag}")
                elif pc is not None:
                    one_sided(pc, f"{path}/{tag}", "prod-only")
                else:
                    one_sided(dc, f"{path}/{tag}", "drill-only")

    walk(prod, drill, "")
    out = []
    for r in rows:
        if len(r) == 4:
            out.append({"path": r[0], "kind": r[1], "bucket": r[2], "rule": r[3]})
        else:
            b, n = cmap.classify(r[0], r[1])
            out.append({"path": r[0], "kind": r[1], "bucket": b, "rule": n})
    return out


def section(path):
    parts = path.split("/")
    head = re.sub(r"\[.*$", "", parts[0])
    if head == "OPNsense" and len(parts) > 1:
        return "OPNsense/" + re.sub(r"\[.*$", "", parts[1])
    return head


def redact(path):
    return re.sub(r"\[[^\]]*\]", "[*]", path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("prod"); ap.add_argument("drill")
    ap.add_argument("--map", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "compare-map.txt"))
    ap.add_argument("--report"); ap.add_argument("--prom"); ap.add_argument("--detail"); ap.add_argument("--json")
    ap.add_argument("--prom-prefix", default="mgmt_opnsense_drill")
    a = ap.parse_args()
    cmap = Map(a.map)
    rows = compare(ET.parse(a.prod).getroot(), ET.parse(a.drill).getroot(), cmap)

    per = collections.defaultdict(collections.Counter)
    for r in rows:
        per[section(r["path"])][r["bucket"]] += 1
    tot = collections.Counter(r["bucket"] for r in rows)
    score = tot["clickops"]

    agg = collections.Counter((redact(r["path"]), r["kind"]) for r in rows if r["bucket"] == "clickops")
    lines = [f"**Realism score: {score}** (clickops rows) — env {tot['env']}, accepted {tot['accepted']}", "",
             "| section | (a) clickops | (b) env | (c) accepted |", "|---|---|---|---|"]
    for s in sorted(per, key=lambda s: (-per[s]["clickops"], s)):
        c = per[s]
        lines.append(f"| `{s}` | {c['clickops']} | {c['env']} | {c['accepted']} |")
    lines += ["", "(a) rows by redacted path (item keys → `[*]`, no values):", "",
              "| rows | kind | path |", "|---|---|---|"]
    for (p, k), n in agg.most_common():
        lines.append(f"| {n} | {k} | `{p}` |")
    unused = [r[5] for r in cmap.rules if cmap.hits[r[5]] == 0]
    if unused:
        lines += ["", f"Map lines that matched nothing this run (stale?): {', '.join(map(str, unused))}"]
    report = "\n".join(lines) + "\n"
    if a.report:
        open(a.report, "w").write(report)
    else:
        sys.stdout.write(report)

    if a.prom:
        P = a.prom_prefix
        pl = [f"# HELP {P}_realism_score Rows of prod config.xml not explained by code, the env map or the accepted list (FU-297).",
              f"# TYPE {P}_realism_score gauge", f"{P}_realism_score {score}",
              f"# HELP {P}_config_diff_rows Config diff rows per section and bucket (clickops|env|accepted).",
              f"# TYPE {P}_config_diff_rows gauge"]
        for s in sorted(per):
            for b in ("clickops", "env", "accepted"):
                pl.append(f'{P}_config_diff_rows{{section="{s}",bucket="{b}"}} {per[s][b]}')
        open(a.prom, "w").write("\n".join(pl) + "\n")

    if a.detail:
        fd = os.open(a.detail, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            for r in rows:
                f.write(f"{r['bucket']}\t{r['kind']}\t{r['path']}\t{r['rule'] or ''}\n")
    if a.json:
        json.dump({"score": score, "totals": dict(tot), "sections": {s: dict(c) for s, c in per.items()}},
                  open(a.json, "w"), indent=1, sort_keys=True)


if __name__ == "__main__":
    main()
