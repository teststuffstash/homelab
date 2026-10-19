"""The OpenRouter rail's provider axis (GW-RAIL-OPENROUTER §Attribution / §Selection / §Failover,
specs/endpoints/openai-chat.md; operator rulings 2026-10-19, homelab#2741).

`:exacto` is NOT ported: the gateway attributes every openrouter answer to the provider that
served it (the response's `provider`), selects the provider itself from the endpoint snapshot
and its own outcome evidence, and relaunches a failed provider transparently — at the REQUEST
level, before the first byte, never after one was relayed.

- **The endpoint snapshot** — per model, the rows of `GET /api/v1/models/<id>/endpoints`
  (`parse_endpoints`), kept in the store under `catalog_snapshots.openrouter-endpoints`. Who
  writes it is the catalog leg (homelab#2742); this module only reads it. No snapshot for a
  model = no selection on it (the request rides unpinned, attribution only).
- **Eligibility** (`eligible`): one representative endpoint per PROVIDER (the tag's base slug,
  what `provider.order` names — `deepinfra`, never the display name; the 2026-07-09 lesson), kept
  only when it supports every tool-choice mode the session's harness uses, its quantization
  clears the policy floor (`unknown` is excluded), its uptime_last_1d clears the floor and its
  status is 0. Every threshold is `rails.openrouter.providers` policy data.
- **Order** (`order`): price × (1 / the cell's clean-ride rate from the outcome store); while a
  cell has fewer than `min_rides` judged rides, its uptime is the prior; p90 latency breaks ties.
- **Attribution** (`attribute`, `slug_for`): the response's `provider` (a chat completion's top
  level, the first SSE chunk's, an error's `metadata.provider_name`) joined to the snapshot's
  provider_name → slug; a name the snapshot lacks is slugged by rule (lower-case, runs of
  non-alphanumerics → `-`), never a table.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass

from .store import Store

log = logging.getLogger("gateway.providers")

SNAPSHOT_SOURCE = "openrouter-endpoints"  # the store's catalog_snapshots row
TOOL_CHOICE_MODES = ("none", "auto", "required", "function")
UNATTRIBUTED = "unattributed"  # the metrics label when no answer named a provider
_SLUG_RE = re.compile(r"[^a-z0-9]+")


class ParseError(ValueError):
    """The endpoints answer is not the shape this parser knows — never a guess."""


@dataclass(frozen=True)
class Endpoint:
    slug: str  # the tag's base — what `provider.order` names; the cell's provider key
    tag: str
    provider_name: str  # the display name a response's `provider` carries
    quantization: str
    tool_choice: dict[str, bool]
    uptime_1d: float
    p90_ms: float | None
    in_price: float | None  # $ per 1M tokens
    out_price: float | None
    status: int
    service_tier: str | None


def _num(where: str, v, *, optional: bool = False) -> float | None:
    if v is None and optional:
        return None
    if isinstance(v, bool):
        raise ParseError(f"{where} is a boolean")
    try:
        return float(v)
    except (TypeError, ValueError) as e:
        raise ParseError(f"{where} is not a number: {v!r}") from e


def _per_million(where: str, v) -> float | None:
    f = _num(where, v, optional=True)
    if f is None:
        return None
    if f < 0:
        return None  # a negative = dynamic pricing = no price (the tier derivation's rule)
    return round(f * 1_000_000, 9)


def parse_endpoints(doc) -> dict:
    """The raw `GET /api/v1/models/<id>/endpoints` answer → `{model, endpoints: [row…]}` (the
    snapshot's per-model entry). Strict: a row that lacks a field this module reads fails the
    whole parse. Prices are the API's $/token strings, scaled to $/1M."""
    if not isinstance(doc, dict) or not isinstance(doc.get("data"), dict):
        raise ParseError("no `data` object")
    data = doc["data"]
    model = data.get("id")
    if not isinstance(model, str) or not model:
        raise ParseError("no `data.id`")
    eps = data.get("endpoints")
    if not isinstance(eps, list) or not eps:
        raise ParseError(f"{model}: `data.endpoints` is not a non-empty list")
    rows: list[dict] = []
    for i, e in enumerate(eps):
        where = f"{model}.endpoints[{i}]"
        if not isinstance(e, dict):
            raise ParseError(f"{where} is not an object")
        tag = e.get("tag")
        if not isinstance(tag, str) or not tag:
            raise ParseError(f"{where}.tag is not a non-empty string")
        name = e.get("provider_name")
        if not isinstance(name, str) or not name:
            raise ParseError(f"{where}.provider_name is not a non-empty string")
        quant = e.get("quantization")
        if not isinstance(quant, str) or not quant:
            raise ParseError(f"{where}.quantization is not a non-empty string")
        tc = e.get("supports_tool_choice")
        if not isinstance(tc, dict) or set(tc) != set(TOOL_CHOICE_MODES) or any(not isinstance(v, bool) for v in tc.values()):
            raise ParseError(f"{where}.supports_tool_choice is not {{{', '.join(TOOL_CHOICE_MODES)}}} of booleans")
        pricing = e.get("pricing")
        if not isinstance(pricing, dict):
            raise ParseError(f"{where}.pricing is not an object")
        lat = e.get("latency_last_30m")
        if lat is not None and not isinstance(lat, dict):
            raise ParseError(f"{where}.latency_last_30m is neither null nor an object")
        tier = e.get("service_tier")
        if tier is not None and not isinstance(tier, str):
            raise ParseError(f"{where}.service_tier is neither null nor a string")
        status = e.get("status")
        if isinstance(status, bool) or not isinstance(status, int):
            raise ParseError(f"{where}.status is not an integer")
        rows.append({
            "slug": tag.split("/")[0],
            "tag": tag,
            "provider_name": name,
            "quantization": quant,
            "tool_choice": {m: tc[m] for m in TOOL_CHOICE_MODES},
            "uptime_1d": _num(f"{where}.uptime_last_1d", e.get("uptime_last_1d")),
            "p90_ms": _num(f"{where}.latency_last_30m.p90", (lat or {}).get("p90"), optional=True),
            "in_price": _per_million(f"{where}.pricing.prompt", pricing.get("prompt")),
            "out_price": _per_million(f"{where}.pricing.completion", pricing.get("completion")),
            "status": status,
            "service_tier": tier,
        })
    return {"model": model, "endpoints": rows}


def _row(d: dict) -> Endpoint:
    return Endpoint(d["slug"], d["tag"], d["provider_name"], d["quantization"], dict(d["tool_choice"]), float(d["uptime_1d"]),
                    d.get("p90_ms"), d.get("in_price"), d.get("out_price"), int(d["status"]), d.get("service_tier"))


def representatives(endpoints: list[Endpoint]) -> dict[str, Endpoint]:
    """One endpoint per PROVIDER: `provider.order` names the tag's base slug, so a provider's
    service tiers (`deepinfra/fp8`, `deepinfra/fp8/flex`, `deepinfra/fp8/priority`) are one
    order entry — the representative is the one the vendor routes to by default: no
    `service_tier`, then the shortest tag ⚖."""
    out: dict[str, Endpoint] = {}
    for e in sorted(endpoints, key=lambda e: (e.service_tier is not None, len(e.tag), e.tag)):
        out.setdefault(e.slug, e)
    return out


def slug_from_display(name: str) -> str:
    """The attribution fallback for a provider name the snapshot lacks: a RULE, never a table."""
    return _SLUG_RE.sub("-", name.strip().lower()).strip("-")


def attribute(body: bytes, streaming: bool) -> str | None:
    """The serving provider's display name as the openrouter answer states it: a chat
    completion's / a Messages answer's top-level `provider`; for a stream, the first data chunk
    that carries one; for an error envelope, `error.metadata.provider_name`. None = unnamed."""
    if not body:
        return None
    try:
        if not streaming:
            doc = json.loads(body)
            return _provider_of(doc)
        for line in body.decode("utf-8", errors="replace").splitlines():
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                ev = json.loads(payload)
            except ValueError:
                continue
            p = _provider_of(ev)
            if p:
                return p
    except (ValueError, AttributeError, TypeError):
        return None
    return None


def _provider_of(doc) -> str | None:
    if not isinstance(doc, dict):
        return None
    p = doc.get("provider")
    if isinstance(p, str) and p:
        return p
    err = doc.get("error")
    if isinstance(err, dict):
        meta = err.get("metadata")
        if isinstance(meta, dict) and isinstance(meta.get("provider_name"), str) and meta["provider_name"]:
            return meta["provider_name"]
    return None


def provider_error(body: bytes) -> bool:
    """A 4xx whose JSON error names the provider that produced it (`error.metadata.provider_name`
    — OpenRouter's wrap of a provider's own refusal, a refused tool call among them)."""
    try:
        doc = json.loads(body)
    except ValueError:
        return False
    err = doc.get("error") if isinstance(doc, dict) else None
    meta = err.get("metadata") if isinstance(err, dict) else None
    return isinstance(meta, dict) and bool(meta.get("provider_name"))


class EndpointSnapshot:
    """The store's last snapshot of the openrouter endpoints, per model (written by the catalog
    leg — homelab#2742; this reads it). `endpoints(model)` is None when the snapshot does not
    cover the model: the request rides unpinned."""

    def __init__(self, store: Store):
        self.store = store
        self.fetched_at: float | None = None
        self.models: dict[str, list[Endpoint]] = {}
        self.reload()

    def reload(self) -> None:
        row = self.store.snapshot_load(SNAPSHOT_SOURCE)
        if row is None:
            self.fetched_at, self.models = None, {}
            return
        try:
            self.models = {mid: [_row(d) for d in entry["endpoints"]] for mid, entry in row[1]["models"].items()}
            self.fetched_at = row[0]
        except (KeyError, TypeError, ValueError, AttributeError):
            log.error("providers: the stored %s snapshot is not this build's shape — ignored", SNAPSHOT_SOURCE)
            self.fetched_at, self.models = None, {}

    def endpoints(self, model: str) -> list[Endpoint] | None:
        return self.models.get(model)

    def slugs(self) -> set[str]:
        return {e.slug for eps in self.models.values() for e in eps}

    def slug_for(self, model: str, display: str) -> str:
        """A response's `provider` (display name) → the cell's provider key: the snapshot's join
        on provider_name, else the rule."""
        for e in self.models.get(model) or ():
            if e.provider_name == display:
                return e.slug
        return slug_from_display(display)


def eligible(endpoints: list[Endpoint], pol, harness: str) -> tuple[list[Endpoint], dict[str, str]]:
    """The representatives that pass the policy's floors for `harness`, and why each other
    provider was dropped (`{slug: reason}` — for the log line and the admission detail)."""
    ladder = {q: i for i, q in enumerate(pol.quantization_ladder)}
    floor = ladder[pol.quantization_floor]
    modes = pol.tool_choice.get(harness, ())
    kept: list[Endpoint] = []
    dropped: dict[str, str] = {}
    for slug, e in representatives(endpoints).items():
        missing = [m for m in modes if not e.tool_choice.get(m)]
        if missing:
            dropped[slug] = f"no tool_choice {','.join(missing)}"
        elif e.quantization not in ladder:
            dropped[slug] = f"quantization {e.quantization}"
        elif ladder[e.quantization] < floor:
            dropped[slug] = f"quantization {e.quantization} < {pol.quantization_floor}"
        elif e.uptime_1d < pol.uptime_1d_floor:
            dropped[slug] = f"uptime_1d {e.uptime_1d:g} < {pol.uptime_1d_floor:g}"
        elif e.status != 0:
            dropped[slug] = f"status {e.status}"
        else:
            kept.append(e)
    return kept, dropped


def clean_rate(e: Endpoint, stats: dict[str, tuple[int, int]], min_rides: int) -> tuple[float, str]:
    """(rate, basis): the cell's measured clean-ride rate once it has `min_rides` judged rides,
    else its uptime as the prior ⚖."""
    clean, total = stats.get(e.slug, (0, 0))
    if total >= min_rides:
        return clean / total, f"measured {clean}/{total}"
    return e.uptime_1d / 100.0, f"prior uptime {e.uptime_1d:g} ({total} judged rides)"


def order(candidates: list[Endpoint], stats: dict[str, tuple[int, int]], pol, exclude: set[str] = frozenset(),
          cooled: set[str] = frozenset()) -> list[Endpoint]:
    """Cheapest cost per CLEAN ride first: output price ÷ the cell's clean rate (input price,
    p90 latency, slug break ties ⚖); struck and cooled providers are left out."""
    def key(e: Endpoint):
        rate, _ = clean_rate(e, stats, pol.min_rides)
        price = e.out_price if e.out_price is not None else float("inf")
        return (price / max(rate, 1e-6), e.in_price if e.in_price is not None else float("inf"),
                e.p90_ms if e.p90_ms is not None else float("inf"), e.slug)

    return sorted((e for e in candidates if e.slug not in exclude and e.slug not in cooled), key=key)


def pin(body: bytes, slug: str) -> bytes:
    """The request body with `provider: {order: [slug], allow_fallbacks: false}` — one provider
    per attempt, so a failure is attributable; the gateway, not the vendor, moves to the next."""
    doc = json.loads(body) if body else {}
    doc["provider"] = {"order": [slug], "allow_fallbacks": False}
    return json.dumps(doc, separators=(",", ":")).encode()
