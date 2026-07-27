#!/usr/bin/env python3
"""openrouter-proxy — the ADR-081 egress proxy, v1 slice (FU-018 / FU-062 §M4).

Worker harnesses that cannot carry OpenRouter `provider` routing themselves (goose) send their
OpenRouter traffic here instead of to openrouter.ai directly (`OPENROUTER_HOST`, wired by homelab
agents/agent-session.sh). For every `POST …/chat/completions` whose JSON body has NO `provider`
field, the proxy injects the per-model session pin — the effective-cheapest cache-supporting,
tools-capable provider at ≥ the uptime floor, plus allow_fallbacks and a max_price guard — and
forwards. Everything else (other paths, bodies that already carry `provider`, `:free` models where
routing is $0 either way) passes through untouched. Cache lives AT the provider, so pinning per
session/model is the whole point (the $5.79 qwen autopsy: default routing = a 1/price² lottery).

v1 scope (deliberate): provider injection ONLY. The pod still holds its own OPENROUTER_API_KEY —
the Authorization header passes through unread. Credential minting/injection and the Cilium
egress lockdown are the remaining ADR-081 legs (homelab FU-018 / FU-020).

The pin math mirrors homelab agents/estimate_budget.py `pinned_provider()` (that file is the
authoritative twin — keep them in step): h-blended effective price over pools
cached+tools+uptime → tools+uptime → tools.

ADR-096 (FU-095): this service is also the ROUTER — the control-plane half lives in router.py
(same ConfigMap): durable strikes/attribution (POST /report), passive provider-event
observation on the forwarded OpenRouter leg, rotation/canary ingest (POST /rotation,
TokenReview-gated), latch persistence across restarts, GET /router-status, and the router_*
/metrics series. The decision endpoint (POST /route) and the budgeter legs land per the
ADR-096 phases.

Stdlib only; runs on a stock python:3.13-slim from a ConfigMap (github-exporter pattern).
"""

import base64
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import router  # ADR-096 control plane — sibling file in the same ConfigMap/dir

UPSTREAM = os.environ.get("UPSTREAM", "https://openrouter.ai")
# FU-066 (claude+haiku worker tier): requests under /anthropic/* forward to the Anthropic API
# instead — same ref-injection rails, so the subscription OAuth token (an unscoped ~1y
# credential) never sits in a worker pod. Wired by agent-session.sh --harness claude
# (ANTHROPIC_BASE_URL=<proxy>/anthropic, ANTHROPIC_AUTH_TOKEN=ref:<ns>/<secret>).
ANTHROPIC_UPSTREAM = os.environ.get("ANTHROPIC_UPSTREAM", "https://api.anthropic.com")
# claude-code sends this beta when IT holds the oauth token; through the ANTHROPIC_AUTH_TOKEN
# gateway path it does not — the proxy restores it whenever the INJECTED token is an oauth one.
OAUTH_BETA = "oauth-2025-04-20"
# FU-088(a) reactive 429 latch: the subscription's account rate limit is invisible until a request
# dies on it (no official quota interface — anthropics/claude-code#13585), so this proxy — the one
# choke point EVERY subscription session already flows through (coordinator tick, reviewer,
# claude-tier worker, interactive rides) — latches on the first upstream 429 from the /anthropic
# leg. Launchers probe GET /anthropic-limit pre-spawn (agents/subscription-latch.sh) and defer
# while latched: a report-only line instead of a doomed pod. Self-healing both ways: the latch
# expires after Retry-After (or ANTHROPIC_429_HOLD_S), and any /anthropic 2xx that lands earlier
# (e.g. an interactive session after the window reset) clears it. In-memory by design — a proxy
# restart forgets, the next 429 re-latches.
ANTHROPIC_429_HOLD_S = int(os.environ.get("ANTHROPIC_429_HOLD_S", "900"))
# Passive headroom harvest (the upgrade path past 429-only): Anthropic answers every request
# with `anthropic-ratelimit-*` headers — the same source the Claude Code statusline's
# `rate_limits` block (5h/7d used_percentage + resets_at) is fed from. Since all subscription
# traffic rides this leg, the last-seen set + its age is served on /anthropic-limit for free —
# no extra API call, no undocumented usage endpoint. Real shape (probed live 2026-07-17):
# `anthropic-ratelimit-unified-{5h,7d}-utilization` is a 0–1 FRACTION, each window carries its
# own `-reset` epoch + `-status`; overage is org-disabled on this account, so hitting a window
# hard-stops (429) rather than spilling to paid.
# Threshold deferral: dispatch reads limited=true once EITHER window's utilization crosses
# ANTHROPIC_UTIL_THRESHOLD (fraction; 0 disables) and that window hasn't reset yet — deferring
# BEFORE the 429 leaves headroom for interactive rides instead of burning it on batch spawns.
ANTHROPIC_UTIL_THRESHOLD = float(os.environ.get("ANTHROPIC_UTIL_THRESHOLD", "0.80"))
_latch = {"until": 0.0, "last_429": 0.0, "headers": {}, "headers_at": 0.0,
          "windows": {}, "count_429": 0}
_latch_lock = threading.Lock()
_latch_saved_at = 0.0  # happy-path persistence throttle (latch TRANSITIONS always persist)


def _parse_windows(seen: dict) -> dict:
    """{'5h': {'utilization': 0.19, 'reset': 1784331600.0, 'status': 'allowed'}, '7d': …}
    from the harvested headers — absent/malformed fields drop the window (no guessing)."""
    windows = {}
    for w in ("5h", "7d"):
        try:
            windows[w] = {
                "utilization": float(seen[f"anthropic-ratelimit-unified-{w}-utilization"]),
                "reset": float(seen[f"anthropic-ratelimit-unified-{w}-reset"]),
                "status": seen.get(f"anthropic-ratelimit-unified-{w}-status", ""),
            }
        except (KeyError, ValueError):
            pass
    return windows


