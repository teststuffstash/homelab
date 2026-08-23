#!/usr/bin/env bash
# resolve-model — shared resolve step for subscription lanes (G-A 9, issue #782).
#
# Each lane (responder triage, fix-debounce set-pass, retro cells) resolves its model via
# POST /route before spawning.  The script does ONE /route call, fail-OPEN to the literal
# fallback when the proxy is unreachable (an unroutable triage is worse than an unrouted
# one; the responder is an alert lane).  The literal stays the fallback — the deletion
# sweep is a later child of the parent goal.
#
# Explicit override: AGENT_MODEL env var or --model <m> wins over everything (the ADR-096
# override rule for operators/env workflow parameters).
#
# Usage:
#   MODEL="$(bash agents/resolve-model.sh \
#       --role responder --fallback sonnet)"
#   MODEL="$(bash agents/resolve-model.sh \
#       --role dispatch-unit --fallback sonnet)"
#   MODEL="$(bash agents/resolve-model.sh \
#       --role retro --class audit --cell 'claude:opus' --fallback 'claude/opus')"
#
# Output: the model name (single line to stdout).  Diagnostic / loud-fallback lines go
# to stderr so the caller captures only the model.
set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────────
ROLE="" FALLBACK="" CLASS="" CELL="" EXPLICIT_MODEL=""

while [ $# -gt 0 ]; do case "$1" in
  --role)     ROLE="$2"; shift 2;;
  --fallback) FALLBACK="$2"; shift 2;;
  --class)    CLASS="$2"; shift 2;;
  --cell)     CELL="$2"; shift 2;;
  --model)    EXPLICIT_MODEL="$2"; shift 2;;
  --help|-h)
    echo "Usage: resolve-model --role <r> --fallback <m> [--class <c>] [--cell <h:m>] [--model <m>]"
    echo "  --role      lane role (responder, dispatch-unit, retro)"
    echo "  --fallback  literal model used when the proxy is unreachable"
    echo "  --class     class constraint (e.g. audit)"
    echo "  --cell      harness:model cell identifier (retro only, passed as a constraint)"
    echo "  --model     explicit override (wins over everything, same as AGENT_MODEL env)"
    exit 0;;
  *) echo "resolve-model: unknown flag $1" >&2; exit 2;;
esac; done

# ── validate ────────────────────────────────────────────────────────────────────
[ -n "$ROLE" ] || { echo "FATAL: --role is required" >&2; exit 2; }
[ -n "$FALLBACK" ] || { echo "FATAL: --fallback is required" >&2; exit 2; }

# ── explicit override check (operator env / workflow parameter wins) ────────────
OVERRIDE="${AGENT_MODEL:-$EXPLICIT_MODEL}"
if [ -n "$OVERRIDE" ]; then
  echo "→ resolve-model(${ROLE}): explicit override AGENT_MODEL=${OVERRIDE} — routed path skipped" >&2
  printf '%s\n' "$OVERRIDE"
  exit 0
fi

ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"

# ── build the /route payload ────────────────────────────────────────────────────
# Minimal: role + session identity.  The router gets what it needs from the role
# (class policy, role_defaults) and the session namespace avoids collision.
_req="$(jq -nc --arg role "$ROLE" --arg class "$CLASS" --arg cell "$CELL" \
  '{role: $role}
   + (if $class != "" then {class: $class} else {} end)
   + (if $cell != "" then {cell: $cell} else {} end)' 2>/dev/null)" || _req='{}'

# ── POST /route — fail-OPEN ─────────────────────────────────────────────────────
_decision="$(curl -fsS --max-time 5 -H "Content-Type: application/json" \
    -d "$_req" "$ROUTER_URL/route" 2>/dev/null)" || _decision=""

if [ -z "$_decision" ]; then
  # Proxy unreachable — loud line on stderr, fallback on stdout
  echo "⚠️  resolve-model(${ROLE}): ${ROUTER_URL} UNREACHABLE — falling back to literal '${FALLBACK}' (fail-OPEN; an unroutable ${ROLE} is worse than an unrouted one)" >&2
  printf '%s\n' "$FALLBACK"
  exit 0
fi

# ── parse the decision ──────────────────────────────────────────────────────────
_verdict="$(printf '%s' "$_decision" | jq -r '.decision // "?"')"
_rmodel="$(printf '%s' "$_decision" | jq -r '.model // ""')"
_rwhy="$(printf '%s' "$_decision" | jq -r '[.reason, .basis] | map(select(. != null and . != "")) | join(",")')"

echo "→ resolve-model(${ROLE}): router=${_verdict} model=${_rmodel:-—} [${_rwhy}]" >&2

case "$_verdict" in
  dispatch)
    if [ -n "$_rmodel" ]; then
      printf '%s\n' "$_rmodel"
    else
      echo "⚠️  resolve-model(${ROLE}): router dispatched but returned no model — fallback to '${FALLBACK}'" >&2
      printf '%s\n' "$FALLBACK"
    fi
    ;;
  defer)
    echo "⚠️  resolve-model(${ROLE}): router deferred (${_rwhy}) — fallback to literal '${FALLBACK}' (fail-OPEN, the lane keeps running)" >&2
    printf '%s\n' "$FALLBACK"
    ;;
  *)
    echo "⚠️  resolve-model(${ROLE}): unexpected verdict '${_verdict}' — fallback to literal '${FALLBACK}'" >&2
    printf '%s\n' "$FALLBACK"
    ;;
