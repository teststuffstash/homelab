#!/usr/bin/env python3
"""Render the trigger (b) table and the case view from the one YAML model (goal #3656 child 3).

    python scripts/render_model.py            # write the page section and trial/checkpoint-b-view.md
    python scripts/render_model.py --check    # exit 1 when either differs from a fresh render

The model is `specs/models/scan-clause-goal-b.yaml`; the table lands on `specs/scan-decision.md` between
the two marker comments that name it. The view lists, per case, the recorded files and the derived
elements it stands on, its test node id and a result cell that reads `unverified` (no evidence publisher
in this root).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ISLAND = Path(__file__).resolve().parent.parent
MODEL = ISLAND / "specs" / "models" / "scan-clause-goal-b.yaml"
PAGE = ISLAND / "specs" / "scan-decision.md"
VIEW = ISLAND / "trial" / "checkpoint-b-view.md"
MODEL_NAME = "specs/models/scan-clause-goal-b.yaml"
BEGIN = f"<!-- generated from {MODEL_NAME} by scripts/render_model.py — edit the model, not this table -->"
END = f"<!-- end generated: {MODEL_NAME} -->"
HEADER = ["description", "world", "open assembly PR", "(b) markers on it", "since the marker", "fault", "lane winner",
          "(b) this wake?", "marker write?", "(b) next wake?"]
FIELDS = ["id", "world", "open_assembly_pr", "b_markers_on_it", "since_the_marker", "fault", "lane_winner"]
EXPECT = ["b_this_wake", "marker_write", "b_next_wake"]
TEST = "tests/test_checkpoint_b.py::test_trigger_b_hold_model"

# what a cell stands on: recorded files read whole, and the elements derived from recorded ones (pin 5)
OPEN_LIST = {
    "none": ("pr-list.json", "no open assembly PR: the open list has no element for #3118"),
    "A": ("pr-list.json", "open-list element for #3270, copied from a recorded element, values from the recorded #3270 read"),
    "A, its head branch is not a `goal/**` branch": (
        "pr-list.json", "as A, its head branch overridden to `fix/not-a-goal-branch`"),
    "B (A is closed: not in the open list)": (
        "pr-list.json", "as A, its number overridden to B; B's comments read aliased to #3270's recorded list"),
}
MARKERS = {
    "—": "the recorded comments of #3270 as they are",
    "none": "the ten recorded markers given a plain body",
    "the ten recorded on #3270, none of them the marker for A": "the ten recorded markers on #3270, unchanged",
    "the marker for A": "comment copied from a recorded one, body = the marker for A",
    "the marker for A, quoted (each line starts `> `)": "comment copied from a recorded one, body = the marker for A quoted",
    "none on B; the marker for A stays on A": "comment copied from a recorded one, body = the marker for A, in B's list",
    "the marker for A, and the three `state-fp:assembly-cr:` markers recorded on #3270": (
        "comment copied from a recorded one, body = the marker for A; the three recorded assembly-cr markers unchanged"),
}


def load(path: Path = MODEL) -> dict:
    return json.loads(path.read_text("utf-8"))


def esc(cell: str) -> str:
    return cell.replace("|", "\\|")


def table(model: dict) -> str:
    rows = ["| " + " | ".join(HEADER) + " |", "|" + "---|" * len(HEADER)]
    for c in model["cases"]:
        cells = [c[k] for k in FIELDS] + [c["expect"][k] for k in EXPECT]
        rows.append("| " + " | ".join(esc(x) for x in cells) + " |")
    return "\n".join(rows)


def section(model: dict) -> str:
    return f"{BEGIN}\n\n{table(model)}\n\n{END}"


def splice(page: str, model: dict) -> str:
    head, rest = page.split(BEGIN, 1)
    _old, tail = rest.split(END, 1)
    return head + section(model) + tail


def view(model: dict) -> str:
    out = [
        "# Trigger (b) — the case view, rendered from the model",
        "",
        f"Rendered by `scripts/render_model.py` from `{MODEL_NAME}`; never edited by hand. The result cell reads",
        "`unverified`: this root has no evidence publisher.",
        "",
        "| case | world | recorded files | derived elements | test node id | result |",
        "|---|---|---|---|---|---|",
    ]
    for c in model["cases"]:
        files, derived_pr = OPEN_LIST[c["open_assembly_pr"]]
        recorded = f"`{files}`, `api.issues.3270.comments@per_page=100.json`"
        derived = f"open list: {derived_pr}; comments: {MARKERS[c['b_markers_on_it']]}"
        if c["since_the_marker"] != "—":
            derived += f"; since the marker: {c['since_the_marker']}"
        if c["fault"] != "—":
            derived += f"; fault: {c['fault']}"
        node = f"`{TEST}[{c['id']}]`"
        out.append("| " + " | ".join(esc(x) for x in (c["id"], c["world"], recorded, derived, node, "unverified")) + " |")
    return "\n".join(out) + "\n"


def main(argv: list[str]) -> int:
    model = load()
    page, fresh_page, fresh_view = PAGE.read_text("utf-8"), None, view(model)
    fresh_page = splice(page, model)
    if "--check" in argv:
        stale = [p.name for p, new in ((PAGE, fresh_page), (VIEW, fresh_view))
                 if not p.exists() or p.read_text("utf-8") != new]
        print("render drift: " + ", ".join(stale) if stale else "render matches")
        return 1 if stale else 0
    PAGE.write_text(fresh_page, "utf-8")
    VIEW.write_text(fresh_view, "utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