def _dispatch_verdict(now: float) -> tuple[bool, str | None, dict]:
    """The composite launcher answer: (limited, reason, windows). 429 latch wins; otherwise a
    window past the utilization threshold that hasn't reset yet defers dispatch. A window whose
    reset epoch has passed is dead data, never a verdict — stale headers can't wedge dispatch."""
    with _latch_lock:
        until = _latch["until"]
        windows = {k: dict(v) for k, v in _latch["windows"].items()}
    if until > now:
        return True, "429-latch", windows
    if ANTHROPIC_UTIL_THRESHOLD > 0:
        for w, data in sorted(windows.items()):
            if data["utilization"] >= ANTHROPIC_UTIL_THRESHOLD and now < data["reset"]:
                return True, f"utilization-{w}", windows
    return False, None, windows
PORT = int(os.environ.get("PORT", "8080"))
CACHE_HIT = float(os.environ.get("CACHE_HIT", "0.8"))  # h for the effective-price blend (§M3)
UPTIME_FLOOR = float(os.environ.get("UPTIME_FLOOR", "95"))
PIN_TTL_S = int(os.environ.get("PIN_TTL_S", "3600"))  # pin cache; providers/prices drift slowly
PIN_FAIL_TTL_S = int(os.environ.get("PIN_FAIL_TTL_S", "300"))  # don't hammer a failing endpoint
MAX_PRICE_FACTOR = float(os.environ.get("MAX_PRICE_FACTOR", "2.0"))  # guard vs fallback lottery
READ_TIMEOUT_S = int(os.environ.get("READ_TIMEOUT_S", "300"))  # idle timeout per upstream read
# Completion floor (0 = off). Three worker runs died to goose -32602 tool-call truncation at
# 14781/15267/16322 chars — all ≈4k tokens: a max_tokens=4096 default somewhere goose-side caps
# any file-write tool call above ~4k tokens mid-JSON (oracle-fleet#1 autopsies, TICK-LOG 2026-07-09).
# The proxy raises max_tokens to this floor (clamped to the pinned endpoint's max_completion_tokens
# when known); an explicit request value ABOVE the floor always wins.
MAX_TOKENS_FLOOR = int(os.environ.get("MAX_TOKENS_FLOOR", "16384"))
# ADR-087 / FU-018 leg A: pods hold an OPAQUE REF (`ref:<ns>/<secret>`) instead of the real
# OpenRouter key; this proxy resolves the ref via the K8s API and injects the real key upstream.
# Only Secrets carrying SESSION_KEY_LABEL are honored — the label check keeps the proxy's
# get-secret RBAC from becoming a generic secret oracle. Short cache = revocation latency.
SESSION_KEY_LABEL = "openrouter.teststuff.net/session-key"
REF_CACHE_TTL_S = int(os.environ.get("REF_CACHE_TTL_S", "60"))
_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
_refs: dict[str, tuple[float, dict | None]] = {}  # "ns/name" -> (expires_epoch, {key,guardrail}|None)
_refs_lock = threading.Lock()


def _resolve_ref(ref: str) -> dict | None:
    """`ns/name` -> {"key": OPENROUTER_API_KEY, "guardrail": ...}, or None
    (missing/unlabeled/unreadable). guardrail feeds the FU-024 only-free enforcement."""
    now = time.time()
    with _refs_lock:
        hit = _refs.get(ref)
        if hit and hit[0] > now:
            return hit[1]
    resolved = None
    try:
        ns, name = ref.split("/", 1)
        token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/secrets/{name}",
            headers={"Authorization": "Bearer " + token},
        )
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            secret = json.load(resp)
        if (secret.get("metadata", {}).get("labels") or {}).get(SESSION_KEY_LABEL) == "true":
            data = secret.get("data") or {}
            # OPENROUTER_API_KEY = the standing/session OpenRouter keys; AUTH_TOKEN = the
            # claude-tier session secrets (FU-066 — the Anthropic subscription oauth token).
            b64 = data.get("OPENROUTER_API_KEY") or data.get("AUTH_TOKEN") or ""
            if b64:
                resolved = {
                    "key": base64.b64decode(b64).decode(),
                    "guardrail": base64.b64decode(data.get("GUARDRAIL", "")).decode(),
                }
        else:
            log(f"ref: {ref} exists but lacks {SESSION_KEY_LABEL} — refusing (not a session key)")
    except Exception as e:  # noqa: BLE001 — a failed resolve degrades to passthrough (upstream 401s the ref)
        log(f"ref: resolve failed for {ref}: {e}")
    with _refs_lock:
        _refs[ref] = (now + REF_CACHE_TTL_S, resolved)
    return resolved


GIT_TOKEN_LABEL = "homelab.teststuff.net/agent-git-token"
# FU-080 loop tokens: per-STACK coordinator/reviewer git tokens (issues:write over one stack's
# repos — strictly more privilege than a worker token), minted centrally in agent-coordinator by
# the Composition (`loop-git-<stack>` / `loop-reviewer-git-<stack>`; the App private keys never
# leave that ns) and served ONLY here — no Secret ever sits in <stack>-agents, so the workbench
# SA may hold pod-create there without the airlock dying. Serving REQUIRES TokenReview: the
# caller presents its projected ServiceAccount token and must BE system:serviceaccount:
# <requested-ns>:agentstack-loop. The legacy worker /git-token path stays honor-system (repo-
# scoped contents tokens; the FU-020 CNP is its belt) but VERIFIES when a token is offered.
LOOP_GIT_LABEL = "homelab.teststuff.net/loop-git-token"
LOOP_NS_LABEL = "platform.teststuff.net/loop-ns"
# FU-089: worker tokens are minted centrally too; this label binds agent-git-<ns> to its ns.
WORKER_NS_LABEL = "platform.teststuff.net/worker-ns"
# Migration flag: "1" once the agent-runtime credential helper sends the worker SA token —
# then an unauthenticated /git-token is refused (until then it is logged loudly, not denied).
GIT_TOKEN_REQUIRE_AUTH = os.environ.get("GIT_TOKEN_REQUIRE_AUTH", "0") == "1"


