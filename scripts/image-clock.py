#!/usr/bin/env python3
"""image-clock — the release clock Renovate lacks for Docker images (ADR-166; docs/renovate.md §The image clock).

    devbox run image-clock -- rules  --store DIR --base CONFIG --out FILE   (before Renovate)
    devbox run image-clock -- ingest --store DIR --report REPORT            (after Renovate)
    devbox run image-clock -- show   --store DIR [PACKAGE]                  (read the clock)
    devbox run image-clock -- --self-test                                   (offline)

WHY: Renovate's docker datasource has no usable release time. On Docker Hub it reads
`tag_last_pushed`, which every rebuild resets (`postgres:18-alpine` is re-pushed weekly), and other
registries give none; so `.github/renovate-global.json` runs docker timestamp-optional and a Docker
version lands the day it is published — the Trivy Docker Hub overwrite's vector (docs/renovate.md
§Threat model), and no ADR-166 lead offset for the stacks.

WHAT: a first-seen clock. `rules` lists the tags of every docker package the LAST Renovate run
reported (the universe, from `ingest`), records the time each tag was first seen, and writes the
effective Renovate config: the base config plus one `allowedVersions` rule per (repo, package, tag
family) that admits only tags old enough — the base config's cooldown (7 days), or the platform
offset (the rule carrying `matchRepositories` + a longer `minimumReleaseAge`: 14 days on homelab)
when the tag is a minor/major step from what the repo runs. The list is POSITIVE: a tag the clock
has never seen is not admitted, so a failed listing or a tag pushed seconds before Renovate's lookup
fails closed, never open. First seen = Docker Hub's `tag_last_pushed` on the tag's first sighting
(an upper bound on its age — a rebuild only makes it look newer), elsewhere the sighting time; the
first sighting of a whole package dates its candidate tags by the image config's `created`.
The store is a side branch (`image-clock`): `clock.json` (package → tag → first seen) and
`universe.json` (repo → package → the tags it runs). Stdlib only.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

UA = "homelab-image-clock (+https://github.com/teststuffstash/homelab)"
HUB = "https://hub.docker.com/v2"
HUB_HOSTS = {"docker.io", "index.docker.io", "registry-1.docker.io", "registry.hub.docker.com"}
HUB_MAX_PAGES = 10              # Docker Hub 403s page 11+ (the 1000 most recently updated tags);
                                 # older tags stay unseen → out, which is fail-closed and harmless
BOOTSTRAP_DATE_CAP = 40          # config-created lookups per package on its first sighting
EPOCH_FLOOR = datetime(2010, 1, 1, tzinfo=timezone.utc)   # reproducible builds stamp 1970: unknown
TAG_RE = re.compile(r"^(v?)(\d+(?:\.\d+)*)(.*)$")
MANIFEST_ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


def parse_days(s):
    m = re.fullmatch(r"\s*(\d+)\s*days?\s*", s or "")
    if not m:
        raise SystemExit(f"image-clock: cannot read minimumReleaseAge {s!r} (want 'N days')")
    return int(m.group(1))


# ── tags: family + version ────────────────────────────────────────────────────────────────────
def split_tag(tag):
    """'18.3-alpine' → (('', '-alpine'), (18, 3)); None for a tag with no leading version."""
    m = TAG_RE.match(tag)
    if not m:
        return None
    return (m.group(1), m.group(3)), tuple(int(x) for x in m.group(2).split("."))


def step(cur, cand):
    """The update type Renovate would give cur → cand: major / minor / patch."""
    if cand[0] != cur[0]:
        return "major"
    if len(cand) > 1 and len(cur) > 1 and cand[1] != cur[1]:
        return "minor"
    return "patch"


def family_regex(fam):
    v, suffix = fam
    return "/^" + re.escape(v) + r"\d+(\.\d+)*" + re.escape(suffix).replace("/", r"\/") + "$/"


# ── package names → registry endpoints ────────────────────────────────────────────────────────
def locate(package):
    """('hub', 'library/postgres') or ('oci', 'ghcr.io', 'org/img') for a Renovate packageName."""
    first, _, rest = package.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        if first in HUB_HOSTS:
            return ("hub", rest if "/" in rest else "library/" + rest)
        return ("oci", first, rest)
    return ("hub", package if "/" in package else "library/" + package)


class Net:
    def __init__(self, opener=None):
        self.open = opener or urllib.request.urlopen
        self.tokens = {}

    def get(self, url, headers=None, auth_scope=None, attempt=0):
        h = {"User-Agent": UA, **(headers or {})}
        if auth_scope and auth_scope in self.tokens:
            h["Authorization"] = "Bearer " + self.tokens[auth_scope]
        req = urllib.request.Request(url, headers=h)
        try:
            with self.open(req, timeout=30) as r:
                return r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            if e.code == 401 and auth_scope and auth_scope not in self.tokens:
                self.tokens[auth_scope] = self.token(e.headers.get("WWW-Authenticate", ""))
                return self.get(url, headers, auth_scope)
            # Docker Hub answers a paging burst with 403/429 (seen 2026-11-21): back off, then give up
            # — a failed listing leaves the clock unchanged and unseen tags out (fail closed).
            if e.code in (403, 429) and attempt < 4:
                time.sleep(int(e.headers.get("Retry-After") or 0) or 5 * 2 ** attempt)
                return self.get(url, headers, auth_scope, attempt + 1)
            raise

    def token(self, challenge):
        m = re.match(r"\s*Bearer\s+(.*)", challenge or "", re.I)
        if not m:
            raise RuntimeError(f"no Bearer challenge ({challenge!r})")
        params = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        realm = params.pop("realm")
        body, _ = self.get(realm + "?" + urllib.parse.urlencode(params))
        doc = json.loads(body)
        return doc.get("token") or doc["access_token"]


def hub_tags(net, repo, since):
    """[(tag, tag_last_pushed)] newest-updated first; stops paging once past `since`."""
    url = f"{HUB}/repositories/{repo}/tags?page_size=100&ordering=last_updated"
    out, pages = [], 0
    while url and pages < HUB_MAX_PAGES:
        pages += 1
        body, _ = net.get(url)
        page = json.loads(body)
        for t in page.get("results", []):
            pushed = t.get("tag_last_pushed") or t.get("last_updated")
            out.append((t["name"], pushed))
        oldest = page["results"][-1].get("last_updated") if page.get("results") else None
        if since and oldest and parse_iso(oldest) < since:
            break
        url = page.get("next")
    return out


def oci_tags(net, host, repo):
    url = f"https://{host}/v2/{repo}/tags/list?n=1000"
    scope = f"{host}/{repo}"
    tags = []
    while url:
        body, headers = net.get(url, auth_scope=scope)
        tags += json.loads(body).get("tags") or []
        link = next((v for k, v in headers.items() if k.lower() == "link"), "")
        m = re.search(r'<([^>]+)>;\s*rel="next"', link)
        url = urllib.parse.urljoin(f"https://{host}", m.group(1)) if m else None
    return tags


def oci_created(net, host, repo, tag):
    scope = f"{host}/{repo}"
    body, _ = net.get(f"https://{host}/v2/{repo}/manifests/{tag}",
                      {"Accept": MANIFEST_ACCEPT}, scope)
    man = json.loads(body)
    if "manifests" in man:
        body, _ = net.get(f"https://{host}/v2/{repo}/manifests/{man['manifests'][0]['digest']}",
                          {"Accept": MANIFEST_ACCEPT}, scope)
        man = json.loads(body)
    body, _ = net.get(f"https://{host}/v2/{repo}/blobs/{man['config']['digest']}", None, scope)
    return json.loads(body).get("created")


# ── observe: refresh the clock for every package in the universe ──────────────────────────────
def candidate_tags(tags, floors):
    """Tags of a watched family at or above that family's lowest running version."""
    out = []
    for t in tags:
        s = split_tag(t)
        if s and s[0] in floors and s[1] >= floors[s[0]]:
            out.append(t)
    return out


