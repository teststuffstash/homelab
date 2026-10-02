#!/usr/bin/env python3
"""lock-intake-lint — what a PR's lockfile change BRINGS IN must be known-clean and old enough (ADR-143).

    devbox run lock-intake-lint [<base-ref>]     (default: origin/master)
    devbox run lock-intake-lint -- --self-test   (offline: extractors + diff, no network)

Reads every lockfile the diff <base>..HEAD touches, takes the set of (package, version) pairs the
HEAD side has and the base side does not — the INTAKE, transitive dependencies included — and
fails the PR when any of them:

  (a) has an OSV record (api.osv.dev querybatch): a known vulnerability, or a MAL- advisory (a
      known-malicious package — the Shai-Hulud class once reported);
  (b) was published less than MIN_AGE_DAYS ago (the registry's own `time` field) — the cooldown
      Renovate's minimumReleaseAge applies to the DIRECT dependency only, enforced here on every
      resolved version, so a worm published an hour ago cannot arrive as someone's transitive;
  (c) can run code at install time (package-lock `hasInstallScript`; for deno.lock, the sibling
      deno.json enabling a node_modules dir — Deno runs lifecycle scripts only there).

WHY a static check: it reads lockfiles and registry metadata, installs and executes nothing, so it
decides before any step that runs dependency code. Renovate's own `osvVulnerabilityAlerts` covers
direct dependencies on the base branch only; it never saw lodash-es@4.17.23 arriving three levels
under mermaid 12 (homelab#2032, FU-294) — an LLM reviewer did, which is not a gate.

Fails CLOSED: a lockfile type with no extractor here, a non-npm entry (jsr:, remote URL), or an
unreachable OSV/registry is exit 2, never a pass. Only net-new pairs are judged: an advisory
published against something already on master is not this PR's intake.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

MIN_AGE_DAYS = 7
OSV_BATCH = "https://api.osv.dev/v1/querybatch"
REGISTRY = os.environ.get("NPM_CONFIG_REGISTRY", "https://registry.npmjs.org/").rstrip("/")
# Lockfile names this gate knows exist in the org; a changed one without an extractor fails closed.
KNOWN_UNSUPPORTED = {"pnpm-lock.yaml", "yarn.lock", "uv.lock", "poetry.lock", "go.sum", "Cargo.lock",
                     "Gemfile.lock", "composer.lock", "bun.lock", "bun.lockb"}


class Closed(Exception):
    """A condition the gate cannot judge — exit 2, never a pass."""


def git_show(ref, path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def split_spec(spec):
    """'@scope/name@1.2.3_peer@4' → ('@scope/name', '1.2.3'). deno.lock npm keys carry peer suffixes."""
    at = spec.find("@", 1)  # the name's own leading @ (a scope) is at 0; the version separator follows
    if at <= 0:
        raise Closed(f"unparseable lock key {spec!r}")
    return spec[:at], spec[at + 1:].split("_", 1)[0]


def extract_deno(text, path):
    lock = json.loads(text)
    if str(lock.get("version")) not in {"4", "5"}:
        raise Closed(f"{path}: deno.lock version {lock.get('version')!r} — extractor knows 4 and 5")
    pkgs = {}
    for key in lock.get("npm", {}):
        name, ver = split_spec(key)
        pkgs[(name, ver)] = {"scripts": False}
    for sect in ("jsr", "remote"):
        for key in lock.get(sect, {}):
            pkgs[(f"{sect}:{key}", "")] = {"unsupported": sect}
    return pkgs


def extract_package_lock(text, path):
    lock = json.loads(text)
    if "packages" not in lock:
        raise Closed(f"{path}: lockfileVersion {lock.get('lockfileVersion')!r} has no `packages` map (v1) — regenerate with npm ≥7")
    pkgs = {}
    for key, meta in lock["packages"].items():
        if not key or meta.get("link"):
            continue  # the root project, workspace symlinks
        name = meta.get("name") or key.rsplit("node_modules/", 1)[-1]
        pkgs[(name, meta.get("version", ""))] = {"scripts": bool(meta.get("hasInstallScript"))}
    return pkgs


EXTRACTORS = {"deno.lock": extract_deno, "package-lock.json": extract_package_lock}


def deno_scripts_enabled(ref, lock_path):
    """Deno runs npm lifecycle scripts only with a node_modules dir; deno.json is where that is set."""
    d = os.path.dirname(lock_path)
    for name in ("deno.json", "deno.jsonc"):
        text = git_show(ref, os.path.join(d, name) if d else name)
        if text is None:
            continue
        try:
            cfg = json.loads(text)
        except json.JSONDecodeError as e:
            raise Closed(f"{name} next to {lock_path} is not plain JSON ({e}) — the gate cannot read nodeModulesDir")
        return cfg.get("nodeModulesDir") not in (None, "none", False)
    return False


def intake(base, path):
    fname = os.path.basename(path)
    if fname in KNOWN_UNSUPPORTED:
        raise Closed(f"{path}: no extractor for {fname} yet — add one here (ADR-143) before this lockfile type lands")
    ext = EXTRACTORS[fname]
    head_text = git_show("HEAD", path)
    if head_text is None:
        return {}  # deleted at HEAD — brings nothing in
    base_text = git_show(base, path)
    head = ext(head_text, path)
    old = ext(base_text, path) if base_text is not None else {}
    new = {k: v for k, v in head.items() if k not in old}
    if fname == "deno.lock" and new and deno_scripts_enabled("HEAD", path):
        for v in new.values():
            v["scripts"] = True
    return new


def http_json(url, data=None):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        raise Closed(f"{url}: {e}")


def osv_findings(pairs):
    out = {}
    for i in range(0, len(pairs), 500):
        chunk = pairs[i:i + 500]
        res = http_json(OSV_BATCH, {"queries": [{"package": {"name": n, "ecosystem": "npm"}, "version": v} for n, v in chunk]})
        results = res.get("results", [])
        if len(results) != len(chunk):
            raise Closed(f"OSV answered {len(results)} results for {len(chunk)} queries")
        for pair, r in zip(chunk, results):
            if r.get("next_page_token"):
                raise Closed(f"OSV paginated {pair} — more advisories than one page; judge it by hand")
            ids = [v["id"] for v in r.get("vulns", [])]
            if ids:
                out[pair] = ids
    return out


def publish_age_days(name, version, now):
    doc = http_json(f"{REGISTRY}/{urllib.parse.quote(name, safe='@')}")
    stamp = (doc.get("time") or {}).get(version)
    if not stamp:
        raise Closed(f"{name}@{version}: the registry document carries no publish time")
    t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    return (now - t).total_seconds() / 86400


def changed_lockfiles(base):
    r = subprocess.run(["git", "diff", "--name-only", base, "HEAD"], capture_output=True, text=True, check=True)
    names = set(EXTRACTORS) | KNOWN_UNSUPPORTED
    return [p for p in r.stdout.split() if os.path.basename(p) in names]


def run(base):
    locks = changed_lockfiles(base)
    if not locks:
        print("lock-intake-lint: no lockfile changed — nothing brought in")
        return 0
    failures = []
    intake_all = {}
    for path in locks:
        for pair, meta in intake(base, path).items():
            intake_all.setdefault(pair, {"where": [], **meta})["where"].append(path)
    unsupported = [p for p, m in intake_all.items() if m.get("unsupported")]
    if unsupported:
        raise Closed("non-npm lock entries this gate cannot judge: " + ", ".join(p[0] for p in unsupported))
    pairs = sorted(intake_all)
    print(f"lock-intake-lint: {len(pairs)} net-new package version(s) across {len(locks)} lockfile(s)")
    for (n, v), ids in sorted(osv_findings(pairs).items()):
        kind = "MALICIOUS" if any(i.startswith("MAL-") for i in ids) else "vulnerable"
        failures.append(f"{kind} {n}@{v} — " + ", ".join(f"https://osv.dev/vulnerability/{i}" for i in ids))
    now = datetime.now(timezone.utc)
    for n, v in pairs:
        age = publish_age_days(n, v, now)
        if age < MIN_AGE_DAYS:
            failures.append(f"too new {n}@{v} — published {age:.1f} d ago, the floor is {MIN_AGE_DAYS} d")
    for (n, v), m in sorted(intake_all.items()):
        if m.get("scripts"):
            failures.append(f"install-time code {n}@{v} ({', '.join(m['where'])})")
    for f in failures:
        print(f"FAIL {f}")
    print(f"lock-intake-lint: {len(failures)} failure(s)")
    if failures:
        # ADR-143: the remedy is upstream, never a local pin/override — the PR stays red until a
        # release (or the cooldown) clears it and the proposer re-proposes; red is the correct state.
        print("lock-intake-lint: do NOT pin or override to go green (ADR-143) — this PR waits for an upstream "
              "release that clears it (vulnerable), or for the floor to pass (too new)")
    return 1 if failures else 0


def self_test():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {name}" + ("" if good else f": got {got!r}, want {want!r}"))

    check("scoped key", split_spec("@chevrotain/gast@11.1.2"), ("@chevrotain/gast", "11.1.2"))
    check("peer suffix", split_spec("react-dom@18.3.1_react@18.3.1"), ("react-dom", "18.3.1"))
    check("plain key", split_spec("lodash-es@4.17.23"), ("lodash-es", "4.17.23"))
    base = extract_deno(json.dumps({"version": "5", "npm": {"lodash-es@4.18.1": {}, "mermaid@11.17.2": {}}}), "b")
    head = extract_deno(json.dumps({"version": "5", "npm": {"lodash-es@4.18.1": {}, "lodash-es@4.17.23": {},
                                                           "mermaid@12.0.0": {}}, "jsr": {"@std/fs@1.0.0": {}}}), "h")
    check("deno net-new", sorted(k for k in head if k not in base),
          [("jsr:@std/fs@1.0.0", ""), ("lodash-es", "4.17.23"), ("mermaid", "12.0.0")])
    pl = extract_package_lock(json.dumps({"lockfileVersion": 3, "packages": {
        "": {"name": "root"}, "node_modules/esbuild": {"version": "0.25.0", "hasInstallScript": True},
        "node_modules/a/node_modules/@s/b": {"version": "1.0.0"}}}), "p")
    check("package-lock names + scripts", sorted((k, v["scripts"]) for k, v in pl.items()),
          [(("@s/b", "1.0.0"), False), (("esbuild", "0.25.0"), True)])
    try:
        extract_deno(json.dumps({"version": "3", "npm": {}}), "x")
        check("unknown deno.lock version fails closed", "passed", "Closed")
    except Closed:
        check("unknown deno.lock version fails closed", "Closed", "Closed")
    return 0 if ok else 1


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    base = argv[0] if argv else "origin/master"
    try:
        return run(base)
    except Closed as e:
        print(f"lock-intake-lint: CANNOT JUDGE — {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
