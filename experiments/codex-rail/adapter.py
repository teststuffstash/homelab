"""Transport-independent Responses prototype. No gateway imports or live credentials."""
from dataclasses import dataclass
import hmac
import json
from typing import Iterable, Iterator


class Refused(Exception):
    """Only fixed codes cross the boundary; never include upstream payloads."""


@dataclass
class Observation:
    outcome: str = "pending"
    input_tokens: int | None = None
    output_tokens: int | None = None


class Events:
    """Bound one SSE event, not a prefix of the whole generation."""

    def __init__(self, observation: Observation, max_event_bytes: int = 1024 * 1024):
        self.observation = observation
        self.limit = max_event_bytes
        self.line = bytearray()
        self.data = bytearray()
        self.size = 0
        self.terminal = False
        self.after_cr = False

    def feed(self, chunk: bytes):
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

    def _line(self):
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

    def _event(self, data: bytes):
        if self.terminal or data == b"[DONE]":
            return
        try:
            event = json.loads(data)
        except (ValueError, UnicodeError):
            raise Refused("upstream-event-invalid") from None
        if not isinstance(event, dict):
            raise Refused("upstream-event-invalid")
        kind = event.get("type")
        outcomes = {"response.completed": "completed", "response.failed": "failed",
                    "response.incomplete": "incomplete", "error": "failed"}
        if kind not in outcomes:
            return
        response = event.get("response") or {}
        if not isinstance(response, dict):
            raise Refused("upstream-event-invalid")
        if kind == "response.completed" and response.get("status") != "completed":
            raise Refused("upstream-terminal-invalid")
        self.terminal = True
        self.observation.outcome = outcomes[kind]
        usage = response.get("usage") or {}
        if isinstance(usage, dict):
            for name in ("input_tokens", "output_tokens"):
                value = usage.get(name)
                if type(value) is int and value >= 0:
                    setattr(self.observation, name, value)

    def finish(self):
        if not self.terminal:
            self.observation.outcome = "truncated"
            raise Refused("upstream-stream-truncated")


def prepare(body: bytes, headers: dict[str, str], *, session_token: str,
            model: str, access_token: str, account_id: str | None = None):
    """Called AFTER production session expiry/role checks; fixture token is fixed.

    Return body and allowlisted upstream headers. No arbitrary inbound headers escape.
    Account selection comes from trusted credentials, never the caller.
    """
    inbound = {k.lower(): v for k, v in headers.items()}
    supplied = inbound.get("authorization", "")
    if not hmac.compare_digest(supplied.encode(), ("Bearer " + session_token).encode()):
        raise Refused("session-unknown")
    try:
        doc = json.loads(body)
    except (ValueError, UnicodeError):
        raise Refused("malformed-body") from None
    if not isinstance(doc, dict):
        raise Refused("malformed-body")
    if doc.get("model") != model:
        raise Refused("model-not-session")
    if doc.get("stream") is not True or doc.get("store") is not False:
        raise Refused("responses-mode-unsupported")
    if not isinstance(doc.get("input"), list):
        raise Refused("responses-input-invalid")
    for value in (access_token, account_id):
        if value is not None and (not value or "\r" in value or "\n" in value):
            raise Refused("credential-invalid")
    outgoing = {"authorization": "Bearer " + access_token,
                "content-type": "application/json", "accept": "text/event-stream"}
    if account_id is not None:
        outgoing["chatgpt-account-id"] = account_id
    return body, outgoing


def http_failure(status: int) -> str | None:
    if status in (401, 403):
        return "upstream-auth"
    if status == 429:
        return "upstream-rate-limited"
    if status != 200:
        return "upstream-http-error"
    return None


def relay(chunks: Iterable[bytes], observation: Observation, close,
          max_event_bytes: int = 1024 * 1024) -> Iterator[bytes]:
    """Consumer must close the iterator on disconnect. No retry after first byte.

    A transport supplies chunks and owns status/timeout mapping. finally closes its
    response on EOF, parse failure, transport error or downstream cancellation.
    """
    events = Events(observation, max_event_bytes)
    try:
        for chunk in chunks:
            events.feed(chunk)
            yield chunk
        events.finish()
    except GeneratorExit:
        observation.outcome = "cancelled"
        raise
    except Refused:
        if observation.outcome == "pending":
            observation.outcome = "protocol-error"
        raise
    except Exception:
        observation.outcome = "transport-error"
        raise Refused("upstream-transport-error") from None
    finally:
        close()
