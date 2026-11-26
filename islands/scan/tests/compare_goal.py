"""The `goal` replay family's trigger-(b) rows as a comparison (goal #3656 child 4; the mechanism of tests/compare.py, one fact).

For a row, two answers to one question — *is trigger (b) held on this wake?*:

- **old** — the old member run on the family's own world through the replay adapter (`replay.run_row`,
  the composed clause of `old_subjects.old_goal`): the stream holds a `HELD` line for trigger (b);
- **new** — `scan_island.checkpoint_b evaluate` over the recorded world `goal-checkpoint`, on the row's
  answers lifted onto it: the decision line is `HELD`.

The lift, for the two facts the component reads. The family's open-PR list (`prsjson.json`) holds the
assembly pull request or not: its element becomes the open-list element (copied from a recorded element
of `goal-checkpoint`, its number, head branch, body, head commit id and review decision those of the
family's element, the Goal number in the trailer re-addressed to #3118). The comments of that pull
request are the bodies of the comments of the family's `pr view <n>` answer, each laid over a comment
copied from a recorded one (the ten recorded (b) markers on #3270 get a plain body first, so the only
(b) marker the component can see is the family's). Nothing else of the family is read by the component.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .old_subjects import GOAL_DIR, old_goal
from .replay import ReplayRed, Row, load_family, load_rows, materialise, run_row
from .sequence import derive_open_pr, overlay
from .world import World

WORLD = "goal-checkpoint"
GOAL = "3118"
COMMENTS = "api.issues.3270.comments@per_page=100.json"
STAMP = "🤖 `state-fp:goal-checkpoint-b:"
OLD_HELD = re.compile(rb"^OUT .*child-set complete pre-launch HELD\b", re.M)
RULINGS_FILE = Path(__file__).resolve().parent / "comparison" / "goal-checkpoint-b.rulings"
NEW = [sys.executable, "-m", "scan_island.checkpoint_b"]


def compared_ids() -> list[str]:
    """`child-set-complete` and every id that starts `goal-checkpoint-b-`, in the family's order."""
    fam = load_family(GOAL_DIR)
    return [r.id for r in load_rows(fam) if r.id == "child-set-complete" or r.id.startswith("goal-checkpoint-b-")]


def family_row(row_id: str) -> tuple:
    fam = load_family(GOAL_DIR)
    [row] = [r for r in load_rows(fam) if r.id == row_id]
    return fam, row


@dataclass
class Facts:
    old_held: bool
    new_held: bool | None  # None: not liftable (the reason says why)
    reason: str | None = None

    @property
    def differs(self) -> bool:
        return self.new_held is None or self.old_held != self.new_held


_OLD: dict[str, tuple[bool, bool]] = {}


def old_fact(row_id: str) -> tuple[bool, bool]:
    """(the old member holds trigger (b), its stream equals the family's expected file)."""
    if row_id not in _OLD:
        fam, row = family_row(row_id)
        actual, expected = run_row(fam, row, old_goal(fam, row))
        _OLD[row_id] = (bool(OLD_HELD.search(actual)), actual == expected)
    return _OLD[row_id]


def lifted_world(fam, row: Row) -> tuple[World, str]:
    """The row's answers laid onto `goal-checkpoint`; returns the world and the slug to ask about."""
    with tempfile.TemporaryDirectory() as t:
        synth = materialise(fam, row, Path(t).resolve()) / "world"
        listed = json.loads((synth / "prsjson.json").read_text("utf-8"))
        views = {p.name: json.loads(p.read_text("utf-8")) for p in (synth / "gh").glob("pr-view-*.json")}
    w = World(WORLD)
    repo = w.provenance["repo"]
    for i, c in enumerate(w.get(COMMENTS, ())):
        if c["body"].startswith(STAMP):
            w.set(COMMENTS, (i, "body"), f"(the recorded checkpoint-b marker, neutralised: {c['id']})")
    for element in listed:
        derived = derive_open_pr(w)[0]
        n = element["number"]
        w.set("pr-list.json", (derived.index, "number"), n)
        w.set("pr-list.json", (derived.index, "headRefName"), element["headRefName"])
        w.set("pr-list.json", (derived.index, "body"), re.sub(r"(?m)^(Assembly-for: #)\d+", rf"\g<1>{GOAL}", element["body"]))
        w.set("pr-list.json", (derived.index, "headRefOid"), element["headRefOid"])
        w.set("pr-list.json", (derived.index, "reviewDecision"), element["reviewDecision"])
        # the comments read of #n: the recorded #3270 list, aliased (its own read is not recorded for another number)
        w.provenance["reads"].append({"argv": ["api", f"repos/{repo}/issues/{n}/comments?per_page=100"], "file": COMMENTS, "auth": "token"})
        for comment in views.get(f"pr-view-{n}.json", {}).get("comments", []):
            overlay(w, COMMENTS, comment["body"], 0)
    return w, repo


def new_fact(row_id: str) -> tuple[bool | None, str | None]:
    fam, row = family_row(row_id)
    try:
        w, repo = lifted_world(fam, row)
    except (ReplayRed, ValueError, KeyError) as e:
        return None, f"not liftable: {e}"
    run = w.run([*NEW, "evaluate", repo, GOAL])
    if run.rc != 0:
        return None, f"the component answered rc {run.rc}: {run.stderr.strip()}"
    return " HELD: " in run.stdout, None


def facts(row_id: str) -> Facts:
    old_held, _ = old_fact(row_id)
    new_held, reason = new_fact(row_id)
    return Facts(old_held, new_held, reason)


def load_rulings(known: set[str]) -> dict[str, tuple[str, str]]:
    from .compare import parse_rulings

    return parse_rulings(RULINGS_FILE.read_text("utf-8"), known, RULINGS_FILE.name)


def verdict(f: Facts, ruling: tuple[str, str] | None) -> str | None:
    """None when the row passes: the facts agree and no ruling stands, or they differ and a ruling does."""
    if f.differs and ruling is None:
        return f"unruled difference — old member holds (b): {f.old_held}, new component holds (b): {f.new_held} ({f.reason or 'compared'}); rule it spec/old/new in {RULINGS_FILE.name}"
    if not f.differs and ruling is not None:
        return f"ruling `{ruling[0]}` for a row that does not differ — remove it"
    return None