def _token_review(token: str) -> str | None:
    """TokenReview the caller's SA token -> authenticated username, or None. A failed review is
    a failed AUTH (deny), never a pass-through — this is the one place rule #6 inverts: the
    conservative outcome for a credential gate is refusal."""
    try:
        sa_token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        body = json.dumps({"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
                           "spec": {"token": token}}).encode()
        req = urllib.request.Request(
            "https://kubernetes.default.svc/apis/authentication.k8s.io/v1/tokenreviews",
            data=body, method="POST",
            headers={"Authorization": "Bearer " + sa_token, "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            status = (json.load(resp).get("status") or {})
        if status.get("authenticated"):
            return (status.get("user") or {}).get("username") or None
    except Exception as e:  # noqa: BLE001
        log(f"token-review: failed: {e}")
    return None


def _resolve_loop_git(secret_name: str, for_ns: str) -> str | None:
    """Read `agent-coordinator/<secret_name>`; honor it only when it carries LOOP_GIT_LABEL and
    its LOOP_NS_LABEL equals the namespace it is being served to (belt against a mis-mint)."""
    ref = f"agent-coordinator/{secret_name}#loop"
    now = time.time()
    with _refs_lock:
        hit = _refs.get(ref)
        if hit and hit[0] > now:
            return hit[1]
    token_value = None
    try:
        sa_token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/agent-coordinator/secrets/{secret_name}",
            headers={"Authorization": "Bearer " + sa_token})
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            secret = json.load(resp)
        labels = secret.get("metadata", {}).get("labels") or {}
        if labels.get(LOOP_GIT_LABEL) == "true" and labels.get(LOOP_NS_LABEL) == for_ns:
            b64 = (secret.get("data") or {}).get("GH_TOKEN", "")
            token_value = base64.b64decode(b64).decode() if b64 else None
        else:
            log(f"loop-git: {secret_name} exists but labels refuse it for ns {for_ns}")
    except Exception as e:  # noqa: BLE001
        log(f"loop-git: resolve failed for {secret_name}: {e}")
    with _refs_lock:
        _refs[ref] = (now + REF_CACHE_TTL_S, token_value)
    return token_value


def _resolve_git_token(ns: str) -> str | None:
    """ADR-087 leg B, FU-089 central form: serve the worker token for namespace <ns> from the
    CENTRALLY minted `agent-coordinator/agent-git-<ns>` Secret (the App private key never sits
    in a stack-reachable namespace any more). Honors only Secrets carrying GIT_TOKEN_LABEL AND
    whose WORKER_NS_LABEL equals the namespace being served (belt against a mis-mint). Cached
    briefly like refs."""
    ref = f"agent-coordinator/agent-git-{ns}#git"
    now = time.time()
    with _refs_lock:
        hit = _refs.get(ref)
        if hit and hit[0] > now:
            return hit[1]
    token_value = None
    try:
        sa_token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            f"https://kubernetes.default.svc/api/v1/namespaces/agent-coordinator/secrets/agent-git-{ns}",
            headers={"Authorization": "Bearer " + sa_token},
        )
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            secret = json.load(resp)
        labels = secret.get("metadata", {}).get("labels") or {}
        if labels.get(GIT_TOKEN_LABEL) == "true" and labels.get(WORKER_NS_LABEL) == ns:
            b64 = (secret.get("data") or {}).get("token", "")
            token_value = base64.b64decode(b64).decode() if b64 else None
        else:
            log(f"git-token: agent-git-{ns} exists but labels refuse it for ns {ns}")
    except Exception as e:  # noqa: BLE001
        log(f"git-token: resolve failed for {ns}: {e}")
    with _refs_lock:
        _refs[ref] = (now + REF_CACHE_TTL_S, token_value)
    return token_value


def _inject_ref_auth(headers: dict) -> str:
    """Rewrite `Authorization: Bearer ref:<ns>/<name>` to the real key. Returns a note suffix."""
    auth = next((k for k in headers if k.lower() == "authorization"), None)
    if not auth or not headers[auth].startswith("Bearer ref:"):
        return ""
    ref = headers[auth][len("Bearer ref:"):].strip()
    resolved = _resolve_ref(ref)
    if resolved:
        headers[auth] = "Bearer " + resolved["key"]
        return "+cred"
    return "+cred-unresolved"  # forwarded as-is; upstream will 401 loudly (never fail silently)


def _guardrail_reject(self_ref: str, model: str) -> bytes | None:
    """FU-024: a `only-free` session may complete ONLY on :free model variants. Enforced here
    because the proxy already resolves the session (injection rails); direct-key sessions are
    out of scope by design — guardrailed keys are issued injected (model-scout canaries)."""
    resolved = _resolve_ref(self_ref)
    if not resolved or resolved.get("guardrail") != "only-free":
        return None
    if normalize_model(model).endswith(":free"):
        return None
    return json.dumps({
        "error": {
            "code": 403,
            "message": f"guardrail only-free: model '{model}' is not a :free variant — "
                       "this session key is restricted to free-tier models (FU-024)",
        }
    }).encode()

# Hop-by-hop (and framing) headers never forwarded either way. accept-encoding is stripped so the
# upstream answers identity — we re-frame the response as stream-until-close.
_DROP_REQ = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
    "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding",
}
_DROP_RESP = {"connection", "keep-alive", "transfer-encoding", "content-length"}

_pins: dict[str, tuple[float, dict | None]] = {}  # model -> (expires_epoch, provider block|None)
_pins_lock = threading.Lock()

# ADR-096 market pricing (operator direction 2026-07-27): the pin's price basis upgrades from a
# LIST-price blend at an assumed cache-hit to the MARKET effective price — what customers actually
# paid per provider over the rolling 30d, incl. each provider's REAL cache hit rate. Source: the
# model page's "Effective Pricing" chart data at
# GET /api/frontend/v1/stats/effective-pricing?permaslug=<dated-permaslug>
# (unofficial frontend route, found 2026-07-27; the dated permaslug rides in every /endpoints
# entry's name "Provider | vendor/model-YYYYMMDD"). Fail-soft: no market data → the list blend.
MARKET_ENABLE = os.environ.get("MARKET_ENABLE", "1") == "1"
MARKET_TTL_S = int(os.environ.get("MARKET_TTL_S", "21600"))  # 30d rolling averages drift slowly
_market: dict[str, tuple[float, dict | None]] = {}  # model -> (expires, {slug/name: row}|None)
_market_lock = threading.Lock()
_PERMASLUG_RE = re.compile(r"\|\s*([a-z0-9-]+/[A-Za-z0-9._:-]+)\s*$")


