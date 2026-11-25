"""The `gateway-admit` replay family as a COMPARISON — old helper vs the Python component (rule 4 of
`islands/README.md`). Not the gate for any requirement: no case here carries a `rule()` label.

Both targets run the family's 12 rows through `agents/replay/run.sh` from a throwaway copy of the
harness (`compare/harness.py`): `agents/gateway-admit.sh` unmodified, and the test-side adapter
(`compare/adapter.sh` → `adapter.py` → `src/launch/gateway_admit.py`). Per row: same or different, with both
action streams for a different one. `compare/gateway-admit.rulings.tsv` names every difference that
remains with its ruling (`spec` | `old` | `new`); an unnamed difference and a ledger line with no
difference both fail — per differing line, by the ledger line's pattern, not per row.
"""

from __future__ import annotations

import difflib
import re
from pathlib import Path

import allure
import pytest

from compare.harness import COMPARE, REPO, row_ids, streams

LEDGER = COMPARE / "gateway-admit.rulings.tsv"
RULINGS = {"spec", "old", "new"}
STUB = "gw_preflight_caller() { return 0; }\ngw_admit() { return 0; }\ngw_release() { return 0; }\n"


Ruling = tuple[str, str, "re.Pattern[str]"]


def ledger() -> dict[str, list[Ruling]]:
    """row id → its (ruling, line, pattern) triples: a row that differs in two ways has a line per way."""
    out: dict[str, list[Ruling]] = {}
    for n, ln in enumerate(LEDGER.read_text(encoding="utf-8").splitlines(), 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        cells = ln.split("\t")
        assert len(cells) == 4 and cells[1] in RULINGS and cells[2].strip() and cells[3], (
            f"{LEDGER.name}:{n}: want `id<TAB>spec|old|new<TAB>one line<TAB>pattern`"
        )
        try:
            pat = re.compile(cells[3])
        except re.error as e:
            raise AssertionError(f"{LEDGER.name}:{n}: pattern does not compile: {e}") from e
        out.setdefault(cells[0], []).append((cells[1], cells[2], pat))
    return out


def diff_lines(old: list[str], new: list[str]) -> list[str]:
    """The `-`/`+` lines of the old-vs-new diff, headers and hunk marks excluded."""
    return [d for d in difflib.unified_diff(old, new, lineterm="", n=0) if d[:1] in "-+" and not d.startswith(("---", "+++"))]


def check_rulings(comparison: dict[str, tuple[list[str], list[str]]], rulings: dict[str, list[Ruling]]) -> tuple[list[str], list[str]]:
    """(unruled, stale): a differing line no ledger pattern of ITS row matches; a ledger pattern matching no differing line of its row."""
    unruled: list[str] = []
    stale: list[str] = []
    for row, (old, new) in comparison.items():
        lines = diff_lines(old, new)
        pats = rulings.get(row, [])
        unruled += [f"{row}: {d}" for d in lines if not any(p.search(d) for _, _, p in pats)]
        stale += [f"{row}: {r} /{p.pattern}/" for r, _, p in pats if not any(p.search(d) for d in lines)]
    stale += [f"{row}: (no difference at all)" for row in rulings if row not in comparison]
    return unruled, stale


@pytest.fixture(scope="module")
def comparison() -> dict[str, tuple[list[str], list[str]]]:
    old = streams(REPO / "agents" / "gateway-admit.sh")
    new = streams(COMPARE / "adapter.sh")
    ids = row_ids()
    assert len(ids) == 12
    missing = [r for r in ids if r not in old or r not in new]
    assert not missing, f"rows with no action stream (the family did not run them): {missing}"
    return {r: (old[r], new[r]) for r in ids}


def _report(row: str, old: list[str], new: list[str]) -> str:
    if old == new:
        return f"{row}: same"
    diff = "\n".join(difflib.unified_diff(old, new, "old (agents/gateway-admit.sh)", "new (the component, via the adapter)", lineterm=""))
    return f"{row}: DIFFERENT\n--- old action stream\n" + "\n".join(old) + "\n--- new action stream\n" + "\n".join(new) + "\n--- diff\n" + diff


def test_every_difference_is_ruled_and_every_ruling_has_a_difference(comparison) -> None:
    report = "\n\n".join(_report(r, *comparison[r]) for r in comparison)
    allure.attach(report, name="comparison", attachment_type=allure.attachment_type.TEXT)
    print(report)
    unruled, stale = check_rulings(comparison, ledger())
    assert not unruled, f"differences with no ruling in {LEDGER.name}:\n" + "\n".join(unruled) + f"\n{report}"
    assert not stale, f"{LEDGER.name} lines with no difference:\n" + "\n".join(stale)


def _rows(**kw: tuple[list[str], list[str]]) -> dict[str, tuple[list[str], list[str]]]:
    return kw


_SYN = _rows(r1=(["POST a", "OUT old wording"], ["POST a", "ERR new wording"]))
_SPEC = ("spec", "wording", re.compile(r"^[-+](OUT|ERR) "))


def test_check_green_when_every_difference_is_ruled() -> None:
    assert check_rulings(_SYN, {"r1": [_SPEC]}) == ([], [])


def test_check_red_when_a_rows_ledger_line_is_removed() -> None:
    unruled, stale = check_rulings(_SYN, {})
    assert unruled == ["r1: -OUT old wording", "r1: +ERR new wording"] and stale == []


def test_check_red_when_a_ledger_pattern_matches_nothing() -> None:
    unruled, stale = check_rulings(_SYN, {"r1": [_SPEC, ("old", "gone", re.compile(r"^[-+]OUT GW_"))]})
    assert unruled == [] and len(stale) == 1 and "GW_" in stale[0]


def test_check_red_when_a_same_stream_row_has_a_ledger_line() -> None:
    unruled, stale = check_rulings(_rows(r1=(["POST a"], ["POST a"])), {"r1": [_SPEC]})
    assert unruled == [] and len(stale) == 1


def test_check_red_on_a_new_difference_in_an_already_ruled_row() -> None:
    changed = _rows(r1=(["POST a", "OUT old wording"], ["POST b", "ERR new wording"]))
    unruled, stale = check_rulings(changed, {"r1": [_SPEC]})
    assert unruled == ["r1: -POST a", "r1: +POST b"] and stale == []


def test_control_stub_target_differs_on_all_12_rows(tmp_path: Path, comparison) -> None:
    stub = tmp_path / "gateway-admit.sh"
    stub.write_text(STUB, encoding="utf-8")
    stubbed = streams(stub)
    same = [r for r in row_ids() if stubbed.get(r) == comparison[r][0]]
    assert same == [], f"rows where a do-nothing stub equals the old helper: {same}"
    assert len(row_ids()) == 12


def test_adapter_translates_only() -> None:
    """The adapter builds no request and checks no answer: it names no endpoint field of the wire."""
    text = (COMPARE / "adapter.sh").read_text(encoding="utf-8") + (COMPARE / "adapter.py").read_text(encoding="utf-8")
    for word in ('"decision"', '"env_keys"', '"pull_url"', '"serviceaccount"', "dispatch-unusable"):
        assert word not in text, word
