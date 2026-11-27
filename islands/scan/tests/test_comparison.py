"""Replay as a comparison (goal #3490 pin 8): every row of both replay families, old member vs new component.

No case here carries a `rule()` label — a comparison is not evidence (islands/README.md §Built from the
specs, never copied, rule 4). A differing row passes only with a committed ruling in
`comparison/<family>.rulings`; a ruling for a row that does not differ fails. Mechanism: tests/compare.py.
"""

import dataclasses
import difflib
import json
import shutil
import sys
import tempfile
from pathlib import Path

import allure
import pytest

from .compare import SPECS, NotLiftable, RulingError, compare, lift_row, load_rulings, parse_rulings, verdict
from .replay import load_family, load_rows
from .world import WORLDS

ROWS = {name: load_rows(spec.family) for name, spec in SPECS.items()}


def _ids(name: str) -> set[str]:
    return {r.id for r in ROWS[name]}


@pytest.mark.parametrize(("name", "row"), [pytest.param(n, r, id=f"{n}/{r.id}") for n, rows in ROWS.items() for r in rows])
def test_comparison(name, row):
    spec = SPECS[name]
    rulings = load_rulings(spec, _ids(name))
    with allure.step(f"Given row {row.id} of the {name} family, lifted onto the recorded world {spec.world}"):
        outcome = compare(spec, row)
    with allure.step(f"Then old and new agree, or {spec.rulings_file.name} rules the difference"):
        result = verdict(outcome, rulings.get(row.id))
        assert result is None, result


def test_every_family_row_is_compared():
    # agents/replay/fixtures/major-handoff/rows.psv holds 15 rows, updater/rows.psv 43 (#3492 acceptance 1).
    assert len(ROWS["major-handoff"]) >= 15
    assert len(ROWS["updater"]) >= 43


@pytest.mark.parametrize("name", list(SPECS))
def test_rulings_file_parses(name):
    spec = SPECS[name]
    load_rulings(spec, _ids(name))  # the grammar, the three words, rows of the family, each at most once


# ── the lift is not vacuous: the new component sees fields the family's own file lacks ───────────────

LIFT_CONTROLS = [
    # family, row, family file, its lifted read, the path: the recorded value at that path stands
    ("major-handoff", "handoff", "gh/pr-view-738.json", "pr-view-3344.state,labels,reviews,commits.json", ("commits", 0, "authoredDate")),
    ("updater", "fifo-pick", "gh/pr-list.json", "pr-list.json", (0, "headRefName")),
]


def _get(data, path):
    for k in path:
        data = data[k]
    return data


@pytest.mark.parametrize(("name", "rid", "fam_file", "recorded", "path"), LIFT_CONTROLS, ids=[c[0] for c in LIFT_CONTROLS])
def test_lift_holds_a_field_the_family_lacks(name, rid, fam_file, recorded, path):
    spec = SPECS[name]
    row = next(r for r in ROWS[name] if r.id == rid)
    with tempfile.TemporaryDirectory() as t:
        lifted = lift_row(spec, spec.family, row, Path(t))
        family = json.loads((lifted.family / fam_file).read_text("utf-8"))
        answer = json.loads((lifted.dir / lifted.reads[fam_file][0]).read_text("utf-8"))
    rec = json.loads((WORLDS / spec.world / recorded).read_text("utf-8"))
    parent = _get(family, path[:-1])
    assert path[-1] not in parent, f"the family's own {fam_file} already holds {list(path)} — pick a field it lacks"
    # the lifted answer carries the recorded value of the field the family never set
    assert _get(answer, path) == _get(rec, path)


def test_a_family_read_the_recording_lacks_is_not_liftable(tmp_path):
    """A family answer with no recorded read of its shape fails the lift (the row is then a difference)."""
    spec = SPECS["updater"]
    fam = spec.family
    row = next(r for r in ROWS["updater"] if r.id == "armed-only-noop")
    copy = tmp_path / "fam"
    shutil.copytree(fam.dir, copy)
    (copy / "worlds" / "board" / "gh" / "issue-list.json").write_text("[]\n")
    with pytest.raises(NotLiftable, match="issue-list.json: the family answers a read the recorded world pr-board does not hold"):
        lift_row(spec, load_family(copy), row, tmp_path / "run")