def market_for(model: str, permaslug: str | None) -> dict | None:
    """{lowercased providerSlug AND providerName: {"in": effective $/M input, "hit": cache rate}}
    from the market effective-pricing stats, or None (no permaslug / fetch failed / no traffic)."""
    if not (MARKET_ENABLE and permaslug):
        return None
    now = time.time()
    with _market_lock:
        hit = _market.get(model)
        if hit and hit[0] > now:
            return hit[1]
    rows = None
    try:
        req = urllib.request.Request(
            f"{UPSTREAM}/api/frontend/v1/stats/effective-pricing?"
            + urllib.parse.urlencode({"permaslug": permaslug}),
            headers={"User-Agent": "homelab-openrouter-proxy"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = (json.load(resp).get("data") or {})
        summaries = data.get("providerSummaries") or []
        if summaries:
            rows = {}
            for s in summaries:
                row = {"in": float(s.get("effectiveInputPrice") or 0.0),
                       "hit": float(s.get("cacheHitRate") or 0.0)}
                for key in (s.get("providerSlug"), s.get("providerName")):
                    if key:
                        rows[str(key).lower()] = row
    except Exception as e:  # noqa: BLE001 — market data is an upgrade, never a dependency
        log(f"market: effective-pricing fetch failed for {permaslug}: {e} — list-price basis")
    with _market_lock:
        _market[model] = (now + (MARKET_TTL_S if rows else 1800), rows)
    return rows


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S', time.gmtime())} {msg}", flush=True)


def _mtok(pricing: dict, key: str) -> float | None:
    """OpenRouter $/token strings → $/M floats (None = not offered)."""
    value = pricing.get(key)
    if value is None:
        return None
    try:
        return float(value) * 1e6
    except (TypeError, ValueError):
        return None


def normalize_model(model: str) -> str:
    """Bare vendor/model id; keep openrouter/<cloaked> (same rule as estimate_budget.py)."""
    stripped = model.removeprefix("openrouter/")
    return stripped if "/" in stripped else model


def compute_pin(model: str) -> dict | None:
    """The M4 session pin as an OpenRouter `provider` routing block, or None (no eligible
    provider). Raises on fetch failure (caller caches the failure briefly)."""
    url = f"{UPSTREAM}/api/v1/models/{model}/endpoints"
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-openrouter-proxy"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.load(resp)
    endpoints = []
    permaslug = None
    for e in (data.get("data") or {}).get("endpoints") or []:
        pricing = e.get("pricing") or {}
        if permaslug is None:  # "StreamLake | deepseek/deepseek-v4-flash-20260423"
            m = _PERMASLUG_RE.search(e.get("name") or "")
            permaslug = m.group(1) if m else None
        endpoints.append(
            {
                "provider": e.get("provider_name") or e.get("name"),
                # provider.order matches the endpoint tag's base slug ("deepinfra/fp4" →
                # "deepinfra"), NOT the display provider_name (measured 2026-07-09: display
                # names silently no-op under allow_fallbacks).
                "slug": (e.get("tag") or "").split("/")[0] or None,
                "prompt": _mtok(pricing, "prompt") or 0.0,
                "completion": _mtok(pricing, "completion"),
                "cache_read": _mtok(pricing, "input_cache_read"),
                "uptime": e.get("uptime_last_30m"),
                "tools": "tools" in (e.get("supported_parameters") or []),
                "max_completion": e.get("max_completion_tokens"),
            }
        )

    tooled = [e for e in endpoints if e["tools"]]
    market = market_for(model, permaslug)

    def eff(e: dict) -> float:
        # Market basis first: the provider's REAL 30d effective input price (their measured
        # cache hit baked in). List blend at the assumed CACHE_HIT only when unmeasured.
        if market:
            row = market.get((e["slug"] or "").lower()) or market.get((e["provider"] or "").lower())
            if row and row["in"] > 0:
                return row["in"]
        if e["cache_read"] is not None:
            return (1.0 - CACHE_HIT) * e["prompt"] + CACHE_HIT * e["cache_read"]
        return e["prompt"]

    def is_market(e: dict) -> bool:
        return bool(market and (market.get((e["slug"] or "").lower())
                                or market.get((e["provider"] or "").lower())))

    for pool in (
        [e for e in tooled if e["cache_read"] is not None and (e["uptime"] or 0.0) >= UPTIME_FLOOR],
        [e for e in tooled if (e["uptime"] or 0.0) >= UPTIME_FLOOR],
        tooled,
    ):
        if pool:
            best = min(pool, key=eff)
            max_price = {"prompt": round(best["prompt"] * MAX_PRICE_FACTOR, 4)}
            if best["completion"] is not None:
                max_price["completion"] = round(best["completion"] * MAX_PRICE_FACTOR, 4)
            return {
                "provider": {
                    "order": [best["slug"] or best["provider"]],
                    "allow_fallbacks": True,
                    "max_price": max_price,
                },
                "max_completion": best["max_completion"],
                "basis": "market" if is_market(best) else "list",
            }
    return None


def pin_for(model: str) -> dict | None:
    """{"provider": <routing block>, "max_completion": int|None} for the model, or None
    (free model / no eligible endpoint / fetch failure)."""
    model = normalize_model(model)
    if model.endswith(":free"):
        return None  # $0 either way — free models sidestep M4 (model-routing.md)
    now = time.time()
    with _pins_lock:
        hit = _pins.get(model)
        if hit and hit[0] > now:
            return hit[1]
    try:
        pin = compute_pin(model)
        ttl = PIN_TTL_S
    except Exception as e:  # noqa: BLE001 — any failure degrades to passthrough
        log(f"pin: endpoints fetch failed for {model}: {e} — passthrough")
        pin, ttl = None, PIN_FAIL_TTL_S
    with _pins_lock:
        _pins[model] = (now + ttl, pin)
    return pin


_GEN_ID_RE = re.compile(rb'"id"\s*:\s*"(gen-[A-Za-z0-9_-]+)"')
GEN_LOOKUP = os.environ.get("GEN_LOOKUP", "1") == "1"


def _generation_lookup(gen_id: str, auth_value: str, requested_model: str) -> None:
    """ADR-096 ground-truth cost harvest: GET /api/v1/generation?id= with the SAME key that made
    the request (probed 2026-07-27: a session key reads its own generations — total_cost is the
    billed figure, provider_name/model are what actually served, native_tokens_cached is the
    real cache hit). Runs on a daemon thread AFTER the response closed; the record needs a
    beat to exist upstream, so one delayed retry. Best-effort: a miss only leaves the ledger's
    launcher-reported figures as the fallback. The auth value is used and dropped — never
    logged, never stored."""
    for delay in (2.0, 5.0):
        time.sleep(delay)
        try:
            req = urllib.request.Request(
                f"{UPSTREAM}/api/v1/generation?id={gen_id}",
                headers={"Authorization": auth_value,
                         "User-Agent": "homelab-openrouter-proxy"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = (json.load(resp).get("data") or {})
            if data:
                router.record_generation(gen_id, requested_model, data)
                log(f"generation {gen_id}: ${data.get('total_cost') or 0:.6f} "
                    f"via {data.get('provider_name') or '?'} "
                    f"cached={data.get('native_tokens_cached') or 0}/"
                    f"{data.get('native_tokens_prompt') or 0}")
                return
        except urllib.error.HTTPError as e:
            if e.code != 404:  # 404 = not indexed yet — retry once; anything else, give up quietly
                log(f"generation {gen_id}: lookup {e.code} — skipped")
                return
        except OSError as e:
            log(f"generation {gen_id}: lookup failed: {e} — skipped")
            return
    log(f"generation {gen_id}: never appeared — skipped")


# ADR-096 rotation feed: OpenRouter's DOCUMENTED MCP server (docs/guides/overview/mcp-server)
# accepts a STANDARD API key (probed 2026-07-27 — no OAuth dance, no session id) and its
# `list-daily-model-rankings` tool returns daily model popularity by token volume with dated
# permaslugs. That IS the FU-095 "maintained rotation" the REST surface lacks (P0 probe: no
# rankings API; `order=top-weekly` ignored). A daemon loop pulls it dailyish with the router's
# own account key (ROUTER_ACCOUNT_REF → the labeled router-account-key Secret) and upserts the
# top of the list into the rotation store (source openrouter-daily-rankings). Chain policy is
# untouched: rotation entries are candidate DATA; graduation stays human (scout canary probes
# entrants per FU-095).
MCP_UPSTREAM = os.environ.get("MCP_UPSTREAM", "https://mcp.openrouter.ai/mcp")
RANKINGS_POLL_S = int(os.environ.get("RANKINGS_POLL_S", "86400"))
RANKINGS_TOP_N = int(os.environ.get("RANKINGS_TOP_N", "30"))
ROUTER_ACCOUNT_REF = os.environ.get("ROUTER_ACCOUNT_REF", "")
_RANK_DATE_RE = re.compile(r"-\d{8}$")


def _mcp_call(key: str, tool: str, arguments: dict) -> dict:
    """One MCP tools/call as plain JSON-RPC over HTTP (initialize handshake included — the server
    is stateless enough to take both in sequence without a session header)."""
    headers = {"Content-Type": "application/json",
               "Accept": "application/json, text/event-stream",
               "Authorization": "Bearer " + key}
    init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": "2025-03-26", "capabilities": {},
                                  "clientInfo": {"name": "homelab-router", "version": "1"}}}).encode()
    urllib.request.urlopen(
        urllib.request.Request(MCP_UPSTREAM, data=init, headers=headers), timeout=20).close()
    call = json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                       "params": {"name": tool, "arguments": arguments}}).encode()
    with urllib.request.urlopen(
            urllib.request.Request(MCP_UPSTREAM, data=call, headers=headers), timeout=30) as resp:
        reply = json.load(resp)
    text = ((reply.get("result") or {}).get("content") or [{}])[0].get("text") or "{}"
    return json.loads(text)


