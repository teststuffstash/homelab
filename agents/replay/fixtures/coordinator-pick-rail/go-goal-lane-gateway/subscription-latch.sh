#!/usr/bin/env bash
# Anthropic latched, Go clear — the real script's contract: rail on stdout, diagnostic on stderr.
case "${1:-}" in --pick-rail)
  echo "opencode-go/deepseek-v4-flash"
  echo "→ Anthropic latched — Go rail clear (opencode-go/deepseek-v4-flash)" >&2 ;;
esac
exit 0
