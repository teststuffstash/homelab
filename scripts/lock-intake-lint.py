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
      deno.json enabling a node_modules dir — Deno runs lifecycle scripts only there; for uv.lock,
      an sdist-only package — installing it BUILDS it, which runs its build backend / setup.py).
Ecosystems: npm (deno.lock, package-lock.json) and PyPI (uv.lock — OSV ecosystem `PyPI`, publish
time = the version's first file upload per pypi.org's JSON API).

WHY a static check: it reads lockfiles and registry metadata, installs and executes nothing, so it
decides before any step that runs dependency code. Renovate's own `osvVulnerabilityAlerts` covers
direct dependencies on the base branch only; it never saw lodash-es@4.17.23 arriving three levels
under mermaid 12 (homelab#2032, FU-294) — an LLM reviewer did, which is not a gate.

Fails CLOSED: a lockfile type with no extractor here, a non-registry entry (jsr:, remote URL, a git/path source), or an
unreachable OSV/registry is exit 2, never a pass. Only net-new pairs are judged: an advisory
published against something already on master is not this PR's intake.

homelab#2412 (the FOURTH site of that predicate, after pin-only-lint, governance-lint and
iac-sentinel): a master-sync PR into a `goal/**` base forks from the goal tip, so the diff against
that base carries master's own lockfile content and the intake it judges is master's, not the
worker's — a newly-published advisory against a package master already carries reds the sync PR
(the remedy is upstream either way, ADR-143). The predicate is "content NOT reachable from
origin/master": a lockfile whose HEAD content is byte-identical to the default branch's, and a pair
the default branch already carries, are master's, not this PR's. A PR based on the default branch is
unchanged — the reference IS its base there, so both filters are no-ops.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

MIN_AGE_DAYS = 7
OSV_BATCH = "https://api.osv.dev/v1/querybatch"
REGISTRY = os.environ.get("NPM_CONFIG_REGISTRY", "https://registry.npmjs.org/").rstrip("/")
# Lockfile names this gate knows exist in the org; a changed one without an extractor fails closed.
PYPI = os.environ.get("PYPI_INDEX_JSON", "https://pypi.org/pypi").rstrip("/")
KNOWN_UNSUPPORTED = {"pnpm-lock.yaml", "yarn.lock", "poetry.lock", "go.sum", "Cargo.lock",
                     "Gemfile.lock", "composer.lock", "bun.lock", "bun.lockb"}


class Closed(Exception):
    """A condition the gate cannot judge — exit 2, never a pass."""


def git_show(ref, path):
    r = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def default_branch_ref():
    """A tree reference for the default branch's tip — the master-reachability filter (homelab#2412).

    A master-sync PR into a `goal/**` base forks from the goal tip, so the diff against that base
    carries master's own lockfile content and the intake it judges is master's, not the worker's.
    The predicate is "content NOT reachable from origin/master", so a pair master already carries is
    not this PR's intake. MB = merge-base(default, head) is the exact reference, but a depth-1 CI
    checkout has no merge base and the lock-intake step carries no token for the API read the
    sibling gates use, so the reference is the default branch's TIP: identical to the base for a PR
    based on the default branch (the common case, where the filter is a no-op), and identical to MB
    for the sync PR this fixes (its head has master merged in, so MB IS master's tip). Fails CLOSED.
    """
    for ref in ("origin/master", "master"):
        if subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          capture_output=True).returncode == 0:
            return ref
    # CI's checkout is depth 1 of the merge ref, so there is no remote-tracking branch: fetch the tip.
    if subprocess.run(["git", "fetch", "--no-tags", "--depth=1", "origin", "master"],
                      capture_output=True).returncode == 0:
        return "FETCH_HEAD"
    raise Closed("cannot read the default branch (origin/master) — the master-reachability filter "
                 "(homelab#2412) cannot judge this PR")


def master_pairs(ref, path):
    """The (package, version) pairs the default branch already carries at `path` (homelab#2412)."""
    fname = os.path.basename(path)
    if fname not in EXTRACTORS:
        return set()  # no extractor: the file itself is master's, and is filtered out before this
    text = git_show(ref, path)
    return set(EXTRACTORS[fname](text, path)) if text is not None else set()


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


