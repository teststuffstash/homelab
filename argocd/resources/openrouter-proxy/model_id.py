#!/usr/bin/env python3
"""The ONE model-id parser (FU-127).

A model id in this platform is overloaded by magic prefix, and every consumer re-derived the rules
inline: the launcher (twice), research-fanout, estimate_budget and the egress proxy. That is how
`openrouter/owl-alpha` — OpenRouter's own CLOAKED-model namespace — ends up looking like a rail
prefix, and how a future rail (local vLLM, say) has nowhere to live.

The shape is `{rail, harness, model}`:

  rail     WHERE the completion is bought:   openrouter | anthropic-subscription | opencode-go
  harness  WHICH binary runs the ride:       claude | "" (= caller's default: goose/opencode)
  model    what the rail is asked for, in ITS OWN namespace

Rules, in one place, ordered:

  claude/<alias>              → anthropic-subscription, harness claude, model <alias>
                                (FU-066: the claim carries no harness field, so the tier rides the
                                 string; an explicit --harness still wins at the caller)
  opencode-go/<model>         → opencode-go, harness claude, model UNCHANGED (prefix KEPT: the
                                 egress proxy keys the Go rail on the body's model prefix and
                                 strips it itself — openrouter-proxy.py GO_PREFIX; ADR-107, the
                                 reviewer failover proved the wire shape on PR#437)
  openrouter/<vendor>/<model> → openrouter, model <vendor>/<model>      (rail prefix, stripped)
  openrouter/<codename>       → openrouter, model openrouter/<codename> (CLOAKED — prefix KEPT:
                                 the id genuinely lives under that namespace upstream)
  <vendor>/<model>            → openrouter, model unchanged             (the common case)

The string form stays canonical in claims and `agents/stacks.json`; this parser is the compatibility
layer that lets consumers stop guessing. A structured claim field is the remaining FU-127 leg.

The SECOND rule this file owns is the provider-routing suffix (`<vendor>/<model>:<suffix>`): the
suffix pins ROUTING, never price, so it is never part of a lookup or bookkeeping KEY. `base_id` /
`lookup_ids` are the pricing half (a MISS drives the retry), `strip_routing_suffix` the bookkeeping
half (the suffix this platform's own router appends). See the section below.

Use from shell:  eval "$(python3 agents/model_id.py --shell "$MODEL")"   # MODEL_RAIL/_HARNESS/_MODEL
Use from python: from model_id import parse
"""
from __future__ import annotations

import json
import shlex
import sys

RAIL_OPENROUTER = "openrouter"
RAIL_SUBSCRIPTION = "anthropic-subscription"
RAIL_OPENCODE_GO = "opencode-go"


def parse(model_id: str) -> dict[str, str]:
    """`{rail, harness, model}` for a model id. Never raises: an empty/odd id parses as an
    OpenRouter model unchanged, because refusing here would break dispatch on a typo the caller
    can see for itself in the pod log."""
    raw = (model_id or "").strip()
    if raw.startswith("claude/"):
        return {"rail": RAIL_SUBSCRIPTION, "harness": "claude", "model": raw[len("claude/"):]}
    if raw.startswith("opencode-go/"):
        # The Go subscription rail (ADR-107): claude is the one harness, and the FULL id rides —
        # the proxy routes /anthropic/* requests by this prefix and strips it before forwarding.
        return {"rail": RAIL_OPENCODE_GO, "harness": "claude", "model": raw}
    if raw.startswith("openrouter/"):
        rest = raw[len("openrouter/"):]
        # A remaining "/" means vendor/model — the prefix was OUR rail marker. No "/" means the
        # id itself lives in OpenRouter's namespace (a cloaked codename): keep it whole.
        return {"rail": RAIL_OPENROUTER, "harness": "", "model": rest if "/" in rest else raw}
    return {"rail": RAIL_OPENROUTER, "harness": "", "model": raw}


def is_subscription(model_id: str) -> bool:
    return parse(model_id)["rail"] == RAIL_SUBSCRIPTION