def _rankings_tick() -> int:
    """Pull the latest daily rankings into the rotation store. Returns entries written."""
    resolved = _resolve_ref(ROUTER_ACCOUNT_REF) if ROUTER_ACCOUNT_REF else None
    if not resolved:
        return 0  # off-cluster / key not minted yet — quiet no-op, the loop retries
    data = _mcp_call(resolved["key"], "list-daily-model-rankings", {}).get("data") or []
    latest = max((str(r.get("date") or "") for r in data), default="")
    day = [r for r in data if str(r.get("date") or "") == latest and r.get("model_permaslug")]
    day.sort(key=lambda r: -int(r.get("total_tokens") or 0))
    entries = [{"model": _RANK_DATE_RE.sub("", str(r["model_permaslug"])), "rank": i + 1}
               for i, r in enumerate(day[:RANKINGS_TOP_N])]
    n = router.record_rotation("openrouter-daily-rankings", entries)
    log(f"rankings: {latest} → {n} rotation entries (top {RANKINGS_TOP_N} by tokens)")
    return n


def _rankings_loop() -> None:
    time.sleep(60)  # let the pod settle (readiness, ref RBAC) before the first pull
    while True:
        try:
            _rankings_tick()
        except Exception as e:  # noqa: BLE001 — the feed is an upgrade, never a crash source
            log(f"rankings: pull failed: {e} — next tick in {RANKINGS_POLL_S}s")
        time.sleep(RANKINGS_POLL_S)


