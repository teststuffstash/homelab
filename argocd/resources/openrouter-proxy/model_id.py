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