def extract_uv_lock(text, path):
    """uv.lock (TOML, `version = 1`): every `[[package]]` with a registry source is a PyPI pair.
    Install-time code (c) = an sdist-only package — pip/uv must BUILD it, which runs its build backend
    and any setup.py; a package with wheels installs by unpacking. The editable root project is not
    intake; a git/url/path/directory source is a non-registry entry this gate cannot judge."""
    import tomllib
    lock = tomllib.loads(text)
    if lock.get("version") != 1:
        raise Closed(f"{path}: uv.lock version {lock.get('version')!r} — extractor knows 1")
    pkgs = {}
    for pkg in lock.get("package", []):
        src = pkg.get("source") or {}
        if "editable" in src or "virtual" in src:
            continue  # the project itself / a workspace member
        name, ver = pkg.get("name", ""), pkg.get("version", "")
        if "registry" not in src:
            pkgs[(f"{next(iter(src), 'unknown')}:{name}", ver)] = {"unsupported": "non-registry", "ecosystem": "PyPI"}
            continue
        pkgs[(name, ver)] = {"scripts": not pkg.get("wheels") and bool(pkg.get("sdist")), "ecosystem": "PyPI"}
    return pkgs


EXTRACTORS = {"deno.lock": extract_deno, "package-lock.json": extract_package_lock, "uv.lock": extract_uv_lock}


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


def intake(base, master, path):
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
    # homelab#2412: a pair the default branch already carries is master's, not this PR's intake — a
    # master-sync PR into a goal/** base carries master's own lockfile content past its merge base.
    # `master` is the base itself for a PR based on the default branch, so this is a no-op there.
    already = master_pairs(master, path)
    new = {k: v for k, v in new.items() if k not in already}
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


def osv_findings(pairs, ecosystems=None):
    """pairs = [(name, version)]; ecosystems = {pair: "npm" | "PyPI"} (npm when absent)."""
    ecosystems = ecosystems or {}
    out = {}
    for i in range(0, len(pairs), 500):
        chunk = pairs[i:i + 500]
        res = http_json(OSV_BATCH, {"queries": [{"package": {"name": n, "ecosystem": ecosystems.get((n, v), "npm")},
                                                 "version": v} for n, v in chunk]})
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


def publish_age_days(name, version, now, ecosystem="npm"):
    if ecosystem == "PyPI":
        doc = http_json(f"{PYPI}/{urllib.parse.quote(name)}/{urllib.parse.quote(version)}/json")
        stamps = sorted(u.get("upload_time_iso_8601") or "" for u in doc.get("urls") or [])
        stamp = stamps[0] if stamps and stamps[0] else None  # the FIRST file upload = the publish time
    else:
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
    # homelab#2412: a master-sync PR into a goal/** base carries master's own lockfile edits in its
    # diff against that base. A lockfile whose HEAD content is byte-identical to the default
    # branch's is master's, not the PR's — dropped here so it is neither judged nor counted (and so
    # a lockfile type with no extractor that master added cannot fail this PR closed). The default
    # branch is read only once a lockfile is in play, so a PR that changes none never reads it.
    master = default_branch_ref()
    locks = [p for p in locks if git_show("HEAD", p) != git_show(master, p)]
    if not locks:
        print("lock-intake-lint: no lockfile changed by this PR — nothing brought in")
        return 0
    failures = []
    intake_all = {}
    for path in locks:
        for pair, meta in intake(base, master, path).items():
            intake_all.setdefault(pair, {"where": [], **meta})["where"].append(path)
    unsupported = [p for p, m in intake_all.items() if m.get("unsupported")]
    if unsupported:
        raise Closed("non-registry lock entries this gate cannot judge: " + ", ".join(p[0] for p in unsupported))
    pairs = sorted(intake_all)
    ecosystems = {p: m.get("ecosystem", "npm") for p, m in intake_all.items()}
    print(f"lock-intake-lint: {len(pairs)} net-new package version(s) across {len(locks)} lockfile(s)")
    for (n, v), ids in sorted(osv_findings(pairs, ecosystems).items()):
        kind = "MALICIOUS" if any(i.startswith("MAL-") for i in ids) else "vulnerable"
        failures.append(f"{kind} {n}@{v} — " + ", ".join(f"https://osv.dev/vulnerability/{i}" for i in ids))
    now = datetime.now(timezone.utc)
    for n, v in pairs:
        age = publish_age_days(n, v, now, ecosystems[(n, v)])
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
    uv = extract_uv_lock('''version = 1
revision = 5
[[package]]
name = "agent-gateway"
version = "0.1.0"
source = { editable = "." }
[[package]]
name = "anyio"
version = "4.12.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/a.tar.gz", hash = "sha256:00" }
wheels = [{ url = "https://files.pythonhosted.org/a.whl", hash = "sha256:01" }]
[[package]]
name = "sdistonly"
version = "0.1.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/s.tar.gz", hash = "sha256:02" }
[[package]]
name = "fromgit"
version = "0.0.1"
source = { git = "https://github.com/x/y?rev=abc#abc" }
''', "u")
    check("uv.lock names + ecosystem + sdist-only = install-time code",
          sorted((k, v.get("scripts"), v.get("unsupported"), v["ecosystem"]) for k, v in uv.items()),
          [(("anyio", "4.12.0"), False, None, "PyPI"), (("git:fromgit", "0.0.1"), None, "non-registry", "PyPI"),
           (("sdistonly", "0.1.0"), True, None, "PyPI")])
    try:
        extract_uv_lock("version = 2\n", "x")
        check("unknown uv.lock version fails closed", "passed", "Closed")
    except Closed:
        check("unknown uv.lock version fails closed", "Closed", "Closed")
    try:
        extract_deno(json.dumps({"version": "3", "npm": {}}), "x")
        check("unknown deno.lock version fails closed", "passed", "Closed")
    except Closed:
        check("unknown deno.lock version fails closed", "Closed", "Closed")
    ok &= self_test_master_filter()
    return 0 if ok else 1


