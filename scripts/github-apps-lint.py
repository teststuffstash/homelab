#!/usr/bin/env python3
"""github-apps-lint — the FU-098 ⊆-invariant: every mint site's requested permissions must be
a subset of the App's DECLARED permissions (docs/github-apps.yaml).

A GithubAccessToken generator that requests a permission the App doesn't hold 422s the whole
mint at runtime (live incident: the fleet#134 workflows-scope gap, 2026-07-25) — this makes it
a CI failure instead. Also sync-checks the exporter's ConfigMap copy of the declared file.

Scanned mint sites (regex, not yaml-parse — the Composition is Go-templated):
    argocd/resources/agentstack/composition.yaml
    agents/coordinator/*.yaml
    argocd/resources/github-exporter/rl-tokens.yaml

Run: devbox run github-apps-lint   (pure-local: no network, no credentials — CI-safe)
"""
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DECLARED = os.path.join(ROOT, "docs", "github-apps.yaml")
EXPORTER_COPY = os.path.join(ROOT, "argocd", "resources", "github-exporter", "github-apps.json")
MINT_GLOBS = [
    "argocd/resources/agentstack/composition.yaml",
    "agents/coordinator/*.yaml",
    "argocd/resources/github-exporter/rl-tokens.yaml",
]
LEVELS = {"read": 1, "write": 2}
# permission names a generator may request (GithubAccessToken spec.permissions keys)
PERM_RE = re.compile(r"^\s{2,}(\w+):\s*(read|write)\s*(#.*)?$")
APPID_RE = re.compile(r'appID:\s*"?(\d+)"?')


def declared():
    out = subprocess.run(["yq", "-o=json", DECLARED], check=True,
                         stdout=subprocess.PIPE, text=True).stdout
    apps = json.loads(out)["apps"]
    by_id, problems = {}, []
    for a in apps:
        perms = {k: v["level"] for k, v in (a.get("permissions") or {}).items()}
        for k, v in (a.get("permissions") or {}).items():
            if not (v.get("why") or "").strip():
                problems.append(f"declared: {a['slug']} permission '{k}' has no why: — a grant without a consumer is blast radius")
        for k in (a.get("absent") or {}):
            if k in perms:
                problems.append(f"declared: {a['slug']} lists '{k}' as BOTH granted and absent")
        if a.get("app_id"):
            by_id[str(a["app_id"])] = (a["slug"], perms)
    return by_id, problems


def mint_sites():
    """Yield (path, line, app_id, {perm: level}) for each GithubAccessToken block."""
    for pattern in MINT_GLOBS:
        for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
            lines = open(path).read().splitlines()
            i = 0
            while i < len(lines):
                if "kind: GithubAccessToken" in lines[i]:
                    start, app_id, perms, in_perms = i + 1, None, {}, False
                    j = i + 1
                    while j < len(lines) and "---" not in lines[j] and "kind: " not in lines[j].replace("kind: GithubAccessToken", ""):
                        m = APPID_RE.search(lines[j])
                        if m:
                            app_id = m.group(1)
                        if re.match(r"^\s+permissions:", lines[j]):
                            in_perms = True
                        elif in_perms:
                            pm = PERM_RE.match(lines[j])
                            if pm:
                                perms[pm.group(1)] = pm.group(2)
                            elif lines[j].strip() and not lines[j].lstrip().startswith("#"):
                                in_perms = False
                        j += 1
                    if app_id and perms:
                        yield os.path.relpath(path, ROOT), start, app_id, perms
                    i = j
                else:
                    i += 1


def main():
    by_id, problems = declared()
    n_sites = 0
    for path, line, app_id, perms in mint_sites():
        n_sites += 1
        if app_id not in by_id:
            problems.append(f"{path}:{line}: mints as app_id {app_id} — not declared in docs/github-apps.yaml")
            continue
        slug, granted = by_id[app_id]
        for perm, level in perms.items():
            have = granted.get(perm)
            if have is None:
                problems.append(f"{path}:{line}: requests {perm}:{level} but {slug} does not declare '{perm}' — the mint 422s in prod (fleet#134 class)")
            elif LEVELS[level] > LEVELS[have]:
                problems.append(f"{path}:{line}: requests {perm}:{level} but {slug} declares only {have}")
    # exporter ConfigMap copy is GENERATED JSON (its slim image has no yaml parser; kustomize
    # can't reach docs/) — must semantically match the canonical yaml or the belt judges drift
    # against a stale declaration. Regenerate: yq -o=json docs/github-apps.yaml > <copy>
    rel = os.path.relpath(EXPORTER_COPY, ROOT)
    if not os.path.exists(EXPORTER_COPY):
        problems.append(f"missing {rel} — regenerate: devbox run -- yq -o=json docs/github-apps.yaml > {rel}")
    else:
        canonical = json.loads(subprocess.run(["yq", "-o=json", DECLARED], check=True,
                                              stdout=subprocess.PIPE, text=True).stdout)
        try:
            copy = json.load(open(EXPORTER_COPY))
        except Exception:
            copy = None
        if copy != canonical:
            problems.append(f"{rel} out of sync with docs/github-apps.yaml — regenerate: devbox run -- yq -o=json docs/github-apps.yaml > {rel}")
    if problems:
        print("github-apps-lint: FAIL", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        sys.exit(1)
    print(f"github-apps-lint: ok ({n_sites} mint sites ⊆ declared; exporter copy in sync)")


if __name__ == "__main__":
    main()
