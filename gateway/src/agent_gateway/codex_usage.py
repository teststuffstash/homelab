"""The codex rail's usage poll (GW-CODEX-HEADROOM §Poll) — the gateway's OWN account observation.

One GET of the account usage endpoint per `poll_interval_s`, authenticated with the lifecycle's
credential (the one refresh owner — the poll never becomes a second refresher) and translated into
the gateway's normalised report for `Headroom.observe()`. The vendor payload carries identity
(`account_id`, `email`, `user_id`): it is never logged, attached, persisted or rendered — only the
two flags and the windows' three fields leave `translate`. A payload whose windows do not match the
policy profile is refused WHOLE by the normaliser (a missing window stays unknown — never zero), so
the verdict after a bad poll is whatever the last ACCEPTED report said, or `quota-unknown`.

The payload shape is the one observed on 2026-10-22 (the spike §Live usage payload shape):
`rate_limit.{allowed, limit_reached, primary_window, secondary_window}`, each window
`{used_percent: int, limit_window_seconds: int, reset_after_seconds: int, reset_at: int}` — the
native client's basis is the absolute `reset_at`, so is this poll's. Everything else in the
payload (`credits`, `model_usage`, `spend_control`, …) is unread.

ADR-108 holds: the poll feeds the gateway's own headroom state; Prometheus only observes the
accepted report through the GW-CODEX-HEADROOM gauges and this leg's outcome counter.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable

import httpx

from .headroom import ReportError
from .oauth import Code, Failure
from .responses import USER_AGENT

log = logging.getLogger("gateway.codex.usage")

MAX_BODY_BYTES = 64 * 1024
TIMEOUT_S = 10.0
OUTCOMES = ("accepted", "quota-invalid", "quota-time-invalid", "quota-out-of-order", "credential-unresolved",
            "credential-transient", "upstream-auth", "upstream-http-error", "upstream-content-type",
            "upstream-unreachable", "upstream-timeout")
WINDOW_KEYS = ("primary_window", "secondary_window")


def translate(doc, now: float) -> dict:
    """The vendor usage payload → the gateway's report (`headroom.report`). Only the rate-limit block is
    read; a non-object, a non-bool flag, a window that is not an object of integers, or a window span
    that is not whole minutes raises `quota-invalid` (the normaliser refuses the rest: profile, range,
    passed resets). A null window is OMITTED, which the profile check then refuses — unknown, not zero."""
    if not isinstance(doc, dict) or not isinstance(doc.get("rate_limit"), dict):
        raise ReportError("quota-invalid")
    rl = doc["rate_limit"]
    allowed, reached = rl.get("allowed"), rl.get("limit_reached")
    if type(allowed) is not bool or type(reached) is not bool:
        raise ReportError("quota-invalid")
    windows = []
    for key in WINDOW_KEYS:
        w = rl.get(key)
        if w is None:
            continue
        if not isinstance(w, dict):
            raise ReportError("quota-invalid")
        used, span, reset = w.get("used_percent"), w.get("limit_window_seconds"), w.get("reset_at")
        if any(type(v) is not int for v in (used, span, reset)) or span <= 0 or span % 60:
            raise ReportError("quota-invalid")
        windows.append({"used_percent": used, "resets_at": reset, "window_minutes": span // 60})
    return {"observed_at": now, "source": "poll", "limited": reached or not allowed, "windows": windows}


class UsagePoll:
    """`poll()` = one observation, returning its bounded outcome; `run()` = the schedule."""

    def __init__(self, rail, client: httpx.AsyncClient, url: str, metrics, clock: Callable[[], float]):
        self.rail, self.client, self.url, self.metrics, self.clock = rail, client, url, metrics, clock
        self.polls = 0
        self.last_outcome: str | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.url) and self.rail is not None and self.rail.lifecycle is not None

    async def run(self) -> None:
        interval = self.rail.policy.headroom.poll_interval_s
        while True:
            try:
                await self.poll()
            except Exception:  # noqa: BLE001 — the schedule outlives any one poll's failure
                log.exception("codex usage poll: one pass failed")
            await asyncio.sleep(interval)

    async def poll(self) -> str:
        outcome = await self._poll()
        self.polls += 1
        self.last_outcome = outcome
        self.metrics.codex_poll(outcome)
        (log.info if outcome == "accepted" else log.warning)("codex usage poll: %s", outcome)
        return outcome

    async def _poll(self) -> str:
        if not self.enabled:
            raise RuntimeError("the usage poll is dark: no url or no credential backend")
        try:
            credential = await asyncio.to_thread(self.rail.lifecycle.acquire)
        except Failure as f:
            return "credential-transient" if f.code is Code.STORE else "credential-unresolved"
        headers = {"authorization": "Bearer " + credential.access_token, "chatgpt-account-id": credential.account_id,
                   "accept": "application/json", "user-agent": USER_AGENT}
        del credential
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
            self.rail.headroom.observe(translate(doc, self.clock()))
        except ReportError as e:
            return str(e)
        return "accepted"