def test_a_per_call_failure_faults_every_call_it_names(tmp_path):
    """`STUB_GH_<key>=fail` fails each call of that key in the stub; the lift faults all of them, with the
    stub's own stderr: both field lists of `pr view 120`, and a write split out for its addressed path."""
    spec = SPECS["updater"]
    fam = spec.family
    row = next(r for r in ROWS["updater"] if r.id == "unstrand-yes")
    read = dataclasses.replace(row, env="STUB_GH_pr_view_120=fail")
    lifted = lift_row(spec, fam, read, tmp_path / "read")
    assert sorted(f["target"] for f in lifted.world._faults) == sorted(lifted.reads["gh/pr-view-120.json"])
    assert len(lifted.reads["gh/pr-view-120.json"]) == 2  # --json commits and --json commits,reviews
    assert {f["stderr"] for f in lifted.world._faults} == {"gh: Not Found (HTTP 404)\n"}  # agents/replay/stubs/gh `fail`
    write = next(r for r in ROWS["updater"] if r.id == "lane-hop-wedged-oldest")
    lifted = lift_row(spec, fam, write, tmp_path / "write")
    [fault] = lifted.world._faults
    op = next(w for w in lifted.world.provenance["writes"] if w["op"] == fault["target"])
    assert op["path"] == "repos/teststuffstash/testrepo/pulls/101/update-branch"
    unknown = dataclasses.replace(row, env="STUB_GH_pr_view_999=fail")
    with pytest.raises(NotLiftable, match="holds no read or write for"):
        lift_row(spec, fam, unknown, tmp_path / "unknown")


# ── negative controls: the comparison can red ─────────────────────────────────────────────────────

EXTRA = "extra-write"
WRAP = (
    "import subprocess, sys\n"
    "rc = subprocess.run(sys.argv[2:]).returncode\n"
    f"w = subprocess.run(['gh', 'api', '-X', 'POST', f'repos/{{sys.argv[1]}}/issues/1/labels', '-f', 'labels[]={EXTRA}'], stdout=subprocess.DEVNULL)\n"
    "sys.exit(rc if w.returncode == 0 else 97)\n"
)


@pytest.mark.parametrize("name", list(SPECS))
def test_neg_one_extra_write_makes_unruled_differences(name):
    """A subject that issues one extra write: every row's new stream gains exactly that CALL line, and every
    row without a committed ruling becomes an unruled difference."""
    spec = SPECS[name]
    fam = spec.family
    rulings = load_rulings(spec, _ids(name))
    unruled = 0
    for row in ROWS[name]:
        subject = [sys.executable, "-c", WRAP, spec.repo(fam, row), *spec.new(fam, row)]
        outcome = compare(spec, row, subject)
        assert outcome.reason is None, f"{row.id}: {outcome.reason}"
        diff = [ln for ln in difflib.ndiff(outcome.old.decode().splitlines(), outcome.new.decode().splitlines()) if ln[:1] in "+-"]
        assert diff == [f"+ CALL gh api -X POST repos/{spec.repo(fam, row)}/issues/1/labels -f labels[]={EXTRA}"] or row.id in rulings, (
            f"{row.id}: {diff}"
        )
        if row.id not in rulings:
            unruled += 1
            assert (verdict(outcome, None) or "").startswith("unruled difference"), row.id
    assert unruled > 0, "every row is ruled — the control proves nothing"


@pytest.mark.parametrize("name", list(SPECS))
def test_neg_ruling_for_an_equal_row_fails(name):
    spec = SPECS[name]
    rulings = load_rulings(spec, _ids(name))
    row, outcome = next((r, o) for r in ROWS[name] if r.id not in rulings for o in [compare(spec, r)] if not o.differs)
    assert verdict(outcome, None) is None
    assert "does not differ" in (verdict(outcome, ("spec", "a ruling added for an equal row")) or ""), row.id


@pytest.mark.parametrize(
    ("line", "match"),
    [
        ("handoff | maybe | a word outside the three", "not one of"),
        ("no-such-row | spec | a row the family does not hold", "not a row of the family"),
        ("handoff | spec", "want `<row id> | <ruling> | <reason>`"),
        ("handoff | old | once\nhandoff | new | twice", "ruled twice"),
    ],
    ids=["word", "row", "reason", "twice"],
)
def test_rulings_grammar_refuses(line, match):
    with pytest.raises(RulingError, match=match):
        parse_rulings(line + "\n", _ids("major-handoff"), "probe.rulings")
