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
SUBSCRIPTION_MAX_RUNNING = int(os.environ.get("SUBSCRIPTION_MAX_RUNNING", "3"))
SUBSCRIPTION_SESSION_SELECTOR = "homelab.teststuff.net/subscription-session=claude"
SEMAPHORE_TTL_S = int(os.environ.get("SEMAPHORE_TTL_S", "10"))
_semaphore_cache: tuple[float, int | None] = (0.0, None)
_semaphore_lock = threading.Lock()
# FU-109 attribution: /anthropic requests counted per ref-derived consumer (in-memory — a roll
# resets the counter, rate() doesn't care).
_consumers: dict[str, int] = {}
_consumers_lock = threading.Lock()


def _subscription_running() -> int | None:
    """Cluster-wide Running count of subscription-labelled pods, briefly cached. None = count
    unavailable (fail-open, logged) — the caller must treat that as 'not limited'."""
    global _semaphore_cache
    now = time.time()
    with _semaphore_lock:
        ts, val = _semaphore_cache
        if now - ts < SEMAPHORE_TTL_S:
            return val
    count = None
    try:
        token = open(f"{_SA_DIR}/token").read().strip()
        ctx = ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt")
        qs = urllib.parse.urlencode({"labelSelector": SUBSCRIPTION_SESSION_SELECTOR,
                                     "fieldSelector": "status.phase=Running"})
        req = urllib.request.Request(f"https://kubernetes.default.svc/api/v1/pods?{qs}",
                                     headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
            count = len(json.load(resp).get("items") or [])
    except Exception as e:  # noqa: BLE001 — fail-open by design
        log(f"semaphore: pod count failed: {e} — failing open")
    with _semaphore_lock:
        _semaphore_cache = (now, count)
    return count


def _semaphore_state() -> dict:
    running = _subscription_running()
    return {"running": running, "max": SUBSCRIPTION_MAX_RUNNING,
            "limited": bool(SUBSCRIPTION_MAX_RUNNING > 0 and running is not None
                            and running >= SUBSCRIPTION_MAX_RUNNING)}
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
                 cb_session: str | None = None) -> None:
        # homelab#22: every forwarded request is registered in-flight for its full lifetime —
        # try/finally so a handler exception can never leak a phantom entry into the gauge.
        key = threading.get_ident()
        label = or_model or ("anthropic" if self.path.startswith("/anthropic/") else "other")
        with _inflight_lock:
            _inflight[key] = (label, time.time())
        try:
            self._forward_upstream(body, note, or_model=or_model, or_provider=or_provider,
                                   cb_session=cb_session)
        finally:
            with _inflight_lock:
                _inflight.pop(key, None)

    def _forward_upstream(self, body: bytes | None, note: str,
                          or_model: str | None = None, or_provider: str | None = None,
                          cb_session: str | None = None) -> None:
        started = time.time()
        anthropic = self.path.startswith("/anthropic/")
        if anthropic:  # FU-066: the claude-tier leg — strip the prefix, swap the upstream
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
            log(f"POST /route stack={req_body.get('stack')} task={req_body.get('task')} "
                f"role={req_body.get('role')} → {decision['decision']} "
                f"{decision.get('model') or decision.get('reason')} "
                f"[{decision.get('basis') or ''}{'+half-open' if decision.get('half_open') else ''}]")
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
        self._forward(body, note, or_model=or_model, or_provider=or_provider,
                      cb_session=cb_session)


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
    log(f"openrouter-proxy: listening :{PORT} → {UPSTREAM} "
        f"(h={CACHE_HIT}, uptime≥{UPTIME_FLOOR}, max_price×{MAX_PRICE_FACTOR}, "
        f"deadline={REQUEST_DEADLINE_S}s, "
        f"max_tokens_floor={MAX_TOKENS_FLOOR}, market={'on' if MARKET_ENABLE else 'off'}, "
        f"rankings={'on' if ROUTER_ACCOUNT_REF and RANKINGS_POLL_S > 0 else 'off'}, "
        f"semaphore≤{SUBSCRIPTION_MAX_RUNNING}, headroom={HEADROOM_POLL_S}s, "
        f"breaker=auth:{_cb_config()['auth']}/generic:{_cb_config()['generic']})")
    ThreadingHTTPServer(("", PORT), Proxy).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
