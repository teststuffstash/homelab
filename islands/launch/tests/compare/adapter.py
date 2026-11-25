"""Command-line shim from the `gateway-admit` replay family's bash bridge to the Python component.

`adapter.py admit <out> -- <gw_admit argv…>` and `adapter.py release <out> <session> <released>`.
It translates: argv → `GatewayAdmit.admit`, the component's outputs → shell assignments written to
<out> (sourced by adapter.sh), its stderr lines → stderr. The transport hands each request to the
`curl` the family's bridge defines (exported shell function), exactly as the old helper called it.
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

from launch.gateway_admit import (
    Admission,
    CallerTokenError,
    GatewayAdmit,
    Reply,
    Request,
    TransportError,
)

GW_URL = os.environ.get("GW_URL", "http://agent-gateway.agent-egress.svc.cluster.local:8080")
OUTPUTS = ("GW_SESSION_ID", "GW_RAIL", "GW_HARNESS", "GW_MODEL", "GW_WIRE_MODEL", "GW_CONTEXT_TOKENS",
           "GW_EXPIRES_AT", "GW_ENV_KEYS", "GW_PULL_URL", "GW_PULL_PRELUDE", "GW_DEFER_REASON", "GW_RETRY_AFTER")


def caller_token() -> str:
    path = os.environ.get("AGENT_GATEWAY_CALLER_TOKEN_FILE", "")
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError as why:
        raise CallerTokenError(str(why)) from why


def transport(req: Request) -> Reply:
    with tempfile.TemporaryDirectory() as tmp:
        hdr, body_out = Path(tmp, "h"), Path(tmp, "o")
        hdr.write_text("".join(f"{k}: {v}\n" for k, v in req.headers.items()), encoding="utf-8")
        # A POST's answer is its status code + body; a DELETE's is the curl exit status alone (-f),
        # exactly how the call is read at this seam: exit 0 = the gateway accepted it.
        args = ["-sS", "-o", str(body_out), "-X", req.method, "-H", f"@{hdr}"]
        args += ["-f"] if req.method == "DELETE" else ["-w", "%{http_code}"]
        if req.body is not None:
            args += ["-d", json.dumps(req.body, separators=(",", ":"), ensure_ascii=False)]
        proc = subprocess.run(["bash", "-c", 'curl "$@"', "curl", *args, GW_URL + req.path],
                              capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise TransportError(f"curl exit {proc.returncode}")
        if req.method == "DELETE":
            return Reply(200, None)
        text = body_out.read_text(encoding="utf-8") if body_out.exists() else ""
        try:
            parsed = json.loads(text) if text else None
        except ValueError:
            parsed = text
        return Reply(int(proc.stdout.strip() or 0), parsed)


def emit(out: Path, adm: Admission) -> None:
    lines = [f"{k}={shlex.quote(adm.outputs.get(k, ''))}" for k in OUTPUTS]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for line in adm.stderr:
        print(line, file=sys.stderr)


def main(argv: list[str]) -> int:
    component = GatewayAdmit(transport, caller_token)
    if argv[0] == "admit":
        adm = component.admit(argv[3:])
        emit(Path(argv[1]), adm)
        return adm.rc
    adm = Admission(0, {"GW_SESSION_ID": argv[2]}, released=argv[3] == "1")
    component.release(adm)
    emit(Path(argv[1]), Admission(0, {}, adm.stderr))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
