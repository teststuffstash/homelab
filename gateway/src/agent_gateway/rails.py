"""The three rails (GW-RAIL-ANTHROPIC, GW-RAIL-OPENCODE, GW-RAIL-OPENROUTER).

A rail = an upstream base URL per dialect + the header policy that turns an inbound ride request
into the upstream one. Rules shared by all rails: hop-by-hop headers are dropped; the inbound auth
(`authorization`, `x-api-key`, `api-key`, `cookie`) NEVER reaches upstream; the resolved credential
is injected in the form the rail wants; a credential-shaped value in any other header is refused.
"""

from __future__ import annotations

from dataclasses import dataclass

from .config import RAIL_DIALECTS
from .logging import looks_like_credential

OAUTH_BETA = "oauth-2025-04-20"
USER_AGENT = "agent-gateway"  # the gateway's own User-Agent (`user_agent: fixed`, the default)

# Hop-by-hop + framing headers the gateway owns (the old proxy's _DROP_REQ / _DROP_RESP).
DROP_REQUEST = frozenset(
    {
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers",
        "transfer-encoding", "upgrade", "host", "content-length",
    }
)
DROP_RESPONSE = frozenset({"connection", "keep-alive", "transfer-encoding", "content-length"})
# Credential-bearing inbound headers: never forwarded on any rail (GW-CRED-BOUNDARY).
DENY_INBOUND_AUTH = frozenset({"authorization", "x-api-key", "api-key", "cookie"})

# Dialect → upstream path (the dialect's own API path, identical on every rail that serves it).
DIALECT_PATHS = {
    ("anthropic", "messages"): "/v1/messages",
    ("openai", "chat"): "/v1/chat/completions",
    ("openai", "models"): "/v1/models",
}


class HeaderRefused(Exception):
    """A credential-shaped value in a header the gateway does not own (the FU-251 tripwire)."""

    def __init__(self, names: list[str]):
        super().__init__(f"credential-shaped value in header(s) {names}")
        self.names = names


@dataclass(frozen=True)
class Upstream:
    url: str
    headers: dict[str, str]
    note: str  # one log-safe token per header decision, e.g. "+oauth-beta+oc-session[native]"


def serves(rail: str, dialect: str) -> bool:
    return dialect in RAIL_DIALECTS[rail]


def upstream_url(rail: str, base: str, dialect: str, op: str) -> str:
    return base + DIALECT_PATHS[(dialect, op)]


def build_headers(
    rail: str, dialect: str, inbound: list[tuple[str, str]], credential: str, session_id: str, user_agent: str = "fixed"
) -> tuple[dict[str, str], str]:
    """Inbound headers → upstream headers for (rail, dialect). Raises HeaderRefused on a leak."""
    out: dict[str, str] = {}
    for k, v in inbound:
        kl = k.lower()
        if kl in DROP_REQUEST or kl in DENY_INBOUND_AUTH:
            continue
        out[kl] = v
    note = ""
    if rail == "anthropic":
        out["authorization"] = f"Bearer {credential}"
        # claude-code sends the oauth beta only when IT holds the oauth token; through the
        # ANTHROPIC_AUTH_TOKEN path it does not — merge it in (old proxy precedent, FU-066).
        beta = out.get("anthropic-beta")
        if not beta:
            out["anthropic-beta"] = OAUTH_BETA
        elif OAUTH_BETA not in [b.strip() for b in beta.split(",")]:
            out["anthropic-beta"] = beta + "," + OAUTH_BETA
        note += "+oauth-beta"
    elif rail == "opencode":
        # The subscription-specific beta list never reaches opencode.ai (ADR-107 precedent).
        out.pop("anthropic-beta", None)
        if dialect == "anthropic":
            out["x-api-key"] = credential
            note += "+go-x-api-key"
        else:
            out["authorization"] = f"Bearer {credential}"
            note += "+go-bearer"
        # The vendor routes on a per-conversation id (chainless-redesign.md §Proved on the wire):
        # either `x-opencode-session` or `x-claude-code-session-id` alone clears its gate, so both
        # pass through untouched; a client that sent neither gets the gateway session id (per
        # ride — the granularity the 09-17 re-read found correct).
        if out.get("x-opencode-session"):
            note += "+oc-session[client]"
        elif out.get("x-claude-code-session-id"):
            note += "+oc-session[native]"
        else:
            out["x-opencode-session"] = session_id
            note += "+oc-session[gateway]"
    elif rail == "openrouter":
        # anthropic-beta is forwarded untouched here (specs ⚖ verify: whether OpenRouter's
        # Messages endpoint honours it is not documented).
        out["authorization"] = f"Bearer {credential}"
        note += "+or-bearer"
    else:  # pragma: no cover — config.RAILS is closed
        raise ValueError(rail)
    # The User-Agent is the rail's policy (GW-CRED-BOUNDARY): `fixed` = the gateway's own, never the
    # caller's (an edge judging client signatures must not see a caller's — Cloudflare 1010, the
    # 2026-10-17 self-latch); `forward` = the harness's, kept (a vendor that admits by harness).
    if user_agent != "forward" or not out.get("user-agent"):
        out["user-agent"] = USER_AGENT
    # Content-Encoding passthrough: the upstream answers in the encoding THE CLIENT asked for, and
    # the bytes go back unchanged — so a client that sent no Accept-Encoding gets `identity`, never
    # a gzip body it did not ask for (the transport's own default would otherwise ask for gzip).
    if not out.get("accept-encoding"):
        out["accept-encoding"] = "identity"
    own = {"authorization", "x-api-key"}
    leaked = sorted(k for k, v in out.items() if k not in own and looks_like_credential(v))
    if leaked:
        raise HeaderRefused(leaked)
    return out, note


def response_headers(upstream: list[tuple[str, str]] | dict) -> dict[str, str]:
    items = upstream.items() if isinstance(upstream, dict) else upstream
    return {k: v for k, v in items if k.lower() not in DROP_RESPONSE}