def self_test_master_filter():
    """homelab#2412: a master-sync PR into a goal/** base judges nothing master already carries.

    Builds that shape in a throwaway repo (offline — local git only): master = base + its own
    lockfile edit; goal/2412 = base + its own commit; the PR = the goal tip + the sync merge of
    master. The reference is the default branch's tip, so master's pair drops out while the PR's own
    addition on top of the sync stays judged.
    """
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f"{'ok  ' if good else 'FAIL'} {name}" + ("" if good else f": got {got!r}, want {want!r}"))

    def lock(pkgs):
        return json.dumps({"lockfileVersion": 3, "packages": {"": {"name": "root"}, **pkgs}})

    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")

        def g(*a):
            return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, env=env, check=True)

        def write(name, text):
            with open(os.path.join(d, name), "w") as f:
                f.write(text)

        g("init", "-q", "-b", "master")
        write("package-lock.json", lock({"node_modules/old": {"version": "1.0.0"}}))
        g("add", "-A"); g("commit", "-q", "-m", "base")
        g("checkout", "-q", "-b", "goal/2412")
        write("GOAL.md", "goal\n")
        g("add", "-A"); g("commit", "-q", "-m", "goal: own commit")
        gtip = g("rev-parse", "HEAD").stdout.strip()
        g("checkout", "-q", "master")
        write("package-lock.json", lock({"node_modules/old": {"version": "1.0.0"},
                                         "node_modules/masterpkg": {"version": "2.0.0"}}))
        g("add", "-A"); g("commit", "-q", "-m", "master: own lockfile edit")
        g("checkout", "-q", "goal/2412")
        g("merge", "-q", "--no-ff", "--no-edit", "master")  # the sync
        cwd = os.getcwd()
        os.chdir(d)
        try:
            master = default_branch_ref()
            check("master ref falls back to the local default branch", master, "master")
            check("the sync's lockfile is in the base diff", changed_lockfiles(gtip), ["package-lock.json"])
            check("master's own lockfile edit is not the PR's",
                  [p for p in changed_lockfiles(gtip) if git_show("HEAD", p) != git_show(master, p)], [])
            check("master's pair is not this PR's intake",
                  sorted(intake(gtip, master, "package-lock.json")), [])
            # The pre-#2412 reference (the base itself) DID judge master's pair — the bug this fixes.
            check("the base reference judges master's pair (the #2412 bug)",
                  sorted(intake(gtip, gtip, "package-lock.json")), [("masterpkg", "2.0.0")])
            # The PR's OWN addition on top of the sync is still judged.
            write("package-lock.json", lock({"node_modules/old": {"version": "1.0.0"},
                                             "node_modules/masterpkg": {"version": "2.0.0"},
                                             "node_modules/ownpkg": {"version": "3.0.0"}}))
            g("add", "-A"); g("commit", "-q", "-m", "pr: own lockfile edit")
            check("the PR's own lockfile edit is kept",
                  [p for p in changed_lockfiles(gtip) if git_show("HEAD", p) != git_show(master, p)],
                  ["package-lock.json"])
            check("the PR's own pair is still judged",
                  sorted(intake(gtip, master, "package-lock.json")), [("ownpkg", "3.0.0")])
        finally:
            os.chdir(cwd)
    return ok


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
