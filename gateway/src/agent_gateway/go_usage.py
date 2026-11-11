"""The OpenCode Go rail's usage poll (GW-SESSIONS-ADMIT §Capacity — the Go twin of GW-CODEX-HEADROOM §Poll).

One GET of the Go account usage endpoint per `poll_interval_s`, authenticated with the gateway's OWN Go
key (`OPENCODE_GO_API_KEY` — the credential owner observes its own account), translated into the
gateway's normalised report for `Headroom.observe()`. The vendor's windows are NAMED (`rolling`,
`weekly`, `monthly`), not spanned, so the policy's profile is keyed by name (`window`). A payload whose
windows do not match that profile is refused WHOLE by the normaliser: a missing window stays unknown,
never zero, so the verdict after a bad poll is whatever the last ACCEPTED report said, or `quota-unknown`.

The payload shape (probed 200 on 2026-11-01 with the gateway's key, synthetic values in the fixture):
`{"usage": {"rolling"|"weekly"|"monthly": {"status": "ok"|…, "percent": 0–100, "resetsAt": RFC 3339}}}`.
Account-level only: no per-model split, no absolute amounts — and nothing else in the payload is read.

ADR-108 holds: the poll feeds the gateway's own headroom state; the outcome is logged, never rendered.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from datetime import datetime

import httpx

from .headroom import Headroom, ReportError
from .responses import USER_AGENT

log = logging.getLogger("gateway.opencode.usage")

MAX_BODY_BYTES = 64 * 1024
TIMEOUT_S = 10.0


def translate(doc, now: float) -> dict:
    """The vendor usage payload → the gateway's report (`headroom.observe`). Every window under `usage` is
    read as `{status, percent, resetsAt}`; a window whose status is not `ok` makes the account `limited`.
    A non-object, a non-number percent, a non-string status or reset, or a reset that is not a timezone-
    aware RFC 3339 instant raises `quota-invalid`; the normaliser refuses the rest (profile, range, a
    reset that has already passed)."""
    if not isinstance(doc, dict) or not isinstance(doc.get("usage"), dict):
        raise ReportError("quota-invalid")
    windows, limited = [], False
    for name, w in doc["usage"].items():
        if not isinstance(w, dict):
            raise ReportError("quota-invalid")
        status, percent, resets = w.get("status"), w.get("percent"), w.get("resetsAt")
        if not isinstance(status, str) or type(percent) not in (int, float) or not isinstance(resets, str):
            raise ReportError("quota-invalid")
        try:
            at = datetime.fromisoformat(resets)
        except ValueError:
            raise ReportError("quota-invalid") from None
        if at.tzinfo is None:
            raise ReportError("quota-invalid")
        limited = limited or status != "ok"
        windows.append({"used_percent": percent, "resets_at": at.timestamp(), "window": name})
    return {"observed_at": now, "source": "poll", "limited": limited, "windows": windows}


class GoUsagePoll:
    """`poll()` = one observation, returning its bounded outcome; `run()` = the schedule."""

    def __init__(self, headroom: Headroom, client: httpx.AsyncClient, url: str, key: str | None, clock: Callable[[], float]):
        self.headroom, self.client, self.url, self.key, self.clock = headroom, client, url, key, clock
        self.polls = 0
        self.last_outcome: str | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.url)

    async def run(self) -> None:
        while True:
            try:
                await self.poll()
            except Exception:  # noqa: BLE001 — the schedule outlives any one poll's failure
                log.exception("opencode usage poll: one pass failed")
            await asyncio.sleep(self.headroom.policy.poll_interval_s)

    async def poll(self) -> str:
        outcome = await self._poll()
        self.polls += 1
        self.last_outcome = outcome
        (log.info if outcome == "accepted" else log.warning)("opencode usage poll: %s", outcome)
        return outcome

    async def _poll(self) -> str:
        if not self.enabled:
            raise RuntimeError("the Go usage poll is dark: no url")
        if not self.key:
            return "credential-unresolved"
        headers = {"authorization": "Bearer " + self.key, "accept": "application/json", "user-agent": USER_AGENT}
        try:
            req = self.client.build_request("GET", self.url, headers=headers, timeout=TIMEOUT_S)
            resp = await self.client.send(req, stream=True)
        except httpx.TimeoutException:
            return "upstream-timeout"
        except httpx.HTTPError:
            return "upstream-unreachable"
        try:
            if resp.status_code in (401, 403):
                return "upstream-auth"
            if resp.status_code != 200:
                return "upstream-http-error"
            if resp.headers.get("content-type", "").split(";")[0].strip() != "application/json":
                return "upstream-content-type"
            body = bytearray()
            async for chunk in resp.aiter_bytes():
                body += chunk
                if len(body) > MAX_BODY_BYTES:
                    return "upstream-content-type"
        except httpx.TimeoutException:
            return "upstream-timeout"
        except httpx.HTTPError:
            return "upstream-unreachable"
        finally:
            await resp.aclose()
        try:
            doc = json.loads(bytes(body))
        except ValueError:
            return "upstream-content-type"
        del body
        try:
            self.headroom.observe(translate(doc, self.clock()))
        except ReportError as e:
            return str(e)
        return "accepted"