def observe(net, clock, package, floors, now, log):
    entry = clock.setdefault(package, {"observed_at": None, "tags": {}})
    known = entry["tags"]
    first_sighting = entry["observed_at"] is None
    loc = locate(package)
    try:
        if loc[0] == "hub":
            since = None if first_sighting else parse_iso(entry["observed_at"]) - timedelta(days=1)
            for tag, pushed in hub_tags(net, loc[1], since):
                if tag not in known:
                    t = parse_iso(pushed) if pushed else now
                    known[tag] = iso(min(t, now))
        else:
            _, host, repo = loc
            new = [t for t in oci_tags(net, host, repo) if t not in known]
            dated = set(sorted(candidate_tags(new, floors), key=lambda t: split_tag(t)[1], reverse=True)[:BOOTSTRAP_DATE_CAP]) if first_sighting else set()
            for tag in new:
                when = now
                if tag in dated:
                    try:
                        c = oci_created(net, host, repo, tag)
                        if c and EPOCH_FLOOR < parse_iso(c[:19] + "Z") < now:
                            when = parse_iso(c[:19] + "Z")
                    except Exception as e:  # undatable → the sighting time (conservative)
                        log(f"  {package}:{tag} created unreadable ({e}); dated at sighting")
                known[tag] = iso(when)
    except Exception as e:
        log(f"image-clock: WARN {package}: listing failed ({e}) — clock unchanged, unseen tags stay out")
        return False
    entry["observed_at"] = iso(now)
    return True


