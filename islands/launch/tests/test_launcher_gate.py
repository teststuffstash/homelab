"""Gate checks of the launcher cases — carry no rule() label."""

from __future__ import annotations

import pytest

from launch.launcher_admission import LauncherAdmission, Refusal
from test_launcher_cases import CASES, NEVER_BUILT, OWNED_BY_3408, ROWS, SETUP
from worlds import STACKS, WorldError, load_stack_world


def test_every_launcher_row_has_a_case_or_is_listed_and_every_case_a_row() -> None:
    ids = [r.id for r in ROWS]
    assert len(ids) == 24 and len(OWNED_BY_3408) == 13 and len(CASES) == 9
    assert set(ids) - set(CASES) == set(OWNED_BY_3408) | set(NEVER_BUILT)
    assert set(SETUP) - set(ids) == set()
    assert not set(CASES) & (set(OWNED_BY_3408) | set(NEVER_BUILT))


def test_stack_world_is_a_whole_recorded_row_with_its_commit() -> None:
    import json
    from pathlib import Path

    world = load_stack_world("stack-platform")
    assert world.get("provenance", "kind") == "recorded" and len(world.get("provenance", "commit")) == 40
    stacks = json.loads((Path(__file__).resolve().parents[3] / "agents" / "stacks.json").read_text())
    assert world.get("row") == next(s for s in stacks["stacks"] if s["name"] == "platform")


def test_strict_stack_reader_refuses_a_row_missing_a_required_field(tmp_path, monkeypatch) -> None:
    import json

    import worlds

    data = json.loads((STACKS / "stack-platform.json").read_text())
    del data["row"]["mainRepo"]
    (tmp_path / "stack-platform.json").write_text(json.dumps(data))
    monkeypatch.setattr(worlds, "STACKS", tmp_path)
    with pytest.raises(WorldError):
        load_stack_world("stack-platform")


def test_a_clean_call_is_admitted_with_the_request_it_would_send() -> None:
    stack = load_stack_world("stack-platform").get("row")
    result = LauncherAdmission(lambda r: None, lambda p: "tok", lambda s: "m").admit(
        {"AGENT_GATEWAY_ROLE": "prober"}, stack, "homelab", "issue-1", round="2", run="x")
    assert not isinstance(result, Refusal)
    assert result.bind == "homelab/agentstack-worker/agent-homelab-issue-1-r2"
    assert result.body["role"] == "prober" and result.body["round"] == 2
