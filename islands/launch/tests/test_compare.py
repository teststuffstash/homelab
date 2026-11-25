"""The `gateway-admit` replay family as a COMPARISON — old helper vs the Python component (rule 4 of
`islands/README.md`). Not the gate for any requirement: no case here carries a `rule()` label.

Both targets run the family's 12 rows through `agents/replay/run.sh` from a throwaway copy of the
harness (`compare/harness.py`): `agents/gateway-admit.sh` unmodified, and the test-side adapter
(`compare/adapter.sh` → `adapter.py` → `src/launch/gateway_admit.py`). Per row: same or different, with both
action streams for a different one. `compare/gateway-admit.rulings.tsv` names every difference that
remains with its ruling (`spec` | `old` | `new`); an unnamed difference and a ledger line with no
difference both fail.
"""

from __future__ import annotations

import difflib
from pathlib import Path

import allure
import pytest

from compare.harness import COMPARE, REPO, row_ids, streams

LEDGER = COMPARE / "gateway-admit.rulings.tsv"
RULINGS = {"spec", "old", "new"}
STUB = "gw_preflight_caller() { return 0; }\ngw_admit() { return 0; }\ngw_release() { return 0; }\n"


def ledger() -> dict[str, list[tuple[str, str]]]:
    """row id → its (ruling, line) pairs: a row that differs in two ways has a line per way."""
    out: dict[str, list[tuple[str, str]]] = {}
    for n, ln in enumerate(LEDGER.read_text(encoding="utf-8").splitlines(), 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        cells = ln.split("\t")
        assert len(cells) == 3 and cells[1] in RULINGS and cells[2].strip(), f"{LEDGER.name}:{n}: want `id<TAB>spec|old|new<TAB>one line`"
        assert cells[1] not in [r for r, _ in out.get(cells[0], [])], f"{LEDGER.name}:{n}: {cells[0]} ruled `{cells[1]}` twice"
        out.setdefault(cells[0], []).append((cells[1], cells[2]))
    return out


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
    differing = {r for r, (o, n) in comparison.items() if o != n}
    ruled = ledger()
    unruled = sorted(differing - ruled.keys())
    stale = sorted(ruled.keys() - differing)
    assert not unruled, f"differences with no ruling in {LEDGER.name}: {unruled}\n{report}"
    assert not stale, f"{LEDGER.name} lines with no difference: {stale}"


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
