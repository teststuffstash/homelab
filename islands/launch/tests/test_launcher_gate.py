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


def _admit(knobs=None, task="issue-1", **kw):
    stack = load_stack_world("stack-platform").get("row")
    return LauncherAdmission(lambda r: None, lambda p: "tok", lambda s: "m", clock=lambda: "010203").admit(
        knobs or {}, stack, "homelab", task, run="x", **kw)


@pytest.mark.parametrize("fb", ["", "abc", "7x", "-1"])
def test_empty_or_non_integer_fallback_exit_is_ignored(fb) -> None:
    r = _admit({"AGENT_GATEWAY_FALLBACK_EXIT": fb, "AGENT_GATEWAY_ATTEMPT": "0"})
    assert isinstance(r, Refusal) and r.rc == 2


def test_integer_fallback_exit_applies() -> None:
    assert _admit({"AGENT_GATEWAY_FALLBACK_EXIT": "75", "AGENT_GATEWAY_ATTEMPT": "0"}).rc == 75


def test_empty_attempt_is_attempt_one_and_empty_sa_falls_to_token_file() -> None:
    r = _admit({"AGENT_GATEWAY_ATTEMPT": "", "AGENT_GATEWAY_CALLER_SA": "", "AGENT_GATEWAY_CALLER_TOKEN_FILE": ""})
    assert not isinstance(r, Refusal) and "attempt" not in r.body


def test_trailing_newline_is_refused() -> None:
    assert _admit({"AGENT_GATEWAY_CALLER_SA": "platform-agents/agentstack-loop\n"}).rc == 2
    assert _admit(round="2\n").rc == 2


def test_task_is_sanitised_in_the_bind_and_untasked_uses_the_clock() -> None:
    assert _admit(task="issue-1_A.b", round="3").bind == "homelab/agentstack-worker/agent-homelab-issue-1---b-r3"
    assert _admit(task="").bind == "homelab/agentstack-worker/agent-homelab-010203"


@pytest.mark.parametrize("task", ["retro-r10", "research-210-arm1", "intake-3"])
def test_non_issue_task_gets_the_clock_pod_name(task) -> None:
    r = _admit(task=task, round="3")
    assert r.bind == "homelab/agentstack-worker/agent-homelab-010203" and r.body["task"] == task


def test_empty_knobs_are_unset_and_empty_task_is_adhoc() -> None:
    r = _admit({"AGENT_GATEWAY_ROLE": "", "AGENT_GATEWAY_RAIL": "", "AGENT_GATEWAY_CANARY": ""}, task="")
    assert r.body["role"] == "worker" and r.body["task"] == "adhoc"
    assert "rail" not in r.body and "canary" not in r.body


def test_attempt_is_sent_only_when_above_one() -> None:
    assert "attempt" not in _admit({"AGENT_GATEWAY_ATTEMPT": "1"}).body
    assert _admit({"AGENT_GATEWAY_ATTEMPT": "2"}).body["attempt"] == 2
