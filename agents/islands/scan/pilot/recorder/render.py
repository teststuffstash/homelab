#!/usr/bin/env python3
"""render — a row's PERSONA: the projection of its full-shape world onto what one requirement reads.

    render.py --family <full family dir> --row <id> --req PICK|UNSTRAND|CONFLICT|RENOVATE

The read sets below are DERIVED BY HAND FROM THE jq PATHS in agents/update-pr-branch.sh and
agents/renovate-currency.sh (line refs inline), not from updater.schema.json: its `x-requirements`
annotate `/properties/pr` as a whole for all four requirements, so the schema cannot tell a PICK
read from a RENOVATE read, and it does not model the per-PR reads (`pr view`, check-runs, status,
the REST body) at all. A path ending in `?` is read for PRESENCE only (`!= null`); its value renders
as "…". Every board PR is rendered with the leg-3 set (leg 3 reads every PR), the row's own PRs
(the ones its patch adds or changes) with the requirement's set.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LEG3 = ["number", "autoMergeRequest?", "mergeStateStatus", "labels[].name"]  # :416-428
READS = {
    # leg 1 pre-filter (:204-211), arms (:235-282), lanes (:292-326), renovate_author gate (:218)
    "PICK": {"board": ["number", "createdAt", "mergeStateStatus", "autoMergeRequest?", "reviewDecision",
                       "labels[].name", "latestReviews[].author.login", "latestReviews[].state",
                       "reviews[].author.login", "reviews[].state", "reviews[].submittedAt",
                       "headRefOid", "baseRefName", "author.login"],
             "pr-view": ["commits[].messageHeadline", "commits[].committedDate"]},
    # leg 2 (:375-410): domain + breakered, the verdict jq, renovate gate
    "UNSTRAND": {"board": ["number", "mergeStateStatus", "autoMergeRequest?", "reviewDecision", "labels[].name",
                           "headRefOid", "author.login"],
                 "pr-view": ["commits[].messageHeadline", "commits[].committedDate", "commits[].authors[].login",
                             "reviews[].author.login", "reviews[].state", "reviews[].submittedAt"]},
    "CONFLICT": {"board": LEG3},
    # renovate-currency.sh: author (:30), probe (:36-46), green/red (:51-68), untouched/merged (:71-80), body (:88-104)
    "RENOVATE": {"board": ["number", "createdAt", "mergeStateStatus", "autoMergeRequest?", "reviewDecision",
                           "labels[].name", "latestReviews[].author.login", "latestReviews[].state",
                           "headRefOid", "baseRefName", "author.login"],
                 "pr-view": ["commits[].messageHeadline", "commits[].committedDate", "commits[].authors[].login"],
                 "check-runs": ["check_runs[].name", "check_runs[].status", "check_runs[].conclusion"],
                 "status": ["statuses[].context", "statuses[].state"],
                 "pull": ["body"]},
}


def project(v, paths: list[str]):
    """Keep only the listed paths (`a.b`, `a[].b`, trailing `?` = presence)."""
    tree: dict = {}
    for p in paths:
        node = tree
        parts = p.replace("[]", ".[]").split(".")
        for i, part in enumerate(parts):
            node = node.setdefault(part, {} if i < len(parts) - 1 else None) if node is not None else None
    return _proj(v, tree)


def _proj(v, tree):
    if tree is None:
        return v
    if "[]" in tree and isinstance(v, list):
        return [_proj(x, tree["[]"]) for x in v]
    if not isinstance(v, dict):
        return v
    out = {}
    for k, sub in tree.items():
        presence = k.endswith("?")
        key = k.rstrip("?")
        if key in v:
            out[key] = ("…" if v[key] is not None else None) if presence else _proj(v[key], sub)
    return out


def materialise(fam: Path, rid: str, dest: Path) -> tuple[Path, str]:
    row = next(ln for ln in (fam / "rows.psv").read_text().splitlines()
               if ln and not ln.startswith("#") and ln.split("|")[0].strip() == rid)
    c = [x.strip() for x in row.split("|")]
    w = dest / "world"
    shutil.copytree(fam / "worlds" / (c[1] or "board"), w)
    if (fam / "rows" / rid).is_dir():
        shutil.copytree(fam / "rows" / rid, w, dirs_exist_ok=True)
    if c[2]:
        rel, _, pf = (x.strip() for x in c[2].partition("@"))
        out = subprocess.run(["jq", "-f", str(fam / pf), str(w / rel)], capture_output=True, check=True).stdout
        (w / rel).write_bytes(out)
    return w, c[2]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--family", required=True)
    ap.add_argument("--row", required=True)
    ap.add_argument("--req", required=True, choices=sorted(READS))
    a = ap.parse_args()
    fam = Path(a.family)
    base_nums = {p["number"] for p in json.loads((fam / "worlds/board/gh/pr-list.json").read_text())}
    base = {p["number"]: p for p in json.loads((fam / "worlds/board/gh/pr-list.json").read_text())}
    reads = READS[a.req]
    with tempfile.TemporaryDirectory() as td:
        w, _ = materialise(fam, a.row, Path(td))
        board = json.loads((w / "gh/pr-list.json").read_text())
        persona: dict = {"board": []}
        for pr in board:
            own = pr["number"] not in base_nums or pr != base[pr["number"]]
            persona["board"].append(project(pr, reads["board"] if own else LEG3))
        for f in sorted((w / "gh").glob("*.json")):
            if f.name == "pr-list.json":
                continue
            kind = ("pr-view" if f.stem.startswith("pr-view") else "check-runs" if "check-runs" in f.stem
                    else "status" if f.stem.endswith("-status") else "pull")
            if kind not in reads:
                continue
            try:
                persona[f.stem] = project(json.loads(f.read_text()), reads[kind])
            except ValueError:
                persona[f.stem] = "(not JSON — a transport-failure persona)"
    print(json.dumps(persona, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
