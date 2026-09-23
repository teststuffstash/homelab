#!/usr/bin/env bash
# Worker-authored + latch-passing: the dispatching legs must reach the pod probes and the handoff
# to prove the holds released. A non-zero here would defer on capacity and never test them.
# `--pick-rail`'s contract is "rail on stdout, diagnostics on stderr, exit 1 = both latched"
# (agents/subscription-latch.sh) — stay latch-passing on the Anthropic rail.
case "${1:-}" in --pick-rail) echo "anthropic";; esac

exit 0
