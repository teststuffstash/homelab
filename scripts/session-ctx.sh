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
#   bash scripts/session-ctx.sh --startup       # the STATIC context every seat session pays before
#                                               # its first turn (CLAUDE.md + the composed cards +
#                                               # MEMORY.md + every skill's frontmatter) and the
#                                               # design-agents read plan — bytes and a 4-chars/token
#                                               # estimate, per file. Needs no transcript: this is
#                                               # the budget line the trims are measured against.
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
  --startup) MODE=startup; shift;;
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

if [ "$MODE" = startup ]; then
  # Static startup context — what Claude Code injects before the first user turn. Paths are
  # the jail's: the repo root is the seat's cwd, the cards are composed by the jail entrypoint
  # (claude-jail tools/jail-entrypoint.sh), MEMORY.md is the auto-memory index (only its first
  # 200 lines load). Skill bodies are NOT counted: they load on invocation — only the
  # frontmatter (name + description) sits in every session. Token estimate = bytes/4.
  REPO="$(cd "$(dirname "$0")/.." && pwd)"
  MEM="${SESSION_CTX_MEMORY:-$HOME/.claude/projects/-workspace-homelab/memory/MEMORY.md}"
  total=0
  row() { # label bytes
    printf '%8d B  ~%6d tok  %s\n' "$2" "$(( $2 / 4 ))" "$1"; total=$(( total + $2 )); }
  fsize() { [ -f "$1" ] && wc -c <"$1" || echo 0; }
  echo "== static startup context (auto-injected, every seat session) =="
  row "CLAUDE.md" "$(fsize "$REPO/CLAUDE.md")"
  row "CLAUDE.local.md (jail card + seat card; 0 = not composed here, i.e. a clone or the host)" "$(fsize "$REPO/CLAUDE.local.md")"
  row "/workspace/CLAUDE.md (claude-jail)" "$(fsize /workspace/CLAUDE.md)"
  row "/workspace/CLAUDE.local.md (jail card)" "$(fsize /workspace/CLAUDE.local.md)"
  row "MEMORY.md (auto-memory index, $(fsize "$MEM" >/dev/null; wc -l <"$MEM" 2>/dev/null || echo 0) lines)" "$(fsize "$MEM")"
  fm=0
  for f in "$REPO"/.claude/skills/*/SKILL.md; do
    n=$(awk '/^---$/{c++; next} c==1' "$f" | wc -c); fm=$(( fm + n ))
  done
  row "skill frontmatter × $(ls -d "$REPO"/.claude/skills/*/ | wc -l) skills (descriptions only)" "$fm"
  printf '%8d B  ~%6d tok  TOTAL before the first turn\n' "$total" "$(( total / 4 ))"
  echo
  echo "== design-agents read plan (paid only on an operator-typed /design-agents) =="
  plan=0
  for f in "$REPO"/CONTEXT.md "$REPO"/ARCHITECTURE.md "$REPO"/docs/agents/*.md "$REPO"/agents/README.md \
           "$REPO"/agents/coordinator/README.md "$REPO"/docs/glossary.md; do
    [ -f "$f" ] || continue; n=$(wc -c <"$f"); plan=$(( plan + n ))
    printf '%8d B  ~%6d tok  %s\n' "$n" "$(( n / 4 ))" "${f#"$REPO"/}"
  done
  # replay README: the read plan takes it "through the generated index only" (~first third)
  if [ -f "$REPO/agents/replay/README.md" ]; then
    n=$(( $(wc -c <"$REPO/agents/replay/README.md") / 3 )); plan=$(( plan + n ))
    printf '%8d B  ~%6d tok  agents/replay/README.md (first third — index only)\n' "$n" "$(( n / 4 ))"
  fi
  printf '%8d B  ~%6d tok  READ PLAN total (measured loads ran 299k/346k — tokenizer + tool framing, see docs/spikes/doc-heat.md)\n' "$plan" "$(( plan / 4 ))"
  exit 0
fi

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
