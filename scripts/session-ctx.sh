#!/usr/bin/env bash
# session-ctx — real context/spend numbers for a RUNNING jail session, from its own transcript.
#
#   bash scripts/session-ctx.sh                 # current ctx + session totals (statusbar parity)
#   bash scripts/session-ctx.sh --turns         # per-assistant-turn growth ledger
#   bash scripts/session-ctx.sh --big 20000     # turns that ADDED ≥N tokens, attributed to the
#                                               # tool calls that preceded them (the corpus-
#                                               # trimming view: which Read cost what, measured)
#   bash scripts/session-ctx.sh --session <id>  # a specific session (default: newest jsonl —
#                                               # the running session, since it writes constantly)
#
# WHY NO OTEL / NO MCP (operator question, 2026-08-19): the statusline computes everything it
# shows FROM the transcript (latest assistant usage block = ctx; a 5h find-sum = window burn) —
# the payload adds only the API-learned rate_limits. The data was always local; a session that
# wants its own numbers reads its own JSONL. OTLP (CLAUDE_CODE_ENABLE_TELEMETRY=1) already
# ships per-request metrics for the CROSS-session dashboards; this script is the IN-session
# half, and per-turn cache_creation_input_tokens is the measured price of each read — what the
# corpus diet needs instead of estimates.
#
# ⚠ One API response is SPLIT across multiple JSONL entries when a turn makes parallel tool
# calls — each entry repeats the same message.id + usage block, so every mode dedups on
# message.id before summing (found on this script'"'"'s own first run: 306 raw entries vs real
# turns, cache-creation double-counted).
#
# Reading the columns: ctx = cache_read + cache_creation + input + output of a turn (what the
# statusbar shows); +cache_creation = tokens NEWLY written to cache that turn ≈ context ADDED
# since the previous turn (tool results + user text). Attribution: the content an assistant
# turn pays cache_creation for arrived BETWEEN it and the previous assistant turn — i.e. the
# previous turn's tool calls' results — so --big names those calls.
set -uo pipefail

DIR="${SESSION_CTX_DIR:-$HOME/.claude/projects/-workspace-homelab}"
MODE="now"; BIG=20000; SID=""
while [ $# -gt 0 ]; do case "$1" in
  --turns) MODE=turns; shift;;
  --big)
    # optional numeric N: bare `--big` keeps the 20000 default. NEVER `shift 2` here — with
    # only `--big` left, bash's shift-past-end is an unchanged-args NO-OP (nonzero, uncaught
    # without -e), so $1 stays `--big` and the while loop busy-hangs (bot catch, PR#584 r1).
    MODE=big; shift
    case "${1:-}" in ''|*[!0-9]*) : ;; *) BIG="$1"; shift ;; esac
    ;;
  --session) SID="$2"; shift 2;;
  *) echo "session-ctx: unknown flag $1" >&2; exit 64;;
esac; done

if [ -n "$SID" ]; then
  T="$DIR/$SID.jsonl"
else
  T="$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -1)"
fi
[ -f "${T:-}" ] || { echo "session-ctx: no transcript found in $DIR" >&2; exit 1; }

case "$MODE" in
  now)
    jq -rs '
      [ .[] | select(.type=="assistant" and .message.usage != null) ]
      | [group_by(.message.id)[] | .[0].message.usage] as $u
      | if ($u|length)==0 then "no assistant turns yet" else
        ($u[-1]) as $last
        | ($last.cache_read_input_tokens//0)+($last.cache_creation_input_tokens//0)
          +($last.input_tokens//0)+($last.output_tokens//0) | . as $ctx
        | ([$u[].output_tokens//0]|add) as $out
        | ([$u[].cache_creation_input_tokens//0]|add) as $cc
        | ([$u[].cache_read_input_tokens//0]|add) as $cr
        | "session \("'"$(basename "$T" .jsonl)"'")\nctx now: \($ctx) tokens\nturns: \($u|length) · output total: \($out) · cache-creation total: \($cc) · cache-read total: \($cr)"
        end' "$T"
    ;;
  turns)
    jq -rs '[ .[] | select(.type=="assistant" and .message.usage != null) ]
      | [group_by(.message.id)[] | .[0]] | sort_by(.timestamp) | .[]
      | .message.usage as $u
      | ((.timestamp//"")[11:19]) + "  ctx=" +
        ((($u.cache_read_input_tokens//0)+($u.cache_creation_input_tokens//0)+($u.input_tokens//0)+($u.output_tokens//0))|tostring)
        + "  +creation=" + (($u.cache_creation_input_tokens//0)|tostring)
        + "  out=" + (($u.output_tokens//0)|tostring)' "$T"
    ;;
  big)
    # Attribute each big cache_creation to the PREVIOUS assistant turn's tool calls.
    jq -rs --argjson big "$BIG" '
      [ .[] | select(.type=="assistant" and .message.usage != null) ]
      | [group_by(.message.id)[]
         | { ts: .[0].timestamp, usage: .[0].message.usage,
             tools: [ .[].message.content[]? | select(.type=="tool_use")
                      | .name + "(" + ((.input.file_path // .input.command // .input.pattern // .input.skill // "") | tostring | .[0:90]) + ")" ] } ]
      | sort_by(.ts) as $a
      | range(1; $a|length) as $i
      | ($a[$i].usage.cache_creation_input_tokens // 0) as $cc
      | select($cc >= $big)
      | (($a[$i].ts//"")[11:19]) + "  +" + ($cc|tostring) + "  ← "
        + (if ($a[$i-1].tools|length)==0 then "(user/system text)" else ($a[$i-1].tools|join(" + ")) end)
      ' "$T"
    ;;
esac