esac
exit 0

# >>>REPLAY:resolve-model>>>
# ── replay-resident block (ADR-103 ratchet for issue #782) ──
# Identical semantics to the standalone resolve-model.sh above, but reads from env vars
# (ROLE, FALLBACK, CLASS, CELL, OVERRIDE) set by the replay bridge, and writes the result
# to RESOLVED_MODEL instead of printf-exit-call.  Diagnostics still go to stderr and are
# captured in the action stream.
#
# Expected env before the block:
#   ROLE, FALLBACK   (required)
#   CLASS, CELL      (optional; constrained route)
#   OVERRIDE         (explicit model override, empty = no override)
#   AGENT_EGRESS_PROXY / AGENT_OPENROUTER_PROXY
#
# After the block:
#   RESOLVED_MODEL   (the model name, or the fallback on failure)
#   RESOLVED_VERDICT (the router verdict text, for post.sh)
#
# NOTE: wrapped in a function so `return` works at the top level of the composed script;
# the function is called once after definition.
resolve_model_block() {
  set -u
  [ -n "${ROLE:-}" ] || { echo "FATAL(replay): ROLE is required" >&2; RESOLVED_MODEL="${FALLBACK:-}"; RESOLVED_VERDICT='missing-role'; return 0; }
  [ -n "${FALLBACK:-}" ] || { echo "FATAL(replay): FALLBACK is required" >&2; RESOLVED_MODEL=''; RESOLVED_VERDICT='missing-fallback'; return 0; }

  # ── explicit override check ──────────────────────────────────────────────────────────
  if [ -n "${OVERRIDE:-}" ]; then
    echo "→ resolve-model(${ROLE}): explicit override AGENT_MODEL=${OVERRIDE} — routed path skipped" >&2
    RESOLVED_MODEL="$OVERRIDE"
    RESOLVED_VERDICT='override'
    return 0
  fi

  ROUTER_URL="${AGENT_EGRESS_PROXY:-${AGENT_OPENROUTER_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}}"

  # ── build the /route payload ──────────────────────────────────────────────────────────
  _req="$(jq -nc --arg role "$ROLE" --arg class "${CLASS:-}" --arg cell "${CELL:-}" \
    '{role: $role}
     + (if $class != "" then {class: $class} else {} end)
     + (if $cell != "" then {cell: $cell} else {} end)' 2>/dev/null)" || _req='{}'

  # ── POST /route — fail-OPEN ───────────────────────────────────────────────────────────
  _decision="$(curl -fsS --max-time 5 -H "Content-Type: application/json" \
      -d "$_req" "$ROUTER_URL/route" 2>/dev/null)" || _decision=""

  if [ -z "$_decision" ]; then
    # Proxy unreachable — loud line on stderr, fallback
    echo "⚠️  resolve-model(${ROLE}): ${ROUTER_URL} UNREACHABLE — falling back to literal '${FALLBACK}' (fail-OPEN; an unroutable ${ROLE} is worse than an unrouted one)" >&2
    RESOLVED_MODEL="$FALLBACK"
    RESOLVED_VERDICT='proxy-unreachable'
    return 0
  fi

  # ── parse the decision ────────────────────────────────────────────────────────────────
  _verdict="$(printf '%s' "$_decision" | jq -r '.decision // "?"')"
  _rmodel="$(printf '%s' "$_decision" | jq -r '.model // ""')"
  _rwhy="$(printf '%s' "$_decision" | jq -r '[.reason, .basis] | map(select(. != null and . != "")) | join(",")')"

  echo "→ resolve-model(${ROLE}): router=${_verdict} model=${_rmodel:-—} [${_rwhy}]" >&2

  case "$_verdict" in
    dispatch)
      if [ -n "$_rmodel" ]; then
        RESOLVED_MODEL="$_rmodel"
      else
        echo "⚠️  resolve-model(${ROLE}): router dispatched but returned no model — fallback to '${FALLBACK}'" >&2
        RESOLVED_MODEL="$FALLBACK"
      fi
      RESOLVED_VERDICT='dispatch'
      ;;
    defer)
      echo "⚠️  resolve-model(${ROLE}): router deferred (${_rwhy}) — fallback to literal '${FALLBACK}' (fail-OPEN, the lane keeps running)" >&2
      RESOLVED_MODEL="$FALLBACK"
      RESOLVED_VERDICT='defer'
      ;;
    *)
      echo "⚠️  resolve-model(${ROLE}): unexpected verdict '${_verdict}' — fallback to literal '${FALLBACK}'" >&2
      RESOLVED_MODEL="$FALLBACK"
      RESOLVED_VERDICT='unexpected-verdict'
      ;;
  esac
}
resolve_model_block
# <<<REPLAY:resolve-model<<<