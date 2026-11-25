"""The launcher's own admission, before any request — LAUNCH-ADMIT-LAUNCHER (specs/admission.md).

`LauncherAdmission(transport, read_token_file, mint).admit(...)` takes the `launcher.knobs` values
(a mapping of the operator's knobs), the argv values the page names, the stack row and the
repo/task, and answers a `Refusal` (exit code + one stderr line) or an `Admitted` (the request it
would send). A refusal reaches nothing: the gateway transport is never called. Sending the request
is the next component's (#3408); the transport is held for it.

The caller-token file read and the canary token mint are injected, so a case answers them from a
world; nothing here ends the calling process.
"""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from launch.gateway_admit import CallerTokenError, Request

DEFAULT_TOKEN_FILE = "/var/run/secrets/agent-gateway/token"
_CALLER_SA = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9.]*[a-z0-9])?")
_INT = re.compile(r"[0-9]+")


@dataclass(frozen=True)
class Refusal:
    rc: int
    stderr: str


@dataclass(frozen=True)
class Admitted:
    body: dict[str, Any]  # the POST /sessions body
    bind: str  # <repo>/agentstack-worker/agent-<repo>-<task>-r<round>
    caller_token: str


class LauncherAdmission:
    def __init__(
        self,
        transport: Callable[[Request], Any],
        read_token_file: Callable[[str], str | None],
        mint: Callable[[str], str],
        clock: Callable[[], str] = lambda: time.strftime("%H%M%S"),
    ) -> None:
        self.clock = clock
        self.transport = transport
        self.read_token_file = read_token_file
        self.mint = mint

    def admit(
        self,
        knobs: Mapping[str, str],
        stack_row: Mapping[str, Any],
        repo: str,
        task: str,
        *,
        model: str | None = None,
        round: str = "1",
        run: str | None = None,
        recipe: str | None = None,
        harness: str | None = None,
    ) -> Refusal | Admitted:
        # an empty knob is unset; a non-integer fallback exit is ignored
        fallback = knobs.get("AGENT_GATEWAY_FALLBACK_EXIT") or ""
        fallback_rc = int(fallback) if _INT.fullmatch(fallback) else 2

        def refuse(why: str) -> Refusal:
            # a refusal before the request takes the wrapper's exit when one is set
            return Refusal(fallback_rc, f"PREFLIGHT REFUSED: {why}")

        if model is not None:
            # unchanged by the fallback exit: a contradiction, not a failure to ask
            return Refusal(
                2,
                f"PREFLIGHT REFUSED: --model {model} under AGENT_GATEWAY=sessions — "
                "the gateway owns the model; drop --model",
            )
        if run is None and recipe is None:
            return refuse("an interactive ride needs --run or --recipe under AGENT_GATEWAY=sessions")
        if not _INT.fullmatch(round):
            return refuse(f"--round {round!r} is not an integer")
        attempt = knobs.get("AGENT_GATEWAY_ATTEMPT") or None
        if attempt is not None and not (_INT.fullmatch(attempt) and int(attempt) >= 1):
            return refuse(f"AGENT_GATEWAY_ATTEMPT={attempt!r} is not an integer >= 1")
        sa = knobs.get("AGENT_GATEWAY_CALLER_SA") or None
        if sa is not None and not _CALLER_SA.fullmatch(sa):
            return refuse(f"AGENT_GATEWAY_CALLER_SA={sa!r} is not <namespace>/<serviceaccount>")
        if sa is not None:
            try:
                token = self.mint(sa)
            except CallerTokenError as e:
                return refuse(f"no caller token could be minted for {sa}: {e}")
        else:
            path = knobs.get("AGENT_GATEWAY_CALLER_TOKEN_FILE") or DEFAULT_TOKEN_FILE
            token = self.read_token_file(path)
        if not token or not token.strip():
            return refuse("no caller token (no token file and no AGENT_GATEWAY_CALLER_SA)")

        # LAUNCH-POD-IDENTITY: a tasked ride's pod name, non-[a-z0-9] of the task -> '-'
        pod = f"agent-{repo}-{re.sub('[^a-z0-9]', '-', task)}-r{round}" if task else f"agent-{repo}-{self.clock()}"
        bind = f"{repo}/agentstack-worker/{pod}"
        body: dict[str, Any] = {
            "stack": stack_row["name"],
            "role": knobs.get("AGENT_GATEWAY_ROLE", "worker"),
            "task": task,
            "round": int(round),
            "bind": bind,
        }
        if harness is not None:
            body["harness"] = harness
        if attempt is not None:
            body["attempt"] = int(attempt)
        if "AGENT_GATEWAY_RAIL" in knobs:
            body["rail"] = knobs["AGENT_GATEWAY_RAIL"]
        if "AGENT_GATEWAY_CANARY" in knobs:
            model_id, _, provider = knobs["AGENT_GATEWAY_CANARY"].partition("@")
            body["canary"] = {"model": model_id, "provider": provider}
        return Admitted(body, bind, token.strip())
