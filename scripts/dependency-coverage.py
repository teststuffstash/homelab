#!/usr/bin/env python3
"""dependency-coverage — the generated dependency coverage table (homelab#1992, stint S9 #1985).

One row per pinned dependency, seven columns — proposer, merge gate, deploy edge, detector, revert,
canary, last proven end to end — plus the per-class roll-up the owner rule is written against: an
owner leaves a dependency class only when every column is filled and the proof is recent (FU-097's
capability-ledger rule, generalized from box surfaces to dependency classes).

Two inputs, never hand-merged:

    docs/dependency-classes.yaml   the RULINGS — per class, the six mechanism columns (ok/human/gap)
    the repo's own files            the DEPENDENCIES — extracted per class the way Renovate's managers
                                    read them (argocd/platform charts, image: refs, tofu lockfiles and
                                    variable defaults, devbox.lock, .github/workflows uses:, …)

and one external source for the seventh column: GitHub, read with `gh api` — the newest MERGED PR
from the class's proposer (head prefix `renovate/`, `deploy/`, `runner-image-pin`, `devbox-update`)
whose added lines name the dependency. The substrate class (6) has no proposer PR; its proof is the
capability ledger row in docs/management-box.md. Proofs persist in the generated JSON so an
`--offline` run (and the `--check` currency gate) needs no network.

Outputs (both generated, both committed; CONTEXT.md principle 2 — a regeneration is a stable diff):

    docs/dependency-upgrades.md                          the marker-delimited block in
                                                         §The dependency inventory
    argocd/resources/github-exporter/dependency-coverage.json
                                                         the same facts for the github-exporter
                                                         gauges (shipped in its script ConfigMap,
                                                         the docs/github-apps.yaml → github-apps.json
                                                         pattern)

    devbox run dependency-coverage                # regenerate (online: refreshes the proofs)
    devbox run dependency-coverage -- --offline   # regenerate from the committed proofs
    devbox run dependency-coverage -- --check     # exit 1 if the committed outputs are stale

Deterministic: sorted rows, sorted JSON keys, no timestamps of its own — "recent" is evaluated by
the alert (`DependencyClassProofStale`, PromQL over the proof epoch), never baked into the doc.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REGISTRY = os.path.join(ROOT, "docs", "dependency-classes.yaml")
DOC = os.path.join(ROOT, "docs", "dependency-upgrades.md")
LEDGER = os.path.join(ROOT, "docs", "management-box.md")
JSON_OUT = os.path.join(ROOT, "argocd", "resources", "github-exporter", "dependency-coverage.json")
REPO = os.environ.get("DEPENDENCY_COVERAGE_REPO", "teststuffstash/homelab")
KEY = "dependency-coverage"
BEGIN = (f"<!-- BEGIN GENERATED {KEY} — do not edit; edit docs/dependency-classes.yaml (rulings) or the "
         f"pinned files (dependencies) and run `devbox run dependency-coverage` -->")
END = f"<!-- END GENERATED {KEY} -->"
GLYPH = {"ok": "✅", "human": "👤", "gap": "⚠"}
COLUMNS = ("proposer", "merge_gate", "deploy_edge", "detector", "revert", "canary")
COLUMN_TITLES = {"proposer": "Proposer", "merge_gate": "Merge gate", "deploy_edge": "Deploy edge",
                 "detector": "Detector", "revert": "Revert", "canary": "Canary"}
SUBSTRATE_VARS = {"talos_version_controlplane": "Talos (control planes)",
                  "talos_version_worker": "Talos (workers)",
                  "kubernetes_version": "Kubernetes",
                  "cilium_version": "Cilium"}
FIRST_PARTY = "ghcr.io/teststuffstash/"
IMAGE_GLOBS = ("argocd/resources/**/*.yaml", "agents/coordinator/*.yaml", "agents/fixer/**/*.yaml")
IMAGE_RE = re.compile(r'^\s*(?:-\s*)?image:\s*"?([^"\s]+)"?\s*(?:#.*)?$')
REF_RE = re.compile(r"^(?P<name>[^:@\s]+(?::\d+/[^:@\s]+)?)(?::(?P<tag>[^@\s]+))?(?:@(?P<digest>sha256:[0-9a-f]+))?$")


def die(msg):
    sys.exit(f"dependency-coverage: FAIL — {msg}")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def rel(path):
    return os.path.relpath(path, ROOT)


# ── inputs ────────────────────────────────────────────────────────────────────────────────────


def yaml_docs(path):
    """Every YAML document in `path` as a Python object (the jail python has no yaml module — yq)."""
    try:
        import yaml  # noqa
        with open(path, encoding="utf-8") as handle:
            return [d for d in yaml.safe_load_all(handle) if d is not None]
    except ImportError:
        out = subprocess.run(["yq", "-o=json", "-I0", ".", path], check=True,
                             stdout=subprocess.PIPE, text=True).stdout
        docs = []
        for line in out.splitlines():
            line = line.strip()
            if line and line != "null":
                docs.append(json.loads(line))
        return docs


def load_registry():
    reg = yaml_docs(REGISTRY)[0]
    seen = set()
    for cls in reg.get("classes") or []:
        cid = cls.get("id")
        if cid in seen:
            die(f"registry: duplicate class id {cid!r}")
        seen.add(cid)
        for field in ("name", "extract", "where", "manager"):
            if not cls.get(field):
                die(f"registry: class {cid}: missing {field!r}")
        for col in COLUMNS:
            cell = cls.get(col)
            if not isinstance(cell, dict) or cell.get("status") not in GLYPH or not cell.get("text"):
                die(f"registry: class {cid}: column {col!r} must be {{status: ok|human|gap, text: …}}")
        cls.setdefault("proof_head_prefixes", [])
        cls.setdefault("proof_paths", [])
    for name, cols in (reg.get("overrides") or {}).items():
        for col, cell in cols.items():
            if col not in COLUMNS or cell.get("status") not in GLYPH or not cell.get("text"):
                die(f"registry: override {name!r}: bad column {col!r}")
    if not isinstance(reg.get("proof_recent_days"), int):
        die("registry: proof_recent_days must be an integer")
    return reg


def tofu_default(src, var_name):
    block = re.search(r'variable\s+"%s"\s*\{(.*?)\n\}' % re.escape(var_name), src, re.S)
    if not block:
        return None
    default = re.search(r'\n\s*default\s*=\s*"([^"]+)"', block.group(1))
    return default.group(1) if default else None


def repo_files(pattern):
    return sorted(p for p in glob.glob(os.path.join(ROOT, pattern), recursive=True) if os.path.isfile(p))


# ── extractors: one per class, each yields rows {name, version, where[], match[], overrides{}} ──


def parse_image_refs():
    """Every `image:` literal under the GitOps trees → {name: {versions: {ver: count}, files: set}}.
    Templated refs (`{{ … }}`) are skipped — they are not pins."""
    refs = {}
    for pattern in IMAGE_GLOBS:
        for path in repo_files(pattern):
            for line in read(path).splitlines():
                m = IMAGE_RE.match(line)
                if not m or "{{" in m.group(1):
                    continue
                ref = REF_RE.match(m.group(1))
                if not ref:
                    continue
                name = ref.group("name")
                ver = ref.group("tag") or ""
                if ref.group("digest"):
                    ver = (ver + "@" if ver else "@") + ref.group("digest")[:19]
                entry = refs.setdefault(name, {"versions": {}, "files": set()})
                entry["versions"][ver or "(none — floats to :latest)"] = \
                    entry["versions"].get(ver or "(none — floats to :latest)", 0) + 1
                entry["files"].add(rel(path))
    return refs


def extract_helm_gitops():
    """One row per chart; the same chart pinned by several Applications (the two ARC scale sets)
    is one dependency whose row lists every file — and every DISTINCT version, so a lockstep break
    shows up in the Version cell."""
    found = {}
    for path in repo_files("argocd/platform/*.yaml"):
        for doc in yaml_docs(path):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            spec = doc.get("spec") or {}
            sources = spec.get("sources") or ([spec["source"]] if spec.get("source") else [])
            for src in sources:
                if not isinstance(src, dict):
                    continue
                repo_url, rev = str(src.get("repoURL", "")), str(src.get("targetRevision", ""))
                if "teststuffstash" in repo_url or rev in ("", "master", "HEAD"):
                    continue
                name = src.get("chart") or repo_url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
                entry = found.setdefault(name, {"versions": set(), "files": set()})
                entry["versions"].add(rev)
                entry["files"].add(rel(path))
    return [{"name": n, "version": ", ".join(sorted(e["versions"])), "where": sorted(e["files"]), "match": [n]}
            for n, e in found.items()]


def extract_images_gitops(refs):
    rows = []
    for name, entry in refs.items():
        if name.startswith(FIRST_PARTY):
            continue
        rows.append({"name": name, "version": ", ".join(sorted(entry["versions"])),
                     "where": sorted(entry["files"]), "match": [name.rsplit("/", 1)[-1]]})
    for var, value in images_env().items():
        ref = REF_RE.match(value)
        if not ref or ref.group("name").startswith(FIRST_PARTY):
            continue
        ver = (ref.group("tag") or "") + ("@" + ref.group("digest")[:19] if ref.group("digest") else "")
        rows.append({"name": ref.group("name"), "version": ver, "where": ["agents/images.env"],
                     "match": [ref.group("name").rsplit("/", 1)[-1]],
                     "overrides": {"proposer": {"status": "gap", "text": f"no Renovate manager reads `agents/images.env` (`{var}`)"}}})
    return rows


def images_env():
    out = {}
    for line in read(os.path.join(ROOT, "agents", "images.env")).splitlines():
        m = re.match(r"^([A-Z_]+_IMAGE)=(\S+)", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def extract_first_party_images(refs):
    rows = []
    pinned = {}
    for var, value in images_env().items():
        ref = REF_RE.match(value)
        if ref and ref.group("name").startswith(FIRST_PARTY):
            pinned[ref.group("name")] = (var, ref.group("tag") or "")
    for name in sorted(set(refs) | set(pinned)):
        if not name.startswith(FIRST_PARTY):
            continue
        entry = refs.get(name, {"versions": {}, "files": set()})
        versions = dict(entry["versions"])
        where = set(entry["files"])
        short = name[len(FIRST_PARTY):]
        row = {"name": short, "where": sorted(where), "match": [short.rsplit("/", 1)[-1]]}
        if name in pinned:
            var, tag = pinned[name]
            where.add("agents/images.env")
            row["where"] = sorted(where)
            stray = {v: n for v, n in versions.items() if v != tag}
            row["version"] = f"`{var}`={tag}" + (f"; {sum(versions.values())} manifest ref(s)" if versions else "")
            if stray:
                detail = ", ".join(f"{n}× {v}" for v, n in sorted(stray.items()))
                row["overrides"] = {"deploy_edge": {"status": "gap", "text": f"{len(stray)} ref(s) NOT at the images.env pin ({detail}) — the deploy-pin sweep misses them"}}
        else:
            row["version"] = ", ".join(f"{v} (×{n})" for v, n in sorted(versions.items()))
            if len(versions) > 1 or any(v.startswith("(none") for v in versions):
                row["overrides"] = {"deploy_edge": {"status": "gap", "text": f"{len(versions)} distinct ref(s) with no images.env pin — nothing sweeps them"}}
        rows.append(row)
    return rows


def extract_helm_tofu():
    rows = []
    vars_src = "\n".join(read(p) for p in repo_files("tofu/*.tf"))  # a variable may sit beside its resource (longhorn.tf)
    for path in repo_files("tofu/*.tf"):
        src = read(path)
        for m in re.finditer(r'resource\s+"helm_release"\s+"(\w+)"\s*\{(.*?)\n\}', src, re.S):
            body = m.group(2)
            chart = re.search(r'\n\s*chart\s*=\s*"([^"]+)"', body)
            ver = re.search(r'\n\s*version\s*=\s*(var\.(\w+)|"([^"]+)")', body)
            if not chart or not ver:
                continue
            var = ver.group(2)
            if var in SUBSTRATE_VARS:
                continue  # class 6 carries Cilium
            version = tofu_default(vars_src, var) if var else ver.group(3)
            if version is None:
                die(f"{rel(path)}: helm_release {m.group(1)} pins version = var.{var} but no string default was found in tofu/*.tf")
            declared = next((rel(p) for p in repo_files("tofu/*.tf") if re.search(r'variable\s+"%s"' % re.escape(var or ""), read(p))), None)
            rows.append({"name": chart.group(1), "version": version,
                         "where": [rel(path)] + ([declared] if declared and declared != rel(path) else []),
                         "match": [chart.group(1)] + ([var] if var else [])})
    return rows


def extract_tofu_providers():
    rows = []
    for versions_tf in repo_files("tofu/**/versions.tf"):
        root = os.path.dirname(versions_tf)
        constraints = dict(re.findall(r'source\s*=\s*"([^"]+)"\s*\n\s*version\s*=\s*"([^"]+)"', read(versions_tf)))
        locked = {}
        lock = os.path.join(root, ".terraform.lock.hcl")
        if os.path.exists(lock):
            for m in re.finditer(r'provider\s+"[^"]*?/([^/"]+/[^/"]+)"\s*\{\s*\n\s*version\s*=\s*"([^"]+)"', read(lock)):
                locked[m.group(1).lower()] = m.group(2)
        for source, constraint in sorted(constraints.items()):
            pin = locked.get(source.lower())
            rows.append({"name": source, "key": f"{source}@{rel(root)}",
                         "version": (pin or "unlocked") + f" (`{constraint}`)",
                         "where": [rel(versions_tf)] + ([rel(lock)] if pin else []),
                         # the short name is what Renovate puts in the title/branch ("update terraform
                         # random to …", `renovate/random-3.9.x-lockfile`); safe because a proof must
                         # also touch one of THIS row's files
                         "match": [source, source.rsplit("/", 1)[-1]]})
    return rows


def extract_substrate():
    src = read(os.path.join(ROOT, "tofu", "variables.tf"))
    rows = []
    for var, label in SUBSTRATE_VARS.items():
        default = tofu_default(src, var)
        if default is None:
            die(f"tofu/variables.tf: no string default for {var} (renamed? update SUBSTRATE_VARS)")
        rows.append({"name": label, "version": default, "where": ["tofu/variables.tf"], "match": [var]})
    return rows


def extract_devbox():
    lock = json.loads(read(os.path.join(ROOT, "devbox.lock")))
    rows = []
    for key, pkg in sorted((lock.get("packages") or {}).items()):
        if key.startswith("github:"):
            # a flake ref: `github:NixOS/nixpkgs/<rev>#attr` (a pinned attr) or `github:NixOS/nixpkgs/<branch>`
            ref, _, attr = key.partition("#")
            rev = re.search(r"/([0-9a-f]{40})(?:\?|#|$)", pkg.get("resolved", "") + "#") or re.search(r"/([0-9a-f]{40})$", ref)
            name = attr or ref.rsplit("/", 1)[-1]
            version = f"{ref.split('/')[1]}@{rev.group(1)[:12]}" if rev else "unpinned"
            rows.append({"name": name, "version": version, "where": ["devbox.lock"],
                         "match": [f'"{key}"'] + ([rev.group(1)[:12]] if rev else [])})
            continue
        name = key.split("@", 1)[0]
        rows.append({"name": name, "version": pkg.get("version", "?"), "where": ["devbox.lock"],
                     "match": [f'"{key}"', f"-{name}-{pkg.get('version', '')}"]})
    return rows


def extract_github_actions():
    found = {}
    for path in repo_files(".github/workflows/*.yml") + repo_files(".github/workflows/*.yaml"):
        for line in read(path).splitlines():
            if line.lstrip().startswith("#"):
                continue
            m = re.search(r"uses:\s*([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@([A-Za-z0-9_.-]+)(?:\s*#\s*(\S+))?", line)
            if not m or m.group(1).startswith(("./", "docker://", "teststuffstash/")):
                continue
            name = m.group(1)
            ver = m.group(2) + (f" ({m.group(3)})" if m.group(3) else "")
            entry = found.setdefault(name, {"versions": set(), "files": set()})
            entry["versions"].add(ver)
            entry["files"].add(rel(path))
    return [{"name": n, "version": ", ".join(sorted(e["versions"])), "where": sorted(e["files"]), "match": [n]}
            for n, e in found.items()]


def extract_ansible():
    rows = []
    path = os.path.join(ROOT, "ansible", "requirements.yml")
    if not os.path.exists(path):
        return rows
    for doc in yaml_docs(path):
        if not isinstance(doc, dict):
            continue
        for kind in ("roles", "collections"):
            for item in doc.get(kind) or []:
                if isinstance(item, dict) and item.get("name"):
                    rows.append({"name": item["name"], "version": str(item.get("version", "unpinned")),
                                 "where": ["ansible/requirements.yml"], "match": [item["name"]]})
    return rows


def extract_arc_runner():
    path = os.path.join(ROOT, "docker", "arc-runner", "Dockerfile")
    src = read(path)
    rows = []
    for m in re.finditer(r"^FROM\s+(\S+)", src, re.M):
        ref = REF_RE.match(m.group(1))
        if ref:
            rows.append({"name": ref.group("name"), "version": ref.group("tag") or "?", "where": [rel(path)],
                         "match": [ref.group("name").rsplit("/", 1)[-1]]})
    dep_names = {"DEVBOX_VERSION": "jetify-com/devbox", "NIX_VERSION": "NixOS/nix"}  # renovate-global.json depNameTemplate
    for m in re.finditer(r"^ARG\s+(DEVBOX_VERSION|NIX_VERSION)=([0-9.]+)", src, re.M):
        rows.append({"name": dep_names[m.group(1)], "version": m.group(2), "where": [rel(path)],
                     "match": [f"ARG {m.group(1)}="]})
    return rows


def extract_npm():
    rows = []
    for path in repo_files("scripts/*/package.json"):
        pkg = json.loads(read(path))
        for section in ("dependencies", "devDependencies"):
            for name, ver in sorted((pkg.get(section) or {}).items()):
                rows.append({"name": name, "version": ver, "where": [rel(path)], "match": [f'"{name}"']})
    return rows


def extract_all(registry):
    refs = parse_image_refs()
    extractors = {
        "helm_gitops": extract_helm_gitops,
        "images_gitops": lambda: extract_images_gitops(refs),
        "first_party_images": lambda: extract_first_party_images(refs),
        "helm_tofu": extract_helm_tofu,
        "tofu_providers": extract_tofu_providers,
        "substrate": extract_substrate,
        "devbox": extract_devbox,
        "github_actions": extract_github_actions,
        "ansible": extract_ansible,
        "arc_runner": extract_arc_runner,
        "npm": extract_npm,
        "none": lambda: [],
    }
    rows = []
    for cls in registry["classes"]:
        fn = extractors.get(cls["extract"])
        if fn is None:
            die(f"registry: class {cls['id']}: unknown extractor {cls['extract']!r}")
        for row in fn():
            row["class"] = cls["id"]
            row.setdefault("key", row["name"])
            row["key"] = f"{cls['id']}:{row['key']}"
            row.setdefault("overrides", {})
            overrides = registry.get("overrides") or {}
            # by printed name first, then by the full row key (`<class>:<name>@<where>`) — the key
            # form is for a dependency pinned in several places where only one of them differs
            for col, cell in list(overrides.get(row["name"], {}).items()) + list(overrides.get(row["key"], {}).items()):
                row["overrides"][col] = cell
            rows.append(row)
    keys = [r["key"] for r in rows]
    dupes = sorted({k for k in keys if keys.count(k) > 1})
    if dupes:
        die(f"duplicate row keys: {dupes}")
    known = {r["name"] for r in rows} | set(keys)
    for name in (registry.get("overrides") or {}):
        if name not in known:
            die(f"registry: override {name!r} matches no row (renamed or unpinned? — a dead override is a stale ruling)")
    return sorted(rows, key=lambda r: (r["class"], r["name"].lower(), r["key"]))


# ── the seventh column ─────────────────────────────────────────────────────────────────────────


def gh_api(path):
    out = subprocess.run(["gh", "api", path], check=True, stdout=subprocess.PIPE, text=True).stdout
    return json.loads(out)


def fetch_proof_prs(prefixes, pages):
    """Merged PRs of REPO per proposer head prefix (the Search API's `head:` qualifier — a plain
    closed-PR walk sorted by update misses a weekly `devbox-update` behind a wave of fresher
    closes), with their files (filename + added lines + hunk headers)."""
    prs, seen = [], set()
    for prefix in prefixes:
        for page in range(1, pages + 1):
            q = f"repo:{REPO} is:pr is:merged head:{prefix}"
            found = gh_api(f"search/issues?q={q.replace(' ', '+')}&sort=updated&order=desc&per_page=100&page={page}")
            items = found.get("items") or []
            for item in items:
                if item["number"] in seen:
                    continue
                pr = gh_api(f"repos/{REPO}/pulls/{item['number']}")
                head = (pr.get("head") or {}).get("ref", "")
                if pr.get("merged_at") and head.startswith(prefix):
                    seen.add(item["number"])
                    prs.append({"number": pr["number"], "merged_at": pr["merged_at"], "head": head,
                                "title": pr.get("title", ""), "files": None})
            if len(items) < 100:
                break
    for pr in prs:
        files, page = [], 1
        while True:
            batch = gh_api(f"repos/{REPO}/pulls/{pr['number']}/files?per_page=100&page={page}")
            for f in batch:
                patch = (f.get("patch") or "").splitlines()
                files.append({"filename": f.get("filename", ""),
                              "text": [ln[1:] for ln in patch if ln.startswith("+")]})
            if len(batch) < 100:
                break
            page += 1
        pr["files"] = files
    return sorted(prs, key=lambda p: p["number"])


def newer(a, b):
    return a if (b is None or (a and a["merged_at"] > b["merged_at"])) else b


def attribute_proofs(registry, rows, prs, proofs):
    """Per row: the newest merged proposer PR that touched one of the row's pinned files AND named
    the dependency (in its added lines, title or branch — a lockfile bump's `provider "…"` line is
    diff CONTEXT, so only the title / `renovate/<dep>-…` branch carry the name; hunk headers are NOT
    used: git's funcname context names the PREVIOUS provider block for a change on a block's first
    lines, which mis-attributed every lockfile PR on the first run).
    Per class: the newest proposer PR that touched the class's proof paths at all."""
    class_proofs = {str(c["id"]): proofs.get("classes", {}).get(str(c["id"])) for c in registry["classes"]}
    row_proofs = dict(proofs.get("rows", {}))
    by_class = {c["id"]: c for c in registry["classes"]}
    for pr in prs:
        for cls in registry["classes"]:
            if not any(pr["head"].startswith(p) for p in cls["proof_head_prefixes"]):
                continue
            files = [f for f in pr["files"] if any(f["filename"].startswith(p) for p in cls["proof_paths"])]
            if not files:
                continue
            record = {"pr": pr["number"], "merged_at": pr["merged_at"], "title": pr["title"]}
            class_proofs[str(cls["id"])] = newer(record, class_proofs.get(str(cls["id"])))
            touched = {f["filename"] for f in files}
            text = "\n".join([pr["title"], pr["head"]] + [ln for f in files for ln in f["text"]]).lower()
            for row in rows:
                if row["class"] != cls["id"] or not touched.intersection(row["where"]):
                    continue
                if any(m.lower() in text for m in row["match"]):
                    row_proofs[row["key"]] = newer(record, row_proofs.get(row["key"]))
    # the ledger-backed classes (no proposer PR by design)
    for cls in registry["classes"]:
        if cls.get("ledger_row"):
            class_proofs[str(cls["id"])] = ledger_proof(cls["ledger_row"])
    live_keys = {r["key"] for r in rows}
    row_proofs = {k: v for k, v in row_proofs.items() if k in live_keys}
    for row in rows:
        row["proof"] = row_proofs.get(row["key"])
        if by_class[row["class"]].get("ledger_row"):
            row["proof"] = class_proofs[str(row["class"])]
    return {"classes": {k: v for k, v in class_proofs.items() if v}, "rows": row_proofs}


