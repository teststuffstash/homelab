"""Compare a native CLI's tool continuation directly and through the gateway, offline (FU-270).

Only a read-only get_goal tool call is requested: no shell command or external inference.
The first upstream response supplies a dummy x-codex-turn-state. The CLI should replay it on
the tool-result request. A direct baseline distinguishes CLI behavior from gateway filtering.
The fixture reports a known compatibility gap, never subscription readiness.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import compat
from tests._codex_world import completion, sse

STATE = "fixture-turn-state"


def responses(request_number):
    if request_number != 1:
        return {}, completion()
    item = {"id": "fc_fixture", "type": "function_call", "call_id": "call_fixture",
            "name": "get_goal", "arguments": "{}",
            "status": "completed"}
    response = {"id": "resp_tool_fixture", "object": "response", "created_at": 1,
                "status": "completed", "model": "fixture-model", "output": [item],
                "usage": {"input_tokens": 7, "output_tokens": 3, "total_tokens": 10}}
    return {"x-codex-turn-state": STATE}, [
        sse("response.created", response={**response, "status": "in_progress", "output": []}),
        sse("response.output_item.added", output_index=0, item={**item, "arguments": ""}),
        sse("response.function_call_arguments.delta", item_id=item["id"], output_index=0, delta=item["arguments"]),
        sse("response.output_item.done", output_index=0, item=item),
        sse("response.completed", response=response),
    ]


class Observations:
    def __init__(self):
        self.rows = []

    def observe(self, body, headers):
        headers = {k.lower(): v for k, v in headers.items()}
        self.rows.append({"turn_state_matches": headers.get("x-codex-turn-state") == STATE,
                          "fixture_tool_declared": any(tool.get("type") == "function" and tool.get("name") == "get_goal"
                                                       for tool in body.get("tools", []) if isinstance(tool, dict)),
                          "tool_result_present": any(item.get("type") == "function_call_output"
                                                     and item.get("call_id") == "call_fixture"
                                                     for item in body.get("input", []) if isinstance(item, dict))})


def run(binary, expected_version):
    executable = shutil.which(binary)
    if executable is None:
        raise RuntimeError("codex executable not found")
    version = subprocess.check_output([executable, "--version"], text=True, timeout=10).strip()
    if version != "codex-cli " + expected_version:
        raise RuntimeError("CLI version differs from --expect-version")
    direct, proxied = Observations(), Observations()
    with tempfile.TemporaryDirectory(prefix="codex-continuation-") as directory:
        root = Path(directory)
        home, work = root / "home", root / "work"
        home.mkdir()
        work.mkdir()
        with compat.fake_upstream("DUMMY-SECRET-direct", direct.observe, responses) as (url, _):
            (home / "config.toml").write_text(compat._provider_block(
                {"CODEX_MODEL": "fixture-model", "OPENAI_BASE_URL": url}))
            result = compat._exec(executable, compat._child_env(home, "DUMMY-SECRET-direct"), work, 60)
            direct_ok = result.returncode == 0 and compat.TEXT in result.stdout and not (home / "auth.json").exists()
    gateway = compat.run(binary, expected_version, request_observer=proxied.observe, response_factory=responses)
    if (not direct_ok or len(direct.rows) != 2 or not direct.rows[0]["fixture_tool_declared"]
            or not direct.rows[1]["tool_result_present"]):
        raise RuntimeError("direct continuation baseline failed (logs suppressed)")
    if len(proxied.rows) != 2 or not proxied.rows[0]["fixture_tool_declared"] or not proxied.rows[1]["tool_result_present"]:
        raise RuntimeError("gateway continuation failed (logs suppressed)")
    return {"cli_version": version, "live_subscription_verified": False,
            "direct": direct.rows, "gateway": proxied.rows,
            "gateway_turn_completed": gateway["turn_completed"],
            "native_turn_state_replayed": direct.rows[1]["turn_state_matches"],
            "gateway_turn_state_replayed": proxied.rows[1]["turn_state_matches"],
            "gateway_compatibility_gap": direct.rows[1]["turn_state_matches"] and not proxied.rows[1]["turn_state_matches"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True)
    parser.add_argument("--expect-version", required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.codex, args.expect_version), indent=2))
