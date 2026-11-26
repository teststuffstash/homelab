"""Asking the gateway, once — LAUNCH-ADMIT-HELPER and LAUNCH-ADMIT-BOUND (specs/admission.md).

`GatewayAdmit(transport, caller_token).admit(argv)` takes the `gw_admit.args` fields as an argv and
returns an `Admission`: the rc (0 · 1 · 2 · 3) and the outputs under the names `gw_admit.outputs`
declares. `release(admission)` is the release entry. The gateway transport and the caller-token
source are injected, so a caller (or a case) answers them from anywhere; nothing here ends the
calling process, and the caller's token is asked for per call, handed to the transport and kept nowhere.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any

HARNESSES = ("claude", "opencode", "goose", "codex")
MODEL_KEY = {
    "claude": "ANTHROPIC_MODEL",
    "opencode": "OPENCODE_CONFIG_CONTENT",
    "goose": "GOOSE_MODEL",
    "codex": "CODEX_MODEL",
}
# the model's rail prefix, stripped to give the harness invocation's id
RAIL_PREFIX = {"anthropic": "claude/", "opencode": "opencode-go/", "codex": "codex/"}

_SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_SHELL_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_BIND = re.compile(r"^([^/]+)/([^/]+)/([^/]+)$")
_CANARY = re.compile(r"^([^@]+)@([^@]+)$")

# the in-pod pull (LAUNCH-POD-ENV-PULL): first in the pod command, exits 97 before the harness
PULL_PRELUDE = r"""
_gw_ans=$(printf 'Authorization: Bearer %s\n' "$(cat /var/run/secrets/agent-gateway/token)" \
  | curl -sf --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused -X POST -H @- "$AGENT_GATEWAY_PULL_URL") || {
  echo "gateway(sessions): env pull FAILED at ${AGENT_GATEWAY_PULL_URL} - the harness does not start" >&2
  exit 97
}
for _gw_k in $(printf '%s' "$AGENT_GATEWAY_ENV_KEYS" | tr ',' ' '); do
  _gw_v=$(printf '%s' "$_gw_ans" | jq -er --arg k "$_gw_k" '.env[$k] | strings') || {
    echo "gateway(sessions): the env pull answer lacks ${_gw_k} as a string - the harness does not start" >&2
    exit 97
  }
  export "$_gw_k=$_gw_v"