def ledger_proof(surface):
    """The capability ledger (docs/management-box.md §The capability ledger, FU-097): the row whose
    Surface cell starts with `surface` → its 'Tested on its own' date + evidence."""
    src = read(LEDGER)
    section = src.split("### The capability ledger", 1)
    if len(section) < 2:
        die("docs/management-box.md: no §The capability ledger heading")
    for line in section[1].splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) >= 4 and cells[0].startswith(surface):
            date = re.search(r"\d{4}-\d{2}-\d{2}", cells[2])
            if not date:
                die(f"capability ledger row {surface!r}: no date in the 'Tested on its own' cell ({cells[2]!r})")
            return {"pr": None, "merged_at": date.group(0) + "T00:00:00Z",
                    "title": f"capability ledger — {cells[0]}: {cells[3]}"}
    die(f"capability ledger: no row starting with {surface!r}")


# ── rendering ──────────────────────────────────────────────────────────────────────────────────


def cell_of(cls, row, col):
    return row["overrides"].get(col) or cls[col]


def md(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def proof_md(proof):
    if not proof:
        return "— never"
    date = proof["merged_at"][:10]
    if proof.get("pr"):
        return f"{date} ([#{proof['pr']}](https://github.com/{REPO}/pull/{proof['pr']}))"
    return f"{date} ({md(proof['title'])})"


def summarize(registry, rows, proofs):
    """Per-class facts — the same dict feeds the class table and the exporter JSON."""
    out = []
    for cls in registry["classes"]:
        mine = [r for r in rows if r["class"] == cls["id"]]
        gap_cells = [c for c in COLUMNS if cls[c]["status"] == "gap"]
        human_cells = [c for c in COLUMNS if cls[c]["status"] == "human"]
        gap_rows = [r for r in mine if any(cell_of(cls, r, c)["status"] == "gap" for c in COLUMNS)]
        proof = proofs["classes"].get(str(cls["id"]))
        complete = not gap_cells and not gap_rows and proof is not None
        out.append({"id": cls["id"], "name": cls["name"], "rows": len(mine), "gap_rows": len(gap_rows),
                    "gap_cells": gap_cells, "human_cells": human_cells, "complete": complete,
                    "owner_may_leave": complete and not human_cells,
                    "last_proven": proof["merged_at"] if proof else None,
                    "last_proven_pr": proof.get("pr") if proof else None})
    return out


def render(registry, rows, proofs, summary):
    lines = [BEGIN, ""]
    n_rows, n_gap = len(rows), sum(s["gap_rows"] for s in summary)
    lines.append(f"**{n_rows} pinned dependencies in {len(registry['classes'])} classes; {n_gap} rows carry a ⚠ column; "
                 f"{sum(1 for s in summary if s['complete'])} class(es) complete, "
                 f"{sum(1 for s in summary if s['owner_may_leave'])} of them without a 👤 cell.** "
                 "✅ built and proven · 👤 a human by ruling (filled, not a gap — the owner stays by design) · "
                 "⚠ missing. A row is complete when no column is ⚠ and the proof is recent "
                 f"(≤{registry['proof_recent_days']} d — `DependencyClassProofStale` fires when a complete class's proof ages out; "
                 "`github_dependency_coverage_gap_rows` counts the ⚠ rows).")
    lines.append("")
    lines.append("#### Per class — the seven columns")
    lines.append("")
    lines.append("| # | Class | Pinned where · manager | " + " | ".join(COLUMN_TITLES[c] for c in COLUMNS)
                 + " | Last proven E2E | Rows (⚠) | Owner may leave? |")
    lines.append("|---|---|---|" + "---|" * len(COLUMNS) + "---|---|---|")
    for cls, s in zip(registry["classes"], summary):
        cells = [f"{GLYPH[cls[c]['status']]} {md(cls[c]['text'])}" for c in COLUMNS]
        proof = proofs["classes"].get(str(cls["id"]))
        if s["owner_may_leave"]:
            verdict = "**yes** — complete"
        elif s["complete"]:
            verdict = "no — complete, but a 👤 cell keeps the human by ruling"
        else:
            reasons = ([f"{len(s['gap_cells'])} ⚠ column(s)"] if s["gap_cells"] else [])
            if s["gap_rows"] and not s["gap_cells"]:
                reasons.append(f"{s['gap_rows']} ⚠ row(s)")
            if not proof:
                reasons.append("never proven")
            verdict = "no — " + ", ".join(reasons)
        lines.append(f"| {cls['id']} | **{md(cls['name'])}** | {md(cls['where'])} · `{md(cls['manager'])}` | "
                     + " | ".join(cells) + f" | {proof_md(proof)} | {s['rows']} ({s['gap_rows']}) | {verdict} |")
    lines.append("")
    lines.append("#### Per dependency — the register")
    lines.append("")
    lines.append("Columns P/G/D/Det/R/C are the class's proposer / merge gate / deploy edge / detector / revert / "
                 "canary; a cell carries text only where the dependency differs from its class. "
                 "Last proven = the newest merged proposer PR whose diff named the dependency (class 6: the capability ledger).")
    lines.append("")
    lines.append("| Class | Dependency | Version | Pinned in | P | G | D | Det | R | C | Last proven E2E |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|")
    by_id = {c["id"]: c for c in registry["classes"]}
    for row in rows:
        cls = by_id[row["class"]]
        glyphs = []
        for col in COLUMNS:
            cell = cell_of(cls, row, col)
            glyphs.append(GLYPH[cell["status"]] + (f" {md(cell['text'])}" if col in row["overrides"] else ""))
        where = ", ".join(f"`{w}`" for w in row["where"][:3]) + (f" +{len(row['where']) - 3}" if len(row["where"]) > 3 else "")
        lines.append(f"| {row['class']} | `{md(row['name'])}` | {md(row['version'])} | {where} | "
                     + " | ".join(glyphs) + f" | {proof_md(row.get('proof'))} |")
    lines += ["", END]
    return "\n".join(lines)


def inject(doc_src, block):
    pattern = re.compile(r"<!-- BEGIN GENERATED %s\b.*?<!-- END GENERATED %s -->" % (re.escape(KEY), re.escape(KEY)), re.S)
    if not pattern.search(doc_src):
        die(f"{rel(DOC)}: no `<!-- BEGIN GENERATED {KEY} … -->` / `<!-- END GENERATED {KEY} -->` marker pair")
    return pattern.sub(lambda _m: block, doc_src, count=1)


def exporter_json(registry, rows, proofs, summary):
    by_id = {c["id"]: c for c in registry["classes"]}
    payload = {
        "generated_by": "scripts/dependency-coverage.py (devbox run dependency-coverage) — never hand-edit",
        "proof_recent_days": registry["proof_recent_days"],
        "classes": summary,
        "rows": [{"key": r["key"], "class": r["class"], "name": r["name"], "version": r["version"],
                  "where": r["where"],
                  "gap_columns": sorted(c for c in COLUMNS if cell_of(by_id[r["class"]], r, c)["status"] == "gap"),
                  "last_proven": (r.get("proof") or {}).get("merged_at")}
                 for r in rows],
        "proofs": proofs,
    }
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


# ── main ───────────────────────────────────────────────────────────────────────────────────────


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--offline", action="store_true", help="reuse the committed proofs; no `gh api`")
    ap.add_argument("--check", action="store_true", help="offline; exit 1 if the committed outputs are stale")
    ap.add_argument("--pages", type=int, default=1, help="search pages (×100 merged PRs) per proposer prefix")
    args = ap.parse_args()
    registry = load_registry()
    rows = extract_all(registry)
    previous = json.loads(read(JSON_OUT)).get("proofs", {}) if os.path.exists(JSON_OUT) else {}
    prs = []
    if not (args.offline or args.check):
        prefixes = sorted({p for c in registry["classes"] for p in c["proof_head_prefixes"]})
        prs = fetch_proof_prs(prefixes, args.pages)
    proofs = attribute_proofs(registry, rows, prs, previous)
    summary = summarize(registry, rows, proofs)
    block = render(registry, rows, proofs, summary)
    doc_new = inject(read(DOC), block)
    json_new = exporter_json(registry, rows, proofs, summary)
    stale = [rel(p) for p, new in ((DOC, doc_new), (JSON_OUT, json_new))
             if not os.path.exists(p) or read(p) != new]
    if args.check:
        if stale:
            print(f"dependency-coverage: FAIL — generated output is stale for: {' '.join(stale)}", file=sys.stderr)
            print("  fix: devbox run dependency-coverage -- --offline   (or without --offline to refresh the proofs)",
                  file=sys.stderr)
            sys.exit(1)
        print(f"dependency-coverage: outputs current ({len(rows)} rows, {len(registry['classes'])} classes)")
        return
    with open(DOC, "w", encoding="utf-8") as handle:
        handle.write(doc_new)
    with open(JSON_OUT, "w", encoding="utf-8") as handle:
        handle.write(json_new)
    gaps = sum(s["gap_rows"] for s in summary)
    print(f"dependency-coverage: {len(rows)} rows / {len(registry['classes'])} classes, {gaps} ⚠ rows, "
          f"{len(prs)} proof PR(s) read → {rel(DOC)}, {rel(JSON_OUT)}"
          + (f" (rewrote: {' '.join(stale)})" if stale else " (no change)"))


if __name__ == "__main__":
    main()
