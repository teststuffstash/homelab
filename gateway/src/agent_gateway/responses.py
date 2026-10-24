"""The `responses` dialect's wire (GW-RAIL-CODEX): OpenAI Responses over SSE.

Ported from `experiments/codex-rail/adapter.py` (FU-270). Transport-independent: `check_body`
refuses what the rail does not serve, `upstream_headers` is the allowlist (no inbound header
crosses — the account selector comes from the trusted credential, never the caller), `relay`
forwards SSE bytes unchanged while an incremental, per-event-bounded parser observes the terminal
outcome and its usage once. Missing usage is unknown, never zero; `[DONE]` or EOF alone never
proves completion; a failed/incomplete terminal keeps its own outcome.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass

MAX_EVENT_BYTES = 1024 * 1024  # one SSE event, not a prefix of the generation
USER_AGENT = "agent-gateway"  # the gateway's own, as on every rail — the harness's never crosses


class Refused(Exception):
    """Only fixed codes cross the boundary; never an upstream payload."""


@dataclass
class Observation:
    outcome: str = "pending"  # completed | failed | incomplete | truncated | protocol-error | transport-error | cancelled
    input_tokens: int | None = None  # INCLUDES cached_tokens (the Responses usage shape)
    cached_tokens: int | None = None
    output_tokens: int | None = None


TERMINAL = {"response.completed": "completed", "response.failed": "failed",
            "response.incomplete": "incomplete", "error": "failed"}


class Events:
    def __init__(self, observation: Observation, max_event_bytes: int = MAX_EVENT_BYTES):
        self.observation = observation
        self.limit = max_event_bytes
        self.line = bytearray()
        self.data = bytearray()
        self.size = 0
        self.terminal = False
        self.after_cr = False

    def feed(self, chunk: bytes) -> None:
        for byte in chunk:
            if self.after_cr:
                self.after_cr = False
                if byte == 10:
                    continue
            if byte in (10, 13):
                self._line()
                self.after_cr = byte == 13
            else:
                self.line.append(byte)
                self.size += 1
                if self.size > self.limit:
                    raise Refused("upstream-event-too-large")

    def _line(self) -> None:
        line = bytes(self.line)
        self.line.clear()
        if line:
            if line.startswith(b"data:"):
                value = line[5:]
                self.data.extend(value[1:] if value.startswith(b" ") else value)
                self.data.extend(b"\n")
            return
        if self.data:
            self._event(bytes(self.data).rstrip(b"\n"))
        self.data.clear()
        self.size = 0

    def _event(self, data: bytes) -> None:
        if self.terminal or data == b"[DONE]":
            return  # usage is counted once: a second terminal event never replaces it
        try:
            event = json.loads(data)
        except (ValueError, UnicodeError):
            raise Refused("upstream-event-invalid") from None
        if not isinstance(event, dict):
            raise Refused("upstream-event-invalid")
        kind = event.get("type")
        if kind not in TERMINAL:
            return
        response = event.get("response") or {}
        if not isinstance(response, dict):
            raise Refused("upstream-event-invalid")
        if kind == "response.completed" and response.get("status") != "completed":
            raise Refused("upstream-terminal-invalid")
        self.terminal = True
        self.observation.outcome = TERMINAL[kind]
        usage = response.get("usage") or {}
        if isinstance(usage, dict):
            for name in ("input_tokens", "output_tokens"):
                value = usage.get(name)
                if type(value) is int and value >= 0:
                    setattr(self.observation, name, value)
            cached = (usage.get("input_tokens_details") or {}).get("cached_tokens") if isinstance(
                usage.get("input_tokens_details"), dict) else None
            if type(cached) is int and cached >= 0:
                self.observation.cached_tokens = cached

    def finish(self) -> None:
        if not self.terminal:
            self.observation.outcome = "truncated"
            raise Refused("upstream-stream-truncated")


def check_body(doc: dict) -> None:
    """The Responses shapes this rail serves: streaming, server-side storage off, array input."""
    if doc.get("stream") is not True or doc.get("store") is not False:
        raise Refused("responses-mode-unsupported")
    if not isinstance(doc.get("input"), list):
        raise Refused("responses-input-invalid")


def upstream_headers(access_token: str, account_id: str | None) -> dict[str, str]:
    """The complete upstream header set — nothing inbound passes. `accept-encoding: identity`
    keeps the bytes the parser reads the bytes the client receives."""
    for value in (access_token, account_id):
        if value is not None and (not value or "\r" in value or "\n" in value):
            raise Refused("credential-invalid")
    out = {"authorization": "Bearer " + access_token, "content-type": "application/json",
           "accept": "text/event-stream", "accept-encoding": "identity", "user-agent": USER_AGENT}
    if account_id is not None:
        out["chatgpt-account-id"] = account_id
    return out


def http_failure(status: int) -> str | None:
    """Upstream status → the gateway's typed refusal, or None: 200 (a stream follows) and 429 (the
    rate limit passes through with its `retry-after`, as on every rail). 401/403 never relay a body;
    every other status — a redirect included, which is never followed — is `upstream-http-error`."""
    if status in (401, 403):
        return "upstream-auth"
    if status in (200, 429):
        return None
    return "upstream-http-error"


async def relay(chunks: AsyncIterator[bytes], observation: Observation, close: Callable[[], Awaitable[None]],
                max_event_bytes: int = MAX_EVENT_BYTES) -> AsyncIterator[bytes]:
    """Forward each chunk after the parser has seen it; close upstream on EOF, parse failure,
    transport error or downstream cancellation (never drain it, never retry after a byte left).
    A protocol/transport failure ENDS the stream (no terminal event reaches the client — the
    client's own completion check sees the truncation); the outcome records why."""
    events = Events(observation, max_event_bytes)
    try:
        async for chunk in chunks:
            events.feed(chunk)
            yield chunk
        events.finish()
    except (GeneratorExit, asyncio.CancelledError):
        # A consumer that goes away AFTER the terminal event has everything: the outcome it earned
        # stands. The live native CLI closes the connection right after `response.completed` while
        # the vendor holds the stream open (2026-10-22 22:57Z — both requests of the first completed
        # canary turn were recorded cancelled/499 with their usage counted). Only a stream still
        # pending (no terminal seen) is a cancellation.
        if observation.outcome == "pending":
            observation.outcome = "cancelled"
        raise
    except Refused:
        if observation.outcome == "pending":
            observation.outcome = "protocol-error"
    except Exception:  # noqa: BLE001 — a transport fault mid-stream is one fixed outcome, never its text
        observation.outcome = "transport-error"
    finally:
        await close()