# ── rules: the allowedVersions each (repo, package, family) gets ──────────────────────────────
def platform_policy(base):
    """(base cooldown days, {repo: offset days}) read from the base config — one home for both."""
    cooldown = parse_days(base.get("minimumReleaseAge"))
    offset = {}
    for r in base.get("packageRules", []):
        if r.get("matchRepositories") and r.get("minimumReleaseAge") and \
                set(r.get("matchUpdateTypes", [])) >= {"minor", "major"}:
            for repo in r["matchRepositories"]:
                offset[repo] = parse_days(r["minimumReleaseAge"])
    return cooldown, offset


def build_rules(universe, clock, cooldown, offset, now):
    rules = []
    for repo in sorted(universe):
        for package in sorted(universe[repo]):
            families = {}
            for cur in universe[repo][package]:
                s = split_tag(cur)
                if s:
                    families.setdefault(s[0], []).append((s[1], cur))
            for fam in sorted(families):
                running = sorted(families[fam])
                floor, top = running[0][0], running[-1][0]
                allowed = {c for _, c in running}
                for tag, seen in clock.get(package, {}).get("tags", {}).items():
                    s = split_tag(tag)
                    if not s or s[0] != fam or s[1] < floor:
                        continue
                    need = cooldown
                    if repo in offset and step(top, s[1]) in ("major", "minor"):
                        need = max(cooldown, offset[repo])
                    if now - parse_iso(seen) >= timedelta(days=need):
                        allowed.add(tag)
                alts = "|".join(re.escape(t) for t in sorted(allowed, key=lambda t: split_tag(t)[1]))
                rules.append({
                    "description": f"image-clock (ADR-166): {package} {fam[0]}N{fam[1]} on {repo} "
                                   f"— tags first seen ≥ {cooldown} d ago ({offset.get(repo, cooldown)} d for "
                                   f"a minor/major), generated {iso(now)}",
                    "matchRepositories": [repo],
                    "matchDatasources": ["docker"],
                    "matchPackageNames": [package],
                    "matchCurrentValue": family_regex(fam),
                    "allowedVersions": f"/^({alts})$/",
                })
    return rules