def _anthropic_latch_update(status: int, resp_headers) -> str:
    """FU-088(a): fold one /anthropic upstream status into the 429 latch. Returns a note suffix."""
    now = time.time()
    seen = {k.lower(): v for k, v in resp_headers.items()
            if k.lower().startswith("anthropic-ratelimit")}
    if seen:
        with _latch_lock:
            _latch["headers"], _latch["headers_at"] = seen, now
            _latch["windows"] = _parse_windows(seen)
        unified = seen.get("anthropic-ratelimit-unified-status", "")
        if unified and unified != "allowed":
            log(f"anthropic ratelimit headers: {json.dumps(seen)}")
    if status == 429:
        try:  # Retry-After may be absent or an HTTP-date — both fall back to the fixed hold
            hold = float(resp_headers.get("retry-after") or 0) or ANTHROPIC_429_HOLD_S
        except (TypeError, ValueError):
            hold = ANTHROPIC_429_HOLD_S
        with _latch_lock:
            _latch["until"] = now + hold
            _latch["last_429"] = now
            _latch["count_429"] += 1
            router.latch_save(_latch)  # ADR-096: an active hold survives a proxy roll
        log(f"anthropic 429 — subscription LATCHED for {hold:.0f}s (launchers defer via /anthropic-limit)")
        return "+429-latched"
    if 200 <= status < 300:
        global _latch_saved_at
        with _latch_lock:
            if _latch["until"] > now:
                _latch["until"] = 0.0
                _latch_saved_at = now
                router.latch_save(_latch)
                log("anthropic 2xx while latched — latch cleared early")
                return "+latch-cleared"
            # Keep the persisted windows fresh without one sqlite write per streamed request.
            if now - _latch_saved_at > 30:
                _latch_saved_at = now
                router.latch_save(_latch)
    return ""


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "openrouter-proxy"

    def log_message(self, fmt, *args):  # default logger writes to stderr with client noise
        pass

    def _forward(self, body: bytes | None, note: str,
                 or_model: str | None = None, or_provider: str | None = None) -> None:
        started = time.time()
        anthropic = self.path.startswith("/anthropic/")
        if anthropic:  # FU-066: the claude-tier leg — strip the prefix, swap the upstream
            url = ANTHROPIC_UPSTREAM + self.path[len("/anthropic"):]
            note += "+anthropic"
        else:
            url = UPSTREAM + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() not in _DROP_REQ}
        note += _inject_ref_auth(headers)  # ADR-087: opaque-ref -> real key, every method/path
        if anthropic:
            # Subscription oauth tokens need the oauth beta; the ANTHROPIC_AUTH_TOKEN gateway
            # path in claude-code doesn't send it (only the CLAUDE_CODE_OAUTH_TOKEN path does).
            auth_k = next((k for k in headers if k.lower() == "authorization"), None)
            if auth_k and headers[auth_k].startswith("Bearer sk-ant-oat"):
                beta_k = next((k for k in headers if k.lower() == "anthropic-beta"), None)
                if beta_k is None:
                    headers["anthropic-beta"] = OAUTH_BETA
                elif OAUTH_BETA not in headers[beta_k]:
                    headers[beta_k] = headers[beta_k] + "," + OAUTH_BETA
                note += "+oauth-beta"
        req = urllib.request.Request(url, data=body, headers=headers, method=self.command)
        try:
            resp = urllib.request.urlopen(req, timeout=READ_TIMEOUT_S)
        except urllib.error.HTTPError as e:
            resp = e  # an HTTPError IS the response — forward its status/body verbatim
        except OSError as e:
            log(f"{self.command} {self.path} → 502 upstream unreachable: {e}")
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(f"openrouter-proxy: upstream unreachable: {e}".encode())
            self.close_connection = True
            return

        status = resp.getcode()
        if anthropic:
            note += _anthropic_latch_update(status, resp.headers)
        elif or_model:
            # ADR-096: passive provider health — every forwarded completion is an observation
            # (the router's health store costs zero extra polling by living in the data plane).
            router.record_provider_event(or_model, or_provider or "", status)
        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() not in _DROP_RESP:
                self.send_header(k, v)
        # Stream-until-close framing: correct for both SSE (stream:true) and plain JSON, and it
        # sidesteps re-computing Content-Length for a rewritten request's response.
        self.send_header("Connection", "close")
        self.send_header("X-Openrouter-Proxy", note)
        self.end_headers()
        sent = 0
        head = b""  # first bytes of the response — the generation id lives here (JSON and SSE both)
        try:
            while chunk := resp.read(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
                if or_model and len(head) < 16384:
                    head += chunk
                sent += len(chunk)
        except OSError as e:
            log(f"{self.command} {self.path} → client/upstream dropped mid-stream: {e}")
        finally:
            resp.close()
        if GEN_LOOKUP and or_model and 200 <= status < 300:
            # ADR-096 cost harvest: fire the /generation lookup for this completion. A client
            # that dropped mid-stream still spent money — harvest regardless of how we exited.
            m = _GEN_ID_RE.search(head)
            auth_value = next((v for k, v in headers.items() if k.lower() == "authorization"), "")
            if m and auth_value and not auth_value.startswith("Bearer ref:"):
                threading.Thread(
                    target=_generation_lookup,
                    args=(m.group(1).decode(), auth_value, or_model),
                    daemon=True,
                ).start()
        self.close_connection = True
        log(f"{self.command} {self.path} → {status} [{note}] {sent}B {time.time() - started:.1f}s")

    def do_GET(self) -> None:
        if self.path == "/anthropic-limit":
            # FU-088(a): the launcher-side probe (agents/subscription-latch.sh). limited=true →
            # every subscription launcher defers its spawn until the latch expires/clears.
            now = time.time()
            limited, reason, windows = _dispatch_verdict(now)
            with _latch_lock:
                until, last = _latch["until"], _latch["last_429"]
                seen, seen_at = dict(_latch["headers"]), _latch["headers_at"]
            payload = json.dumps({
                "limited": limited,
                "reason": reason,
                "threshold": ANTHROPIC_UTIL_THRESHOLD,
                "windows": windows,
                "until_epoch": round(until),
                "remaining_s": max(0, round(until - now)),
                "last_429_epoch": round(last),
                "ratelimit_headers": seen,
                "headers_age_s": round(now - seen_at) if seen_at else None,
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/metrics":
            # FU-088 observability: subscription headroom → Prometheus (ServiceMonitor in this
            # app). Window gauges only exist once a subscription request has flowed — absent
            # series ≠ zero utilization, dashboards should show "no data yet" honestly.
            now = time.time()
            limited, reason, windows = _dispatch_verdict(now)
            with _latch_lock:
                until, count_429 = _latch["until"], _latch["count_429"]
                seen_at = _latch["headers_at"]
            lines = [
                "# TYPE anthropic_subscription_utilization gauge",
                "# HELP anthropic_subscription_utilization Last-seen unified rate-limit utilization (0-1 fraction) per window.",
            ]
            for w, data in sorted(windows.items()):
                lines.append(f'anthropic_subscription_utilization{{window="{w}"}} {data["utilization"]}')
            lines += [
                "# TYPE anthropic_subscription_reset_timestamp_seconds gauge",
            ]
            for w, data in sorted(windows.items()):
                lines.append(f'anthropic_subscription_reset_timestamp_seconds{{window="{w}"}} {data["reset"]:.0f}')
            lines += [
                "# TYPE anthropic_subscription_headers_age_seconds gauge",
                f"anthropic_subscription_headers_age_seconds {now - seen_at:.0f}" if seen_at
                else "anthropic_subscription_headers_age_seconds NaN",
                "# TYPE anthropic_subscription_utilization_threshold gauge",
                f"anthropic_subscription_utilization_threshold {ANTHROPIC_UTIL_THRESHOLD}",
                "# TYPE anthropic_subscription_latched gauge",
                "# HELP anthropic_subscription_latched 1 while the reactive 429 latch holds.",
                f"anthropic_subscription_latched {1 if until > now else 0}",
                "# TYPE anthropic_subscription_dispatch_limited gauge",
                "# HELP anthropic_subscription_dispatch_limited The composite /anthropic-limit verdict launchers defer on (429 latch OR utilization threshold).",
                f"anthropic_subscription_dispatch_limited {1 if limited else 0}",
                "# TYPE anthropic_subscription_429_total counter",
                f"anthropic_subscription_429_total {count_429}",
            ]
            lines += router.metrics_lines()  # ADR-096: the router_* series
            payload = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/router-status":
            # ADR-096: the human/debug view of the router store (strikes, provider errors,
            # rotation age, tier config). Read-only; port-forward from the jail to reach it.
            now = time.time()
            limited, reason, windows = _dispatch_verdict(now)
            summary = router.status_summary()
            summary["subscription"] = {"limited": limited, "reason": reason, "windows": windows}
            payload = json.dumps(summary, indent=1).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/healthz":
            payload = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/loop-git-token"):
            # FU-080: per-stack LOOP token (issues:write over the stack's repos). TokenReview is
            # MANDATORY — the caller must be the requested namespace's agentstack-loop SA.
            from urllib.parse import parse_qs, urlparse
            q = parse_qs(urlparse(self.path).query)
            ns = (q.get("ns") or [""])[0]
            role = (q.get("role") or ["coordinator"])[0]
            auth = self.headers.get("Authorization") or ""
            caller = _token_review(auth[len("Bearer "):]) if auth.startswith("Bearer ") else None
            expected = f"system:serviceaccount:{ns}:agentstack-loop"
            token_value = None
            if ns.endswith("-agents") and caller == expected and role in ("coordinator", "reviewer"):
                stack = ns[: -len("-agents")]
                name = f"loop-git-{stack}" if role == "coordinator" else f"loop-reviewer-git-{stack}"
                token_value = _resolve_loop_git(name, ns)
            elif caller != expected:
                log(f"GET /loop-git-token ns={ns} → 403 (caller={caller or 'unauthenticated'})")
                payload = b"forbidden"
                self.send_response(403)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            if token_value:
                payload = token_value.encode()
                self.send_response(200)
                log(f"GET /loop-git-token ns={ns} role={role} → served (TokenReview ok)")
            else:
                payload = b"unresolvable"
                self.send_response(404)
                log(f"GET /loop-git-token ns={ns} role={role} → 404")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path.startswith("/git-token"):
            # ADR-087 leg B, FU-089 — GET /git-token?ns=<worker-namespace> → the live App token
            # (repo-scoped, minted centrally in agent-coordinator), plaintext body. In-cluster
            # only; FU-020's NetworkPolicy narrows callers to worker pods. A caller offering its
            # SA token (Authorization: Bearer) is VERIFIED to be the requested namespace's
            # agentstack-worker SA (any other identity is refused). Until the agent-runtime
            # credential helper ships the token, unauthenticated calls are served-but-logged;
            # GIT_TOKEN_REQUIRE_AUTH=1 flips them to 403 (the FU-089 finale).
            from urllib.parse import parse_qs, urlparse
            ns = (parse_qs(urlparse(self.path).query).get("ns") or [""])[0]
            auth = self.headers.get("Authorization") or ""
            if auth.startswith("Bearer "):
                caller = _token_review(auth[len("Bearer "):])
                expected = f"system:serviceaccount:{ns}:agentstack-worker"
                if caller != expected and not (caller or "").startswith(f"system:serviceaccount:{ns}:"):
                    log(f"GET /git-token ns={ns} → 403 (offered token from {caller or 'nobody'})")
                    payload = b"forbidden"
                    self.send_response(403)
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
            elif GIT_TOKEN_REQUIRE_AUTH:
                log(f"GET /git-token ns={ns} → 403 (no SA token; GIT_TOKEN_REQUIRE_AUTH)")
                payload = b"forbidden"
                self.send_response(403)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
            else:
                log(f"GET /git-token ns={ns} → UNAUTHENTICATED caller (allowed until "
                    f"GIT_TOKEN_REQUIRE_AUTH=1 — FU-089 migration)")
            token_value = _resolve_git_token(ns) if ns else None
            if token_value:
                payload = token_value.encode()
                self.send_response(200)
                log(f"GET /git-token ns={ns} → served")
            else:
                payload = b"unresolvable"
                self.send_response(404)
                log(f"GET /git-token ns={ns} → 404")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self._forward(None, "passthrough")

    def _reply_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if self.path == "/report":
            # ADR-096: post-run attribution from the launcher finalizer (M5). The AGENT_STRIKE
            # GitHub comment remains the human/audit twin — this is the queryable one. In-cluster
            # callers only (the FU-020 CNP bounds reach); idempotent per session, so best-effort
            # retries are safe.
            try:
                report = json.loads(body)
                assert isinstance(report, dict) and report.get("session")
            except (ValueError, AssertionError):
                self._reply_json(400, {"error": "body must be JSON with a session field"})
                return
            stored, striked = router.record_report(report)
            log(f"POST /report session={report.get('session')} "
                f"error_class={report.get('error_class') or 'clean'} → "
                f"stored={stored} strike={striked}")
            self._reply_json(200 if stored else 503, {"stored": stored, "strike": striked})
            return
        if self.path == "/rotation":
            # ADR-096 rotation/canary ingest. TokenReview MANDATORY (loop-git pattern): the
            # caller must be an agent-coordinator SA (the scout CronWorkflow) — rotation data
            # steers future model choice, so it is a credential-gated write.
            auth = self.headers.get("Authorization") or ""
            caller = _token_review(auth[len("Bearer "):]) if auth.startswith("Bearer ") else None
            if not (caller or "").startswith("system:serviceaccount:agent-coordinator:"):
                log(f"POST /rotation → 403 (caller={caller or 'unauthenticated'})")
                self._reply_json(403, {"error": "rotation ingest requires an agent-coordinator SA token"})
                return
            try:
                payload = json.loads(body)
                source = str(payload["source"])
                entries = payload.get("entries") or []
            except (ValueError, KeyError, TypeError):
                self._reply_json(400, {"error": "body must be JSON {source, entries[]}"})
                return
            n = router.record_rotation(source, entries)
            log(f"POST /rotation source={source} → {n} entries (caller={caller})")
            self._reply_json(200, {"stored": n})
            return
        note = "passthrough"
        or_model = None
        or_provider = None
        if self.path.rstrip("/").endswith("/chat/completions") and body:
            try:
                payload = json.loads(body)
                if isinstance(payload, dict) and payload.get("model"):
                    # FU-024 only-free enforcement (before any forwarding spend)
                    auth_hdr = self.headers.get("Authorization", "")
                    if auth_hdr.startswith("Bearer ref:"):
                        reject = _guardrail_reject(
                            auth_hdr[len("Bearer ref:"):].strip(), str(payload["model"]))
                        if reject:
                            log(f"POST {self.path} → 403 [guardrail only-free] model={payload['model']}")
                            self.send_response(403)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(reject)))
                            self.send_header("Connection", "close")
                            self.end_headers()
                            self.wfile.write(reject)
                            self.close_connection = True
                            return
                    notes = []
                    or_model = normalize_model(str(payload["model"]))
                    pin = pin_for(str(payload["model"]))
                    # An explicit `provider` (a harness/opencode.json that CAN carry prefs, or a
                    # hand-crafted request) always wins — never overwrite policy already in the body.
                    if isinstance(payload.get("provider"), dict):
                        or_provider = (payload["provider"].get("order") or [None])[0]
                    if pin and "provider" not in payload:
                        payload["provider"] = pin["provider"]
                        or_provider = pin["provider"]["order"][0]
                        notes.append(f"injected:{pin['provider']['order'][0]}"
                                     + (":mkt" if pin.get("basis") == "market" else ""))
                    # max_tokens floor (goose -32602 truncation class): raise a missing/low
                    # max_tokens to MAX_TOKENS_FLOOR, clamped to the pinned endpoint's
                    # max_completion_tokens when known. An explicit value ABOVE the floor wins.
                    floor = MAX_TOKENS_FLOOR
                    if pin and isinstance(pin.get("max_completion"), int):
                        floor = min(floor, pin["max_completion"])
                    current = payload.get("max_tokens")
                    if floor > 0 and (not isinstance(current, int) or current < floor):
                        payload["max_tokens"] = floor
                        notes.append(f"max_tokens:{floor}")
                    if notes:
                        body = json.dumps(payload).encode()
                        note = "+".join(notes)
            except ValueError:
                pass  # not JSON — forward untouched
        self._forward(body, note, or_model=or_model, or_provider=or_provider)


def main() -> int:
    # ADR-096: open the router store (PVC-backed; :memory: degrade keeps the data plane alive)
    # and restore a persisted 429 latch/windows so a pod roll can't forget an active hold.
    router.init(os.environ.get("ROUTER_DB") or None,
                os.path.join(os.path.dirname(os.path.abspath(__file__)), "model-classes.json"))
    saved = router.latch_load()
    if saved:
        with _latch_lock:
            for k in ("until", "last_429", "windows", "count_429", "headers_at"):
                if saved.get(k) is not None:
                    _latch[k] = saved[k]
        if float(saved.get("until") or 0) > time.time():
            log(f"restored ACTIVE 429 latch from store (until={saved['until']:.0f})")
    if ROUTER_ACCOUNT_REF and RANKINGS_POLL_S > 0:
        threading.Thread(target=_rankings_loop, daemon=True).start()
    log(f"openrouter-proxy: listening :{PORT} → {UPSTREAM} "
        f"(h={CACHE_HIT}, uptime≥{UPTIME_FLOOR}, max_price×{MAX_PRICE_FACTOR}, "
        f"max_tokens_floor={MAX_TOKENS_FLOOR}, market={'on' if MARKET_ENABLE else 'off'}, "
        f"rankings={'on' if ROUTER_ACCOUNT_REF and RANKINGS_POLL_S > 0 else 'off'})")
    ThreadingHTTPServer(("", PORT), Proxy).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