done
unset _gw_ans _gw_k _gw_v
""".strip()


class TransportError(Exception):
    """The gateway gave no answer (unreachable, timed out)."""


class CallerTokenError(Exception):
    """No caller identity could be produced."""


@dataclass(frozen=True)
class Request:
    method: str
    path: str
    headers: Mapping[str, str]
    body: dict[str, Any] | None = None
    base: str = ""  # the gateway's address when the caller names one; empty = the transport's own


@dataclass(frozen=True)
class Reply:
    status: int
    body: Any


Transport = Callable[[Request], Reply]
CallerToken = Callable[[], str]


@dataclass
class Admission:
    rc: int
    outputs: dict[str, str] = field(default_factory=dict)
    stderr: list[str] = field(default_factory=list)
    released: bool = field(default=False, repr=False)

    @property
    def session_id(self) -> str:
        return self.outputs.get("GW_SESSION_ID", "")


class _Refused(Exception):
    pass


def _parse_args(argv: list[str]) -> dict[str, Any]:
    flags = {"stack", "role", "task", "round", "attempt", "tier", "harness", "rail", "canary", "bind",
             "env-file", "harnesses"}
    given: dict[str, str] = {}
    it = iter(argv)
    for arg in it:
        name = arg[2:] if arg.startswith("--") else ""
        if name not in flags:
            raise _Refused(f"unknown argument {arg!r}")
        try:
            given[name] = next(it)
        except StopIteration:
            raise _Refused(f"--{name} needs a value") from None
    for name in ("stack", "role", "task"):
        if not given.get(name):
            raise _Refused(f"--{name} is required")
    for name in ("bind", "env-file"):
        if name in given and not given[name]:
            raise _Refused(f"--{name} must not be empty")
    if ("bind" in given) == ("env-file" in given):
        raise _Refused("exactly one of --bind / --env-file")
    out: dict[str, Any] = dict(given)
    if "bind" in given and not _BIND.fullmatch(given["bind"]):
        raise _Refused("--bind must be <ns>/<sa>/<pod>")
    if "canary" in given and not _CANARY.fullmatch(given["canary"]):
        raise _Refused("--canary must be <model>@<provider>")
    out["round"] = _integer(given.get("round", "0"), "round", 0)
    out["attempt"] = _integer(given.get("attempt", "1"), "attempt", 1)
    out["harnesses"] = [h for h in given.get("harnesses", ",".join(HARNESSES)).split(",") if h]
    unknown = [h for h in out["harnesses"] if h not in HARNESSES]
    if unknown:
        raise _Refused(f"--harnesses: unknown {', '.join(unknown)}")
    return out


def _integer(text: str, name: str, minimum: int) -> int:
    if not re.fullmatch(r"[0-9]+", text) or int(text) < minimum:
        raise _Refused(f"--{name} must be an integer >= {minimum}")
    return int(text)


def _request_body(a: dict[str, Any]) -> dict[str, Any]:
    body: dict[str, Any] = {"stack": a["stack"], "role": a["role"], "task": a["task"], "round": a["round"]}
    if a["attempt"] > 1:
        body["attempt"] = a["attempt"]
    for key in ("tier", "harness", "rail"):
        if key in a:
            body[key] = a[key]
    if "canary" in a:
        model, provider = _CANARY.fullmatch(a["canary"]).groups()  # type: ignore[union-attr]
        body["canary"] = {"model": model, "provider": provider}
    if "bind" in a:
        ns, sa, pod = _BIND.fullmatch(a["bind"]).groups()  # type: ignore[union-attr]
        body["bind"] = {"namespace": ns, "serviceaccount": sa, "pod": pod}
    return body


def _pull_url(session_id: str) -> re.Pattern[str]:
    """http(s), a plain host[:port], plain path segments, then /sessions/<id>/env — nothing else."""
    return re.compile(
        rf"https?://[A-Za-z0-9.:-]+(?:/[A-Za-z0-9._-]+)*/sessions/{re.escape(session_id)}/env", re.ASCII
    )


def _is_shell_names(value: Any) -> bool:
    return isinstance(value, list) and bool(value) and all(
        isinstance(k, str) and _SHELL_NAME.fullmatch(k) for k in value
    )


def _unusable(answer: dict[str, Any], a: dict[str, Any], session_id: str) -> list[str]:
    """Every failed check of a dispatch, in the order the spec lists them."""
    bound = "bind" in a
    failed: list[str] = []
    session = answer.get("session")
    session = session if isinstance(session, dict) else {}
    if bound:
        if "token" in session or "env" in answer:
            failed.append("a credential in a bound answer")
        if not _is_shell_names(answer.get("env_keys")):
            failed.append("env_keys")
        pull = answer.get("pull_url")
        if not (isinstance(pull, str) and _pull_url(session_id).fullmatch(pull)):
            failed.append("pull_url")
        keys = answer.get("env_keys") if isinstance(answer.get("env_keys"), list) else []
    else:
        env = answer.get("env")
        ok = (
            isinstance(env, dict)
            and bool(env)
            and all(_SHELL_NAME.fullmatch(k) for k in env)
            and all(isinstance(v, str) and "\n" not in v for v in env.values())
        )
        if not ok:
            failed.append("env")
        keys = list(env) if isinstance(env, dict) else []
    model = answer.get("model")
    if not (isinstance(model, str) and model):
        failed.append("model")
    if "rail" in answer and not isinstance(answer["rail"], str):
        failed.append("rail")
    harness = answer.get("harness")
    if harness not in a["harnesses"]:
        failed.append(f"harness '{harness}' (this launcher runs {','.join(a['harnesses'])})")
    elif MODEL_KEY[harness] not in keys:
        failed.append(f"env_keys lacks {MODEL_KEY[harness]}")
    return failed


class GatewayAdmit:
    """The admission component: `admit(argv)` and `release(admission)` over an injected transport."""

    def __init__(self, transport: Transport, caller_token: CallerToken, base_url: str = "") -> None:
        self._transport = transport
        self._caller_token = caller_token
        self._base = base_url

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._caller_token()}", "Content-Type": "application/json"}

    def admit(self, argv: list[str]) -> Admission:
        try:
            a = _parse_args(argv)
        except _Refused as why:
            return Admission(2, stderr=[f"gw_admit: refused: {why}"])
        try:
            headers = self._headers()
        except CallerTokenError as why:
            return Admission(2, stderr=[f"gw_admit: refused: no caller token ({why})"])
        try:
            reply = self._transport(Request("POST", "/sessions", headers, _request_body(a), self._base))
        except TransportError:
            return self._fail("gateway-unreachable")
        if reply.status != 200:
            return self._fail(f"gateway-http {reply.status}: {json.dumps(reply.body, separators=(',', ':'))}")
        answer = reply.body if isinstance(reply.body, dict) else {}
        decision = answer.get("decision")
        if decision == "defer":
            return self._defer(answer)
        if decision != "dispatch":
            # never printed beyond the decision: a 200 that is neither verdict could carry a token
            return self._fail(f"gateway-http 200, unknown decision '{decision}'")
        return self._dispatch(answer, a)

    def _fail(self, reason: str) -> Admission:
        return Admission(3, {"GW_DEFER_REASON": reason, "GW_RETRY_AFTER": "?"},
                         [f"→ gateway(sessions): fail closed — {reason.split(':')[0]}"])

    def _defer(self, answer: dict[str, Any]) -> Admission:
        reason, retry = str(answer.get("reason", "")), str(answer.get("retry_after_s", ""))
        return Admission(1, {"GW_DEFER_REASON": reason, "GW_RETRY_AFTER": retry},
                         [f"→ gateway(sessions): defer — [{reason}] retry_after={retry}s"])

    def _dispatch(self, answer: dict[str, Any], a: dict[str, Any]) -> Admission:
        session = answer.get("session") if isinstance(answer.get("session"), dict) else {}
        session_id = session.get("id")
        if not (isinstance(session_id, str) and _SESSION_ID.fullmatch(session_id)):
            return self._fail("dispatch-unusable: session id")
        failed = _unusable(answer, a, session_id)
        if failed:
            adm = self._fail("dispatch-unusable: " + ", ".join(failed))
            adm.outputs["GW_SESSION_ID"] = session_id
            adm.stderr.append("→ gateway(sessions): dispatch unusable, FAIL CLOSED, releasing and not dispatching.")
            self.release(adm)
            adm.outputs.pop("GW_SESSION_ID")
            return adm
        model = answer["model"]
        prefix = RAIL_PREFIX.get(answer.get("rail"), "")
        keys = list(answer["env_keys"]) if "bind" in a else list(answer["env"])
        context = answer.get("context_tokens")
        out = {
            "GW_SESSION_ID": session_id,
            "GW_RAIL": str(answer.get("rail", "")),
            "GW_HARNESS": answer["harness"],
            "GW_MODEL": model,
            "GW_WIRE_MODEL": model[len(prefix):] if prefix and model.startswith(prefix) else model,
            "GW_CONTEXT_TOKENS": "" if context is None else str(context),
            "GW_EXPIRES_AT": str(session.get("expires_at", "")),
            "GW_ENV_KEYS": ",".join(keys),
            "GW_RETRY_AFTER": "",
        }
        if "bind" in a:
            out["GW_PULL_URL"] = answer["pull_url"]
            out["GW_PULL_PRELUDE"] = PULL_PRELUDE
        else:
            try:
                _write_env(a["env-file"], answer["env"])
            except (OSError, ValueError):
                _remove(a["env-file"])
                adm = self._fail("dispatch-unusable: env-file")
                adm.outputs["GW_SESSION_ID"] = session_id
                self.release(adm)
                adm.outputs.pop("GW_SESSION_ID")
                return adm
        return Admission(0, out, [f"→ gateway(sessions): dispatch {model} on {out['GW_RAIL']} ({out['GW_HARNESS']})"])

    def release(self, admission: Admission) -> None:
        """One DELETE for the session, however often it is called; a failed one warns and leaves the
        slot to the session's TTL."""
        if admission.released or not admission.session_id:
            return
        admission.released = True
        try:
            reply = self._transport(Request("DELETE", f"/sessions/{admission.session_id}", self._headers(), None, self._base))
        except (TransportError, CallerTokenError):
            admission.stderr.append(f"gw_release: DELETE {admission.session_id} failed; the slot ends with the session TTL")
            return
        if reply.status != 200:
            admission.stderr.append(f"gw_release: DELETE {admission.session_id} answered {reply.status}")


def _remove(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _write_env(path: str, env: Mapping[str, str]) -> None:
    """KEY=VALUE lines, mode 0600 from creation, never sourced."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        os.fchmod(fh.fileno(), 0o600)
        fh.write("".join(f"{k}={v}\n" for k, v in env.items()))
