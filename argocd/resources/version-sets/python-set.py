#!/usr/bin/env python3
"""python-set — the platform's Python version SET agrees on one major.minor (docs/dependency-upgrades.md
§Version SETS; the gateway island's twin is gateway/tests/test_python_version_set.py).

Members: the repo-root devbox python (devbox.json + devbox.lock — the interpreter every ConfigMap
script's `--self-test` runs under in ci) and every `python:X.Y` image pin in a manifest or script
under argocd/resources/ and scripts/ (the interpreter those scripts deploy on). Renovate starts a
bump by moving an image tag; this check reds the PR until the other members follow, naming the odd
one(s). Static text scan of tracked files: no network, no Docker, no interpreter launch. Not part of
the probe's ConfigMap (kustomization.yaml ships probe.py only).

    python3 argocd/resources/version-sets/python-set.py     # check the tree, then the mutation rows

Decision table (row = output line):

| row | probe | expect |
|---|---|---|
| the Python version set agrees | every member's major.minor | one value |
| bumping only `<member>` is red, naming it | that member mutated to 9.99 | red; names the member + the majority |
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# devbox's search index can lag nixpkgs (homelab#2610), so the devbox members read the nixpkgs
# flake-ref form `github:NixOS/nixpkgs/<rev>#python3NN` → "3.NN" as well as `python@X.Y` /
# `"python3": {"version": "X.Y"}`, so a swap back to the index form stays green.
_FLAKE = r"github:NixOS/nixpkgs/[0-9a-f]+#python(\d)(\d{2,})"
DEVBOX_MEMBERS = {
    "devbox.json python": (
        "devbox.json",
        rf'"{_FLAKE}"\s*:|"python3?@(\d+)\.(\d+)[^"]*"\s*:|"python3?"\s*:\s*\{{\s*"version"\s*:\s*"(\d+)\.(\d+)'),
    "devbox.lock python": (
        "devbox.lock",
        rf'^\s*"(?:{_FLAKE}|python3?@(\d+)\.(\d+)[^"]*)"\s*:|^\s*"python3?@[^"]*"\s*:\s*\{{[^}}]*?"version"\s*:\s*"(\d+)\.(\d+)'),
}
# an image PIN (an `image:` value or a Dockerfile FROM), never prose — a comment that names a tag is
# documentation, and recorded data (*.json, fixtures/) is history
IMAGE_RE = r'^\s*(?:-\s*)?(?:image:\s*["\']?|FROM\s+)(?:docker\.io/library/)?python:(\d+)\.(\d+)'
IMAGE_TREES = ("argocd/resources/", "scripts/")
IMAGE_SKIP = re.compile(r"(^|/)fixtures/|\.json$")


def _ver(m: re.Match[str] | None) -> str:
    return ".".join(g for g in m.groups() if g is not None) if m else "<not found>"


def image_files() -> list[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", *IMAGE_TREES],
                         check=True, capture_output=True, text=True).stdout.split()
    return sorted(f for f in out if not IMAGE_SKIP.search(f))


def members(texts: dict[str, str]) -> dict[str, str]:
    """{member: major.minor}. One member per devbox file, one per image file (its first pin; a
    file whose pins disagree is reported as a member per distinct value)."""
    out = {name: _ver(re.search(rx, texts[f], re.MULTILINE)) for name, (f, rx) in DEVBOX_MEMBERS.items()}
    for f, text in texts.items():
        if f in ("devbox.json", "devbox.lock"):
            continue
        vers = sorted({_ver(m) for m in re.finditer(IMAGE_RE, text, re.MULTILINE)})
        for v in vers:
            out[f if len(vers) == 1 else f"{f} ({v})"] = v
    return out


def problem(vers: dict[str, str]) -> str | None:
    if len(set(vers.values())) == 1:
        return None
    counts: dict[str, int] = {}
    for v in vers.values():
        counts[v] = counts.get(v, 0) + 1
    majority = max(counts, key=lambda v: (counts[v], v))
    odd = [m for m, v in vers.items() if v != majority]
    return ("the Python version set must agree on one major.minor — move every member together "
            "(root devbox.json + devbox.lock, every python:X.Y image pin under argocd/resources/ and scripts/):\n"
            + "\n".join(f"  {m}: {v}" for m, v in vers.items())
            + f"\nmajority={majority}; odd one(s) out: {', '.join(odd)}")


def _mutate(rx: str, text: str) -> str:
    """Rewrite the first match's version groups to read 9.99 ("X","Y" → "9","99")."""
    m = re.search(rx, text, re.MULTILINE)
    assert m, rx
    spans = [m.span(i) for i, g in enumerate(m.groups(), 1) if g is not None]
    for (lo, hi), r in reversed(list(zip(spans, ["9", "99"], strict=True))):
        text = text[:lo] + r + text[hi:]
    return text


def main() -> int:
    files = ["devbox.json", "devbox.lock"]
    imgs = [f for f in image_files() if re.search(IMAGE_RE, (ROOT / f).read_text(encoding="utf-8", errors="replace"), re.MULTILINE)]
    texts = {f: (ROOT / f).read_text(encoding="utf-8", errors="replace") for f in files + imgs}
    vers = members(texts)
    fails = 0
    # positive control: an empty member list would make "agrees" vacuous
    if "<not found>" in vers.values() or not imgs:
        print(f"FAIL the Python version set agrees — a member pattern no longer matches / no image pins found "
              f"(an unpinned devbox `python3@latest` has no major.minor in devbox.json — pin it): {vers}")
        return 1
    p = problem(vers)
    print(("ok   " if p is None else "FAIL ") + f"the Python version set agrees ({len(vers)} members, {sorted(set(vers.values()))})")
    if p:
        print(p)
        fails += 1
    # mutation rows: a one-member move is red and names exactly that member
    rows = [(n, f, rx) for n, (f, rx) in DEVBOX_MEMBERS.items()] + [(f, f, IMAGE_RE) for f in imgs]
    for name, f, rx in rows:
        if name not in vers:   # a file whose own pins already disagree is reported above
            continue
        t = dict(texts)
        t[f] = _mutate(rx, t[f])
        q = problem(members(t))
        ok = (q is not None and f"odd one(s) out: {name}" in q and f"{name}: 9.99" in q
              and f"majority={vers[name]}" in q)
        print(("ok   " if ok else "FAIL ") + f"bumping only {name} is red, naming it")
        fails += not ok
    print(f"python-set: {'ok' if fails == 0 else f'{fails} failing row(s)'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
