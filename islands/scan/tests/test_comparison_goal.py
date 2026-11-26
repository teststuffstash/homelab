"""The nine trigger-(b) rows of the `goal` replay family, old member against new component (goal #3656 child 4).

No case here carries a `rule()` label: a comparison is not evidence (islands/README.md §Built from the specs,
never copied, rule 4). The one fact compared per row: the old stream holds a `HELD` line for trigger (b) ⇔ the
new decision is `held`. A differing row passes only with a line in `comparison/goal-checkpoint-b.rulings`;
a ruling for a row that does not differ fails. Mechanism: tests/compare_goal.py.
"""

import allure
import pytest

from .compare_goal import compared_ids, facts, load_rulings, old_fact, verdict
from .page import params as page_params
from .page import tables
from .rules import SPECS

IDS = compared_ids()
PAGE_ROWS = {r.id: r.values for r in page_params(tables(SPECS / "scan-decision.md"), "Does trigger (b) fire while an assembly pull request is open?")[1]}
PAGE_ARGS = page_params(tables(SPECS / "scan-decision.md"), "Does trigger (b) fire while an assembly pull request is open?")[0]


def test_the_family_holds_the_nine_rows():
    assert len(IDS) == 9, IDS
    assert "child-set-complete" in IDS and sum(i.startswith("goal-checkpoint-b-") for i in IDS) == 8


@pytest.mark.parametrize("row_id", IDS)
def test_every_compared_row_has_a_counterpart_on_the_page(row_id):
    assert row_id in PAGE_ROWS, f"{row_id} is a row of the replay family `goal` with no row of that id in the (b) table"


@pytest.mark.parametrize("row_id", IDS)
def test_the_old_member_reproduces_its_own_expected_stream(row_id):
    # the adapter's positive control on this family: a stream that moved would make the fact below meaningless
    assert old_fact(row_id)[1], f"{row_id}: the composed old clause no longer prints expected/{row_id}.txt"


@pytest.mark.parametrize("row_id", IDS)
def test_old_and_new_agree_or_a_ruling_rules_the_difference(row_id):
    rulings = load_rulings(set(IDS))
    with allure.step(f"Given row {row_id} of the goal family, lifted onto the recorded world goal-checkpoint"):
        f = facts(row_id)
    with allure.step("Then old holds (b) ⇔ new holds (b), or goal-checkpoint-b.rulings rules the difference"):
        result = verdict(f, rulings.get(row_id))
        assert result is None, result


@pytest.mark.parametrize("row_id", IDS)
def test_the_new_fact_is_the_pages_this_wake_cell(row_id):
    cells = dict(zip(PAGE_ARGS, PAGE_ROWS[row_id], strict=True))
    held, reason = facts(row_id).new_held, facts(row_id).reason
    assert held is not None, reason
    assert held == (cells["expected_b_this_wake"] == "held")


def test_the_rulings_file_parses():
    load_rulings(set(IDS))


def test_a_difference_without_a_ruling_fails_and_a_ruling_without_a_difference_fails():
    from .compare_goal import Facts

    assert "unruled difference" in verdict(Facts(old_held=True, new_held=False), None)
    assert "unruled difference" in verdict(Facts(old_held=True, new_held=None, reason="not liftable: x"), None)
    assert verdict(Facts(old_held=True, new_held=False), ("old", "why")) is None
    assert "does not differ" in verdict(Facts(old_held=True, new_held=True), ("old", "why"))
