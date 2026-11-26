"""The assembly review's five findings on `gateway_admit.py` (homelab#3795) — not page rows, so no
`rule()` label: the component never raises past its caller, releases the session on every way out,
and the in-pod pull prelude exits 97 before the harness with a diagnostic."""

from __future__ import annotations

import copy
import os
import shutil
import subprocess
import textwrap

import pytest

from launch.gateway_admit import PULL_PRELUDE, GatewayAdmit
from test_admit_cases import BOUND_ARGS, Gateway
from worlds import load_world

BOUND = ["--stack", "platform", *BOUND_ARGS.split()]


def _admit(world_name, argv, mutate=None):
    world = load_world(world_name)
    body = copy.deepcopy(world.get("body"))
    if mutate:
        mutate(body)
    gw = Gateway(world, body)
    result = GatewayAdmit(gw, lambda: "placeholder-caller-token").admit(argv)
    return result, gw


def _unbound(env_file):
    return ["--stack", "platform", "--role", "responder", "--task", "t", "--env-file", str(env_file)]


@pytest.mark.parametrize("rail", [["anthropic"], {"a": 1}, 7])
def test_non_string_rail_fails_closed_and_releases(rail) -> None:
    result, gw = _admit("gw-dispatch-bound", BOUND, lambda b: b.update(rail=rail))
    assert result.rc == 3 and "rail" in result.outputs["GW_DEFER_REASON"]
    assert len(gw.deletes()) == 1


def test_unencodable_env_value_releases_and_leaves_no_file(tmp_path) -> None:
    env_file = tmp_path / "env"

    def lone_surrogate(body):
        body["env"]["ANTHROPIC_MODEL"] = "sonnet\ud800"

    result, gw = _admit("gw-dispatch-unbound", _unbound(env_file), lone_surrogate)
    assert result.rc == 3 and result.outputs["GW_DEFER_REASON"] == "dispatch-unusable: env-file"
    assert len(gw.deletes()) == 1
    assert not env_file.exists()


@pytest.mark.parametrize("flag", ["--env-file", "--bind"])
def test_empty_destination_is_refused_before_any_request(flag) -> None:
    argv = ["--stack", "platform", "--role", "r", "--task", "t", flag, ""]
    result, gw = _admit("gw-dispatch-unbound", argv)
    assert result.rc == 2 and gw.requests == []


@pytest.mark.parametrize(
    "url",
    [
        "http://gw host/sessions/s-coord-1/env",
        "http://gw.example:8080/a b/sessions/s-coord-1/env",
        "http://gw.example/x;rm/sessions/s-coord-1/env",
        "http://gw.example/sessions/s-coord-1/env\n",
        "http://gw$(id)/sessions/s-coord-1/env",
        "http://gw.example/`x`/sessions/s-coord-1/env",
    ],
)
def test_pull_url_with_whitespace_or_metacharacters_fails_closed(url) -> None:
    result, gw = _admit("gw-dispatch-bound", BOUND, lambda b: b.update(pull_url=url))
    assert result.rc == 3 and "pull_url" in result.outputs["GW_DEFER_REASON"]
    assert len(gw.deletes()) == 1


# --- the in-pod prelude, run for real against a fake curl -------------------------------------


def _run_prelude(tmp_path, curl_exit, answer, keys="A,B"):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "curl.args"
    curl = bin_dir / "curl"
    curl.write_text(textwrap.dedent(f"""\
        #!/bin/sh
        cat >/dev/null
        echo "$@" >> {log}
        printf '%s' '{answer}'
        exit {curl_exit}
        """))
    curl.chmod(0o755)
    token = tmp_path / "token"
    token.write_text("placeholder-pod-token")
    prelude = PULL_PRELUDE.replace("/var/run/secrets/agent-gateway/token", str(token))
    script = prelude + '\necho HARNESS-STARTED "$A" "$B"\n'
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "AGENT_GATEWAY_PULL_URL": "http://gw.example/sessions/s-1/env",
        "AGENT_GATEWAY_ENV_KEYS": keys,
    }
    sh = shutil.which("dash") or "sh"
    proc = subprocess.run([sh, "-c", script], env=env, capture_output=True, text=True, check=False)
    return proc, log.read_text() if log.exists() else ""


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq is the pod's own dependency")
class TestPrelude:
    def test_failing_pull_exits_97_with_a_diagnostic_and_spaced_retries(self, tmp_path) -> None:
        proc, curl_args = _run_prelude(tmp_path, 22, "")
        assert proc.returncode == 97 and "HARNESS-STARTED" not in proc.stdout
        assert "env pull FAILED" in proc.stderr and "http://gw.example/sessions/s-1/env" in proc.stderr
        assert "--retry 3" in curl_args and "--retry-delay 2" in curl_args and "--retry-connrefused" in curl_args

    def test_non_string_env_value_exits_97_with_a_diagnostic(self, tmp_path) -> None:
        proc, _ = _run_prelude(tmp_path, 0, '{"env":{"A":"x","B":42}}')
        assert proc.returncode == 97 and "HARNESS-STARTED" not in proc.stdout
        assert "lacks B" in proc.stderr

    def test_missing_key_exits_97(self, tmp_path) -> None:
        proc, _ = _run_prelude(tmp_path, 0, '{"env":{"A":"x"}}')
        assert proc.returncode == 97 and "lacks B" in proc.stderr

    def test_good_answer_exports_and_starts_the_harness(self, tmp_path) -> None:
        proc, _ = _run_prelude(tmp_path, 0, '{"env":{"A":"x","B":"y"}}')
        assert proc.returncode == 0 and "HARNESS-STARTED x y" in proc.stdout