# ── store I/O ─────────────────────────────────────────────────────────────────────────────────
def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def dump(path, doc):
    with open(path + ".tmp", "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(path + ".tmp", path)


def ingest_report(report):
    """Renovate's `reportType: file` → {repo: {package: [current tags]}} for docker deps."""
    uni = {}
    for repo, rr in (report.get("repositories") or {}).items():
        for pfs in (rr.get("packageFiles") or {}).values():
            for pf in pfs:
                for d in pf.get("deps", []):
                    if d.get("datasource") != "docker" or d.get("skipReason"):
                        continue
                    pkg, cur = d.get("packageName") or d.get("depName"), d.get("currentValue")
                    if pkg and cur and split_tag(cur):
                        tags = uni.setdefault(repo, {}).setdefault(pkg, [])
                        if cur not in tags:
                            tags.append(cur)
    return uni


def cmd_rules(a, net=None, now=None, log=print):
    now = now or datetime.now(timezone.utc)
    net = net or Net()
    base = load(a.base, None)
    cooldown, offset = platform_policy(base)
    clock = load(os.path.join(a.store, "clock.json"), {})
    universe = load(os.path.join(a.store, "universe.json"), {})
    floors = {}
    for repo_pk in universe.values():
        for pkg, curs in repo_pk.items():
            for cur in curs:
                fam, ver = split_tag(cur)
                f = floors.setdefault(pkg, {})
                f[fam] = min(f.get(fam, ver), ver)
    failed = [p for p in sorted(floors) if not observe(net, clock, p, floors[p], now, log)]
    dump(os.path.join(a.store, "clock.json"), clock)
    rules = build_rules(universe, clock, cooldown, offset, now)
    base["packageRules"] = base.get("packageRules", []) + rules
    dump(a.out, base)
    log(f"image-clock: {len(floors)} package(s) observed ({len(failed)} failed: {', '.join(failed) or '-'}), "
        f"{len(rules)} allowedVersions rule(s) → {a.out}")
    return 0


def cmd_ingest(a, log=print):
    try:
        report = load(a.report, None)
    except json.JSONDecodeError as e:
        log(f"image-clock: report unreadable ({e}) — universe unchanged")
        return 1
    if not report or not report.get("repositories"):
        log("image-clock: no report / no repositories — universe unchanged")
        return 1
    uni = ingest_report(report)
    dump(os.path.join(a.store, "universe.json"), uni)
    log(f"image-clock: universe = {sum(len(v) for v in uni.values())} docker package(s) in {len(uni)} repo(s)")
    return 0


def cmd_show(a, log=print):
    now = datetime.now(timezone.utc)
    clock = load(os.path.join(a.store, "clock.json"), {})
    for pkg in sorted(clock):
        if a.package and pkg != a.package:
            continue
        tags = sorted(clock[pkg]["tags"].items(), key=lambda kv: kv[1], reverse=True)[:a.limit]
        log(f"{pkg} (observed {clock[pkg]['observed_at']})")
        for tag, seen in tags:
            log(f"  {tag:32} first seen {seen}  ({(now - parse_iso(seen)).days} d)")
    return 0


# ── self-test (offline) ───────────────────────────────────────────────────────────────────────
def self_test():
    ok = 0

    def check(cond, what):
        nonlocal ok
        if not cond:
            raise SystemExit(f"image-clock self-test FAILED: {what}")
        ok += 1

    check(split_tag("18.3-alpine") == (("", "-alpine"), (18, 3)), "split 18.3-alpine")
    check(split_tag("v1.2.3") == (("v", ""), (1, 2, 3)), "split v1.2.3")
    check(split_tag("latest") is None and split_tag("19rc2-alpine")[0] == ("", "rc2-alpine"),
          "latest has no version; an rc is its own family")
    check(step((18,), (19,)) == "major" and step((1, 2), (1, 3)) == "minor"
          and step((1, 2, 3), (1, 2, 4)) == "patch" and step((18,), (18, 7)) == "patch", "step kinds")
    check(locate("postgres") == ("hub", "library/postgres"), "locate bare")
    check(locate("docker.io/library/python") == ("hub", "library/python"), "locate docker.io")
    check(locate("grafana/grafana") == ("hub", "grafana/grafana"), "locate hub org")
    check(locate("ghcr.io/cloudnative-pg/postgresql") == ("oci", "ghcr.io", "cloudnative-pg/postgresql"),
          "locate ghcr")
    check(re.fullmatch(family_regex(("", "-alpine"))[2:-2], "18.3-alpine")
          and not re.fullmatch(family_regex(("", "-alpine"))[2:-2], "18.3-bookworm"), "family regex")

    base = {"minimumReleaseAge": "7 days", "packageRules": [
        {"matchRepositories": ["o/platform"], "matchUpdateTypes": ["minor", "major"],
         "minimumReleaseAge": "14 days"},
        {"matchUpdateTypes": ["minor"], "minimumReleaseAge": "3 days"}]}
    check(platform_policy(base) == (7, {"o/platform": 14}), "policy read from base config")

    now = parse_iso("2026-11-21T12:00:00Z")
    clock = {"postgres": {"observed_at": "2026-11-21T06:00:00Z", "tags": {
        "18-alpine": "2026-11-21T06:00:00Z",       # re-pushed today: running, so admitted anyway
        "18.7-alpine": "2026-11-12T00:00:00Z",     # 9 d: a patch step from 18 → 7 d is enough
        "19-alpine": "2026-11-20T04:09:00Z",       # 1 d: out everywhere
        "17-alpine": "2026-01-01T00:00:00Z",       # below the floor: never listed
        "20-alpine": "2026-11-05T00:00:00Z",       # 16 d: in everywhere
        "19-bookworm": "2026-01-01T00:00:00Z"}}}   # another family
    uni = {"o/platform": {"postgres": ["18-alpine"]}, "o/stack": {"postgres": ["18-alpine"]}}
    rules = {r["matchRepositories"][0]: r for r in build_rules(uni, clock, 7, {"o/platform": 14}, now)}
    check(rules["o/stack"]["allowedVersions"] == r"/^(18\-alpine|18\.7\-alpine|20\-alpine)$/",
          f"stack allowed: {rules['o/stack']['allowedVersions']}")
    check(rules["o/platform"]["allowedVersions"] == r"/^(18\-alpine|18\.7\-alpine|20\-alpine)$/",
          "platform allowed (20 is 16 d ≥ 14)")
    clock["postgres"]["tags"]["20-alpine"] = "2026-11-11T00:00:00Z"   # 10 d: ≥7, <14
    rules = {r["matchRepositories"][0]: r for r in build_rules(uni, clock, 7, {"o/platform": 14}, now)}
    check("20" in rules["o/stack"]["allowedVersions"] and "20" not in rules["o/platform"]["allowedVersions"],
          "a 10-day major: in for a stack, out for the platform (the offset)")
    check(rules["o/stack"]["matchCurrentValue"] == r"/^\d+(\.\d+)*\-alpine$/", "rule keyed on the family")

    unknown = build_rules({"o/stack": {"ghcr.io/x/y": ["1.2.3"]}}, {}, 7, {}, now)
    check(unknown[0]["allowedVersions"] == r"/^(1\.2\.3)$/", "never-observed package: only what runs (fails closed)")

    report = {"repositories": {"o/stack": {"packageFiles": {"kubernetes": [{"deps": [
        {"datasource": "docker", "packageName": "postgres", "currentValue": "18-alpine"},
        {"datasource": "docker", "depName": "busybox", "currentValue": "latest"},
        {"datasource": "docker", "packageName": "x", "currentValue": "1", "skipReason": "unsupported"},
        {"datasource": "helm", "packageName": "y", "currentValue": "1.0.0"}]}]}}}}
    check(ingest_report(report) == {"o/stack": {"postgres": ["18-alpine"]}}, "ingest keeps versioned docker deps only")

    # hub paging + incremental stop
    pages = {
        f"{HUB}/repositories/library/postgres/tags?page_size=100&ordering=last_updated":
            {"results": [{"name": "19-alpine", "tag_last_pushed": "2026-11-20T04:09:49Z",
                          "last_updated": "2026-11-20T04:09:49Z"}], "next": "https://p/2"},
        "https://p/2": {"results": [{"name": "18.3-alpine", "tag_last_pushed": "2026-04-22T07:13:34Z",
                            "last_updated": "2026-04-22T07:13:34Z"}], "next": "https://p/3"},
        "https://p/3": {"results": [{"name": "OLD", "last_updated": "2020-01-01T00:00:00Z"}], "next": None}}

    class Resp:
        def __init__(self, doc):
            self.doc, self.headers = doc, {}

        def read(self):
            return json.dumps(self.doc).encode()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    net = Net(opener=lambda req, timeout: Resp(pages[req.full_url]))
    got = hub_tags(net, "library/postgres", parse_iso("2026-11-01T00:00:00Z"))
    check([t for t, _ in got] == ["19-alpine", "18.3-alpine"], f"hub incremental stop: {got}")
    clk = {}
    observe(net, clk, "postgres", {("", "-alpine"): (18,)}, now, lambda m: None)
    check(clk["postgres"]["tags"]["19-alpine"] == "2026-11-20T04:09:49Z" and "OLD" in clk["postgres"]["tags"],
          "first sighting reads every page, dated by tag_last_pushed")
    check(Net().__class__ and re.findall(r'(\w+)="([^"]*)"', 'realm="https://ghcr.io/token",service="ghcr.io"')
          == [("realm", "https://ghcr.io/token"), ("service", "ghcr.io")], "challenge parse")
    print(f"image-clock self-test: {ok} checks ok")
    return 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    p = argparse.ArgumentParser(prog="image-clock")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rules")
    r.add_argument("--store", required=True)
    r.add_argument("--base", required=True)
    r.add_argument("--out", required=True)
    i = sub.add_parser("ingest")
    i.add_argument("--store", required=True)
    i.add_argument("--report", required=True)
    s = sub.add_parser("show")
    s.add_argument("--store", required=True)
    s.add_argument("package", nargs="?")
    s.add_argument("--limit", type=int, default=8)
    a = p.parse_args(argv[1:])
    return {"rules": cmd_rules, "ingest": cmd_ingest, "show": cmd_show}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
