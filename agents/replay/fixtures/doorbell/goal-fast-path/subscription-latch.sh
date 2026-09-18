#!/usr/bin/env bash
# Latch passes — the fast path must reach the dispatch to prove goal units are accepted.
# #439 leg 3: the coordinator sites call `--pick-rail`, whose contract is "rail on stdout,
# diagnostics on stderr, exit 1 = both latched" (agents/subscription-latch.sh). Stay latch-passing
# on the Anthropic rail so the fixture still exercises the path it was built for.
case "${1:-}" in --pick-rail) echo "anthropic";; esac

exit 0
