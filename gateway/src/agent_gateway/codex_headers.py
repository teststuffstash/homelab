"""The codex rail's upstream headroom headers (GW-CODEX-HEADROOM §Upstream headers) — the SECOND
observation source, read off every relayed 200 stream.

The backend's streaming answer carries the account's windows as response headers (observed on the
wire 2026-10-22, the spike §The second ride: `x-codex-primary-used-percent`, `-window-minutes`,
`-reset-at`, the `secondary` set, `x-codex-rate-limit-reached-type` when a limit is hit). The value
grammar is the pinned CLI's own reader (codex-rs `codex-api/src/rate_limits.rs` @ rust-v0.163.0):
used-percent a float, window-minutes and reset-at integers (epoch seconds), a window present iff
its used-percent header is. This module translates those names into the gateway's normalised
report (`source: upstream`, `observed_at` = now) for `Headroom.observe()` — the same strictly-newer
replacement the poll rides, so the two producers compete only by time. A window whose used-percent
header is absent is OMITTED, which the profile check refuses whole (unknown, never zero); any value
the grammar cannot read raises `quota-invalid`. Nothing else in the header set is read (plan type,
credits, the over-secondary percent, the safety flags); the request's own outcome never depends on
this read — a malformed header leaves the stream relayed and the last accepted report standing.
"""

from __future__ import annotations

from collections.abc import Mapping

from .headroom import ReportError

PREFIX = "x-codex-"
WINDOWS = ("primary", "secondary")
LIMIT_HEADER = "x-codex-rate-limit-reached-type"  # present (non-empty) = the vendor says a limit is reached
OUTCOMES = ("accepted", "absent", "quota-invalid", "quota-time-invalid", "quota-out-of-order")


def translate(headers: Mapping[str, str], now: float) -> dict | None:
    """The relayed answer's `x-codex-*` headers → the gateway's report; None when no window header is
    present at all (`absent`). Raises `quota-invalid` on a value the pinned CLI's grammar cannot read
    (the normaliser refuses the rest: range, profile, passed resets, non-finite floats)."""
    windows = []
    for name in WINDOWS:
        used = headers.get(f"{PREFIX}{name}-used-percent")
        if used is None:
            continue
        minutes, reset = headers.get(f"{PREFIX}{name}-window-minutes"), headers.get(f"{PREFIX}{name}-reset-at")
        try:
            window = {"used_percent": float(used.strip()), "window_minutes": int(minutes.strip()),
                      "resets_at": int(reset.strip())}
        except (AttributeError, TypeError, ValueError) as e:
            raise ReportError("quota-invalid") from e
        windows.append(window)
    if not windows:
        return None
    limited = bool((headers.get(LIMIT_HEADER) or "").strip())
    return {"observed_at": now, "source": "upstream", "limited": limited, "windows": windows}