# ── Provider-routing suffixes: the strip rule's ONE home (homelab#1670, #1697) ───────────────────
# OpenRouter overloads an id with a colon-suffix shorthand that pins ROUTING, never PRICE, and the
# registry keys a model by its BARE id. So an id this platform's own router appends — `:exacto`,
# from the FU-186 `provider_policy` on the coding class — used to miss every lookup in
# `agents/estimate_budget.py`, price at the conservative $1.0/M default and print a PHANTOM
# `⚠ ESCALATE`: 31× the real price on the #1665 ride, which a coordinator following
# `agents/coordinator/README.md` step 3 ("stop, label agent/blocked") turns into every queued item
# on the stack parked for a human, with correct numbers and a wrong conclusion.
#
# Both halves of the rule live HERE, and every consumer imports them (#1697): the PRICING half
# retries a MISS (`base_id`/`lookup_ids` — the registry read, the static table and `--lookup`'s
# report all go through them, so those three can never disagree about what an id costs), and the
# BOOKKEEPING half strips the suffix OUR router appends (`strip_routing_suffix` — the cooldown /
# breaker key must be the chain id the /route eligibility loop filters candidates against).
#
# The retry is MISS-DRIVEN, and that is the whole safety argument: the id AS GIVEN is tried first
# against the registry and the static table, and only an id NOTHING carries is retried as its base.
# `:free` is therefore never degraded to its paid sibling — it is a variant OpenRouter lists in its
# own right (`tencent/hy3:free`), priced as itself while any table still carries it, and it is a
# chain id in its own right too, which is why `strip_routing_suffix` leaves it whole — and a
# genuinely unknown model still reaches the $1.0/M default and can still escalate.
def base_id(model: str) -> str | None:
    """`model` truncated at its last `:` — the id a lookup RETRIES when nothing carries `model`
    itself. Pricing-only: the suffix pins provider routing, so the FULL id stays the dispatch id
    (`Estimate.model`, the claim, the routed model)."""
    base, sep, _suffix = model.rpartition(":")
    return base if sep and base else None


def base_ids(model: str) -> list[str]:
    """Every id `model` reduces to by dropping ONE colon-suffix at a time, nearest first (#1693's
    doubled `:exacto` on a pre-suffixed chain entry reduces to the paid id, and `tencent/hy3:free`
    reduces to `tencent/hy3` only AFTER itself has been tried)."""
    out: list[str] = []
    rest = base_id(model)
    while rest and rest not in out:
        out.append(rest)
        rest = base_id(rest)
    return out


def lookup_ids(model: str) -> list[str]:
    """The ids a PRICE lookup tries for `model`, in order: the id as given, its rail-normalized
    form, then each one's successive base ids — best first, never degrading an id a table already
    carries."""
    out: list[str] = []
    for candidate in (model, parse(model)["model"]):
        for one in (candidate, *base_ids(candidate)):
            if one and one not in out:
                out.append(one)
    return out


def routing_suffix(model: str, priced: str) -> str | None:
    """The routing suffix `priced` dropped from `model` (e.g. ':exacto'), or None when `priced` is
    not `model`'s base id — a rail prefix normalized away is NOT a routing suffix. Both sides are
    normalized, so `priced` may be a candidate carrying the rail prefix itself."""
    normalized, base = parse(model)["model"], parse(priced)["model"]
    return normalized[len(base):] if base and normalized.startswith(base + ":") else None


# The suffixes THIS platform's router appends to a pick (`route()`: the class's `provider_policy`),
# i.e. the closed set a BOOKKEEPING key may drop. OpenRouter's shorthand family is wider — `:nitro`
# (throughput ordering), `:floor` (price ordering), `:online` (the web plugin) — and a second
# appended shorthand adds its name HERE, in the one home, never at a call site.
ROUTING_SUFFIXES = (":exacto",)


def strip_routing_suffix(model: str) -> str:
    """`model` without ONE routing suffix (`ROUTING_SUFFIXES`), unchanged when it carries none —
    the BOOKKEEPING half of the strip rule. A cooldown/breaker row is keyed under the id the
    /route eligibility loop filters candidates against, and a VARIANT (`:free`) IS that chain id,
    so it stays whole: `base_id` truncates ANY suffix because there a miss drives the retry, while
    this drops only what the router itself appended."""
    base = base_id(model)
    if base is None:
        return model
    return base if model[len(base):] in ROUTING_SUFFIXES else model


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    shell = argv[1] == "--shell"
    ids = argv[2:] if shell else argv[1:]
    if shell:
        if len(ids) != 1:
            print("--shell takes exactly one model id", file=sys.stderr)
            return 2
        p = parse(ids[0])
        # Quoted: a model id is untrusted text (it comes from a claim/issue label).
        print(f"MODEL_RAIL={shlex.quote(p['rail'])} "
              f"MODEL_HARNESS={shlex.quote(p['harness'])} "
              f"MODEL_MODEL={shlex.quote(p['model'])}")
        return 0
    print(json.dumps([parse(i) for i in ids] if len(ids) > 1 else parse(ids[0])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
