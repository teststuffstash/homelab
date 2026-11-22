"""Row helpers for the sessions page's test modules (specs/endpoints/sessions.md) — the v0.6.9 row
shape (allure-behavior-snippets CONVENTIONS § The intent column; specs/README.md §Rules):

- the header is the parameter list: every argname of a module's `parametrize` is a header cell of
  the table it proves (`decision?` is the argname `expected_decision`), and the description cell is
  the `pytest.param` id verbatim;
- `world` is a column where a rule's rows span more than one world — `enter_world` turns the cell
  (`policy-default · upstream-429-reset` = the policy document + the fake upstream's behaviour,
  specs/worlds/README.md) into the `world()` call;
- every column threads the steps (§ Prime rule of reporting): `inputs()` opens one given step naming
  every input column with its value; `expect()` pronounces ONE verdict step whose `verdict:` JSON is
  keyed by the `expected_<col>` argnames and whose name carries every claimed value.

Cell literals every legend decodes the same way: `—` = not in the answer (the key is null or
absent); `null` = a JSON null the answer carries; `(absent)` = the key is not in the answer at all;
`(policy)` = the body does not name it, the role's policy default applies.

Not a test module — no rule label; the row modules import it.
"""

from __future__ import annotations

from typing import Any

from .conftest import given, then, world

DASH = "—"
NULL = "null"
ABSENT = "(absent)"
POLICY = "(policy)"


def enter_world(name: str) -> str:
    """The `world` cell → `world(policy, upstream)`: `policy-default · upstream-429` names the policy
    document and the fake upstream's behaviour the case rides."""
    policy, _, upstream = name.partition(" · ")
    return world(policy, upstream or None)


def inputs(**cols: Any) -> None:
    """Given: one step naming every input column with the row's value (the thread's given leg)."""
    with given("inputs: " + " · ".join(f"{k} = {v}" for k, v in cols.items())):
        pass


def body_of(**cols: Any) -> dict:
    """A request body from input columns: a `(policy)` or `—` cell is a key the body does not carry."""
    return {k: v for k, v in cols.items() if v not in (POLICY, DASH, None)}


def decode(cell: Any) -> Any:
    """`—` / `null` → None; everything else is itself."""
    return None if cell in (DASH, NULL) else cell


def expect(actual: dict, **cols: Any) -> None:
    """Then: ONE verdict step over the row's expected columns. The `verdict:` JSON is keyed by the
    `expected_<col>` argnames (expected / actual), the step's name carries every claimed value. A
    `—` or `null` cell claims the key is null or absent; `(absent)` claims the key is not there."""
    claim = "expected " + " · ".join(f"{k} = {v}" for k, v in cols.items())
    compared = {f"expected_{k}": {"expected": v, "actual": (actual[k] if k in actual else ABSENT)} for k, v in cols.items()}
    with then(claim, **compared):
        for k, v in cols.items():
            if v == ABSENT:
                assert k not in actual, f"{k}: expected absent, got {actual.get(k)!r}"
            else:  # a `—` / `null` cell matches the key's None, or the literal a case computed for it
                assert actual.get(k) in (v, decode(v)), f"{k}: expected {v!r}, got {actual.get(k)!r}"
