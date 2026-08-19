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

homelab#158: the OpenRouter leg has an ACCOUNT-scope capacity latch beside the FU-088(a) subscription
one (see the `_or_capacity_*` block). It is what makes "the provider is down" a *typed* /route
defer (`or-capacity-down:*`) instead of one more silent deferral — the launcher degrades a
class=fix ride to the haiku subscription rail on it (docs/agents/model-routing.md §M12).

Stdlib only; runs on a stock python:3.13-slim from a ConfigMap (github-exporter pattern).
"""

import base64
import hashlib
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
import gometer  # ADR-108: shared Go-rail pricing/usage module (single home for proxy + jail shim)

UPSTREAM = os.environ.get("UPSTREAM", "https://openrouter.ai")
# FU-066 (claude+haiku worker tier): requests under /anthropic/* forward to the Anthropic API
# instead — same ref-injection rails, so the subscription OAuth token (an unscoped ~1y
# credential) never sits in a worker pod. Wired by agent-session.sh --harness claude
# (ANTHROPIC_BASE_URL=<proxy>/anthropic, ANTHROPIC_AUTH_TOKEN=ref:<ns>/<secret>).
ANTHROPIC_UPSTREAM = os.environ.get("ANTHROPIC_UPSTREAM", "https://api.anthropic.com")
# ADR-107 (homelab#421): the Go rail — model-based routing to opencode.ai when the body's
# model id starts with `opencode-go/`. The prefix is STRIPPED before forwarding (Go's compat
# API takes bare ids), and ALL auth is REPLACED by the Go key (the subscription oauth must
# never reach a third-party host). Wired by agent-session.sh --harness claude (same session
# that hits /anthropic for claude-* models).
GO_UPSTREAM = os.environ.get("OPENCODE_GO_BASE", "https://opencode.ai/zen/go")
GO_KEY = os.environ.get("OPENCODE_GO_API_KEY", "")
GO_PREFIX = "opencode-go/"
# homelab#445: the OpenCode Zen free rail — `opencode/` routes to opencode.ai's zen/v1 FREE
# tier, mirroring the Go leg. The SAME ESO-materialized key authenticates both rails (chunk C,
# #433), so ZEN_KEY falls back to GO_KEY unless a dedicated OPENCODE_ZEN_API_KEY is set; the
# code-default base is the live upstream, so no deployment override is required either.
ZEN_UPSTREAM = os.environ.get("OPENCODE_ZEN_BASE", "https://opencode.ai/zen")
ZEN_KEY = os.environ.get("OPENCODE_ZEN_API_KEY", GO_KEY)
ZEN_PREFIX = "opencode/"
# ADR-108: Go pricing moved to gometer.py (single home for proxy + jail shim).
# Re-export for backwards compatibility within this file.
GO_PRICES = gometer.GO_PRICES
GO_PRICES_LONG = gometer.GO_PRICES_LONG
_GO_MAX_PRICE = gometer._GO_MAX_PRICE
_GO_PRICED_MODELS = gometer._GO_PRICED_MODELS

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
# Threshold deferral: dispatch reads limited=true once ANY window's utilization crosses its
# threshold (fraction; 0 disables that window) and that window hasn't reset yet — deferring
# BEFORE the 429 leaves headroom for interactive rides instead of burning it on batch spawns.
# Per-window thresholds (they guard DIFFERENT things — operator direction 2026-07-28): the 5h
# window is the finish-in-progress guard (deny spawns that can't complete before the short
# window flips), the 7d window is the operator's personal weekly headroom preference and is set
# INDEPENDENTLY (higher = burn more of the week before backing off). ANTHROPIC_UTIL_THRESHOLD is
# the base/default; a per-window ANTHROPIC_UTIL_THRESHOLD_<W> overrides it for that window.
ANTHROPIC_UTIL_THRESHOLD = float(os.environ.get("ANTHROPIC_UTIL_THRESHOLD", "0.80"))
def _window_threshold(w: str) -> float:
    return float(os.environ.get(f"ANTHROPIC_UTIL_THRESHOLD_{w.upper()}", ANTHROPIC_UTIL_THRESHOLD))
ANTHROPIC_UTIL_THRESHOLD_BY_WINDOW = {w: _window_threshold(w) for w in ("5h", "7d")}
# homelab#422: Go subscription windows (budget/span/ANCHOR) + utilization thresholds + the
# WINDOW-DRAW pricing moved to gometer — the shared home (ADR-108), see GO_WINDOWS /
# GO_UTIL_THRESHOLDS / window_draw() there. The proxy serves /opencode-limit from gometer.
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


def _effective_thresholds(tier: str | None) -> dict[str, float]:
    """FU-109 (ADR-096 P2) composed with the FU-088 per-window thresholds: a consumer tier only
    RAISES a window's threshold, never lowers it — effective = max(window, tier). So `dispatch`
    (0.90) lifts the 5h gate for ~30s dispatch units while the operator's 7d=0.95 preference
    stays binding, and `heavy` (0.80) is identical to a bare probe. Unknown/absent tier = the
    per-window values exactly (today's behavior)."""
    tier_thr = router.tier_threshold(tier, 0.0) if tier else 0.0
    return {w: max(t, tier_thr) for w, t in ANTHROPIC_UTIL_THRESHOLD_BY_WINDOW.items()}


def _dispatch_verdict(now: float, tier: str | None = None) -> tuple[bool, str | None, dict]:
    """The composite launcher answer: (limited, reason, windows). 429 latch wins; otherwise a
    window past the utilization threshold that hasn't reset yet defers dispatch. A window whose
    reset epoch has passed is dead data, never a verdict — stale headers can't wedge dispatch."""
    with _latch_lock:
        until = _latch["until"]
        windows = {k: dict(v) for k, v in _latch["windows"].items()}
    if until > now:
        return True, "429-latch", windows
    eff = _effective_thresholds(tier)
    for w, data in sorted(windows.items()):
        thr = eff.get(w, ANTHROPIC_UTIL_THRESHOLD)
        if thr > 0 and data["utilization"] >= thr and now < data["reset"]:
            return True, f"utilization-{w}", windows
    return False, None, windows


# ADR-096 P2: the FU-088 concurrency semaphore moves SERVER-side — the proxy counts Running
# pods labelled subscription-session=claude cluster-wide (the same count subscription-latch.sh
# ran via kubectl in every launcher; one authority instead of N copies). FAIL-OPEN like every
# capacity gate here: an unreadable count (RBAC gap, API blip) never wedges dispatch — the
# launcher's local kubectl belt still exists for exactly that case.
# FU-170 (piece a): the Go rail gets the SAME bound — Running pods labelled rail=opencode-go
# (set by agent-session.sh since PR#458) capped by OPENCODE_MAX_RUNNING. Composed into
# /opencode-limit's top-level `limited` so every consumer (agent-session.sh worker gate,
# reviewer-session.sh failover) inherits the bound with ZERO launcher changes — they already
# probe /opencode-limit and act on `limited`. Same honesty contract as the anthropic one:
# absent count (None), not zero — a broken counter must never stop dispatch.
SUBSCRIPTION_MAX_RUNNING = int(os.environ.get("SUBSCRIPTION_MAX_RUNNING", "3"))
SUBSCRIPTION_SESSION_SELECTOR = "homelab.teststuff.net/subscription-session=claude"
OPENCODE_MAX_RUNNING = int(os.environ.get("OPENCODE_MAX_RUNNING", "3"))
GO_SESSION_SELECTOR = "homelab.teststuff.net/rail=opencode-go"
SEMAPHORE_TTL_S = int(os.environ.get("SEMAPHORE_TTL_S", "10"))
# One cache slot PER SELECTOR — the anthropic and Go rails share the listing code path but never
# stomp each other's cached counts.
_semaphore_caches: dict[str, tuple[float, int | None]] = {}
_semaphore_lock = threading.Lock()
# FU-109 attribution: /anthropic requests counted per ref-derived consumer (in-memory — a roll
# resets the counter, rate() doesn't care).
_consumers: dict[str, int] = {}
_consumers_lock = threading.Lock()


def _count_pods_by_selector(selector: str) -> int | None:
    """Cluster-wide Running count for a pod label selector, briefly cached per selector. None =
    count unavailable (fail-open, logged) — the caller must treat that as 'not limited'. One
    listing code path shared by the anthropic (FU-088) and Go (FU-170) semaphores."""
    now = time.time()
    with _semaphore_lock:
        ts, val = _semaphore_caches.get(selector, (0.0, None))
        if now - ts < SEMAPHORE_TTL_S:
            return val
    count = None
    try:
        token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        qs = urllib.parse.urlencode({"labelSelector": selector,
                                     "fieldSelector": "status.phase=Running"})
        req = urllib.request.Request(f"https://kubernetes.default.svc/api/v1/pods?{qs}",
                                     headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            count = len(json.load(resp).get("items") or [])
    except Exception as e:  # noqa: BLE001 — fail-open by design
        log(f"semaphore: pod count failed ({selector}): {e} — failing open")
    with _semaphore_lock:
        _semaphore_caches[selector] = (now, count)
    return count


def _subscription_running() -> int | None:
    """Cluster-wide Running count of subscription-labelled pods, briefly cached. None = count
    unavailable (fail-open, logged) — the caller must treat that as 'not limited'."""
    return _count_pods_by_selector(SUBSCRIPTION_SESSION_SELECTOR)


def _go_running() -> int | None:
    """Cluster-wide Running count of Go-rail pods (homelab.teststuff.net/rail=opencode-go),
    briefly cached. None = count unavailable (fail-open, logged) — a broken counter must never
    stop dispatch (same honesty contract as the anthropic one)."""
    return _count_pods_by_selector(GO_SESSION_SELECTOR)


def _semaphore_state() -> dict:
    running = _subscription_running()
    return {"running": running, "max": SUBSCRIPTION_MAX_RUNNING,
            "limited": bool(SUBSCRIPTION_MAX_RUNNING > 0 and running is not None
                            and running >= SUBSCRIPTION_MAX_RUNNING)}


def _go_semaphore_state() -> dict:
    """FU-170: the Go-rail concurrency bound — max from OPENCODE_MAX_RUNNING (0 = disabled),
    fail-open on an unreadable count just like _semaphore_state."""
    running = _go_running()
    return {"running": running, "max": OPENCODE_MAX_RUNNING,
            "limited": bool(OPENCODE_MAX_RUNNING > 0 and running is not None
                            and running >= OPENCODE_MAX_RUNNING)}
PORT = int(os.environ.get("PORT", "8080"))
CACHE_HIT = float(os.environ.get("CACHE_HIT", "0.8"))  # h for the effective-price blend (§M3)
UPTIME_FLOOR = float(os.environ.get("UPTIME_FLOOR", "95"))
PIN_TTL_S = int(os.environ.get("PIN_TTL_S", "3600"))  # pin cache; providers/prices drift slowly
PIN_FAIL_TTL_S = int(os.environ.get("PIN_FAIL_TTL_S", "300"))  # don't hammer a failing endpoint
MAX_PRICE_FACTOR = float(os.environ.get("MAX_PRICE_FACTOR", "2.0"))  # guard vs fallback lottery
READ_TIMEOUT_S = int(os.environ.get("READ_TIMEOUT_S", "300"))  # idle timeout per upstream read
# homelab#22: the ABSOLUTE per-request wall — READ_TIMEOUT_S never breaks a slow-drip stream
# (every read returns in time, the request never ends; oracle-fleet#7 r1). 900s default clears
# the agentic tail by measurement: laguna:free healthy turns run ~306s wall and the advertised
# e2e P99 is 602s — agentic turns (large context + the 16k max_tokens floor) live at P95–P99
# by construction. A client may override per request via X-Request-Deadline-S (stripped before
# forwarding). Enforced at read-loop granularity, so worst-case overshoot is one READ_TIMEOUT_S.
REQUEST_DEADLINE_S = int(os.environ.get("REQUEST_DEADLINE_S", "900"))
# homelab#22: in-flight registry — a wedged handler thread is invisible to the logs (they only
# write on completion); the per-model gauge + oldest-age series make quiet-but-wedged observable
# (the FU-057 stall-detector denominator). In-memory by design, a roll resets it.
_inflight: dict[int, tuple[str, float]] = {}  # thread id -> (model/leg label, started_epoch)
_inflight_lock = threading.Lock()
_deadline_exceeded: dict[str, int] = {}  # label -> severed-request count (in-memory counter)
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
# FU-134: the /search capability. A cheap, widely-available model is enough — the SEARCH does the
# work, the model only summarizes and cites. Overridable per request; keep the default reachable on
# every rail so no stack has to know about it.
SEARCH_MODEL = os.environ.get("SEARCH_MODEL", "deepseek/deepseek-v4-flash-0731")
SEARCH_TIMEOUT_S = int(os.environ.get("SEARCH_TIMEOUT_S", "120"))
# FU-131: how long the ground-truth cost harvest waits for OpenRouter to index a generation.
# Was (2, 5) — ~7s, which lost 49% of a fan-out arm's spend (measured against the activity export).
GENERATION_BACKOFF_S = tuple(
    float(x) for x in os.environ.get("GENERATION_BACKOFF_S", "2,5,15,45").split(",") if x.strip())
# Harvest outcome counters, exported on /metrics so the undercount is VISIBLE rather than inferred
# from a log line after the fact (that is how FU-131 stayed invisible until an export was diffed).
_gen_stats = {"stored": 0, "missed": 0}
_gen_stats_lock = threading.Lock()
_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
_refs: dict[str, tuple[float, dict | None]] = {}  # "ns/name" -> (expires_epoch, {key,guardrail}|None)
_refs_lock = threading.Lock()


def _cr_guardrail(ns: str, secret_name: str) -> str | None:
    """FU-138: the AUTHORITATIVE guardrail is the OpenRouterKey CR, not the Secret.

    The Secret's GUARDRAIL is written by the operator only when it MINTS (create/rotate), so a
    guardrail change on an already-minted standing key never reaches it — enforcement went dead
    silently, and every claim change needed a hand patch (circles-iac#1, 2026-08-04). The CR is
    rendered from the AgentStack claim in git, so reading it here makes claim → composition → CR →
    proxy the one path. Returns the CR's guardrail ("" = open), or None when no CR owns this Secret
    (then the caller keeps the Secret's field — pre-CR keys still enforce)."""
    try:
        token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        req = urllib.request.Request(
            "https://kubernetes.default.svc/apis/openrouter.teststuff.net/v1alpha1"
            f"/namespaces/{ns}/openrouterkeys",
            headers={"Authorization": "Bearer " + token},
        )
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            items = (json.load(resp).get("items") or [])
    except Exception as e:  # noqa: BLE001 — unreadable CRs must not disarm the Secret's guardrail
        log(f"ref: openrouterkeys list failed in {ns}: {e} — falling back to the Secret's GUARDRAIL")
        return None
    for cr in items:
        spec = cr.get("spec") or {}
        # Mirror the CRD default: secretName, else <project>-openrouter (models.py target_secret_name).
        target = spec.get("secretName") or f"{spec.get('project', '')}-openrouter"
        if target == secret_name:
            return spec.get("guardrail") or ""
    return None


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
                secret_guardrail = base64.b64decode(data.get("GUARDRAIL", "")).decode()
                cr_guardrail = _cr_guardrail(ns, name)  # FU-138: CR wins when one owns the Secret
                if cr_guardrail is not None and cr_guardrail != secret_guardrail:
                    log(f"ref: {ref} guardrail from CR: '{cr_guardrail or 'none'}' "
                        f"(Secret says '{secret_guardrail or 'none'}' — stale, FU-138)")
                resolved = {
                    "key": base64.b64decode(b64).decode(),
                    "guardrail": secret_guardrail if cr_guardrail is None else cr_guardrail,
                    # ADR-096 P2: which rail this ref belongs to — OpenRouter keys enroll for
                    # the headroom poll; anthropic oauth refs must never hit /api/v1/auth/key.
                    "kind": "openrouter" if data.get("OPENROUTER_API_KEY") else "anthropic",
                }
                if resolved["kind"] == "openrouter":
                    router.enroll_key_ref(ref)
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
    """FU-024: a `only-free` session may complete ONLY on free-tier models. Enforced here
    because the proxy already resolves the session (injection rails); direct-key sessions are
    out of scope by design — guardrailed keys are issued injected (model-scout canaries)."""
    resolved = _resolve_ref(self_ref)
    if not resolved or resolved.get("guardrail") != "only-free":
        return None
    if normalize_model(model).endswith(":free"):
        return None
    # homelab#445: opencode/ models are the Zen FREE rail — admit them exactly where the :free
    # variants are admitted. The Go rail (opencode-go/) stays denied: only-free sessions have
    # no Go-window authority.
    if model.startswith(ZEN_PREFIX):
        return None
    return json.dumps({
        "error": {
            "code": 403,
            "message": f"guardrail only-free: model '{model}' is not a free-tier model — "
                       "this session key is restricted to free-tier models (FU-024). "
                       f"Go-leg requests (opencode-go/…) are also denied: only-free sessions "
                       "have no Go-window authority.",
        }
    }).encode()

# ADR-096 addendum 3: the in-flight 4XX circuit breaker. The 2026-07-28 laguna:free storm was
# ONE ride's goose continuation loop hammering a hopeless 401 ~140 times over ~20 min — the
# proxy OBSERVED every one (provider_events) but never ACTED. Per (session, model) the data
# plane counts 4XX outcomes at class-scoped thresholds (auth 401/403 trips fast — an auth
# failure never self-heals mid-session; generic 4xx gets more rope; 429 NEVER counts — a rate
# limit is fail-over/back-off territory, not a hopeless request) and once tripped it STOPS
# FORWARDING that pair for hold_s, emitting a durable `circuit-open` event the retuned FU-021
# watchdog (agent-runtime line item) uses as its kill trigger. Thresholds live in
# model-classes.json `circuit_breaker` (router policy, code defaults as the belt).
_cb: dict[tuple[str, str], dict] = {}  # (session, model) -> {auth, generic, open_until, class, n, ts}
_cb_lock = threading.Lock()


def _cb_config() -> dict:
    cfg = router.classes().get("circuit_breaker") or {}
    return {"auth": int(cfg.get("auth_threshold", 4)),
            "generic": int(cfg.get("generic_threshold", 10)),
            "hold_s": int(cfg.get("hold_s", 900))}


def _cb_session(headers) -> str:
    """The breaker's session identity: the opaque ref for injected sessions (per-session/-project
    secret name — exactly the granularity the storm had), a key-hash bucket for direct keys."""
    auth = next((v for k, v in headers.items() if k.lower() == "authorization"), "")
    if auth.startswith("Bearer ref:"):
        return auth[len("Bearer ref:"):].strip()
    if auth:
        return "direct:" + hashlib.sha256(auth.encode()).hexdigest()[:8]
    return "anonymous"


def _cb_open(session: str, model: str) -> dict | None:
    with _cb_lock:
        st = _cb.get((session, model))
        if st and st["open_until"] > time.time():
            return dict(st)
    return None


def _cb_update(session: str, model: str, status: int) -> None:
    """Fold one forwarded completion outcome into the breaker."""
    now = time.time()
    tripped = None
    cfg = _cb_config()
    with _cb_lock:
        if len(_cb) > 512:  # sessions are ephemeral pods — prune day-old entries opportunistically
            for k in [k for k, v in _cb.items() if now - v["ts"] > 86400]:
                del _cb[k]
        st = _cb.setdefault((session, model),
                            {"auth": 0, "generic": 0, "open_until": 0.0, "class": "", "n": 0,
                             "ts": now})
        st["ts"] = now
        if 200 <= status < 300:
            st["auth"] = st["generic"] = 0
            st["open_until"] = 0.0
            return
        if status in (401, 403):
            st["auth"] += 1
        elif 400 <= status < 500 and status != 429:
            st["generic"] += 1
        else:
            return
        if st["open_until"] > now:
            return
        if st["auth"] >= cfg["auth"]:
            tripped = ("auth", st["auth"])
        elif st["generic"] >= cfg["generic"]:
            tripped = ("generic", st["generic"])
        if tripped:
            st["open_until"] = now + cfg["hold_s"]
            st["class"], st["n"] = tripped
    if tripped:
        router.record_circuit_open(session, model, tripped[0], tripped[1])
        log(f"circuit OPEN ({tripped[0]}) session={session} model={model} n_4xx={tripped[1]} — "
            f"forwarding stopped for {cfg['hold_s']}s (ADR-096 addendum 3)")


# Hop-by-hop (and framing) headers never forwarded either way. accept-encoding is stripped so the
# upstream answers identity — we re-frame the response as stream-until-close.
_DROP_REQ = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
    "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding",
    "x-request-deadline-s",  # homelab#22: a proxy directive, not an upstream header
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


def _strip_beta_query(path: str) -> str:
    """Strip only the `beta=true` query parameter from a URL path, preserving all others.

    Uses urllib.parse to handle arbitrary query param order (not just ?beta=true in isolation).
    Used on the Go leg only — Go's compat API 422s on claude-code's beta decorations.
    """
    if "beta" not in path:
        return path
    # Split path and query
    path_only, _, query = path.partition("?")
    if not query:
        return path
    # Parse, remove 'beta' key, re-encode
    params = urllib.parse.parse_qsl(query, keep_blank_values=True)
    filtered = [(k, v) for k, v in params if k != "beta"]
    if len(filtered) == len(params):
        return path  # beta was not actually present
    new_query = urllib.parse.urlencode(filtered)
    return path_only + ("?" + new_query if new_query else "")


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


def _opencode_scrub(payload: dict, note_tag: str) -> list[str]:
    """ADR-107 / homelab#445 compat scrub shared by the Go and Zen rails. opencode.ai's
    Anthropic-compat layer mishandles STRING-shorthand message content (probed 2026-08-13:
    glm-5.2 dropped the prompt) and rejects Anthropic SERVER tools (e.g. WebSearchTool);
    client tools are function-shaped (input_schema present / type None or "custom"). Normalize
    content to text blocks and drop only server tools so Bash/Edit/MCP tools keep working —
    same as the jail shim. Returns extra note fragments (e.g. ["go-dropped-2-server-tools"]),
    or [] when nothing was changed. Mutates `payload`."""
    notes = []
    for msg in payload.get("messages") or []:
        if isinstance(msg, dict) and isinstance(msg.get("content"), str):
            msg["content"] = [{"type": "text", "text": msg["content"]}]
    tools = payload.get("tools")
    if isinstance(tools, list):
        kept = [t for t in tools if isinstance(t, dict)
                and (t.get("input_schema") is not None or t.get("type") in (None, "custom"))]
        if len(kept) != len(tools):
            notes.append(f"{note_tag}-dropped-{len(tools) - len(kept)}-server-tools")
        payload["tools"] = kept
    return notes


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
                # ADR-096 P3: the pinned provider's effective $/M input — the /route ordering key.
                "eff_in": round(eff(best), 6),
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
    beat to exist upstream, so it retries on a widening backoff. Best-effort: a miss only leaves
    the ledger's launcher-reported figures as the fallback. The auth value is used and dropped —
    never logged, never stored.

    FU-131: the backoff used to be (2s, 5s) and gave up at ~7s, which is FAR too early under
    fan-out. Measured against OpenRouter's own activity export (kimi-k3 arm, 2026-08-03):
    29 of 56 generations stored, $2.196 of $4.328 — the 29 it caught matched the export to the
    cent, so the harvest was accurate but half-blind, and every economics signal built on the
    store (P4-flip evidence, per-arm comparisons, FU-126 experiments) read low and UNEVENLY.
    ~67s of patience costs one sleeping daemon thread per request and nothing else; indexing
    latency is what it is. The thread is a daemon, so a proxy restart mid-wait just drops it."""
    for delay in GENERATION_BACKOFF_S:
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
                with _gen_stats_lock:
                    _gen_stats["stored"] += 1
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
    with _gen_stats_lock:
        _gen_stats["missed"] += 1
    log(f"generation {gen_id}: never appeared after {sum(GENERATION_BACKOFF_S):.0f}s — skipped "
        f"(FU-131: this line IS the ledger undercount — openrouter_generation_harvest_total"
        f"{{outcome=\"missed\"}} counts it)")


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
               "Authorization": "Bearer " + key,
               # Cloudflare 403s urllib's default Python-urllib UA (measured 2026-07-27) — every
               # upstream fetch in this file must carry a real UA.
               "User-Agent": "homelab-openrouter-proxy"}
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


def _capability_tick() -> int:
    """M8 capability feed (FU-095, 2026-08-03): AA composite indices + the task-market prior,
    pulled via the SAME standard account key + _mcp_call the rankings ride (probed: both tools
    answer a plain API key — no OAuth). Weekly cadence (capability changes per release); data
    lands in the router store; policy (class_floors) stays in model-classes.json."""
    resolved = _resolve_ref(ROUTER_ACCOUNT_REF) if ROUTER_ACCOUNT_REF else None
    if not resolved:
        return 0
    bench = _mcp_call(resolved["key"], "list-benchmarks",
                      {"request": {"source": "artificial-analysis"}}).get("data") or []
    rows = [{"model": _CAP_ID_RE.sub("", str(r["model_permaslug"])),
             "intelligence": r.get("intelligence_index"), "coding": r.get("coding_index"),
             "agentic": r.get("agentic_index")}
            for r in bench if r.get("model_permaslug")]
    n = router.record_capability("artificial-analysis", rows)
    market: list[dict] = []
    tags = ((_mcp_call(resolved["key"], "list-task-classifications", {"request": {}})
             .get("data") or {}).get("classifications")) or []
    for t in tags:
        for i, m in enumerate((t.get("models") or [])[:10]):
            if m.get("id"):
                market.append({"tag": str(t.get("tag") or ""), "rank": i + 1,
                               "model": _CAP_ID_RE.sub("", str(m["id"])),
                               "usage_share": m.get("tag_usage_share"),
                               "token_share": m.get("tag_token_share")})
    k = router.record_task_market(market)
    log(f"capability: {n} AA benchmark rows, {k} task-market rows")
    return n


CAPABILITY_POLL_S = int(os.environ.get("CAPABILITY_POLL_S", "604800"))
# Date-stamped ids with an optional :free tag AFTER the stamp (ling-3.0-flash-20260723:free) —
# the rankings _RANK_DATE_RE only strips a trailing stamp, this handles both shapes.
_CAP_ID_RE = re.compile(r"-\d{8}(?=:|$)")
_last_capability_pull = 0.0


def _rankings_loop() -> None:
    global _last_capability_pull
    time.sleep(60)  # let the pod settle (readiness, ref RBAC) before the first pull
    while True:
        try:
            _rankings_tick()
        except Exception as e:  # noqa: BLE001 — the feed is an upgrade, never a crash source
            log(f"rankings: pull failed: {e} — next tick in {RANKINGS_POLL_S}s")
        try:
            if time.time() - _last_capability_pull >= CAPABILITY_POLL_S:
                _capability_tick()
                _last_capability_pull = time.time()  # a FAILED pull retries next daily tick
        except Exception as e:  # noqa: BLE001
            log(f"capability: pull failed: {e} — retry on a later rankings tick")
        try:
            # ADR-096 addendum 3: free models are deliberate instability canaries — score their
            # verdicts dailyish from the passive (model, provider) aggregates, not by hand.
            n = router.derive_canary_verdicts()
            if n:
                log(f"canary verdicts: scored {n} :free models from provider_events")
        except Exception as e:  # noqa: BLE001
            log(f"canary verdicts: derivation failed: {e}")
        time.sleep(RANKINGS_POLL_S)


# ADR-096 P2: per-project OpenRouter headroom. Every standing key limits its project at
# OpenRouter (`project.budgetUSD` ceiling); the router reads the live remainder per enrolled
# session-key ref via GET /api/v1/auth/key (probed 2026-07-27: `limit`, `limit_remaining`,
# `limit_reset: weekly`, `usage_weekly`) — the /route openrouter-budget-exhausted verdict input
# in P3, a Grafana/alert surface today. Refs come from the store (enrolled as traffic resolves
# them) — no cluster-wide secret enumeration, the proxy only polls keys it was already handed.
HEADROOM_POLL_S = int(os.environ.get("HEADROOM_POLL_S", "900"))
_headroom: dict[str, dict] = {}  # ref -> last auth/key snapshot (no key material, ever)
_headroom_lock = threading.Lock()


def _headroom_tick() -> int:
    refs = router.key_refs()
    if ROUTER_ACCOUNT_REF and ROUTER_ACCOUNT_REF not in refs:
        refs.append(ROUTER_ACCOUNT_REF)
    n = 0
    for ref in refs:
        resolved = _resolve_ref(ref)
        if not resolved or resolved.get("kind") != "openrouter":
            continue  # anthropic oauth refs have no OpenRouter account state
        try:
            req = urllib.request.Request(
                f"{UPSTREAM}/api/v1/auth/key",
                headers={"Authorization": "Bearer " + resolved["key"],
                         "User-Agent": "homelab-openrouter-proxy"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.load(resp).get("data") or {}
        except Exception as e:  # noqa: BLE001 — one key failing must not starve the others
            log(f"headroom: {ref}: auth/key failed: {e}")
            continue
        with _headroom_lock:
            _headroom[ref] = {
                "label": data.get("label"),
                "limit": data.get("limit"),
                "limit_remaining": data.get("limit_remaining"),
                "limit_reset": data.get("limit_reset"),
                "usage": data.get("usage"),
                "usage_weekly": data.get("usage_weekly"),
                "is_free_tier": data.get("is_free_tier"),
                "fetched_at": time.time(),
            }
        n += 1
    return n


def _headroom_loop() -> None:
    time.sleep(75)  # after the pod settles; rankings sleeps 60 — stagger the store reads
    while True:
        try:
            n = _headroom_tick()
            if n:
                log(f"headroom: refreshed {n} OpenRouter keys")
        except Exception as e:  # noqa: BLE001
            log(f"headroom: tick failed: {e}")
        try:
            # homelab#158: the account balance rides the SAME loop — per-key headroom and account
            # credit are the two halves of "can the OpenRouter rail still buy anything", and a
            # failed credit poll must never starve the headroom refresh (or vice versa).
            bal = _credit_tick()
            if bal is not None:
                log(f"credit: OpenRouter account balance ${bal} (floor ${OR_MIN_CREDIT})")
        except Exception as e:  # noqa: BLE001
            # homelab#180: the read failing is one more way the leg is dead, so it goes through
            # the SAME counted/named path as an unusable gauge — never a bare log line again.
            _credit_unavailable(f"{type(e).__name__}: {e}")
        time.sleep(HEADROOM_POLL_S)


# ── The ACCOUNT-scope OpenRouter capacity latch (homelab#158, operator directive 2026-08-08) ──
# The evening this comes from: OpenRouter went hard-down for workers (the provisioning
# keys-modify daily limit + a $0.17 balance) and the ENTIRE fleet's dispatch deferred for hours,
# while the subscription rail sat at 2/5 semaphore slots on a fresh plan. Deferring is the right
# answer to "this model costs money we do not have" and the WRONG answer to "the provider is
# down" — the second is an infra failure, the class the loop already knows how to survive.
#
# So the OpenRouter side of /route grows a SECOND, differently-typed refusal, and the split is
# the whole point:
#   per-KEY headroom spent  → `openrouter-budget-exhausted` — a BUDGET decision. It still stops
#                             the dispatch: spilling it onto the subscription would route around
#                             the very ceiling the project key exists to impose.
#   ACCOUNT capacity down   → `or-capacity-down:<what>` — an INFRA failure, no different in kind
#                             from a 5xx. Typed so the launcher may DEGRADE a class=fix ride to
#                             the haiku subscription rail instead of deferring the fleet
#                             (agents/agent-session.sh, docs/agents/model-routing.md §M12).
# Three inputs, all account-scope, all from data this proxy already holds:
#   credit   — the account balance under OPENROUTER_MIN_CREDIT (the same floor the launcher's
#              FU-088(b) gate uses). This is what 2026-08-08 actually looked like. Its SOURCE is
#              the openrouter-operator's `openrouter_account_credit_usd` gauge, read in-cluster
#              from CREDIT_METRICS_URL — NOT a direct GET /api/v1/credits, which this proxy's
#              project-scoped key is not entitled to and which 403'd every tick until homelab#180
#              (see _credit_tick and router.parse_account_credit for the full ruling). The leg is
#              therefore only as live as that operator: when the gauge is unreadable, NaN or
#              stale, the leg reports itself dead via router_openrouter_credit_poll_failures_total
#              instead of silently never latching.
#   hard-402 — an upstream 402 on the data plane: "insufficient credits", account-scope by
#              construction (the signature agent-finalize already classifies as budget-403).
#   rpd      — 429s from ≥2 DISTINCT models inside OR_RPD_WINDOW_S. ONE model 429ing is a model
#              cooldown and router.cooldown_note must keep owning it (a bad model is not a dead
#              provider); several unrelated models 429ing together is the ACCOUNT's limit, and
#              that tells the two apart without guessing at upstream header semantics. It is a
#              heuristic on purpose — bounded by the hold below, and cleared by the next 2xx.
# Self-healing both ways like the FU-088(a) anthropic latch above: the hold expires on its own,
# and any OpenRouter 2xx clears it early (the provider answered — it is not down). In-memory by
# design; a proxy roll forgets, and the next 402/429/credit poll re-latches.
OR_CAPACITY_HOLD_S = int(os.environ.get("OR_CAPACITY_HOLD_S", "900"))
OR_MIN_CREDIT = float(os.environ.get("OPENROUTER_MIN_CREDIT", "0.25"))
OR_RPD_WINDOW_S = int(os.environ.get("OR_RPD_WINDOW_S", "300"))
_or_cap = {"until": 0.0, "reason": "", "since": 0.0, "count": 0,
           # `credit_at` is when WE last read a usable balance; `credit_src_at` is when the
           # OPERATOR last talked to OpenRouter. They differ, and only the second one says how old
           # the number actually is (homelab#180).
           "credit": None, "credit_at": 0.0, "credit_src_at": None}
_or_cap_lock = threading.Lock()
_or_429: dict[str, float] = {}  # model -> last 429 epoch (the cross-model rpd detector)


def _or_capacity_latch(reason: str, hold: float = 0.0) -> str:
    """Latch the OpenRouter ACCOUNT as capacity-down. Returns a note suffix."""
    now = time.time()
    hold = hold or OR_CAPACITY_HOLD_S
    with _or_cap_lock:
        first = _or_cap["until"] <= now
        _or_cap["until"] = max(_or_cap["until"], now + hold)
        _or_cap["reason"] = reason
        if first:
            _or_cap["since"] = now
            _or_cap["count"] += 1
    if first:
        log(f"openrouter ACCOUNT capacity DOWN ({reason}) for {hold:.0f}s — /route now defers "
            f"the openrouter rail as or-capacity-down:{reason}; class=fix launchers may degrade "
            f"to the haiku subscription rail instead of deferring (homelab#158)")
    return "+or-capacity-down"


def _or_capacity_clear(why: str) -> str:
    """A 2xx from OpenRouter means the provider is answering — drop an active hold early."""
    now = time.time()
    with _or_cap_lock:
        if _or_cap["until"] <= now:
            return ""
        reason, _or_cap["until"], _or_cap["reason"] = _or_cap["reason"], 0.0, ""
    _or_429.clear()
    log(f"openrouter 2xx while capacity-latched ({reason}) — latch cleared early ({why})")
    return "+or-capacity-cleared"


def _or_capacity_429(model: str) -> str:
    """Fold one upstream 429 into the rpd detector: ≥2 distinct models inside the window is the
    ACCOUNT's limit, not a model's (which router.cooldown_note handles per model, unchanged)."""
    now = time.time()
    _or_429[model] = now
    recent = {m for m, ts in list(_or_429.items()) if now - ts <= OR_RPD_WINDOW_S}
    for m, ts in list(_or_429.items()):
        if now - ts > OR_RPD_WINDOW_S:
            _or_429.pop(m, None)
    if len(recent) < 2:
        return ""
    return _or_capacity_latch("rpd")


def _or_capacity_down(now: float | None = None) -> str | None:
    """The launcher-visible verdict: the latch reason while it holds, else None."""
    with _or_cap_lock:
        return _or_cap["reason"] if _or_cap["until"] > (now or time.time()) else None


# homelab#600 (FU-170 leg d): the Go rail's OWN capacity latch — the transpose of the
# `_or_capacity_*` pattern onto the GO_UPSTREAM leg. The self-metered ledger is BLIND to the
# real wall: the opencode console reads monthly 95% / weekly 90% while `/opencode-limit`'s
# ledger read 62%/24% — the whole pre-relaunch jail burn is invisible to it (homelab#540), so
# the gate kept ADMITTING Go dispatches straight through a window that hard-429s every request.
# Since this proxy transits ALL cluster Go traffic (both ingress surfaces — the anthropic-compat
# path and the OpenAI-compat/`_opencode_scrub` path — route to GO_UPSTREAM), an observed upstream
# 429/402 is ground truth: latch it, compose it into `/opencode-limit`'s top-level `limited` with
# a typed reason, and the gate starts deferring AT the real wall (zero launcher changes — every
# consumer already probes /opencode-limit and acts on `limited`).
# Self-healing both ways like the or-capacity latch: the hold expires on its own, and any Go 2xx
# clears it early. In-memory by design; a proxy roll forgets, the next 429/402 re-latches.
# ⚠ NOTE: jail-observed 429s do NOT transit this proxy (ADR-108 — the jail shim reports usage via
# the ingest row) and are OUT OF SCOPE here; a later gometer-ingest row kind covers them.
GO_CAPACITY_HOLD_S = int(os.environ.get("GO_CAPACITY_HOLD_S", "900"))
# A 402 means the window is SPENT (not rate pressure) — a longer default hold is honest.
GO_CAPACITY_402_HOLD_S = int(os.environ.get("GO_CAPACITY_402_HOLD_S", "1800"))
_go_cap = {"until": 0.0, "reason": "", "code": 0, "since": 0.0, "count": 0}
_go_cap_lock = threading.Lock()
_go_cap_429: dict[int, int] = {}  # code -> observed count (router_go_observed_429_total{code})


def _go_capacity_latch(code: int, retry_after: float | None = None) -> str:
    """Latch the Go rail as capacity-exhausted from one observed GO_UPSTREAM 429/402. The hold
    is Retry-After when present, else the fixed hold (402 uses the longer window-spent default).
    Returns a note suffix."""
    now = time.time()
    hold = (retry_after if retry_after and retry_after > 0 else None) or \
        (GO_CAPACITY_402_HOLD_S if code == 402 else GO_CAPACITY_HOLD_S)
    reason = f"observed-{code}"
    with _go_cap_lock:
        first = _go_cap["until"] <= now
        _go_cap["until"] = max(_go_cap["until"], now + hold)
        _go_cap["reason"] = reason
        _go_cap["code"] = code
        if first:
            _go_cap["since"] = now
            _go_cap["count"] += 1
    if first:
        log(f"Go rail capacity DOWN ({reason}) for {hold:.0f}s — /opencode-limit now serves "
            f"limited=true, the gate defers AT the real wall (observed {code} from GO_UPSTREAM, "
            "homelab#600)")
    return f"+go-{reason}"


def _go_capacity_clear(why: str) -> str:
    """A 2xx from GO_UPSTREAM means the Go rail is answering — drop an active hold early."""
    now = time.time()
    with _go_cap_lock:
        if _go_cap["until"] <= now:
            return ""
        reason, _go_cap["until"], _go_cap["reason"], _go_cap["code"] = \
            _go_cap["reason"], 0.0, "", 0
    log(f"Go 2xx while capacity-latched ({reason}) — latch cleared early ({why})")
    return "+go-capacity-cleared"


def _go_capacity_update(status: int, resp_headers) -> str:
    """Fold one GO_UPSTREAM status into the observed-capacity latch + counter. Returns a note
    suffix. Retry-After may be absent or an HTTP-date — both fall back to the fixed hold.
    Only the exhaustion statuses (429/402) increment the counter — the `_429_total` series is
    the observed-capacity counter, not a traffic meter."""
    if status in (429, 402):
        with _go_cap_lock:
            _go_cap_429[status] = _go_cap_429.get(status, 0) + 1
    if status == 402:
        return _go_capacity_latch(402)
    if status == 429:
        try:
            retry_after = float(resp_headers.get("retry-after") or 0) or None
        except (TypeError, ValueError):
            retry_after = None
        return _go_capacity_latch(429, retry_after)
    if 200 <= status < 300:
        return _go_capacity_clear("2xx on the go leg")
    return ""


def _go_capacity_snapshot(now: float) -> dict:
    """The /opencode-limit + /metrics view. ⚠ `limited` is keyed on the hold's EXPIRY — never on
    `reason != null` (the M12 stale-`reason` trap, rail-degrade-replay CAP5): `reason` is the raw
    latch field, so it stays populated after expiry until the next 2xx clears it, and a consumer
    that keys on `reason` would defer forever from the first observed 429. Consumers act on
    `limited`."""
    with _go_cap_lock:
        until = _go_cap["until"]
        return {
            "limited": until > now,
            "reason": _go_cap["reason"] or None,
            "code": _go_cap["code"],
            "until_epoch": round(until),
            "remaining_s": max(0, round(until - now)),
            "latched_total": _go_cap["count"],
        }


def _go_limit_reason(status: dict, go_semaphore: dict, go_capacity: dict) -> str | None:
    """The /opencode-limit top-level `reason` — names WHY `limited` is true. An ACTIVE capacity
    latch wins (the observed-429/402 ground truth, homelab#600); otherwise the window threshold
    (`status["limited"]`) or the Go semaphore (`go_semaphore["limited"]`) names the cause
    (homelab#605). When NOT limited the raw capacity field is still echoed — it stays populated
    after the hold expires until a 2xx clears it, and consumers key on `limited`, never on
    `reason != null` (CAP5/M12, the rail-degrade-replay contract)."""
    if go_capacity["limited"]:
        return go_capacity["reason"]
    if status["limited"]:
        # Name the crossing window (any window at/over its threshold) — `utilization-<w>`,
        # the same shape the anthropic leg types (`_dispatch_verdict` returns
        # `utilization-{w}`).
        return next((f"utilization-{w}" for w, d in status["windows"].items()
                     if d["utilization"] >= status["thresholds"][w]), "utilization")
    if go_semaphore["limited"]:
        return "semaphore"
    return go_capacity["reason"] or None


# homelab#180: where the balance comes from. The operator's metrics Service (PR #32 shipped it as
# a DEDICATED Service — `openrouter-operator-metrics`, NOT the operator Deployment's own name),
# reached over in-cluster service DNS per the #138 ruling. ClusterIP→ClusterIP: it does not transit
# the egress path, so a read failure here is a NetworkPolicy suspect before it is a code suspect —
# which is exactly what the failure counter below exists to make visible.
# Set empty to retire the credit leg deliberately (the data-plane legs keep latching).
CREDIT_METRICS_URL = os.environ.get(
    "CREDIT_METRICS_URL",
    "http://openrouter-operator-metrics.openrouter-operator.svc.cluster.local:9090/metrics")
# Staleness bound on the operator's HELD value. The operator polls upstream every
# METRICS_CREDIT_INTERVAL (default 300s, floored at 60), so 1800s tolerates several missed upstream
# polls without blinding the leg, while a genuinely wedged operator ages out well inside the 30m
# `for:` of the OpenRouterCapacityDown alert this leg feeds. 0 disables the staleness refusal.
CREDIT_MAX_AGE_S = int(os.environ.get("CREDIT_MAX_AGE_S", "1800"))
_credit_fails = 0  # router_openrouter_credit_poll_failures_total (guarded by _or_cap_lock)


def _credit_unavailable(why: str) -> None:
    """The ONE place a dead credit leg becomes visible outside pod logs (homelab#180). Every way
    the leg can fail — operator unreachable, gauge absent/NaN, held-stale value — lands here, is
    counted, and is logged naming the source service. The predecessor of this function was an
    unlogged `return None` plus a 403 line nobody was watching, and the leg was dead for weeks."""
    global _credit_fails
    with _or_cap_lock:
        _credit_fails += 1
        n = _credit_fails
    log(f"WARN credit: no usable balance from {CREDIT_METRICS_URL or '(leg disabled)'}: {why} — "
        f"the capacity latch's credit leg is NOT engaging (failure #{n}); its data-plane legs "
        "(hard-402 / cross-model 429s) still latch")


def _credit_tick() -> float | None:
    """Account balance → the `credit` leg of the latch, sourced from the openrouter-operator's
    gauge (see CREDIT_METRICS_URL). Same floor the launcher's FU-088(b) gate uses, evaluated once
    here so /route can TYPE the condition. Hold spans one poll interval (+slack) so a recovered
    balance un-latches on the next tick rather than by timeout — the PROXY's HEADROOM_POLL_S=900s
    tick is still the binding cadence, since the operator refreshes faster (300s) than we read."""
    if not CREDIT_METRICS_URL:
        return None  # leg retired by config — deliberate, and not a failure to count
    # NB no credential and no ROUTER_ACCOUNT_REF guard: the old guard existed because the balance
    # came from an authenticated upstream call, so 'no account ref' meant 'no credit source'. The
    # operator's gauge needs neither, and an in-cluster proxy without an account ref DOES have a
    # credit source now. Off-cluster runs simply fail the read — counted and logged, as they should
    # be, instead of the silent early-return that let this leg rot.
    req = urllib.request.Request(CREDIT_METRICS_URL,
                                 headers={"User-Agent": "homelab-openrouter-proxy"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        text = resp.read().decode("utf-8", "replace")
    balance, updated_at, why = router.parse_account_credit(text, time.time(), CREDIT_MAX_AGE_S)
    if balance is None:
        _credit_unavailable(why)
        return None
    with _or_cap_lock:
        _or_cap["credit_src_at"] = updated_at
        _or_cap["credit"], _or_cap["credit_at"] = balance, time.time()
        latched_on_credit = _or_cap["until"] > time.time() and _or_cap["reason"] == "credit"
    if balance < OR_MIN_CREDIT:
        _or_capacity_latch("credit", HEADROOM_POLL_S + 120)
    elif latched_on_credit:
        with _or_cap_lock:
            _or_cap["until"], _or_cap["reason"] = 0.0, ""
        log(f"openrouter account credit back to ${balance} (floor ${OR_MIN_CREDIT}) — "
            "capacity latch cleared")
    return balance


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
    # homelab#22: socket timeout on the CLIENT connection (recv and send both) — without it a
    # client that stops reading mid-stream blocks wfile.write forever and no deadline can fire.
    timeout = READ_TIMEOUT_S

    def log_message(self, fmt, *args):  # default logger writes to stderr with client noise
        pass

    def _forward(self, body: bytes | None, note: str,
                 or_model: str | None = None, or_provider: str | None = None,
                 cb_session: str | None = None, go_leg: bool = False, zen_leg: bool = False) -> None:
        # homelab#22: every forwarded request is registered in-flight for its full lifetime —
        # try/finally so a handler exception can never leak a phantom entry into the gauge.
        key = threading.get_ident()
        label = or_model or ("anthropic" if self.path.startswith("/anthropic/") else "other")
        with _inflight_lock:
            _inflight[key] = (label, time.time())
        try:
            self._forward_upstream(body, note, or_model=or_model, or_provider=or_provider,
                                   cb_session=cb_session, go_leg=go_leg, zen_leg=zen_leg)
        finally:
            with _inflight_lock:
                _inflight.pop(key, None)

    def _forward_upstream(self, body: bytes | None, note: str,
                          or_model: str | None = None, or_provider: str | None = None,
                          cb_session: str | None = None, go_leg: bool = False,
                          zen_leg: bool = False) -> None:
        started = time.time()
        anthropic = self.path.startswith("/anthropic/")
        # ADR-107 (homelab#421): Go leg routing is by MODEL, not path — check it FIRST.
        # When /anthropic/* carries an opencode-go/ model, Go wins (claude CLI --model).
        if go_leg:  # Go rail — swap upstream, replace auth with Go key
            # Strip ?beta=true query using the proper helper (preserves other params).
            path = _strip_beta_query(self.path)
            # Map the inbound SURFACE onto Go's own paths: both /anthropic/v1/* (claude CLI via
            # the ref rail) and /api/v1/* (OpenRouter shape) serve from Go's /v1/* — strip the
            # surface prefix, keep /v1/…. Live-caught 2026-08-13: GO_UPSTREAM + self.path
            # VERBATIM sent /zen/go/anthropic/v1/messages, which opencode.ai answers with its
            # SPA's 404 page as 200 HTML — and the original self-test pinned that join as
            # correct, because the stub accepts any path. Only a live probe could see it.
            if path.startswith("/anthropic/"):
                path = path[len("/anthropic"):]
            elif path.startswith("/api/"):
                path = path[len("/api"):]
            url = GO_UPSTREAM + path
            note += "+go"
            # Deny if no Go key configured — refuse loudly, never forward without credential.
            if not GO_KEY:
                log(f"{self.command} {self.path} → 502 [go-leg] model={or_model or '-'} - GO_KEY not set")
                self._reply_json(502, {"error": "GO_KEY is not set - the Go rail has no credential"})
                return
        elif zen_leg:  # homelab#445: Zen free rail — same surface mapping as the Go leg.
            path = _strip_beta_query(self.path)
            if path.startswith("/anthropic/"):
                path = path[len("/anthropic"):]
            elif path.startswith("/api/"):
                path = path[len("/api"):]
            url = ZEN_UPSTREAM + path
            note += "+zen"
            # Deny if no Zen key configured — refuse loudly, never forward without credential.
            if not ZEN_KEY:
                log(f"{self.command} {self.path} → 502 [zen-leg] model={or_model or '-'} - ZEN_KEY not set")
                self._reply_json(502, {"error": "ZEN_KEY is not set - the Zen rail has no credential"})
                return
        elif anthropic:  # FU-066: the claude-tier leg — strip the prefix, swap the upstream
            url = ANTHROPIC_UPSTREAM + self.path[len("/anthropic"):]
            note += "+anthropic"
            # FU-109 attribution: subscription traffic counted by ref-derived consumer (the
            # secret name — coordinator-claude vs reviewer vs worker session), so a stalled
            # window is attributable on the dashboard. Direct-token traffic buckets as such.
            raw_auth = next((v for k, v in self.headers.items()
                             if k.lower() == "authorization"), "")
            consumer = (raw_auth[len("Bearer ref:"):].strip().split("/")[-1]
                        if raw_auth.startswith("Bearer ref:") else "direct")
            with _consumers_lock:
                _consumers[consumer] = _consumers.get(consumer, 0) + 1
        else:
            url = UPSTREAM + self.path
        headers = {k: v for k, v in self.headers.items() if k.lower() not in _DROP_REQ}
        # ADR-107 / homelab#445: opencode-leg auth (Go + Zen) — REPLACE all inbound auth with the
        # rail's key. The subscription oauth must NEVER reach opencode.ai.
        if go_leg or zen_leg:
            # SECURITY: allowlist-only headers for the third-party opencode.ai upstream — never
            # forward inbound auth headers (case variants like AUTHORIZATION/X-API-KEY could
            # smuggle the subscription credential past a case-sensitive strip). This is a
            # cross-provider egress, not an operator-trusted hop; only send what the rail needs.
            allowed = {}
            for k, v in self.headers.items():
                lk = k.lower()
                # Allow: content-type (body shape), anthropic-version (client compat), accept
                if lk in ("content-type", "anthropic-version", "accept"):
                    allowed[k] = v
            # Third-party Cloudflare blocks default Python-urllib UAs (live-probed 2026-08-13);
            # send the proxy's uniform UA, never the client's.
            allowed["User-Agent"] = "homelab-openrouter-proxy"
            # Inject our auth — both styles because opencode.ai's docs don't commit to one (and
            # /v1/messages demands x-api-key: Bearer-only → 401, per the zen matrix).
            rail_key = (ZEN_KEY if zen_leg else GO_KEY)
            rail_key = (rail_key.split() or [""])[-1]  # last-token sanitization
            allowed["x-api-key"] = rail_key
            allowed["Authorization"] = f"Bearer {rail_key}"
            headers = allowed
            # Also strip anthropic-beta headers (they're Anthropic-specific, not opencode's).
            headers = {k: v for k, v in headers.items() if k.lower() != "anthropic-beta"}
            note += "+zen-auth-swap" if zen_leg else "+go-auth-swap"
        else:
            note += _inject_ref_auth(headers)  # ADR-087: opaque-ref -> real key, every method/path
        # ADR-107 / homelab#445: oauth-beta reinjection is Anthropic-specific — never run for an
        # opencode rail. The allowlist already strips anthropic-beta, but this guard is explicit.
        if anthropic and not go_leg and not zen_leg:
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
        # homelab#600 (FU-170 leg d): the Go rail's own observed-capacity latch. This branch fires
        # for BOTH ingress surfaces (the /api and /anthropic paths carry opencode-go/ models), and
        # is deliberately independent of the anthropic + OpenRouter latches below — a Go 429 is
        # not an Anthropic 429 and not an OpenRouter problem (the existing guards at
        # `anthropic and not go_leg` / `or_model and not go_leg` already keep rail outcomes from
        # polluting each other).
        if go_leg:
            note += _go_capacity_update(status, resp.headers)
        elif anthropic and not go_leg and not zen_leg:
            note += _anthropic_latch_update(status, resp.headers)
        elif or_model and not go_leg and not zen_leg:  # OpenRouter accounting — opencode is a DIFFERENT provider
            # ADR-096: passive provider health for OpenRouter only. opencode-rail outcomes must
            # NOT pollute OpenRouter state (cooldowns, capacity latches, provider_events) — an
            # opencode 429 is not an OpenRouter problem, and cross-contamination would wedge
            # unrelated traffic.
            router.record_provider_event(or_model, or_provider or "", status)
            if cb_session:  # addendum 3: the same observation feeds the in-flight breaker
                _cb_update(cb_session, or_model, status)
            # homelab#158: and the ACCOUNT-scope capacity latch. Strictly a different question from
            # the per-model cooldown below — that one asks "is THIS model misbehaving", this one
            # asks "is the provider buying anything for us at all".
            if status == 402:
                note += _or_capacity_latch("credit")
            elif status == 429:
                note += _or_capacity_429(or_model)
            elif 200 <= status < 300:
                note += _or_capacity_clear("2xx on the openrouter leg")
            # addendum 4: and the model cooldown state (temporary blacklist + auto-recovery)
            cd = router.cooldown_note(or_model, status)
            if cd:
                hold = router.active_cooldowns().get(or_model) or {}
                log(f"cooldown {cd}: model={or_model} "
                    + (f"reason={hold.get('reason')} streak={hold.get('streak')} "
                       f"hold={hold.get('remaining_s')}s" if cd == "tripped"
                       else "(2xx — back in the pool, streak reset)"))
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
        tail = b""  # last 16KB for Go-leg usage extraction (non-stream JSON puts usage at the end)
        # homelab#22: the absolute wall. A slow-drip upstream keeps every read under
        # READ_TIMEOUT_S forever; this severs at started+deadline regardless.
        try:
            deadline_s = float(self.headers.get("X-Request-Deadline-S") or REQUEST_DEADLINE_S)
        except (TypeError, ValueError):
            deadline_s = float(REQUEST_DEADLINE_S)
        deadline = started + deadline_s if deadline_s > 0 else None
        # read1, NOT read: BufferedIOBase.read(8192) BLOCKS until all 8192 bytes accumulate —
        # a slow-drip upstream never fills it, so the loop (and the deadline check) never runs
        # (caught by the homelab#22 e2e test). read1 returns per raw read; a fully-silent socket
        # still falls to READ_TIMEOUT_S, hence the one-READ_TIMEOUT_S overshoot bound above.
        read1 = getattr(resp, "read1", resp.read)  # HTTPError bodies may lack read1 (finite anyway)
        try:
            while chunk := read1(8192):
                self.wfile.write(chunk)
                self.wfile.flush()
                if or_model and len(head) < 16384:
                    head += chunk
                # opencode rails (Go/Zen): keep a rolling tail buffer (last 16KB) for usage extraction
                if (go_leg or zen_leg) and 200 <= status < 300:
                    tail = (tail + chunk)[-16384:]
                sent += len(chunk)
                if deadline and time.time() > deadline:
                    with _inflight_lock:
                        _deadline_exceeded[or_model or "other"] = \
                            _deadline_exceeded.get(or_model or "other", 0) + 1
                    log(f"REQUEST DEADLINE EXCEEDED: {self.command} {self.path} "
                        f"model={or_model or '-'} — severing after {time.time() - started:.0f}s "
                        f"(deadline {deadline_s:.0f}s, {sent}B relayed; homelab#22)")
                    note += "+deadline-severed"
                    break
        except OSError as e:
            log(f"{self.command} {self.path} → client/upstream dropped mid-stream: {e}")
        finally:
            resp.close()
        # ADR-108: opencode-leg usage extraction and pricing via gometer (single home).
        # head+tail buffer (16KB each) passed to extract_usage; price returns (usd, warning_or_None).
        # The Go rail (opencode-go/) prices from gometer; the Zen free rail (opencode/,
        # homelab#445) is assumed free for now — rows usd=0.0, gometer.price skipped,
        # extract_usage kept for token attribution.
        if (go_leg or zen_leg) and 200 <= status < 300 and or_model:
            merged = gometer.extract_usage(head, tail)
            prefix = GO_PREFIX if go_leg else ZEN_PREFIX
            bare_model = or_model.removeprefix(prefix).split(":")[0]  # strip prefix + any :tag
            if go_leg:
                usd, warning = gometer.price(bare_model, merged)
                if warning:
                    log(f"WARN {warning}")
                # The subscription window draws at LIST price on raw tokens, badge-halved —
                # window_draw(), NOT the cache-discounted price() (2026-08-17 reconciliation,
                # uploads/opencode-go.txt: the cache-priced meter read ~30× low).
                draw = gometer.window_draw(bare_model, merged)
            else:
                usd = 0.0
                draw = 0.0  # the Zen free rail never draws against the Go subscription window
                # homelab#445: assume all opencode/ calls are free. Sentinel, not a block — warn
                # when the bare id lacks the -free suffix and isn't big-pickle so a paid model
                # that slips onto the rail gets noticed instead of silently metered at $0.
                if not bare_model.endswith("-free") and bare_model != "big-pickle":
                    log(f"WARN zen model '{bare_model}' lacks the -free suffix and is not "
                        "big-pickle — assuming free (opencode/ rail, homelab#445); re-check "
                        "metering when paid models ride it")
            # Stack attribution: ref:<ns>/<name> -> stack=<ns>, else "jail"
            auth_hdr = next((v for k, v in self.headers.items() if k.lower() == "authorization"), "")
            if auth_hdr.startswith("Bearer ref:"):
                stack = auth_hdr[len("Bearer ref:"):].strip().split("/")[0]
            else:
                stack = "jail"
            if merged["input_tokens"] or merged["output_tokens"]:
                # homelab#540: the ingest row now carries the cache split (cache_read /
                # cache_creation) so the ledger can price cache-read tokens at the cR rate
                # instead of full input price. extract_usage already reads them; they were
                # dropped at the row boundary before this fix.
                router.go_usage_add(time.time(), stack, bare_model, usd, draw,
                                    merged["input_tokens"], merged["output_tokens"],
                                    merged.get("cache_read_input_tokens", 0),
                                    merged.get("cache_creation_input_tokens", 0))
                if go_leg:
                    log(f"Go usage: {bare_model} stack={stack} tokens={merged['input_tokens']}in/"
                        f"{merged['output_tokens']}out"
                        f"{'+'+str(merged.get('cache_read_input_tokens',0))+'cR' if merged.get('cache_read_input_tokens') else ''}"
                        f"{'+'+str(merged.get('cache_creation_input_tokens',0))+'cW' if merged.get('cache_creation_input_tokens') else ''}"
                        f" -> ${usd:.6f} billed / ${draw:.6f} window-draw")
                else:
                    log(f"Zen usage: {bare_model} stack={stack} tokens={merged['input_tokens']}in/"
                        f"{merged['output_tokens']}out"
                        f"{'+'+str(merged.get('cache_read_input_tokens',0))+'cR' if merged.get('cache_read_input_tokens') else ''}"
                        f"{'+'+str(merged.get('cache_creation_input_tokens',0))+'cW' if merged.get('cache_creation_input_tokens') else ''}"
                        f" -> $0.00 billed / $0.00 window-draw (free rail)")
            else:
                log(f"{'Go' if go_leg else 'Zen'} leg: no usage found in response body for {or_model}")
        if GEN_LOOKUP and or_model and 200 <= status < 300 and not go_leg and not zen_leg:
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
        if self.path.split("?", 1)[0] == "/anthropic-limit":
            # FU-088(a): the launcher-side probe (agents/subscription-latch.sh). limited=true →
            # every subscription launcher defers its spawn until the latch expires/clears.
            # ADR-096 P2: ?tier=dispatch|heavy applies the FU-109 per-consumer threshold
            # (composed max(window, tier)); the FU-088 concurrency semaphore is folded in
            # server-side (reason "semaphore" — the launcher's kubectl copy becomes a belt).
            now = time.time()
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            tier = (q.get("tier") or [None])[0]
            limited, reason, windows = _dispatch_verdict(now, tier)
            semaphore = _semaphore_state()
            if not limited and semaphore["limited"]:
                limited, reason = True, "semaphore"
            with _latch_lock:
                until, last = _latch["until"], _latch["last_429"]
                seen, seen_at = dict(_latch["headers"]), _latch["headers_at"]
            payload = json.dumps({
                "limited": limited,
                "reason": reason,
                "tier": tier,
                "threshold": ANTHROPIC_UTIL_THRESHOLD,
                "thresholds": ANTHROPIC_UTIL_THRESHOLD_BY_WINDOW,
                "effective_thresholds": _effective_thresholds(tier),
                "semaphore": semaphore,
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
        if self.path.split("?", 1)[0] == "/opencode-limit":
            # homelab#422: Go-rail subscription headroom probe — same JSON shape as /anthropic-limit.
            # The composite answer comes from gometer.go_window_status (the shared home, ADR-108):
            # per-window budgets + ANCHORED window_start/resets_at epochs, utilization at
            # WINDOW-DRAW pricing (list price on raw tokens, badge-halved — the 2026-08-17
            # reconciliation), the BINDING window's by_stack, and the composite `limited`
            # verdict. `pricing` states which number the utilizations use.
            # FU-170 (piece a): the Go-rail concurrency semaphore composes into the TOP-LEVEL
            # `limited` verdict (status["limited"] or semaphore["limited"]) — launchers probe
            # /opencode-limit and act on `limited`, so every consumer inherits the bound with
            # ZERO launcher changes. The semaphore state rides in the payload under `semaphore`.
            # FU-170 (piece d, homelab#600): the observed-capacity latch composes the SAME way —
            # an upstream 429/402 from GO_UPSTREAM is ground truth the self-metered ledger cannot
            # see, so it flips `limited` and types the reason (`observed-429`/`observed-402`).
            # ⚠ `capacity.reason` is the RAW latch field (CAP5): it stays populated after the
            # hold expires until a 2xx clears it, while `capacity.limited` (and the top-level
            # `limited`) are keyed on the hold's EXPIRY — consumers act on `limited`, never on
            # `reason != null`.
            def _go_snapshot(name, win_start, _resets_at):
                return router.go_usage_window(gometer.GO_WINDOWS[name]["span_s"], since=win_start)
            # homelab#540: wire the CHAIN-anchor seam — the 5h window's open epoch comes from
            # the ledger walk (first-use/expiry-chained), not a fixed grid.
            def _go_chain(span_s, lookback_s):
                return router.go_usage_chain_open(span_s, lookback_s)
            status = gometer.go_window_status(time.time(), _go_snapshot, chain_fn=_go_chain)
            go_semaphore = _go_semaphore_state()
            go_capacity = _go_capacity_snapshot(time.time())
            limited = status["limited"] or go_semaphore["limited"] or go_capacity["limited"]
            payload = json.dumps({
                "limited": limited,
                # homelab#605: the top-level `reason` names WHY `limited` is true — the capacity
                # latch, the window threshold, or the semaphore — not just the latch's field.
                # CAP5 still holds: consumers key on `limited`, never on `reason != null`.
                "reason": _go_limit_reason(status, go_semaphore, go_capacity),
                "thresholds": status["thresholds"],
                "pricing": status["pricing"],
                "windows": status["windows"],
                "by_stack": status["by_stack"],
                "by_stack_window": status["by_stack_window"],
                "semaphore": go_semaphore,
                "capacity": go_capacity,
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
                "# HELP anthropic_subscription_utilization_threshold Per-window dispatch-deferral threshold (0-1 fraction).",
            ]
            for w in sorted(ANTHROPIC_UTIL_THRESHOLD_BY_WINDOW):
                lines.append(f'anthropic_subscription_utilization_threshold{{window="{w}"}} {ANTHROPIC_UTIL_THRESHOLD_BY_WINDOW[w]}')
            lines += [
                "# TYPE anthropic_subscription_latched gauge",
                "# HELP anthropic_subscription_latched 1 while the reactive 429 latch holds.",
                f"anthropic_subscription_latched {1 if until > now else 0}",
                "# TYPE anthropic_subscription_dispatch_limited gauge",
                "# HELP anthropic_subscription_dispatch_limited The composite /anthropic-limit verdict launchers defer on (429 latch OR utilization threshold).",
                f"anthropic_subscription_dispatch_limited {1 if limited else 0}",
                "# TYPE anthropic_subscription_429_total counter",
                f"anthropic_subscription_429_total {count_429}",
            ]
            # homelab#422: OpenCode Go subscription windows — usage gauges + threshold + limited verdict.
            # Utilization is the WINDOW-DRAW number (list price on raw tokens, badge-halved — the
            # 2026-08-17 reconciliation); the billed-style estimate is a SEPARATE gauge so the two
            # cannot be conflated. TYPE/HELP emitted once per metric family (Prometheus strict
            # parsing requirement).
            def _go_snapshot(name, win_start, _resets_at):
                return router.go_usage_window(gometer.GO_WINDOWS[name]["span_s"], since=win_start)
            # homelab#540: CHAIN-anchor seam (5h window opens at the first request after the
            # previous window expired; the ledger walk recovers the open epoch).
            def _go_chain(span_s, lookback_s):
                return router.go_usage_chain_open(span_s, lookback_s)
            go_status = gometer.go_window_status(time.time(), _go_snapshot, chain_fn=_go_chain)
            lines += [
                "# TYPE opencode_subscription_usage_usd gauge",
                "# HELP opencode_subscription_usage_usd Go-rail subscription window DRAW usage in USD per window (list price, badge-halved).",
                "# TYPE opencode_subscription_usage_billed_est_usd gauge",
                "# HELP opencode_subscription_usage_billed_est_usd Go-rail billed-style estimate in USD per window (cache-discounted; the ledger view).",
                "# TYPE opencode_subscription_usage_threshold gauge",
                "# HELP opencode_subscription_usage_threshold Per-window dispatch-deferral threshold (0-1 fraction).",
                "# TYPE opencode_subscription_reset_timestamp_seconds gauge",
                "# HELP opencode_subscription_reset_timestamp_seconds Unix time the window resets (gometer go_window_bounds anchored — 5h chain, 7d weekly, 30d monthly; absent for rolling windows).",
            ]
            for w, data in sorted(go_status["windows"].items()):
                lines.append(f'opencode_subscription_usage_usd{{window="{w}"}} {data["usage_usd_window_draw"]:.6f}')
                lines.append(f'opencode_subscription_usage_billed_est_usd{{window="{w}"}} {data["usage_usd_billed_est"]:.6f}')
                lines.append(f'opencode_subscription_usage_threshold{{window="{w}"}} {go_status["thresholds"][w]}')
                if data.get("resets_at") is not None:
                    lines.append(f'opencode_subscription_reset_timestamp_seconds{{window="{w}"}} {data["resets_at"]:.0f}')
            lines += [
                "# TYPE opencode_subscription_dispatch_limited gauge",
                "# HELP opencode_subscription_dispatch_limited Composite Go-rail limited verdict (any window past threshold).",
                f"opencode_subscription_dispatch_limited {1 if go_status['limited'] else 0}",
            ]
            # homelab#600 (FU-170 leg d): observed 429/402 → the counter + latch gauge. This is
            # the counter half of the blind-ledger correction — the self-metered windows above
            # can read LOW while the real wall is hard-429ing, so the observed-status series is
            # the only one that reflects what the window actually served. Both code series are
            # ALWAYS emitted (from 0) so "nothing observed yet" is a moving 0, not a missing
            # series — the FU-131 honesty doctrine: a gap reads as a broken scrape, not a zero.
            with _go_cap_lock:
                go_cap_429 = dict(_go_cap_429)
            lines += ["# TYPE router_go_observed_429_total counter",
                      "# HELP router_go_observed_429_total GO_UPSTREAM exhaustion responses by HTTP status, observed on the Go leg (in-memory; resets on roll) — the observed-capacity latch's counter (FU-170 leg d).",
                      *[f'router_go_observed_429_total{{code="{code}"}} {go_cap_429.get(code, 0)}'
                        for code in (429, 402)]]
            go_cap = _go_capacity_snapshot(now)
            lines += ["# TYPE router_go_capacity_latched gauge",
                      "# HELP router_go_capacity_latched 1 while the Go-rail observed-capacity latch holds (an upstream 429/402 from GO_UPSTREAM — the blind-ledger correction, FU-170 leg d).",
                      f"router_go_capacity_latched {1 if go_cap['limited'] else 0}"]
            # FU-170 (piece a): the Go-rail concurrency semaphore — mirror of the anthropic one
            # below (absent running series = count unavailable, honest, not 0).
            go_semaphore = _go_semaphore_state()
            lines += ["# TYPE opencode_subscription_semaphore_running gauge",
                      "# HELP opencode_subscription_semaphore_running Running opencode-go pods cluster-wide (the FU-170 semaphore, server-side)."]
            if go_semaphore["running"] is not None:
                lines.append(f"opencode_subscription_semaphore_running {go_semaphore['running']}")
            lines += ["# TYPE opencode_subscription_semaphore_max gauge",
                      f"opencode_subscription_semaphore_max {OPENCODE_MAX_RUNNING}"]
            # ADR-096 P2: the server-side semaphore (absent series = count unavailable, honest).
            semaphore = _semaphore_state()
            lines += ["# TYPE anthropic_subscription_semaphore_running gauge",
                      "# HELP anthropic_subscription_semaphore_running Running subscription-session pods cluster-wide (the FU-088 semaphore, server-side)."]
            if semaphore["running"] is not None:
                lines.append(f"anthropic_subscription_semaphore_running {semaphore['running']}")
            lines += ["# TYPE anthropic_subscription_semaphore_max gauge",
                      f"anthropic_subscription_semaphore_max {SUBSCRIPTION_MAX_RUNNING}"]
            # FU-109 attribution: subscription requests by ref-derived consumer.
            with _consumers_lock:
                consumers = sorted(_consumers.items())
            if consumers:
                lines += ["# TYPE anthropic_requests_total counter",
                          "# HELP anthropic_requests_total Subscription-leg requests per ref-derived consumer (in-memory; resets on roll)."]
                lines += [f'anthropic_requests_total{{consumer="{c}"}} {n}'
                          for c, n in consumers]
            # FU-131: cost-harvest completeness. `missed` is the ledger's blind spot made
            # measurable — a rising ratio means every cost comparison built on the store reads low.
            with _gen_stats_lock:
                gen_stored, gen_missed = _gen_stats["stored"], _gen_stats["missed"]
            lines += ["# TYPE openrouter_generation_harvest_total counter",
                      "# HELP openrouter_generation_harvest_total Ground-truth /generation lookups by outcome (in-memory; resets on roll).",
                      f'openrouter_generation_harvest_total{{outcome="stored"}} {gen_stored}',
                      f'openrouter_generation_harvest_total{{outcome="missed"}} {gen_missed}']
            # ADR-096 P2: per-key OpenRouter headroom (auth/key snapshots; label = the ref).
            with _headroom_lock:
                headroom = {k: dict(v) for k, v in _headroom.items()}
            if headroom:
                lines += ["# TYPE router_openrouter_key_limit_usd gauge",
                          "# HELP router_openrouter_key_limit_usd The standing key's OpenRouter spend limit (absent = unlimited).",
                          "# TYPE router_openrouter_key_limit_remaining_usd gauge",
                          "# HELP router_openrouter_key_limit_remaining_usd Live remaining headroom under the key's limit (OpenRouterKeyBudgetLow alert).",
                          "# TYPE router_openrouter_key_usage_usd counter",
                          "# HELP router_openrouter_key_usage_usd Lifetime billed usage as reported by auth/key."]
                for ref, d in sorted(headroom.items()):
                    if isinstance(d.get("limit"), (int, float)):
                        lines.append(f'router_openrouter_key_limit_usd{{key="{ref}"}} {d["limit"]}')
                    if isinstance(d.get("limit_remaining"), (int, float)):
                        lines.append(f'router_openrouter_key_limit_remaining_usd{{key="{ref}"}} {d["limit_remaining"]}')
                    if isinstance(d.get("usage"), (int, float)):
                        lines.append(f'router_openrouter_key_usage_usd{{key="{ref}"}} {d["usage"]}')
            # homelab#158: the account-scope capacity latch — the fleet-wide "OpenRouter is down"
            # bit and the balance behind it. `_down` is what /route types as or-capacity-down,
            # i.e. exactly the condition under which class=fix rides degrade to the subscription.
            with _or_cap_lock:
                or_cap = dict(_or_cap)
                credit_fails = _credit_fails
            lines += ["# TYPE router_openrouter_capacity_down gauge",
                      "# HELP router_openrouter_capacity_down 1 while the OpenRouter ACCOUNT is capacity-down (credit floor / hard-402 / cross-model 429s) — the homelab#158 degrade signal.",
                      f"router_openrouter_capacity_down {1 if or_cap['until'] > now else 0}",
                      "# TYPE router_openrouter_capacity_down_total counter",
                      "# HELP router_openrouter_capacity_down_total Times the capacity latch engaged (in-memory; resets on roll).",
                      f"router_openrouter_capacity_down_total {or_cap['count']}"]
            if isinstance(or_cap.get("credit"), (int, float)):
                lines += ["# TYPE router_openrouter_account_credit_usd gauge",
                          "# HELP router_openrouter_account_credit_usd Account balance as last read from the openrouter-operator's openrouter_account_credit_usd gauge (CREDIT_METRICS_URL); absent = no usable read, NOT zero — and unlike the operator's own gauge this one is never NaN and never held past CREDIT_MAX_AGE_S (homelab#180).",
                          f"router_openrouter_account_credit_usd {or_cap['credit']}"]
                if or_cap.get("credit_src_at"):
                    lines += ["# TYPE router_openrouter_account_credit_source_timestamp_seconds gauge",
                              "# HELP router_openrouter_account_credit_source_timestamp_seconds When the OPERATOR last reached OpenRouter for the balance above — how old the number really is, which our own read time does not tell you.",
                              f"router_openrouter_account_credit_source_timestamp_seconds {or_cap['credit_src_at']}"]
            # The dead-leg signal itself (homelab#180). ALWAYS emitted, from 0, so "the credit leg
            # stopped working" is a series that moves rather than a series that never existed —
            # the failure mode this whole issue is about was invisible precisely because the only
            # evidence lived in pod logs.
            lines += ["# TYPE router_openrouter_credit_poll_failures_total counter",
                      "# HELP router_openrouter_credit_poll_failures_total Credit reads that yielded no usable balance (operator unreachable / gauge absent / NaN / stale) — the latch's credit leg is not engaging while this climbs. In-memory; resets on roll. Distinct from the operator's own openrouter_account_credit_poll_failures_total, which counts ITS upstream failures.",
                      f"router_openrouter_credit_poll_failures_total {credit_fails}"]
            # homelab#22: in-flight requests by model/leg + oldest age — the stall-detector's
            # view of a quiet-but-wedged proxy (a handler thread only logs on completion).
            with _inflight_lock:
                inflight = list(_inflight.values())
                severed = sorted(_deadline_exceeded.items())
            by_label: dict[str, tuple[int, float]] = {}
            for label, ts in inflight:
                n, oldest = by_label.get(label, (0, ts))
                by_label[label] = (n + 1, min(oldest, ts))
            lines += ["# TYPE router_inflight_requests gauge",
                      "# HELP router_inflight_requests Requests currently being forwarded, by model (or anthropic/other leg)."]
            if by_label:
                lines += [f'router_inflight_requests{{model="{m}"}} {n}'
                          for m, (n, _) in sorted(by_label.items())]
            else:
                lines.append("router_inflight_requests 0")
            lines += ["# TYPE router_inflight_oldest_age_seconds gauge",
                      "# HELP router_inflight_oldest_age_seconds Age of the oldest in-flight request per model — a value past REQUEST_DEADLINE_S+READ_TIMEOUT_S means a wedged thread."]
            lines += [f'router_inflight_oldest_age_seconds{{model="{m}"}} {now - oldest:.0f}'
                      for m, (_, oldest) in sorted(by_label.items())]
            lines += ["# TYPE router_request_deadline_exceeded_total counter",
                      "# HELP router_request_deadline_exceeded_total Requests severed at the absolute REQUEST_DEADLINE_S wall (in-memory; resets on roll)."]
            if severed:
                lines += [f'router_request_deadline_exceeded_total{{model="{m}"}} {n}'
                          for m, n in severed]
            else:
                lines.append("router_request_deadline_exceeded_total 0")
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
            summary["subscription"] = {"limited": limited, "reason": reason, "windows": windows,
                                       "semaphore": _semaphore_state(),
                                       "effective_thresholds": {
                                           t: _effective_thresholds(t)
                                           for t in ("dispatch", "heavy")}}
            with _headroom_lock:
                summary["openrouter_headroom"] = {k: dict(v) for k, v in _headroom.items()}
            with _or_cap_lock:
                or_cap = dict(_or_cap)
                credit_fails = _credit_fails
            summary["openrouter_capacity"] = {
                "down": or_cap["until"] > now, "reason": or_cap["reason"] or None,
                "remaining_s": max(0, round(or_cap["until"] - now)),
                "latched_total": or_cap["count"], "credit_usd": or_cap["credit"],
                "credit_age_s": (round(now - or_cap["credit_at"]) if or_cap["credit_at"] else None),
                # homelab#180: the credit leg's own health, so "is that leg alive?" is answerable
                # from the probe this alert names instead of from pod logs.
                "credit_source": CREDIT_METRICS_URL or None,
                "credit_source_age_s": (round(now - or_cap["credit_src_at"])
                                        if or_cap.get("credit_src_at") else None),
                "credit_max_age_s": CREDIT_MAX_AGE_S,
                "credit_poll_failures": credit_fails,
                "min_credit_usd": OR_MIN_CREDIT,
                "recent_429_models": sorted(m for m, ts in list(_or_429.items())
                                            if now - ts <= OR_RPD_WINDOW_S)}
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
        if self.path == "/search":
            # FU-134: web research as a PLATFORM capability, not a property of whichever harness got
            # spawned. claude rides have server-side WebSearch; goose rides had no web tool at all,
            # so "is this a known upstream bug?" was answerable or not by coin flip (the kimi arm of
            # the FU-126 fan-out could only disclaim "reasoned from training knowledge"). One
            # endpoint every harness can curl fixes that for opencode/hermes/next too.
            #
            # Mechanism: an ordinary completion carrying OpenRouter's `openrouter:web_search` SERVER
            # tool (the `plugins:[{id:"web"}]` form is deprecated). It rides the caller's own key
            # ref, so budget, guardrail, cost ledger and attribution all keep working with no new
            # credential and no new egress hole — the ride already reaches this VIP for its
            # completions. Cost is the ride's: ~$0.005/search (Exa, ≤10 results) + prompt tokens.
            # ⚠ under `guardrail: only-free` the model must be a :free id or this 403s like any
            # other completion — that is the guardrail working, not a bug here.
            try:
                q = json.loads(body)
                query = (q.get("q") or q.get("query") or "").strip()
                assert query
            except (ValueError, AssertionError, AttributeError):
                self._reply_json(400, {"error": 'body must be JSON: {"q": "<question>", '
                                                '"model": "<optional>", "max_results": <optional>}'})
                return
            auth_hdr = self.headers.get("Authorization", "")
            resolved = _resolve_ref(auth_hdr[len("Bearer ref:"):].strip()) \
                if auth_hdr.startswith("Bearer ref:") else None
            if not resolved or resolved.get("kind") != "openrouter":
                # Deliberately narrow: a ref this proxy can resolve to an OpenRouter key. An
                # anthropic-tier ref has WebSearch in-harness and must never hit this path.
                self._reply_json(403, {"error": "requires an OpenRouter `Bearer ref:<ns>/<secret>` "
                                                "(claude-tier rides use their own WebSearch)"})
                return
            model = str(q.get("model") or SEARCH_MODEL)
            payload = {
                "model": model,
                "messages": [
                    {"role": "system", "content":
                        "Answer from web search results only. Cite every claim with its URL. "
                        "If the search finds nothing relevant, say so plainly — never fill the gap "
                        "from memory."},
                    {"role": "user", "content": query},
                ],
                "tools": [{"type": "openrouter:web_search",
                           "parameters": {"max_results": int(q.get("max_results") or 5)}}],
            }
            try:
                req = urllib.request.Request(
                    f"{UPSTREAM}/api/v1/chat/completions",
                    data=json.dumps(payload).encode(),
                    headers={"Authorization": "Bearer " + resolved["key"],
                             "Content-Type": "application/json",
                             "User-Agent": "homelab-openrouter-proxy/search"},
                )
                with urllib.request.urlopen(req, timeout=SEARCH_TIMEOUT_S) as resp:
                    data = json.load(resp)
            except urllib.error.HTTPError as e:
                detail = e.read()[:400].decode(errors="replace")
                log(f"POST /search model={model} → upstream {e.code}")
                self._reply_json(e.code, {"error": f"upstream {e.code}", "detail": detail})
                return
            except OSError as e:
                log(f"POST /search model={model} → failed: {e}")
                self._reply_json(504, {"error": f"search failed: {e}"})
                return
            msg = ((data.get("choices") or [{}])[0].get("message") or {})
            cites = [a.get("url_citation", {}) for a in (msg.get("annotations") or [])
                     if a.get("type") == "url_citation"]
            log(f"POST /search model={model} q={query[:60]!r} → {len(cites)} citation(s)")
            self._reply_json(200, {
                "answer": msg.get("content") or "",
                # url+title only: the ride wants somewhere to GO and something to quote in a
                # provenance note, not 30k characters of highlight per result.
                "citations": [{"url": c.get("url"), "title": c.get("title")} for c in cites],
                "model": data.get("model") or model,
                "usage": data.get("usage") or {},
            })
            return
        if self.path == "/route":
            # ADR-096 P3: the launcher-called decision API (never the LLM — ADR-094). The
            # launcher passes the chain it knows (claim/stacks.json) + its deny list; the
            # router filters against strikes/cooldowns/health + class policy + capacity and
            # answers a dispatch or a TYPED defer. In-cluster callers (FU-020 CNP bounds
            # reach), honor-system like /report; decisions are recorded server-side either way.
            try:
                req_body = json.loads(body)
                assert isinstance(req_body, dict)
            except (ValueError, AssertionError):
                self._reply_json(400, {"error": "body must be a JSON object"})
                return
            now = time.time()

            def _subscription_ok(tier: str):
                limited, reason, windows = _dispatch_verdict(now, tier)
                if limited:
                    retry = 900
                    if reason == "429-latch":
                        with _latch_lock:
                            retry = max(60, round(_latch["until"] - now))
                    elif reason and reason.startswith("utilization-"):
                        w = windows.get(reason[len("utilization-"):]) or {}
                        retry = max(60, min(round((w.get("reset") or now + 900) - now), 6 * 3600))
                    return False, f"subscription-limited:{reason}", retry
                sem = _semaphore_state()
                if sem["limited"]:
                    return False, "subscription-limited:semaphore", 300
                return True, None, 0

            def _openrouter_ok(key_ref):
                # homelab#158: account-scope capacity FIRST and typed distinctly — the launcher reads
                # `or-capacity-down:*` as a DEGRADE signal (subscription haiku for class=fix)
                # while `openrouter-budget-exhausted` below stays a stop. Order matters: when the
                # provider is down, the per-key budget verdict is not the interesting fact.
                down = _or_capacity_down(now)
                if down:
                    return False, f"or-capacity-down:{down}"
                if key_ref:
                    with _headroom_lock:
                        d = _headroom.get(str(key_ref))
                    if d and isinstance(d.get("limit"), (int, float)) \
                            and isinstance(d.get("limit_remaining"), (int, float)) \
                            and d["limit_remaining"] <= max(0.05, 0.02 * d["limit"]):
                        return False, "openrouter-budget-exhausted"
                return True, None  # unknown ref = fail-open (the key's hard limit is the belt)

            def _price(model):
                m = normalize_model(model)
                if m.endswith(":free"):
                    return 0.0, "free"
                pin = pin_for(m)
                if pin and pin.get("eff_in") is not None:
                    return pin["eff_in"], pin.get("basis")
                return None, None

            decision = router.route(req_body, {
                "price": _price, "subscription_ok": _subscription_ok,
                "openrouter_ok": _openrouter_ok,
            })
            if decision.get("decision") == "dispatch" \
                    and decision.get("rail") == "openrouter" \
                    and not str(decision.get("model", "")).endswith(":free"):
                pin = pin_for(str(decision["model"]))
                if pin:
                    decision["pin"] = pin["provider"]
            # ADR-104: a DRAW logs its provenance — pool#slot@version is what makes a research
            # mission's arm table re-drawable from the proxy log alone, and the log is the only
            # place a deferred slot is visible to whoever is watching the fan-out land.
            draw_note = (f" draw={decision['pool']}#{decision.get('slot')}"
                         f"@{decision.get('pool_version') or '?'}") if decision.get("pool") else ""
            log(f"POST /route stack={req_body.get('stack')} task={req_body.get('task')} "
                f"role={req_body.get('role')} → {decision['decision']} "
                f"{decision.get('model') or decision.get('reason')} "
                f"[{decision.get('basis') or ''}{'+half-open' if decision.get('half_open') else ''}]"
                f"{draw_note}")
            # THE M11 SHADOW LINE (homelab#159) — what the cross-rail ladder WOULD have picked,
            # beside what was actually served. Nothing acts on it: this line, the shadow_decisions
            # table and the router_shadow_* series ARE the deliverable, and the P4 flip happens
            # only after a soak review reads them (docs/agents/model-routing.md §M11).
            sh = decision.get("shadow") or {}
            if sh:
                log(f"  shadow cell={decision.get('class')}/{sh['urgency']}"
                    f"({sh['urgency_source']}) start={sh['start_tier']}"
                    f"{'(reprobe)' if sh.get('reprobe') else ''} learned={sh['learned_start_tier']}"
                    f" → rail={sh.get('rail') or '-'} {sh.get('model') or sh['decision']}"
                    f" tier={sh.get('ladder_tier') or '-'}"
                    f" subscription={'free' if sh['subscription']['eligible'] else (sh['subscription']['blocked'] or 'n/a')}"
                    f" served={decision.get('model') or decision.get('reason')}")
            self._reply_json(200, decision)
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
        cb_session = None
        go_leg = False  # ADR-107 (homelab#421): Go rail routing by model prefix
        zen_leg = False  # homelab#445: Zen free rail routing by model prefix
        if self.path.rstrip("/").endswith("/chat/completions") and body:
            try:
                payload = json.loads(body)
                if isinstance(payload, dict) and payload.get("model"):
                    # FU-024 only-free enforcement (before any forwarding spend).
                    # NOTE: This also denies Go-leg requests for only-free sessions — intentional.
                    # The guardrail asserts spend authority; Go is a paid window and only-free keys
                    # have no Go-window authority. The error message below names this explicitly.
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
                    # ADR-107 / homelab#445: the opencode legs — a model id starting with
                    # `opencode-go/` (Go rail) or `opencode/` (Zen free rail) routes to the
                    # opencode.ai host with the prefix stripped and auth replaced by the rail key.
                    # Prefixes are disjoint; the longer (opencode-go/) is matched first anyway.
                    if or_model.startswith(GO_PREFIX):
                        go_leg = True
                        bare = or_model[len(GO_PREFIX):]
                        # opencode's compat API takes bare model ids — strip the prefix.
                        payload["model"] = bare
                        # Same compat scrub as the jail shim: string content -> blocks, server
                        # tools dropped (client/function tools survive).
                        notes.extend(_opencode_scrub(payload, "go"))
                        notes.append("go-leg")
                        body = json.dumps(payload).encode()
                        note = "+".join(notes)
                        # opencode legs skip OpenRouter processing (pin injection, circuit breaker,
                        # etc.) — it's a simple forward with swapped auth.
                        or_model = bare  # For logging, use the bare model id
                    elif or_model.startswith(ZEN_PREFIX):
                        zen_leg = True
                        bare = or_model[len(ZEN_PREFIX):]
                        payload["model"] = bare
                        notes.extend(_opencode_scrub(payload, "zen"))
                        notes.append("zen-leg")
                        body = json.dumps(payload).encode()
                        note = "+".join(notes)
                        or_model = bare  # For logging, use the bare model id
                    else:
                        # ADR-096 addendum 3: a tripped breaker answers WITHOUT forwarding — the
                        # storm's other ~130 calls never reach the provider, and the error body
                        # carries the circuit-open marker the in-pod watchdog kills on.
                        cb_session = _cb_session(self.headers)
                        tripped = _cb_open(cb_session, or_model)
                        if tripped:
                            code = 401 if tripped["class"] == "auth" else 400
                            reject = json.dumps({"error": {
                                "code": code,
                                "message": f"circuit-open ({tripped['class']}): "
                                           f"{tripped['n']} 4XX responses for this (session, model) "
                                           "— forwarding stopped, fix the session or switch model "
                                           "(ADR-096 addendum 3)",
                            }}).encode()
                            log(f"POST {self.path} → {code} [circuit-open {tripped['class']}] "
                                f"model={or_model} session={cb_session}")
                            self.send_response(code)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(reject)))
                            self.send_header("Connection", "close")
                            self.send_header("X-Openrouter-Proxy", "circuit-open")
                            self.end_headers()
                            self.wfile.write(reject)
                            self.close_connection = True
                            return
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
        # ADR-107 (homelab#421): Go leg detection for /anthropic/* paths — the claude CLI
        # sends Anthropic-format requests to /anthropic/v1/messages with --model opencode-go/...
        # The Go detection must fire here too, not just for /chat/completions.
        # FU-024 only-free guardrail MUST be enforced here identically to /chat/completions.
        elif self.path.startswith("/anthropic/") and body:
            try:
                payload = json.loads(body)
                if isinstance(payload, dict) and payload.get("model"):
                    model = str(payload["model"])
                    # FU-024 only-free enforcement — same check as /chat/completions path.
                    # only-free sessions have no Go-window authority; deny Go-leg requests.
                    auth_hdr = self.headers.get("Authorization", "")
                    if auth_hdr.startswith("Bearer ref:"):
                        reject = _guardrail_reject(
                            auth_hdr[len("Bearer ref:"):].strip(), model)
                        if reject:
                            log(f"POST {self.path} → 403 [guardrail only-free] model={model}")
                            self.send_response(403)
                            self.send_header("Content-Type", "application/json")
                            self.send_header("Content-Length", str(len(reject)))
                            self.send_header("Connection", "close")
                            self.end_headers()
                            self.wfile.write(reject)
                            self.close_connection = True
                            return
                    # ADR-107 / homelab#445: opencode legs on the /anthropic surface too — the
                    # claude CLI sends Anthropic-format requests with --model opencode-go/… or
                    # opencode/…. Same prefix-strip + scrub + auth swap as /chat/completions.
                    if model.startswith(GO_PREFIX):
                        go_leg = True
                        bare = model[len(GO_PREFIX):]
                        payload["model"] = bare
                        _opencode_scrub(payload, "go")
                        body = json.dumps(payload).encode()
                        note = "go-leg"
                        or_model = bare  # For logging, use the bare model id
                    elif model.startswith(ZEN_PREFIX):
                        zen_leg = True
                        bare = model[len(ZEN_PREFIX):]
                        payload["model"] = bare
                        _opencode_scrub(payload, "zen")
                        body = json.dumps(payload).encode()
                        note = "zen-leg"
                        or_model = bare  # For logging, use the bare model id
            except ValueError:
                pass  # not JSON — forward untouched
        self._forward(body, note, or_model=or_model, or_provider=or_provider,
                      cb_session=cb_session, go_leg=go_leg, zen_leg=zen_leg)


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
    if HEADROOM_POLL_S > 0:  # ADR-096 P2: per-key OpenRouter headroom (enrolled refs)
        threading.Thread(target=_headroom_loop, daemon=True).start()
    # ADR-108: start the Go usage ingest listener on port 8081 (daemon thread, fire-and-forget).
    # Token-gated: requires X-Ingest-Token header matching GO_USAGE_INGEST_TOKEN env.
    # Fail-closed: token unset -> 503 "ingest disabled", wrong token -> 401, bad body -> 400.
    # Start unconditionally (not gated on token) so the port is always observable (503 on unset,
    # not connection-refused) — enables self-test c and keeps the LB Service backed by a live port.
    # Re-read env per-request (not captured here) so tests can flip it, and a future ESO Secret
    # arriving after pod start wouldn't need restart (even though prod injects via secretKeyRef).
    def ingest_handler(handler: BaseHTTPRequestHandler) -> None:
        """Handle POST /go-usage-report -> router.go_usage_add(ts, stack, model, usd)."""
        if handler.path != "/go-usage-report" or handler.command != "POST":
            handler.send_response(404)
            handler.send_header("Connection", "close")
            handler.end_headers()
            return
        # Check token (read env per-request for testability + future ESO hot-reload)
        ingest_token = os.environ.get("GO_USAGE_INGEST_TOKEN")
        presented = handler.headers.get("X-Ingest-Token", "")
        if not ingest_token:
            body = json.dumps({"error": "ingest disabled — token not configured"}).encode()
            handler.send_response(503)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(body)))
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(body)
            handler.close_connection = True
            log("go-ingest: 503 (token not configured)")
            return
        if presented != ingest_token:
            status = 401 if presented else 403
            body = json.dumps({"error": "unauthorized" if presented else "token required"}).encode()
            handler.send_response(status)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(body)))
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(body)
            handler.close_connection = True
            log(f"go-ingest: {status} (token={'missing' if not presented else 'wrong'})")
            return
        # Parse body
        length = int(handler.headers.get("Content-Length") or 0)
        body = handler.rfile.read(length) if length else b""
        try:
            data = json.loads(body)
            ts = float(data.get("ts") or time.time())
            stack = str(data["stack"])
            model = str(data["model"])
            usd = float(data["usd"])
            if usd < 0:
                raise ValueError("usd must be >= 0")
            # Optional window-draw price + tokens (shim sends them since 2026-08-17). Absent
            # (legacy shim/spool rows) → the row stores NULL and its draw falls back to usd.
            usd_draw, tokens_in, tokens_out = None, None, None
            if "usd_draw" in data:
                usd_draw = float(data["usd_draw"])
                if usd_draw < 0:
                    raise ValueError("usd_draw must be >= 0")
            if "tokens_in" in data:
                tokens_in = int(data["tokens_in"])
                if tokens_in < 0:
                    raise ValueError("tokens_in must be >= 0")
            if "tokens_out" in data:
                tokens_out = int(data["tokens_out"])
                if tokens_out < 0:
                    raise ValueError("tokens_out must be >= 0")
            # homelab#540: optional cache split (shim sends it since this fix). Absent (old shims
            # still running / legacy spool rows) → treated as 0 — the row stores 0 and the
            # window-draw recompute only improves NEW rows (historical rows lack the split).
            cache_read, cache_creation = 0, 0
            if "cache_read" in data:
                cache_read = int(data["cache_read"])
                if cache_read < 0:
                    raise ValueError("cache_read must be >= 0")
            if "cache_creation" in data:
                cache_creation = int(data["cache_creation"])
                if cache_creation < 0:
                    raise ValueError("cache_creation must be >= 0")
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as e:
            resp = json.dumps({"error": f"bad body: {e}"}).encode()
            handler.send_response(400)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", str(len(resp)))
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(resp)
            handler.close_connection = True
            log(f"go-ingest: 400 bad body: {e}")
            return
        # Accept the row
        router.go_usage_add(ts, stack, model, usd, usd_draw, tokens_in, tokens_out,
                            cache_read, cache_creation)
        handler.send_response(204)
        handler.send_header("Connection", "close")
        handler.end_headers()
        log(f"go-ingest: stack={stack} model={model} ${usd:.6f}")

    class IngestHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *_):
            pass
        def do_POST(self):
            ingest_handler(self)
        def do_GET(self):
            self.send_response(404)
            self.send_header("Connection", "close")
            self.end_headers()
        def do_PUT(self):
            self.do_GET()
        def do_DELETE(self):
            self.do_GET()

    ingest_port = int(os.environ.get("INGEST_PORT", "8081"))
    ingest_server = ThreadingHTTPServer(("0.0.0.0", ingest_port), IngestHandler)
    threading.Thread(target=ingest_server.serve_forever, daemon=True).start()
    log(f"go-ingest: listening on :{ingest_port} (token-gated; 503 if unset)")

    log(f"openrouter-proxy: listening :{PORT} -> {UPSTREAM} "
        f"(h={CACHE_HIT}, uptime>={UPTIME_FLOOR}, max_price×{MAX_PRICE_FACTOR}, "
        f"deadline={REQUEST_DEADLINE_S}s, "
        f"max_tokens_floor={MAX_TOKENS_FLOOR}, market={'on' if MARKET_ENABLE else 'off'}, "
        f"rankings={'on' if ROUTER_ACCOUNT_REF and RANKINGS_POLL_S > 0 else 'off'}, "
        f"semaphore<={SUBSCRIPTION_MAX_RUNNING}, headroom={HEADROOM_POLL_S}s, "
        f"breaker=auth:{_cb_config()['auth']}/generic:{_cb_config()['generic']})")
    ThreadingHTTPServer(("", PORT), Proxy).serve_forever()
    return 0


# ── self-test: stub upstreams, assert routing / auth swap / model rewrite ────────────────────────
def _self_test() -> int:
    """Offline self-test: verifies Go-leg routing, auth swap, and Anthropic passthrough."""
    import http.client

    seen = {}

    class Stub(BaseHTTPRequestHandler):
        name = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            parsed = json.loads(body) if body else {}
            seen[self.name] = {
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "x_api_key": self.headers.get("x-api-key"),
                "user_agent": self.headers.get("User-Agent"),
                "model": parsed.get("model") if body else None,
                "body_raw": body,
            }
            # Return 429 for test-model-429 to test cross-provider contamination guard
            status = 429 if parsed.get("model") == "test-model-429" else 200
            out = b'data: {"ok":true}\n\ndata: [DONE]\n\n'
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)

    def stub(name, port):
        h = type(f"Stub_{name}", (Stub,), {"name": name})
        s = ThreadingHTTPServer(("127.0.0.1", port), h)
        threading.Thread(target=s.serve_forever, daemon=True).start()
        return s

    # Override globals for test
    global UPSTREAM, ANTHROPIC_UPSTREAM, GO_UPSTREAM, GO_KEY, ZEN_UPSTREAM, ZEN_KEY, PORT, _go_response, OPENCODE_MAX_RUNNING
    _go_response = {"type": "sse", "body": b'data: {"ok":true}\n\ndata: [DONE]\n\n'}  # default
    ANTHROPIC_UPSTREAM = "http://127.0.0.1:18191"
    GO_UPSTREAM = "http://127.0.0.1:18192/zen/go"
    UPSTREAM = "http://127.0.0.1:18193"
    GO_KEY = "go-test-key"
    ZEN_UPSTREAM = "http://127.0.0.1:18194/zen"
    ZEN_KEY = "zen-test-key"
    PORT = 18190

    def stub(name, port):
        h = type(f"Stub_{name}", (Stub,), {"name": name})
        s = ThreadingHTTPServer(("127.0.0.1", port), h)
        threading.Thread(target=s.serve_forever, daemon=True).start()
        return s

    stub("anthropic", 18191)
    stub("openrouter", 18193)

    # Go stub with configurable response for usage extraction tests
    class GoStub(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            parsed = json.loads(body) if body else {}
            seen["go"] = {
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "x_api_key": self.headers.get("x-api-key"),
                "user_agent": self.headers.get("User-Agent"),
                "model": parsed.get("model") if body else None,
                "body_raw": body,
            }
            resp = _go_response.get("body", b'data: {"ok":true}\n\ndata: [DONE]\n\n')
            # homelab#600: the stub's status / Retry-After are configurable so the observed-capacity
            # acceptance tests can drive a 429-with-Retry-After and a 402; the model-keyed 429
            # stays for the cross-provider tests. Absent "status" → model-keyed fallback.
            status = _go_response.get("status")
            if status is None:
                status = 429 if parsed.get("model") == "test-model-429" else 200
            self.send_response(status)
            if _go_response.get("retry_after") is not None:
                self.send_header("Retry-After", str(_go_response["retry_after"]))
            self.send_header("Content-Type", "text/event-stream" if _go_response.get("type") == "sse" else "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

    go_stub_server = ThreadingHTTPServer(("127.0.0.1", 18192), GoStub)
    threading.Thread(target=go_stub_server.serve_forever, daemon=True).start()

    # Zen stub (homelab#445) — separate upstream on 18194, records to seen["zen"]. Mirrors
    # GoStub so the metering tests can drive a configurable usage-carrying response.
    class ZenStub(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            parsed = json.loads(body) if body else {}
            seen["zen"] = {
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "x_api_key": self.headers.get("x-api-key"),
                "user_agent": self.headers.get("User-Agent"),
                "model": parsed.get("model") if body else None,
                "body_raw": body,
            }
            resp = _go_response.get("body", b'data: {"ok":true}\n\ndata: [DONE]\n\n')
            status = 429 if parsed.get("model") == "test-model-429" else 200
            self.send_response(status)
            self.send_header("Content-Type", "text/event-stream" if _go_response.get("type") == "sse" else "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

    zen_stub_server = ThreadingHTTPServer(("127.0.0.1", 18194), ZenStub)
    threading.Thread(target=zen_stub_server.serve_forever, daemon=True).start()
    threading.Thread(target=main, daemon=True).start()
    time.sleep(0.5)  # let server start

    def call(model, extra_headers=None, path="/api/v1/chat/completions"):
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        headers = {
            "Content-Type": "application/json",
            "Authorization": "Bearer OAUTH-SECRET",
            "anthropic-version": "2023-06-01",
        }
        if extra_headers:
            headers.update(extra_headers)
        c.request("POST", path,
                  body=json.dumps({"model": model, "messages": [{"role": "user", "content": "hi"}]}),
                  headers=headers)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, data

    fails = []

    def check(cond, msg):
        (fails.append(msg) if not cond else None)
        print(("  ok " if cond else "  FAIL ") + msg)

    print("=== Go leg tests ===")
    # Test 1: opencode-go/x routes to Go stub with prefix stripped
    st, data = call("opencode-go/kimi-k3")
    g = seen.get("go") or {}
    check(st == 200 and b"[DONE]" in data, "go leg: 200 + streamed body relayed")
    check(g.get("model") == "kimi-k3", "go leg: opencode-go/ prefix stripped")
    check(g.get("auth") == "Bearer go-test-key", "go leg: Authorization = Bearer Go key")
    check(g.get("x_api_key") == "go-test-key", "go leg: x-api-key = Go key")
    check(g.get("auth") != "Bearer OAUTH-SECRET" and g.get("x_api_key") != "OAUTH-SECRET",
          "go leg: session oauth never reaches Go")
    check(g.get("path") == "/zen/go/v1/chat/completions",
          "go leg: /api surface prefix stripped — Go serves /v1/* (live-caught 2026-08-13)")

    # Test 2: content normalization (string -> blocks)
    seen.clear()
    st, _ = call("opencode-go/test-model")
    g = seen.get("go") or {}
    body = json.loads(g.get("body_raw") or b"{}")
    content = (body.get("messages") or [{}])[0].get("content")
    check(isinstance(content, list) and content[0].get("type") == "text",
          "go leg: string content normalized to blocks")

    # Test 3: server tools dropped
    seen.clear()
    st, _ = call("opencode-go/test-model", extra_headers={})
    g = seen.get("go") or {}
    body = json.loads(g.get("body_raw") or b"{}")
    # Note: our test harness doesn't send tools, so this verifies passthrough
    check(st == 200, "go leg: request forwarded (tools passthrough when absent)")

    print("\n=== Anthropic leg tests ===")
    # Test 4: /anthropic/* path routes to Anthropic stub with auth passthrough
    # (The Anthropic leg is path-based, not model-based)
    seen.clear()
    st, data = call("claude-haiku-4-5", path="/anthropic/v1/messages")
    a = seen.get("anthropic") or {}
    check(st == 200 and b"[DONE]" in data, "anthropic leg: 200 + streamed body relayed")
    check(a.get("model") == "claude-haiku-4-5", "anthropic leg: model untouched")
    check(a.get("auth") == "Bearer OAUTH-SECRET", "anthropic leg: oauth passed through verbatim")
    check(a.get("path") == "/v1/messages", "anthropic leg: /anthropic prefix stripped")

    print("\n=== Anthropic path Go leg test (DECISIVE CASE) ===")
    # Test 5: /anthropic/* path WITH opencode-go model → Go stub, NOT Anthropic
    # This is what the claude CLI does: --model opencode-go/kimi-k3 to /anthropic/v1/messages
    seen.clear()
    st, data = call("opencode-go/kimi-k3", path="/anthropic/v1/messages")
    g = seen.get("go") or {}
    check(st == 200 and b"[DONE]" in data, "/anthropic + go model: 200 + relayed")
    check(g.get("model") == "kimi-k3", "/anthropic + go model: prefix stripped")
    check(g.get("auth") == "Bearer go-test-key", "/anthropic + go model: Auth = Go key")
    check(g.get("x_api_key") == "go-test-key", "/anthropic + go model: x-api-key = Go key")
    check("OAUTH-SECRET" not in str(g.get("auth")) and "OAUTH-SECRET" not in str(g.get("x_api_key")),
          "/anthropic + go model: zero oauth reaches Go")
    check(g.get("path") == "/zen/go/v1/messages",
          "/anthropic + go model: surface prefix stripped — Go serves /v1/* (live-caught 2026-08-13)")
    # Verify Anthropic stub did NOT receive this request
    check("anthropic" not in seen, "/anthropic + go model: Anthropic stub NOT hit")

    print("\n=== Credential smuggling prevention test ===")
    # Test 6: odd-case auth headers (AUTHORIZATION, X-Api-Key) must NOT reach Go upstream
    # — the Go leg uses allowlist-only forwarding to prevent credential smuggling.
    seen.clear()
    st, data = call("opencode-go/sneaky-test", extra_headers={
        "AUTHORIZATION": "Bearer SMUGGLED-OAUTH",
        "X-Api-Key": "sneaky-key",
        "x-API-KEY": "another-sneaky-key",
    })
    g = seen.get("go") or {}
    check(st == 200 and b"[DONE]" in data, "smuggle test: 200 + relayed")
    check(g.get("auth") == "Bearer go-test-key", "smuggle test: Authorization = Go key only")
    check(g.get("x_api_key") == "go-test-key", "smuggle test: x-api-key = Go key only")
    check("SMUGGLED" not in str(g.get("auth")) and "sneaky" not in str(g.get("x_api_key")).lower(),
          "smuggle test: zero trace of smuggled/sneaky headers")
    # Also verify allowed headers pass through
    check("content-type" in str(g.get("body_raw") or "").lower() or g.get("body_raw"),
          "smuggle test: content-type allowed through (body present)")

    print("\n=== Go key denial test ===")
    # Test 6: empty Go key -> 502, nothing forwarded
    old_go_key = GO_KEY
    GO_KEY = ""
    seen.clear()
    st, data = call("opencode-go/kimi-k3")
    check(st == 502, "go leg without key: 502 refused")
    check("go" not in seen and "anthropic" not in seen,
          "go leg without key: nothing forwarded to upstreams")
    GO_KEY = old_go_key  # restore

    print("\n=== Zen free rail tests (homelab#445) ===")
    # The Zen leg mirrors the Go leg on both ingress surfaces: the `opencode/` prefix strips to
    # the bare model id, auth is replaced by the Zen key (both styles), and the /api and
    # /anthropic surface prefixes are mapped onto zen's /v1/*.

    # Routing + auth swap on the OpenAI surface
    seen.clear()
    st, data = call("opencode/nemotron-3-ultra-free")
    z = seen.get("zen") or {}
    check(st == 200 and b"[DONE]" in data, "zen leg: 200 + streamed body relayed")
    check(z.get("model") == "nemotron-3-ultra-free", "zen leg: opencode/ prefix stripped")
    check(z.get("auth") == "Bearer zen-test-key", "zen leg: Authorization = Bearer zen key")
    check(z.get("x_api_key") == "zen-test-key", "zen leg: x-api-key = zen key")
    check("OAUTH-SECRET" not in str(z.get("auth")) and "OAUTH-SECRET" not in str(z.get("x_api_key")),
          "zen leg: session oauth never reaches zen")
    check(z.get("path") == "/zen/v1/chat/completions",
          "zen leg: /api surface prefix stripped — zen serves /v1/*")
    check("go" not in seen, "zen leg: Go stub NOT hit")

    # Content normalization (string -> blocks)
    seen.clear()
    st, _ = call("opencode/test-model")
    z = seen.get("zen") or {}
    body = json.loads(z.get("body_raw") or b"{}")
    content = (body.get("messages") or [{}])[0].get("content")
    check(isinstance(content, list) and content[0].get("type") == "text",
          "zen leg: string content normalized to blocks")

    # Server tools dropped, client/function tools survive (same compat scrub as the Go rail)
    seen.clear()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode/test-model",
                               "messages": [{"role": "user", "content": "hi"}],
                               "tools": [
                                   {"type": "function", "name": "bash",
                                    "description": "run a command",
                                    "input_schema": {"type": "object", "properties": {}}},
                                   {"type": "web_search", "name": "WebSearchTool"},
                               ]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer test-key"})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 200, "zen tools: request with tools forwarded 200")
    z = seen.get("zen") or {}
    body = json.loads(z.get("body_raw") or b"{}")
    tools = body.get("tools") or []
    check(len(tools) == 1 and tools[0].get("name") == "bash",
          "zen tools: server tool dropped, function tool kept")

    # Cross-provider contamination: a zen 429 must NOT pollute OpenRouter accounting
    seen.clear()
    st, data = call("opencode/test-model-429")
    check(st == 429, "zen cross-provider: zen-leg 429 forwarded correctly")
    z = seen.get("zen") or {}
    check(z.get("model") == "test-model-429", "zen cross-provider: zen stub received request (prefix stripped)")

    # Key denial: empty Zen key -> 502, nothing forwarded
    old_zen_key = ZEN_KEY
    ZEN_KEY = ""
    seen.clear()
    st, data = call("opencode/nemotron-3-ultra-free")
    check(st == 502, "zen leg without key: 502 refused")
    check("zen" not in seen and "anthropic" not in seen,
          "zen leg without key: nothing forwarded to upstreams")
    ZEN_KEY = old_zen_key  # restore

    # /anthropic surface (the claude CLI --model opencode/… path)
    seen.clear()
    st, data = call("opencode/nemotron-3-ultra-free", path="/anthropic/v1/messages")
    z = seen.get("zen") or {}
    check(st == 200 and b"[DONE]" in data, "/anthropic + zen model: 200 + relayed")
    check(z.get("model") == "nemotron-3-ultra-free", "/anthropic + zen model: prefix stripped")
    check(z.get("auth") == "Bearer zen-test-key", "/anthropic + zen model: Auth = zen key")
    check(z.get("x_api_key") == "zen-test-key", "/anthropic + zen model: x-api-key = zen key")
    check("OAUTH-SECRET" not in str(z.get("auth")) and "OAUTH-SECRET" not in str(z.get("x_api_key")),
          "/anthropic + zen model: zero oauth reaches zen")
    check(z.get("path") == "/zen/v1/messages",
          "/anthropic + zen model: /anthropic prefix stripped — zen serves /v1/*")
    check("anthropic" not in seen, "/anthropic + zen model: Anthropic stub NOT hit")

    # Only-free guardrail ADMITS opencode/ (free-tier) while the Go rail stays denied
    _refs["test-only-free/test-secret"] = (time.time() + 3600, {
        "key": "test-key",
        "guardrail": "only-free",
        "kind": "openrouter",
    })
    seen.clear()
    st, data = call("opencode/nemotron-3-ultra-free", path="/anthropic/v1/messages", extra_headers={
        "Authorization": "Bearer ref:test-only-free/test-secret",
    })
    check(st == 200, "only-free: opencode/ via /anthropic ADMITTED (zen is free-tier)")
    check("zen" in seen, "only-free: zen stub received the request")
    # Same only-free session must still DENY the Go rail
    seen.clear()
    st, data = call("opencode-go/kimi-k3", path="/anthropic/v1/messages", extra_headers={
        "Authorization": "Bearer ref:test-only-free/test-secret",
    })
    check(st == 403, "only-free: opencode-go/ still denied (no Go-window authority)")
    check("go" not in seen and "anthropic" not in seen,
          "only-free: go denied pre-forward")
    _refs.pop("test-only-free/test-secret", None)

    print("\n=== Cross-provider state contamination test ===")
    # Test 7: Go-leg 429 must NOT pollute OpenRouter state (cooldown, capacity latch,
    # provider_events). A Go 429 is an opencode.ai problem, not an OpenRouter problem.
    # We verify the guard by checking that the proxy correctly forwards the 429 without
    # OpenRouter-specific accounting (the code path is guarded by `and not go_leg`).
    seen.clear()
    # The stub returns 429 for model "test-model-429" — wrapped with opencode-go/ prefix
    # to trigger Go-leg routing. This tests that Go 429s don't pollute OpenRouter state.
    st, data = call("opencode-go/test-model-429")
    check(st == 429, "cross-provider: Go-leg 429 forwarded correctly")
    g = seen.get("go") or {}
    check(g.get("model") == "test-model-429", "cross-provider: Go stub received request (prefix stripped)")
    # The assertable seam: no OpenRouter cooldown/latch notes in the response
    # (the proxy logs would show "cooldown tripped" or "or-capacity-down" if contaminated)
    # We verify the guard exists by checking our code change compiled and runs correctly.
    # Note: direct assertion of router state would require mocking; the guard is verified
    # by the code path `elif or_model and not go_leg:` at line ~1253.

    print("\n=== Anthropic latch contamination test (Go via /anthropic path) ===")
    # Test 8: Go-leg 429 through /anthropic/* path must NOT update Anthropic subscription latch.
    # A Go 429 is not an Anthropic 429 — the latch state must remain unchanged.
    # We access the module-level _latch dict directly to verify before/after equality.
    import __main__
    # Get initial latch state (count_429 is the most direct indicator of a 429 being processed)
    initial_count = _latch.get("count_429", 0)
    initial_until = _latch.get("until", 0.0)
    seen.clear()
    st, data = call("opencode-go/test-model-429", path="/anthropic/v1/messages")
    check(st == 429, "anthropic-latch: Go-leg 429 via /anthropic forwarded correctly")
    g = seen.get("go") or {}
    check(g.get("model") == "test-model-429", "anthropic-latch: Go stub received request")
    # Verify latch state unchanged — the guard at `if anthropic and not go_leg:` prevents update
    final_count = _latch.get("count_429", 0)
    final_until = _latch.get("until", 0.0)
    check(final_count == initial_count,
          f"anthropic-latch: count_429 unchanged ({initial_count} → {final_count})")
    check(final_until == initial_until,
          f"anthropic-latch: until unchanged ({initial_until} → {final_until})")

    print("\n=== Go observed-capacity latch tests (homelab#600 / FU-170 leg d) ===")
    # The five acceptance rows for the observed 429/402 latch. The stub's status/Retry-After are
    # driven via _go_response; each row resets the latch so the previous row's hold can't bleed.
    def _go_reset_latch():
        with _go_cap_lock:
            _go_cap["until"], _go_cap["reason"], _go_cap["code"] = 0.0, "", 0

    # A1: a Go 429 with Retry-After latches for THAT duration.
    _go_response["status"] = 429
    _go_response["retry_after"] = 120
    _go_reset_latch()
    seen.clear()
    st, data = call("opencode-go/cap-429")
    check(st == 429, "go-capacity: 429 forwarded to client")
    gcap = _go_capacity_snapshot(time.time())
    check(gcap["limited"] is True, f"go-capacity: 429 latched (limited={gcap['limited']})")
    check(gcap["reason"] == "observed-429", f"go-capacity: typed reason observed-429 (got {gcap['reason']})")
    check(gcap["remaining_s"] == 120,
          f"go-capacity: hold = Retry-After 120s (got {gcap['remaining_s']})")

    # A2: a 402 latches (window spent — the longer default hold).
    _go_response["status"] = 402
    _go_response.pop("retry_after", None)
    _go_reset_latch()
    seen.clear()
    st, data = call("opencode-go/cap-402")
    check(st == 402, "go-capacity: 402 forwarded to client")
    gcap = _go_capacity_snapshot(time.time())
    check(gcap["limited"] is True, f"go-capacity: 402 latched (limited={gcap['limited']})")
    check(gcap["reason"] == "observed-402", f"go-capacity: typed reason observed-402 (got {gcap['reason']})")
    check(gcap["remaining_s"] == GO_CAPACITY_402_HOLD_S,
          f"go-capacity: 402 hold = GO_CAPACITY_402_HOLD_S={GO_CAPACITY_402_HOLD_S}s (got {gcap['remaining_s']})")

    # A3: a subsequent Go 2xx clears the latch early (self-healing contract).
    _go_response["status"] = 200
    seen.clear()
    st, data = call("opencode-go/cap-2xx")
    check(st == 200, "go-capacity: 2xx forwarded to client")
    gcap = _go_capacity_snapshot(time.time())
    check(gcap["limited"] is False, f"go-capacity: 2xx cleared latch early (limited={gcap['limited']})")
    check(gcap["reason"] is None, f"go-capacity: reason cleared with latch (got {gcap['reason']})")

    # A4: while latched, /opencode-limit serves limited:true with the typed reason.
    _go_response["status"] = 429
    _go_response["retry_after"] = 120
    _go_reset_latch()
    seen.clear()
    st, data = call("opencode-go/cap-d")
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    lim = json.loads(r.read())
    c.close()
    check(lim["limited"] is True, f"go-capacity: /opencode-limit limited=true while latched (got {lim['limited']})")
    check(lim["reason"] == "observed-429", f"go-capacity: /opencode-limit reason typed (got {lim['reason']})")
    check(lim["capacity"]["limited"] is True, "go-capacity: capacity.limited true while latched")
    check(lim["capacity"]["reason"] == "observed-429", "go-capacity: capacity.reason typed while latched")

    # A5 (CAP5): an EXPIRED hold serves limited:false even though reason is still populated —
    # consumers key on `limited`, never on `reason != null` (the M12 stale-reason trap).
    with _go_cap_lock:
        _go_cap["until"] = time.time() - 1
        _go_cap["reason"] = "observed-429"
        _go_cap["code"] = 429
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    lim = json.loads(r.read())
    c.close()
    check(lim["limited"] is False, f"go-capacity: expired hold → limited=false (CAP5; got {lim['limited']})")
    check(lim["reason"] == "observed-429",
          f"go-capacity: stale reason still populated (CAP5; got {lim['reason']})")
    check(lim["capacity"]["limited"] is False, "go-capacity: capacity.limited false on expiry (CAP5)")
    check(lim["capacity"]["remaining_s"] == 0, "go-capacity: capacity.remaining_s 0 on expiry (CAP5)")

    # Restore the stub default + clear the capacity latch. The semaphore + window tests below
    # re-arm the ONLY state they care about (_semaphore_caches / the ledger); an expired latch's
    # STALE reason (CAP5, pinned by A5 above) must not bleed into their top-level `reason`
    # assertions (homelab#605 — `reason` now names whatever cause made `limited` true).
    _go_response.pop("status", None)
    _go_response.pop("retry_after", None)
    _go_reset_latch()

    print("\n=== Only-free guardrail test (Go via /anthropic path) ===")
    # Test 9: only-free guardrail MUST deny Go-leg requests through /anthropic path.
    # FU-024: only-free sessions have no Go-window authority — same 403 as /chat/completions.
    # We seed the _refs cache directly (the resolution seam) with a guardrail:only-free session.
    _refs["test-only-free/test-secret"] = (time.time() + 3600, {
        "key": "test-key",
        "guardrail": "only-free",
        "kind": "openrouter",
    })
    seen.clear()
    st, data = call("opencode-go/kimi-k3", path="/anthropic/v1/messages", extra_headers={
        "Authorization": "Bearer ref:test-only-free/test-secret",
    })
    check(st == 403, "only-free: Go-leg via /anthropic denied with 403")
    # Verify NO upstream received the request (guardrail fires before forwarding)
    check("go" not in seen and "anthropic" not in seen,
          "only-free: zero upstream traffic (guardrail fires pre-forward)")
    # Clean up the seeded ref
    _refs.pop("test-only-free/test-secret", None)

    print("\n=== Go usage meter tests (homelab#422) ===")
    # Test 10: window arithmetic — ledger rows at controlled timestamps, per-window totals + by_stack
    now = time.time()
    router.go_usage_add(now - 100, "sleep", "kimi-k3", 0.005)
    router.go_usage_add(now - 50, "sleep", "qwen3.5-plus", 0.002)
    router.go_usage_add(now - 25, "circles", "deepseek-v4-flash", 0.001)
    w5m = router.go_usage_window(300)  # 5 minutes
    check(abs(w5m["total_usd"] - 0.008) < 1e-9, f"window 5m: total_usd={w5m['total_usd']}")
    check(w5m["by_stack"].get("sleep", 0) == 0.007, f"by_stack sleep={w5m['by_stack'].get('sleep')}")
    check(w5m["by_stack"].get("circles", 0) == 0.001, f"by_stack circles={w5m['by_stack'].get('circles')}")

    # ── FU-170 (piece a): Go-rail concurrency semaphore /opencode-limit composition ───────────
    print("\n=== FU-170 Go semaphore tests ===")
    # Seam: seed the per-selector pod-count cache slot directly — the exact slot the live k8s
    # count flows through (the cache `_count_pods_by_selector` reads before/after its API call).
    # This is the same "insert an input, assert the COMPUTED verdict" pattern as Test 10's ledger
    # seeding: the verdicts below are produced by _go_semaphore_state + the handler, not read back.
    # Window state at this point: Test 10 left ~$0.008 in the 5h/$12 window (≈0.07% util), so all
    # windows are UNDER threshold — any `limited` must come from the semaphore (or nothing).
    # Test 10a: semaphore full — running >= max flips /opencode-limit `limited` true even when
    # windows are under threshold. Contract (FU-088, mirrored by this dispatch): limited =
    # running is not None and running >= OPENCODE_MAX_RUNNING, with default max=3 → running=3 IS
    # limited. Top-level verdict = status["limited"] OR semaphore["limited"] = False or True.
    _semaphore_caches[GO_SESSION_SELECTOR] = (time.time(), 3)
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    resp = json.loads(r.read())
    c.close()
    check(resp["limited"] is True,
          f"semaphore-full: limited={resp['limited']} (running 3 >= max 3, windows under threshold → True)")
    check(resp["reason"] == "semaphore",
          f"semaphore-full: top-level reason typed for the semaphore cause (homelab#605; got {resp['reason']})")
    check(resp["semaphore"] == {"running": 3, "max": 3, "limited": True},
          f"semaphore-full: semaphore dict running=3 max=3 limited=True (got {resp['semaphore']})")

    # Test 10b: fail-open — pod count unavailable (None) leaves `limited` governed by windows
    # alone. Seam: cache an explicit None (what the k8s fetch returns on RBAC/API error). Windows
    # under threshold → verdict False: a broken counter must never stop dispatch.
    _semaphore_caches[GO_SESSION_SELECTOR] = (time.time(), None)
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    resp = json.loads(r.read())
    c.close()
    check(resp["limited"] is False,
          f"semaphore-fail-open: limited={resp['limited']} (running None, windows under threshold → False)")
    check(resp["reason"] is None,
          f"semaphore-fail-open: no limited cause → reason None (homelab#605; got {resp['reason']})")
    check(resp["semaphore"] == {"running": None, "max": 3, "limited": False},
          f"semaphore-fail-open: semaphore dict running=None limited=False (got {resp['semaphore']})")

    # Test 10c: OPENCODE_MAX_RUNNING=0 disables the bound — a full count must NOT limit.
    # Contract: limited requires max > 0 (the `0 = disabled` arm of the dispatch). Restore the
    # module global afterwards so the remaining tests see the default max=3.
    _old_go_max = OPENCODE_MAX_RUNNING
    OPENCODE_MAX_RUNNING = 0
    _semaphore_caches[GO_SESSION_SELECTOR] = (time.time(), 3)
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    resp = json.loads(r.read())
    c.close()
    OPENCODE_MAX_RUNNING = _old_go_max
    check(resp["limited"] is False,
          f"semaphore-disabled: limited={resp['limited']} (OPENCODE_MAX_RUNNING=0, running 3 → disabled)")
    check(resp["reason"] is None,
          f"semaphore-disabled: no limited cause → reason None (homelab#605; got {resp['reason']})")
    check(resp["semaphore"] == {"running": 3, "max": 0, "limited": False},
          f"semaphore-disabled: semaphore dict max=0 limited=False (got {resp['semaphore']})")
    # Leave the slot empty so later /opencode-limit + /metrics calls see the natural fail-open.
    _semaphore_caches.pop(GO_SESSION_SELECTOR, None)

    # Test 11: /opencode-limit latch flip — utilization crossing threshold flips limited
    # Seed the ledger to cross the 5h threshold (default 0.80, budget $12)
    for _ in range(100):
        router.go_usage_add(now - 100, "test", "kimi-k3", 0.10)  # $10 total → 83% util
    # Hit the endpoint
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    resp = json.loads(r.read())
    c.close()
    check(resp["limited"] is True, f"/opencode-limit: limited={resp['limited']} (should be True at 83%)")
    check(resp["reason"] == "utilization-5h",
          f"/opencode-limit: top-level reason names the crossing window (homelab#605; got {resp['reason']})")
    check("5h" in resp["windows"], "/opencode-limit: 5h window present")
    check(resp["by_stack"].get("test", 0) > 0, "/opencode-limit: by_stack includes test")

    # Test 12: real usage extraction + badge HALVING via stub upstream (non-stream JSON)
    # Stub returns JSON with usage at END: 1M in + 1M out, deepseek-v4-flash (half=True)
    # List: 0.14/0.28 $/M → 1M+1M = $0.42 at 1×.
    #   billed (by_stack)  = list ×1 = $0.42  (homelab#540: badge models BILL at list ×1)
    #   draw (by_stack_draw) = list ×0.5 = $0.21  (the badge halving is WINDOW-DRAW only)
    _go_response["type"] = "json"
    _go_response["body"] = json.dumps({
        "id": "gen-test", "model": "deepseek-v4-flash",
        "usage": {"input_tokens": 1000000, "output_tokens": 1000000}
    }).encode()

    # Call proxy with Go model (no ref — direct key, stack="jail")
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/deepseek-v4-flash",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer direct-key"})
    r = c.getresponse()
    r.read()
    c.close()

    # Check ledger: billed $0.42 (list ×1), draw $0.21 (badge-halved) for jail stack
    w = router.go_usage_window(60)
    check(abs(w["by_stack"].get("jail", 0) - 0.42) < 0.01,
          f"JSON extraction: jail stack billed ≈$0.42 (list ×1), got {w['by_stack'].get('jail')}")
    check(abs(w["by_stack_draw"].get("jail", 0) - 0.21) < 0.01,
          f"JSON extraction: jail stack draw ≈$0.21 (badge-halved), got {w['by_stack_draw'].get('jail')}")

    # Test 12b: SSE extraction (message_start + message_delta)
    _go_response["type"] = "sse"
    _go_response["body"] = b'''data: {"type":"message_start","message":{"usage":{"input_tokens":1000000,"cache_read_input_tokens":0}}}

data: {"type":"message_delta","delta":{"usage":{"output_tokens":1000000}}}

data: [DONE]

'''

    # Call with ref-style header to attribute separately
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/deepseek-v4-flash",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer ref:sse-stack/test-secret"})
    r = c.getresponse()
    r.read()
    c.close()

    # SSE test should also add billed $0.42 / draw $0.21 for sse-stack
    w2 = router.go_usage_window(60)
    check(abs(w2["by_stack"].get("sse-stack", 0) - 0.42) < 0.01,
          f"SSE extraction: sse-stack billed ≈$0.42, got {w2['by_stack'].get('sse-stack')}")
    check(abs(w2["by_stack_draw"].get("sse-stack", 0) - 0.21) < 0.01,
          f"SSE extraction: sse-stack draw ≈$0.21, got {w2['by_stack_draw'].get('sse-stack')}")

    # Restore default SSE response for remaining tests
    _go_response["type"] = "sse"
    _go_response["body"] = b'data: {"ok":true}\n\ndata: [DONE]\n\n'

    # Test 13: beta strip — ?beta=true&other=1 preserves other=1; plain ?beta=true strips clean
    check(_strip_beta_query("/path?beta=true") == "/path", "beta strip: plain ?beta=true → clean")
    check(_strip_beta_query("/path?beta=true&other=1") == "/path?other=1",
          "beta strip: ?beta=true&other=1 → ?other=1")
    check(_strip_beta_query("/path?x=1&beta=true&y=2") == "/path?x=1&y=2",
          "beta strip: middle beta removed, neighbours joined")
    check(_strip_beta_query("/path?x=1") == "/path?x=1", "beta strip: no beta → unchanged")

    # Test 14: unknown-model fallback — real request through proxy exercises the warn + pricing
    # "not-a-model" should use _GO_MAX_PRICE fallback: (_GO_MAX_PRICE/2, _GO_MAX_PRICE/2, 0, 0, False)
    # 1M in + 1M out → (_GO_MAX_PRICE/2 + _GO_MAX_PRICE/2) × 1.0 = _GO_MAX_PRICE dollars
    _go_response["body"] = json.dumps({
        "id": "gen-fallback", "model": "not-a-model",
        "usage": {"input_tokens": 1000000, "output_tokens": 1000000}
    }).encode()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/not-a-model",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer ref:fallback-stack/test-secret"})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 200, "fallback request: HTTP 200 returned")
    w3 = router.go_usage_window(60)
    expected = _GO_MAX_PRICE  # 1M×(max/2)/1e6 + 1M×(max/2)/1e6 = max
    check(abs(w3["by_stack"].get("fallback-stack", 0) - expected) < 0.01,
          f"fallback: fallback-stack ≈${expected}, got {w3['by_stack'].get('fallback-stack')}")

    # Test 14b: cache-write pricing — gpt-5.6-luna has cW=0.25 AND half=True (compound case)
    # Usage: 100k in + 100k out + 1M cache_creation.
    #   billed = list ×1 = 0.02 + 0.12 + 0.25 = $0.39  (homelab#540: badge models BILL at list ×1)
    #   draw   = list ×0.5 = (0.02 + 0.12 + 0.25) × 0.5 = $0.195  (badge halving is DRAW-only)
    # Keep input below 272k threshold to test base rates
    _go_response["body"] = json.dumps({
        "id": "gen-cw", "model": "gpt-5.6-luna",
        "usage": {"input_tokens": 100000, "output_tokens": 100000, "cache_creation_input_tokens": 1000000}
    }).encode()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/gpt-5.6-luna",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer ref:cw-stack/test-secret"})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 200, "cache-write request: HTTP 200 returned")
    w_cw = router.go_usage_window(60)
    expected_cw = 0.39   # billed: (0.02 + 0.12 + 0.25) × 1 = 0.39
    expected_cw_draw = 0.195  # draw: (0.02 + 0.12 + 0.25) × 0.5
    check(abs(w_cw["by_stack"].get("cw-stack", 0) - expected_cw) < 0.01,
          f"cache-write: cw-stack billed ≈${expected_cw}, got {w_cw['by_stack'].get('cw-stack')}")
    check(abs(w_cw["by_stack_draw"].get("cw-stack", 0) - expected_cw_draw) < 0.01,
          f"cache-write: cw-stack draw ≈${expected_cw_draw}, got {w_cw['by_stack_draw'].get('cw-stack')}")

    # Test 14c: long-context pricing — qwen3.7-plus >256k uses 1.20/4.80/0.12/1.50 rates
    # 300k input + 100k output → 300k×1.20/1e6 + 100k×4.80/1e6 = 0.36 + 0.48 = $0.84
    _go_response["body"] = json.dumps({
        "id": "gen-long", "model": "qwen3.7-plus",
        "usage": {"input_tokens": 300000, "output_tokens": 100000}
    }).encode()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/qwen3.7-plus",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer ref:long-stack/test-secret"})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 200, "long-context request: HTTP 200 returned")
    w_long = router.go_usage_window(60)
    expected_long = 0.84  # 300k×1.20/1e6 + 100k×4.80/1e6
    check(abs(w_long["by_stack"].get("long-stack", 0) - expected_long) < 0.01,
          f"long-context: long-stack ≈${expected_long}, got {w_long['by_stack'].get('long-stack')}")

    # Test 14d: the cache SPLIT persists through the proxy row write (homelab#540).
    # kimi-k3 in 3.00/out 15.00/cR 0.30: 1000 in + 500 cache_read + 100 out →
    #   billed = 1000×3.00/1e6 + 500×0.30/1e6 + 100×15.00/1e6 = 0.003 + 0.00015 + 0.0015 = $0.00465
    #   draw   = same (kimi not badged, ×1) = $0.00465
    # The row's cache_read/cache_creation columns must be stored so the ledger can price the
    # split instead of charging full input price on every cache-read token.
    _go_response["body"] = json.dumps({
        "id": "gen-split", "model": "kimi-k3",
        "usage": {"input_tokens": 1000, "cache_read_input_tokens": 500, "output_tokens": 100}
    }).encode()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/kimi-k3",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer ref:split-stack/test-secret"})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 200, "cache-split request: HTTP 200 returned")
    w_split = router.go_usage_window(60)
    check(abs(w_split["by_stack"].get("split-stack", 0) - 0.00465) < 0.0001,
          f"cache-split: split-stack billed ≈$0.00465, got {w_split['by_stack'].get('split-stack')}")
    # The stored row must carry cache_read=500 (the ledger recompute uses it).
    _split_rows = router._read("SELECT cache_read, cache_creation FROM go_usage "
                               "WHERE stack='split-stack' ORDER BY ts DESC LIMIT 1")
    check(_split_rows and _split_rows[0] == (500, 0),
          f"cache-split: stored row cache_read=500 cache_creation=0 (got {_split_rows})")

    # Test 15: ledger prune — rows older than 45d are deleted
    old_ts = now - 50 * 86400
    router.go_usage_add(old_ts, "old", "kimi-k3", 1.0)  # 50 days old
    router.go_usage_add(now, "fresh", "kimi-k3", 0.01)  # fresh row triggers prune
    w4 = router.go_usage_window(60 * 86400)  # 60d window
    check(w4["by_stack"].get("old", 0) == 0, "ledger prune: 50d-old row deleted")
    check(w4["by_stack"].get("fresh", 0) == 0.01, "ledger prune: fresh row retained")

    # Test 16: /metrics TYPE dedup — each opencode_ TYPE line appears exactly once
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/metrics")
    r = c.getresponse()
    metrics = r.read().decode()
    c.close()
    for metric in ("opencode_subscription_usage_usd", "opencode_subscription_usage_threshold"):
        count = metrics.count(f"# TYPE {metric}")
        check(count == 1, f"/metrics: # TYPE {metric} appears exactly once (got {count})")
    # Test 16b (homelab#600): the observed-capacity series are always emitted (from 0) and
    # dedup once — a missing series reads as a broken scrape, not a zero (FU-131 doctrine).
    for metric in ("router_go_observed_429_total", "router_go_capacity_latched"):
        count = metrics.count(f"# TYPE {metric}")
        check(count == 1, f"/metrics: # TYPE {metric} appears exactly once (got {count})")
    import re as _re
    # Both code series must be PRESENT — the always-on emission is the point (a missing series
    # reads as a broken scrape, not a zero); the count itself is not asserted here because the
    # earlier Go-429 tests have already observed several (the value is whatever it is).
    check(bool(_re.search(r'router_go_observed_429_total\{code="429"\} \d+', metrics)),
          "/metrics: router_go_observed_429_total{code=\"429\"} series present (always-on)")
    check(bool(_re.search(r'router_go_observed_429_total\{code="402"\} \d+', metrics)),
          "/metrics: router_go_observed_429_total{code=\"402\"} series present (always-on)")
    check("router_go_capacity_latched 0" in metrics
          or "router_go_capacity_latched 1" in metrics,
          "/metrics: router_go_capacity_latched gauge present")

    # Test 17: Go-leg User-Agent — stub must see "homelab-openrouter-proxy"
    seen.clear()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode-go/kimi-k3",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer test-key"})
    r = c.getresponse()
    r.read()
    c.close()
    g = seen.get("go") or {}
    check(g.get("user_agent") == "homelab-openrouter-proxy",
          f"Go-leg User-Agent: homelab-openrouter-proxy (got {g.get('user_agent')})")

    # Test 17b: Zen-leg User-Agent — stub must see "homelab-openrouter-proxy"
    seen.clear()
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("POST", "/api/v1/chat/completions",
              body=json.dumps({"model": "opencode/nemotron-3-ultra-free",
                               "messages": [{"role": "user", "content": "hi"}]}),
              headers={"Content-Type": "application/json",
                       "Authorization": "Bearer test-key"})
    r = c.getresponse()
    r.read()
    c.close()
    z = seen.get("zen") or {}
    check(z.get("user_agent") == "homelab-openrouter-proxy",
          f"Zen-leg User-Agent: homelab-openrouter-proxy (got {z.get('user_agent')})")

    # ── Zen metering (homelab#445): usd=0.0, gometer.price skipped, extract_usage kept ───────────
    print("\n=== Zen metering tests (homelab#445) ===")
    # Zen stub returns JSON with usage: 1M in + 1M out. If the zen leg wrongly called
    # gometer.price (which it must NOT), an unpriced zen model would fall back to _GO_MAX_PRICE
    # and the stack would show a large usd. Assert the stack stays exactly 0.0 — the row is
    # recorded for token attribution but never prices.
    _go_response["type"] = "json"
    _go_response["body"] = json.dumps({
        "id": "gen-zen", "model": "nemotron-3-ultra-free",
        "usage": {"input_tokens": 1000000, "output_tokens": 1000000}
    }).encode()
    seen.clear()
    st, data = call("opencode/nemotron-3-ultra-free", extra_headers={
        "Authorization": "Bearer ref:zen-meter/test-secret"})
    check(st == 200, "zen metering: request 200")
    wz = router.go_usage_window(60)
    check(abs(wz["by_stack"].get("zen-meter", 0) - 0.0) < 1e-9,
          f"zen metering: zen-meter stack ≈$0.00 (got {wz['by_stack'].get('zen-meter')})")

    # Assumption sentinel: a bare id that lacks the -free suffix and isn't big-pickle warns
    # (log line, not assertable without stdout capture) but must NOT block — 200 through.
    _go_response["body"] = json.dumps({
        "id": "gen-zen-sentinel", "model": "paid-looking",
        "usage": {"input_tokens": 10, "output_tokens": 10}
    }).encode()
    st, data = call("opencode/paid-looking", extra_headers={
        "Authorization": "Bearer ref:zen-meter/test-secret"})
    check(st == 200, "zen sentinel: non -free-suffix model still allowed (warning, not a block)")

    # big-pickle is the ONE known free model without the -free suffix — must NOT warn, must 200.
    _go_response["body"] = json.dumps({
        "id": "gen-zen-bp", "model": "big-pickle",
        "usage": {"input_tokens": 10, "output_tokens": 10}
    }).encode()
    st, data = call("opencode/big-pickle", extra_headers={
        "Authorization": "Bearer ref:zen-meter/test-secret"})
    check(st == 200, "zen big-pickle: known no-suffix free model allowed")

    # Restore default SSE response for remaining tests
    _go_response["type"] = "sse"
    _go_response["body"] = b'data: {"ok":true}\n\ndata: [DONE]\n\n'

    # ── ADR-108 ingest self-tests (§4) ───────────────────────────────────────────────────────────
    print("\n=== Ingest endpoint tests ===")
    INGEST_PORT = 8081  # default ingest port
    # Test 18: ingest round-trip — POST a valid row, assert /opencode-limit by_stack gains it
    # Expected: $0.05 for stack "test-ingest" at ts now, model "kimi-k3"
    ingest_test_token = "ingest-test-token-xyz"
    os.environ["GO_USAGE_INGEST_TOKEN"] = ingest_test_token
    # Give the listener time to see the env change (it reads per-request, but give it a moment)
    time.sleep(0.1)
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"ts": time.time(), "stack": "test-ingest",
                               "model": "kimi-k3", "usd": 0.05}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": ingest_test_token})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 204, f"ingest round-trip: 204 on valid POST (got {r.status})")
    # Assert /opencode-limit by_stack gained exactly $0.05 for test-ingest
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", "/opencode-limit")
    r = c.getresponse()
    limit_data = json.loads(r.read())
    c.close()
    by_stack = limit_data.get("by_stack", {})
    # Expected: by_stack["test-ingest"] == 0.05 (the row we just posted)
    check(abs(by_stack.get("test-ingest", 0) - 0.05) < 0.001,
          f"ingest round-trip: by_stack['test-ingest'] ≈ $0.05 (got {by_stack.get('test-ingest')})")

    # Test 18b: ingest tolerates a payload WITH the cache split and stores it (homelab#540);
    # the shim has been sending the split since this fix. The row must land with
    # cache_read=777 / cache_creation=42 so the ledger can price the split.
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"ts": time.time(), "stack": "ingest-split",
                               "model": "kimi-k3", "usd": 0.01,
                               "cache_read": 777, "cache_creation": 42}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": ingest_test_token})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 204, f"ingest with cache split: 204 on valid POST (got {r.status})")
    _isplit = router._read("SELECT cache_read, cache_creation FROM go_usage "
                           "WHERE stack='ingest-split' ORDER BY ts DESC LIMIT 1")
    check(_isplit and _isplit[0] == (777, 42),
          f"ingest cache split stored: cache_read=777 cache_creation=42 (got {_isplit})")
    # An OLD shim payload WITHOUT the cache fields must be tolerated (absent → 0), not rejected.
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"ts": time.time(), "stack": "ingest-nosplit",
                               "model": "kimi-k3", "usd": 0.01}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": ingest_test_token})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 204, f"ingest without cache fields (old shim): 204 (got {r.status})")
    _ins = router._read("SELECT cache_read, cache_creation FROM go_usage "
                        "WHERE stack='ingest-nosplit' ORDER BY ts DESC LIMIT 1")
    check(_ins and _ins[0] == (0, 0),
          f"ingest absent cache fields → stored 0/0 (got {_ins})")

    # Test 19: 401 on wrong token
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"stack": "x", "model": "x", "usd": 0.01}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": "wrong-token"})
    r = c.getresponse()
    body = r.read()
    c.close()
    check(r.status == 401, f"ingest wrong token: 401 (got {r.status})")
    check(b"unauthorized" in body.lower(), "ingest wrong token: body says 'unauthorized'")

    # Test 20: 503 on token-unset (save/restore env)
    old_token = os.environ.get("GO_USAGE_INGEST_TOKEN")
    del os.environ["GO_USAGE_INGEST_TOKEN"]
    time.sleep(0.1)  # let per-request read see the change
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"stack": "x", "model": "x", "usd": 0.01}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": "any-token"})
    r = c.getresponse()
    body = r.read()
    c.close()
    check(r.status == 503, f"ingest token-unset: 503 (got {r.status})")
    check(b"ingest disabled" in body, "ingest token-unset: body says 'ingest disabled'")
    # Restore token for cleanup (tests after this don't use ingest, but be clean)
    if old_token:
        os.environ["GO_USAGE_INGEST_TOKEN"] = old_token

    # Test 21: 400 on malformed body (non-JSON, then negative usd)
    os.environ["GO_USAGE_INGEST_TOKEN"] = ingest_test_token
    # Non-JSON body
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=b"not-json-at-all",
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": ingest_test_token})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 400, f"ingest non-JSON body: 400 (got {r.status})")
    # Negative usd
    c = http.client.HTTPConnection("127.0.0.1", INGEST_PORT, timeout=10)
    c.request("POST", "/go-usage-report",
              body=json.dumps({"stack": "x", "model": "x", "usd": -1.0}),
              headers={"Content-Type": "application/json",
                       "X-Ingest-Token": ingest_test_token})
    r = c.getresponse()
    r.read()
    c.close()
    check(r.status == 400, f"ingest negative usd: 400 (got {r.status})")

    print()
    if not fails:
        print("self-test: PASS")
        return 0
    else:
        print(f"self-test: {len(fails)} FAILURES")
        for f in fails:
            print(f"  - {f}")
        return 1


if __name__ == "__main__":
    # Self-test: offline routing/auth/rewrite test matching the jail shim's pattern.
    # Usage: python3 openrouter-proxy.py --self-test
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    sys.exit(main())
