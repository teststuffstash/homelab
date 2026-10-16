"""Run an explicitly selected Codex executable against a loopback Responses fixture.

Fresh child configuration and a minimal environment exclude the operator's auth/config.
No OAuth, real model, shell tool call, or external upstream is used.
"""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

from adapter import Observation, Refused, prepare, relay

TOKEN = "gws_" + "fixture0" * 4
MODEL = "fixture-model"
TEXT = "codex fixture complete"


def sse(kind, **fields):
    return ("event: " + kind + "\ndata: " + json.dumps({"type": kind, **fields}) + "\n\n").encode()


def completion():
    item = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": TEXT, "annotations": []}]}
    response = {"id": "resp_fixture", "object": "response", "created_at": 1, "status": "completed",
                "model": MODEL, "output": [item], "usage": {"input_tokens": 7, "output_tokens": 3,
                "total_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                "output_tokens_details": {"reasoning_tokens": 0}}}
    return [sse("response.created", response={**response, "status": "in_progress", "output": []}),
            sse("response.output_item.added", output_index=0, item={**item, "status": "in_progress", "content": []}),
            sse("response.content_part.added", item_id=item["id"], output_index=0, content_index=0,
                part={"type": "output_text", "text": "", "annotations": []}),
            sse("response.output_text.delta", item_id=item["id"], output_index=0, content_index=0, delta=TEXT),
            sse("response.output_text.done", item_id=item["id"], output_index=0, content_index=0, text=TEXT),
            sse("response.output_item.done", output_index=0, item=item),
            sse("response.completed", response=response)]


@contextmanager
def fixture():
    evidence = {"requests": [], "errors": [], "closed": 0}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            if self.path != "/openai/v1/responses":
                evidence["errors"].append("unexpected-path")
                self.send_error(404)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 < size <= 2 * 1024 * 1024:
                self.send_error(413)
                return
            body = self.rfile.read(size)
            try:
                _, outgoing = prepare(body, dict(self.headers), session_token=TOKEN, model=MODEL,
                                      access_token="fixture-upstream", account_id="fixture-account")
            except Refused as exc:
                evidence["errors"].append(str(exc))
                self.send_error(400, str(exc))
                return
            doc = json.loads(body)
            evidence["requests"].append({"path": self.path, "model": doc["model"], "stream": doc["stream"],
                                         "store": doc["store"], "input_is_array": isinstance(doc["input"], list),
                                         "auth_replaced": outgoing["authorization"] == "Bearer fixture-upstream"})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            obs = Observation()
            def close():
                evidence["closed"] += 1
            stream = relay(completion(), obs, close)
            try:
                for chunk in stream:
                    self.wfile.write(chunk)
                    self.wfile.flush()
            finally:
                stream.close()
                evidence["observation"] = vars(obs)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/openai/v1", evidence
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def run(binary, expected_version):
    executable = shutil.which(binary)
    if executable is None:
        raise RuntimeError("codex executable not found")
    version = subprocess.check_output([executable, "--version"], text=True, timeout=10).strip()
    if version != "codex-cli " + expected_version:
        raise RuntimeError("CLI version differs from --expect-version; select the intended binary explicitly")
    with tempfile.TemporaryDirectory(prefix="codex-rail-fixture-") as tmp, fixture() as (url, evidence):
        root = Path(tmp)
        child_config = root / "config"
        child_config.mkdir()
        workspace = root / "work"
        workspace.mkdir()
        (child_config / "config.toml").write_text(f'''model = "{MODEL}"
model_provider = "fixture"
cli_auth_credentials_store = "file"
[model_providers.fixture]
name = "Offline gateway fixture"
base_url = "{url}"
wire_api = "responses"
env_key = "CODEX_FIXTURE_TOKEN"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
        # CODEX_HOME is the documented child-process config location, not the operator's home.
        env = {"PATH": os.environ["PATH"], "CODEX_HOME": str(child_config),
               "CODEX_FIXTURE_TOKEN": TOKEN, "NO_PROXY": "127.0.0.1,localhost",
               "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1"}
        result = subprocess.run([executable, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
                                 "--sandbox", "read-only", "-C", str(workspace), "Return the fixture response."],
                                env=env, cwd=workspace, capture_output=True, text=True, timeout=45)
        # Do not print process logs or captured request bodies: evidence is deliberately allowlisted.
        if result.returncode or not evidence["requests"] or evidence["errors"]:
            raise RuntimeError(f"fixture failed: exit={result.returncode}, codes={evidence['errors']}")
        records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        if not any(r.get("type") == "turn.completed" for r in records) or TEXT not in result.stdout:
            raise RuntimeError("CLI did not report the synthetic completed turn")
        if (child_config / "auth.json").exists():
            raise RuntimeError("fixture unexpectedly wrote auth.json")
        if evidence.get("observation", {}).get("outcome") != "completed" or evidence["closed"] != len(evidence["requests"]):
            raise RuntimeError("adapter did not complete and close each response")
        return {"cli_version": version, "live_subscription_verified": False, **evidence}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--expect-version", required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.codex, args.expect_version), indent=2))
