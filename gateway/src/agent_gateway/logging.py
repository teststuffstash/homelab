"""Redacting log formatter (GW-REDACT).

A log line never carries a bearer value, a `gws_` session token, an Anthropic oauth token
(`sk-ant-oat…`) or an OpenRouter key (`sk-or-v1-…`). The old proxy's `_cred_shaped` tripwire is
the precedent; here the formatter scrubs the RENDERED line, so a value that reaches a log call by
any path (message, args, exception text) is masked before it is written.
"""

from __future__ import annotations

import logging
import re
import sys

REDACTED = "<redacted>"

# Literal values the formatter also masks (the Go key is an env value with no recognisable shape).
_LITERALS: list[str] = []

# Order matters only for readability: each pattern masks its own shape.
_PATTERNS = [
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"),  # `Bearer <anything>`
    re.compile(r"\bgws_[A-Za-z0-9_-]+"),  # a gateway session token
    re.compile(r"\bsk-ant-oat[A-Za-z0-9_-]*"),  # the subscription oauth token
    re.compile(r"\bsk-or-v1-[A-Za-z0-9_-]*"),  # an OpenRouter key
    re.compile(r"(?i)\b(x-api-key|api-key)\s*[:=]\s*\S+"),  # `x-api-key: <value>` renderings
]


def redact(text: str) -> str:
    """Mask every credential-shaped span in `text`, plus the registered literal values."""
    for pat in _PATTERNS:
        text = pat.sub(lambda m: _keep_label(m.group(0)), text)
    for lit in _LITERALS:
        if lit:
            text = text.replace(lit, REDACTED)
    return text


def register_literal(value: str | None) -> None:
    """Teach the formatter a value with no recognisable shape (the mounted Go key)."""
    if value and value not in _LITERALS:
        _LITERALS.append(value)


def _keep_label(span: str) -> str:
    low = span.lower()
    if low.startswith("bearer"):
        return "Bearer " + REDACTED
    for label in ("x-api-key", "api-key"):
        if low.startswith(label):
            return f"{label}: {REDACTED}"
    return REDACTED


def looks_like_credential(value: str) -> bool:
    """True when a header VALUE is credential-shaped (the old proxy's `_cred_shaped`)."""
    return (
        "sk-ant-oat" in value
        or "sk-or-v1-" in value
        or "gws_" in value
        or value.lower().startswith("bearer ")
    )


class RedactingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return redact(super().format(record))


def configure(level: str = "INFO", literals: list[str | None] | None = None) -> None:
    for lit in literals or ():
        register_literal(lit)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(RedactingFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
