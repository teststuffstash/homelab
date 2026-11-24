"""RETRO-FINDINGS-BLOCK (specs/findings.md) — world reports. One case per row of the page's table: the
recorded report as it is, or with the ONE change the row's `block` / `candidate_fields` cells name."""

import json
import re

import allure
import pytest
from conftest import rule

from retro_island import reports
from retro_island.findings_block import FindingsBlockError, extract

pytestmark = rule("RETRO-FINDINGS-BLOCK")

_BLOCK = re.compile(r"(^```retro-findings-json\s*\n)(.*?)(^```\s*$)", re.MULTILINE | re.DOTALL)


def recorded_text() -> str:
    (r,) = reports.load()
    return r.text


def changed(text: str, change) -> str:
    """The report with its one block's JSON passed through `change`."""

    def sub(m):
        data = json.loads(m.group(2))
        change(data)
        return m.group(1) + json.dumps(data) + "\n" + m.group(3)

    return _BLOCK.sub(sub, text, count=1)


def make_input(block: str, candidate_fields: str) -> str:
    text = recorded_text()
    if block == "0":
        return _BLOCK.sub("", text)
    if candidate_fields == "—" or candidate_fields.startswith("mechanism"):
        return text
    if candidate_fields == "+ `accepted_by`":
        return changed(text, lambda d: d["findings"][0].update(accepted_by="seat"))
    if candidate_fields == "evidence `[]`":
        return changed(text, lambda d: d["findings"][0].update(evidence=[]))
    if candidate_fields == "related_work `https://example.com/x`":
        return changed(text, lambda d: d["findings"][0].update(related_work=["https://example.com/x"]))
    raise AssertionError(candidate_fields)


@pytest.mark.parametrize(
    "world, block, candidate_fields, expected_accepted, expected_error",
    [
        pytest.param("reports", "1", "mechanism, surface, summary, evidence, related_work", "yes", "—", id="a valid candidate"),
        pytest.param("reports", "0", "—", "no", "report requires exactly one retro-findings-json block", id="no block"),
        pytest.param("reports", "1", "+ `accepted_by`", "no", "candidate contains unsupported fields (acceptance belongs in decisions)", id="⚖ a candidate claiming acceptance"),
        pytest.param("reports", "1", "evidence `[]`", "no", "finding requires occurrence evidence", id="no evidence"),
        pytest.param("reports", "1", "related_work `https://example.com/x`", "no", "related_work requires canonical GitHub issue/PR URLs", id="a non-canonical related ref"),
    ],
)
def test_findings_block(world, block, candidate_fields, expected_accepted, expected_error):
    allure.dynamic.parameter("world", world)
    text = make_input(block, candidate_fields)
    if expected_accepted == "yes":
        found = extract(text)
        assert expected_error == "—" and len(found) == 6
        assert all(set(c) == {"mechanism", "surface", "summary", "evidence", "related_work"} for c in found)
    else:
        with pytest.raises(FindingsBlockError) as exc:
            extract(text)
        assert str(exc.value) == expected_error
