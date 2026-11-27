#!/usr/bin/env python3
"""The trial's two script-measured numbers per arm (goal #3656 child 5, issue #3661). Prints, one `key=value` per line:

    facts-written-twice.hand / .model   facts of the arm's cases stated in more than one authored file
    edits.hand / .model                 authored lines changed by the fixed policy change, `total (n arm-specific)`
    note.*                              the same count over files the issue's list leaves out; never in the table

A *fact* of a case is the value of one of its cells that decides the verdict: the open assembly PR (a pull request
number), the (b) markers on it (a marker hash), the three expected literals. It is *written twice* when a second
authored file of the arm holds the same text as a string literal (exactly, or as a prefix of 10 or more characters,
how a decoder tests `startswith`). The authored files are fixed by the issue: `specs/models/scan-clause-goal-b.yaml`
for `model`; `trial/checkpoint-b-hand.md` and the hand arm's decoding in `tests/test_checkpoint_b.py` for `hand`.
Edits: the added plus deleted lines of `trial/policy-change/<arm>.diff`; the diffs hold no generated file.
Run from anywhere: `python islands/scan/trial/measure.py`.
"""

from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
HAND = ISLAND / "trial" / "checkpoint-b-hand.md"
MODEL = ISLAND / "specs" / "models" / "scan-clause-goal-b.yaml"
DECODING = ISLAND / "tests" / "test_checkpoint_b.py"
RENDERER = ISLAND / "scripts" / "render_model.py"
DIFFS = ISLAND / "trial" / "policy-change"
FACTS = ["open_assembly_pr", "b_markers_on_it", "b_this_wake", "marker_write", "b_next_wake"]
HAND_COLUMNS = {"open_assembly_pr": 2, "b_markers_on_it": 3, "b_this_wake": 7, "marker_write": 8, "b_next_wake": 9}
SKIP = {"—"}


def hand_cases() -> list[dict]:
    rows = []
    for line in HAND.read_text("utf-8").splitlines():
        if line.startswith("| ") and not line.startswith("| description"):
            cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip()[1:-1])]
            if len(cells) == 10:
                rows.append({k: cells[i] for k, i in HAND_COLUMNS.items()})
    return rows


def model_cases() -> list[dict]:
    return [{**{k: c[k] for k in FACTS[:2]}, **{k: c["expect"][k] for k in FACTS[2:]}} for c in json.loads(MODEL.read_text("utf-8"))["cases"]]


def literals(path: Path) -> set[str]:
    return {n.value for n in ast.walk(ast.parse(path.read_text("utf-8"))) if isinstance(n, ast.Constant) and isinstance(n.value, str)}


def twice(cases: list[dict], others: list[Path]) -> int:
    held = set().union(*(literals(p) for p in others)) if others else set()
    return sum(
        1
        for case in cases
        for k in FACTS
        if case[k] not in SKIP and any(case[k] == s or (len(s) >= 10 and case[k].startswith(s)) for s in held)
    )


def edits(arm: str, own: str) -> str:
    total = mine = 0
    path = None
    for line in (DIFFS / f"{arm}.diff").read_text("utf-8").splitlines():
        if line.startswith("diff --git"):
            path = line.split(" b/", 1)[1]
        elif line[:1] in "+-" and not line.startswith(("+++", "---")):
            total += 1
            mine += path == own
    return f"{total} ({mine} arm-specific)"


def measures() -> dict[str, str]:
    return {
        "facts-written-twice.hand": str(twice(hand_cases(), [DECODING])),
        "facts-written-twice.model": str(twice(model_cases(), [])),
        "edits.hand": edits("hand", "trial/checkpoint-b-hand.md"),
        "edits.model": edits("model", "specs/models/scan-clause-goal-b.yaml"),
        "note.facts-written-twice.model-with-renderer-and-decoding": str(twice(model_cases(), [RENDERER, DECODING])),
    }


def main() -> int:
    for k, v in measures().items():
        print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
