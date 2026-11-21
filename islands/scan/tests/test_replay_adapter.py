"""The adapter proven before any component exists: positive controls against the OLD scripts on both
families, and three negative controls (the oracle must be able to red)."""

from __future__ import annotations

import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from .old_subjects import MAJOR_HANDOFF_DIR, UPDATER_DIR, old_major_handoff, old_updater
from .replay import ReplayRed, expected_for, load_family, load_rows, row_verdict, run_row
from .rules import ISLAND

FAMILIES = {
    "major-handoff": (MAJOR_HANDOFF_DIR, old_major_handoff),
    "updater": (UPDATER_DIR, old_updater),
}


def _cases():
    for name, (d, _subj) in FAMILIES.items():
        fam = load_family(d)
        for row in load_rows(fam):
            yield pytest.param(name, row, id=f"{name}/{row.id}")


@pytest.mark.parametrize(("name", "row"), list(_cases()))
def test_old_script_replays_green(name, row):
    """Positive control: the OLD script's stream equals expected/<expect>.txt, byte for byte."""
    d, subj = FAMILIES[name]
    fam = load_family(d)
    actual, expected = run_row(fam, row, subj(fam, row))
    assert actual == expected


def test_family_row_counts():
    assert len(load_rows(load_family(MAJOR_HANDOFF_DIR))) >= 15
    assert len(load_rows(load_family(UPDATER_DIR))) >= 43


def _copy_family(src: Path, dst: Path) -> Path:
    shutil.copytree(src, dst)
    return dst


def test_neg_a_altered_template_reds_exactly_its_rows(tmp_path):
    """(a) one line of one expected/*.txt altered ⇒ exactly the rows using that template red."""
    d, subj = FAMILIES["updater"]
    fam0 = load_family(d)
    rows = load_rows(fam0)
    users: dict[str, list[str]] = {}
    for r in rows:
        users.setdefault(r.expect, []).append(r.id)
    victim = next(t for t, ids in users.items() if len(ids) > 1)
    copy = _copy_family(d, tmp_path / "updater")
    tpl = copy / "expected" / f"{victim}.txt"
    lines = tpl.read_text("utf-8").splitlines(keepends=True)
    lines[0] = lines[0].rstrip("\n") + " ALTERED\n"
    tpl.write_text("".join(lines), "utf-8")
    fam = load_family(copy)
    red = {r.id for r in rows if row_verdict(fam, r, subj(fam, r)) is not None}
    assert red == set(users[victim])


@pytest.mark.parametrize("name", list(FAMILIES))
def test_neg_b_silent_subject_reds_every_row(name):
    """(b) a subject printing nothing and exiting 0 reds every row."""
    d, _ = FAMILIES[name]
    fam = load_family(d)
    green = [r.id for r in load_rows(fam) if row_verdict(fam, r, ["bash", "-c", "exit 0"]) is None]
    assert green == []


def test_neg_d_unfilled_param_reds_that_row(tmp_path):
    """(d) a template `{{k}}` the row's params do not fill reds that row (and only the rows on it)."""
    d, subj = FAMILIES["updater"]
    rows = load_rows(load_family(d))
    victim = next(r for r in rows if not r.params)
    copy = _copy_family(d, tmp_path / "updater")
    tpl = copy / "expected" / f"{victim.expect}.txt"
    tpl.write_text(tpl.read_text("utf-8") + "OUT {{nope}}\n", "utf-8")
    fam = load_family(copy)
    with pytest.raises(ReplayRed, match="unfilled"):
        expected_for(fam, victim)
    assert "unfilled" in (row_verdict(fam, victim, subj(fam, victim)) or "")


def _collect(tmp_path: Path, rule_id: str) -> subprocess.CompletedProcess[str]:
    test = tmp_path / "test_probe.py"
    test.write_text(
        textwrap.dedent(
            f"""
            import sys
            sys.path.insert(0, {str(ISLAND)!r})
            from tests.rules import rule

            @rule({rule_id!r})
            def test_probe():
                pass
            """
        )
    )
    return subprocess.run(
        [sys.executable, "-m", "pytest", "--collect-only", "-q", "-p", "no:cacheprovider", str(test)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
    )


def test_neg_c_rule_marker_checks_spec_headings(tmp_path):
    """(c) rule("SCAN-NO-SUCH") fails at collection; rule("SCAN-HANDOFF-GATE") collects."""
    (tmp_path / "bad").mkdir()
    bad = _collect(tmp_path / "bad", "SCAN-NO-SUCH")
    assert bad.returncode != 0
    assert "no such `### SCAN-NO-SUCH` heading" in bad.stdout + bad.stderr
    (tmp_path / "good").mkdir()
    good = _collect(tmp_path / "good", "SCAN-HANDOFF-GATE")
    assert good.returncode == 0, good.stdout + good.stderr
    assert "1 test collected" in good.stdout
