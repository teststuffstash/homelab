#!/usr/bin/env bash
# Launch a jail Claude Code session with OpenCode Go models on the subagent slots.
#
# The claude-or pattern (sleep-tracking/claude-or) generalized through the local model-splitting
# shim (scripts/claude-model-shim.py): the MAIN loop stays on the operator's Anthropic
# subscription (requests pass through the shim verbatim), while the alias slots the Agent tool
# selects per-call — haiku for small tasks, sonnet for larger — are remapped to Go models at
# launch. Mapping is launch-time (the CLI resolves aliases via env once); SELECTION among the
# mapped slots stays per-call and mid-session.
#
#   claude-go                        # fable main + Go subagents (default slot map below)
#   SLOT_HAIKU=opencode-go/deepseek-v4-flash claude-go   # override a slot
#   CLAUDE_GO_ALL=1 claude-go        # map the MAIN model too — the pure Go trial session
#
# Prereq: the wallet string `opencode-go-api-key` (operator-minted at opencode.ai/auth — a
# sanctioned third-party-console step, docs/secrets.md §Minting doctrine).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${SHIM_PORT:-18091}"

# Slot map / overrides from the repo-local env file (the claude-or .openrouter.env pattern;
# gitignored — the repo is public, and the file MAY carry SHIM_GO_KEY as a wallet bypass).
[ ! -f "$HERE/../.opencode-go.env" ] || { set -a; . "$HERE/../.opencode-go.env"; set +a; }

# tail -n1: devbox's python plugin prints venv-creation noise to STDOUT on the jail's first
# `devbox run` (DEVBOX_QUIET doesn't cover plugins) — the secret is always the last line.
_kp() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli show -q --no-password \
          -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password \
          "$HOME/.claude/homelab-keepass/homelab.kdbx" "$1" 2>/dev/null | tail -n1; }

GO_KEY="${SHIM_GO_KEY:-$(_kp opencode-go-api-key || true)}"
# ⚠ An empty read is a claim about the PROBE, not the wallet (2026-08-13: a gutted devbox.lock
# made every devbox run fail, and this message blamed a wallet entry that was present — the
# operator went hunting the wrong thing). Say both possibilities; name the bypass.
[ -n "$GO_KEY" ] || { echo "claude-go: no Go key — the wallet read returned EMPTY. Either the entry 'opencode-go-api-key' is missing (mint at opencode.ai/auth) OR devbox/keepassxc failed here (run the _kp line by hand to tell). Bypass: put SHIM_GO_KEY=<key> in .opencode-go.env" >&2; exit 1; }

# The shim is shared across sessions: reuse a listener if one is up, else start one.
if ! { exec 3<>"/dev/tcp/127.0.0.1/${PORT}"; } 2>/dev/null; then
  SHIM_GO_KEY="$GO_KEY" SHIM_PORT="$PORT" \
    nohup python3 "$HERE/claude-model-shim.py" >>"${TMPDIR:-/tmp}/claude-model-shim.log" 2>&1 &
  sleep 0.5
else
  exec 3>&-
fi

# Slot map — tool-probed against the live rail 2026-08-13 (chainless-redesign.md §Go rail):
# the Anthropic-compat tool path is PER-MODEL — glm* 422s every function tool, deepseek* is
# region-locked (403), kimi-k2.x compat-broken — and cached-read price is what decides whether
# a lane fits the $30/wk window. The picks tool-call cleanly (tool_use round-trip verified).
SLOT_HAIKU="${SLOT_HAIKU:-opencode-go/qwen3.5-plus}"   # $0.02/M cached read
SLOT_SONNET="${SLOT_SONNET:-opencode-go/kimi-k3}"      # $0.30/M cached read
SLOT_OPUS="${SLOT_OPUS:-opencode-go/qwen3.8-max}"      # qwen-max class, ~$0.50/M cached read

# Best-effort slot verification against the live catalog (never blocks the launch).
if CAT="$(curl -fsS -m 5 -H "Authorization: Bearer ${GO_KEY}" -H "x-api-key: ${GO_KEY}" \
          https://opencode.ai/zen/go/v1/models 2>/dev/null)"; then
  for s in "$SLOT_HAIKU" "$SLOT_SONNET" "$SLOT_OPUS"; do
    printf '%s' "$CAT" | grep -q "${s#opencode-go/}" \
      || echo "claude-go: ⚠ slot model '${s}' not found in the live /models catalog" >&2
  done
else
  echo "claude-go: (catalog unreachable — slot ids unverified this run)" >&2
fi

# Everything except the MAIN model is mapped (operator direction 2026-08-13): all three alias
# slots + the subagent default ride Go; the main model (fable) stays on the subscription via
# passthrough. CLAUDE_GO_ALL=1 maps the main model too — the pure Go trial session.
export ANTHROPIC_BASE_URL="http://127.0.0.1:${PORT}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SLOT_HAIKU"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$SLOT_SONNET"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$SLOT_OPUS"
export CLAUDE_CODE_SUBAGENT_MODEL="${CLAUDE_CODE_SUBAGENT_MODEL:-$SLOT_HAIKU}"
if [ "${CLAUDE_GO_ALL:-0}" = "1" ]; then
  export ANTHROPIC_MODEL="$SLOT_SONNET"
fi

echo "claude-go: shim :${PORT} | haiku→${SLOT_HAIKU} sonnet→${SLOT_SONNET} opus→${SLOT_OPUS} | main $( [ "${CLAUDE_GO_ALL:-0}" = 1 ] && echo "GO (${SLOT_SONNET})" || echo 'subscription (passthrough)' )" >&2
exec claude "$@"
