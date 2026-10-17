"""Starlette app factory (the island's one wiring point)."""

from __future__ import annotations

import contextlib
import logging
import time

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from . import __version__
from .codex import CodexBackend, CodexProxy, CodexRail, openai_responses
from .config import Policy, Settings
from .credentials import CredentialResolver, CredentialSource, KubeSecrets
from .logging import register_literal
from .metrics import Metrics
from .proxy import Proxy, anthropic_messages, openai_chat, openai_models
from .sessions import SessionService, delete_session, get_session, post_sessions
from .store import Store

log = logging.getLogger("gateway.app")


async def healthz(request: Request) -> JSONResponse:
    store: Store = request.app.state.store
    if not store.ping():
        return JSONResponse({"error": {"code": "db-unavailable", "message": "the store does not answer"}}, status_code=503)
    return JSONResponse({"ok": True, "db": store.mode})


async def metrics(request: Request) -> PlainTextResponse:
    return PlainTextResponse(request.app.state.metrics.render(), media_type="text/plain; version=0.0.4; charset=utf-8")


def create_app(
    settings: Settings,
    policy: Policy | None = None,
    source: CredentialSource | None = None,
    store: Store | None = None,
    client: httpx.AsyncClient | None = None,
    clock=time.time,
    codex_backend: CodexBackend | None = None,
) -> Starlette:
    policy = policy or Policy.load(settings.policy_path)
    register_literal(settings.opencode_go_api_key)  # the Go key has no recognisable shape — GW-REDACT masks it by value
    store = store or Store(settings.db_path)
    source = source or KubeSecrets()
    resolver = CredentialResolver(policy, source, settings.opencode_go_api_key, settings.cred_cache_s,
                                  settings.cred_negative_cache_s, clock)
    m = Metrics(policy.stacks)
    m.bind_active_sessions(lambda: store.active_counts(clock()))
    sessions = SessionService(policy, store, resolver, m, settings.self_url, clock)
    client = client or httpx.AsyncClient(
        timeout=httpx.Timeout(connect=settings.connect_timeout_s, read=settings.read_timeout_s, write=60, pool=10),
        follow_redirects=False,
    )
    proxy = Proxy(sessions, m, settings.upstreams, client)
    # The codex rail exists only when the policy declares it; it has a credential backend only when
    # one is handed in (tests: the FAKE store) — production passes none (⚑ gap), so it ships dark.
    codex = (CodexRail(policy.rails["codex"], clock, codex_backend, settings.upstreams.get("codex", ""))
             if "codex" in policy.rails else None)
    sessions.codex = codex
    codex_proxy = CodexProxy(sessions, m, codex, client)

    @contextlib.asynccontextmanager
    async def lifespan(app):
        log.info("agent-gateway %s up: db=%s rails=%s stacks=%s", __version__, store.mode,
                 ",".join(policy.rails), ",".join(policy.stacks))
        try:
            yield
        finally:
            await client.aclose()
            store.close()

    openai_routes = [
        Route("/chat/completions", openai_chat, methods=["POST"]),
        Route("/models", openai_models, methods=["GET"]),
    ]
    app = Starlette(
        routes=[
            Route("/healthz", healthz, methods=["GET"]),
            Route("/metrics", metrics, methods=["GET"]),
            Route("/sessions", post_sessions, methods=["POST"]),
            Route("/sessions/{id}", get_session, methods=["GET"]),
            Route("/sessions/{id}", delete_session, methods=["DELETE"]),
            Route("/anthropic/v1/messages", anthropic_messages, methods=["POST"]),
            # The OpenAI dialect under its contract prefix AND the OpenRouter-shaped `/api/v1`
            # alias: goose computes `$OPENROUTER_HOST/api/v1/…` and opencode's provider baseURL
            # is `<host>/api/v1` today (agent-session.sh), so the alias is what those harnesses
            # reach without a new launcher knob. One handler set, two prefixes.
            # The `responses` dialect (GW-RAIL-CODEX) — the contract prefix only, no `/api/v1` alias.
            Route("/openai/v1/responses", openai_responses, methods=["POST"]),
            *[Route("/openai/v1" + r.path, r.endpoint, methods=list(r.methods or [])) for r in openai_routes],
            *[Route("/api/v1" + r.path, r.endpoint, methods=list(r.methods or [])) for r in openai_routes],
        ],
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.policy = policy
    app.state.store = store
    app.state.resolver = resolver
    app.state.metrics = m
    app.state.sessions = sessions
    app.state.capacity = sessions.capacity
    app.state.proxy = proxy
    app.state.codex = codex
    app.state.codex_proxy = codex_proxy
    return app
