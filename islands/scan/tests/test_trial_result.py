"""The `## Result` table of world-model-pilot.md equals what the suite and `trial/measure.py` produce (goal #3656 child 5)."""

from __future__ import annotations

import re
import subprocess
import sys

import pytest

from . import test_checkpoint_b as cb

ISLAND = cb.HAND.parent.parent
PILOT = ISLAND / "world-model-pilot.md"
MEASURE = ISLAND / "trial" / "measure.py"


def result_table() -> dict[str, tuple[str, str]]:
    section = PILOT.read_text("utf-8").split("\n## Result\n", 1)[1]
    out = {}
    for line in section.splitlines():
        if line.startswith("|") and not line.startswith(("| measure", "|---")):
            measure, hand, model = (c.strip() for c in line.strip().strip("|").split("|"))
            out[measure] = (hand, model)
        elif out and not line.startswith("|"):
            break
    return out


def measured() -> dict[str, str]:
    run = subprocess.run([sys.executable, "-I", str(MEASURE)], capture_output=True, text=True, check=True)
    return dict(line.split("=", 1) for line in run.stdout.splitlines())


def churn_stamp(w):
    """The churn mutant's marker on A where the open list has A; rows without A (none, B) stamp nothing it reads."""
    return cb.churn_stamp(w) if any(p["number"] == cb.A for p in w.get("pr-list.json", ())) else cb.marker(cb.A)


def detected(arm: str) -> int:
    """How many of the two mutants turn at least one labelled row of the arm red."""
    count = 0
    for component, stamp in ((cb.MUTANT, None), (cb.CHURN_MUTANT, churn_stamp)):
        for r in cb.ARMS[arm]:
            cells = dict(zip(cb.ARGS, r.values, strict=True))
            actual, _ = cb.wake_the_row(component, cells, stamp)
            if not all(cb.verdicts(cells, actual).values()):
                count += 1
                break
    return count


def test_the_result_table_has_the_three_measures_and_two_arms():
    assert list(result_table()) == ["mutants detected (of 2)", "facts written twice", "edits for one policy change"]


def test_the_table_equals_the_measure_output():
    table, got = result_table(), measured()
    assert table["facts written twice"] == (got["facts-written-twice.hand"], got["facts-written-twice.model"])
    assert table["edits for one policy change"] == (got["edits.hand"], got["edits.model"])


@pytest.mark.parametrize("arm", ["hand", "model"])
def test_the_table_equals_the_mutants_detected_in_the_arm(arm):
    assert result_table()["mutants detected (of 2)"][arm == "model"] == str(detected(arm))


def test_the_policy_change_diffs_touch_no_generated_file():
    for arm in ("hand", "model"):
        files = re.findall(r"^diff --git a/(\S+)", (ISLAND / "trial" / "policy-change" / f"{arm}.diff").read_text("utf-8"), re.M)
        assert "trial/checkpoint-b-view.md" not in files and files, (arm, files)
