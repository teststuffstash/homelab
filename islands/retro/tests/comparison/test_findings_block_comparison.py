"""RETRO-FINDINGS-BLOCK comparison (unlabelled): the suite the page names, run read-only, then the old
member's `extract` and the new component on the same five inputs as the cases. A difference needs a
rulings.json entry."""

import importlib.util
import json
import subprocess

import pytest
from conftest import REPO
from rulings import check
from test_findings_block import make_input

from retro_island.findings_block import FindingsBlockError, extract

REQ = "RETRO-FINDINGS-BLOCK"
INPUTS = {
    "a valid candidate": ("1", "mechanism, surface, summary, evidence, related_work"),
    "no block": ("0", "—"),
    "⚖ a candidate claiming acceptance": ("1", "+ `accepted_by`"),
    "no evidence": ("1", "evidence `[]`"),
    "a non-canonical related ref": ("1", "related_work `https://example.com/x`"),
}


def _old_extract():
    spec = importlib.util.spec_from_file_location("old_retro_findings", REPO / "agents" / "retro_findings.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.extract


def outcome(fn, text):
    try:
        return json.dumps(fn(text), sort_keys=True)
    except (ValueError, FindingsBlockError) as e:
        return f"error: {e}"


def test_page_suite_green():
    proc = subprocess.run(
        ["bash", "agents/replay/run.sh", "agents/replay/fixtures/retro-activity-window"],
        cwd=REPO, capture_output=True, text=True, check=False,
    )
    assert "1 passed, 0 failed" in proc.stdout, proc.stdout[-500:]


@pytest.mark.parametrize("case", list(INPUTS))
def test_extract_outcome(case):
    text = make_input(*INPUTS[case])
    check(REQ, case, outcome(_old_extract(), text), outcome(extract, text))
