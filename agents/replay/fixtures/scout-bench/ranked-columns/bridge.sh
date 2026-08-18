# ── bridge ── the state model-scout.sh holds when it reaches leg 2, and nothing else: the leg-1
# clause has already written `candidates.json`, the enrichment seam has already written
# `enriched.json` (both recorded in world/scout/), and the digest's two optional blocks are empty.
#
# `scout_get_model` is NOT shadowed — it is composed from the shipped script by the `scout-seams`
# block above and runs for real. What is shadowed is `curl`, the seam pattern the responder and
# fix-debounce bridges already use, so the JSON-RPC this leg puts on the wire lands in the SAME
# action stream as everything else. "One get-model per surviving candidate" is a claim about calls;
# it can only be asserted where the calls are.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CEILING="0.50"
ORG="teststuffstash"
DIGEST_REPO="homelab"
CANARY="0"
CANARY_BLOCK=""
SUPPRESSED_LINE=$'\n\n*Suppressed by the base-id diff (§M7 leg 1): 3 `:batch` re-listing(s) — an async endpoint cannot serve an interactive session — and 1 other suffix variant(s) of a base already known or already listed above. A variant is not a newcomer.*'

log() { printf '%s\n' "$*"; }   # shipped `log` stamps a wall clock; only that is dropped

cp "$REPLAY_FIXTURE/world/scout/candidates.json" "$WORK/candidates.json"
cp "$REPLAY_FIXTURE/world/scout/enriched.json"   "$WORK/enriched.json"

# The MCP transport, recorded. The Authorization header is deliberately NOT in the CALL line: a
# world that pins a bearer token is a world nobody can re-record safely.
curl() {
  local a payload="" url="" prev="" method model f
  for a in "$@"; do
    [ "$prev" = "-d" ] && payload="$a"
    case "$a" in http*) url="$a" ;; esac
    prev="$a"
  done
  method="$(printf '%s' "$payload" | jq -r '.method // "?"')"
  model="$(printf '%s' "$payload" | jq -r '.params.arguments.request.model // empty')"
  printf 'CALL curl POST %s %s%s\n' "$url" "$method" "${model:+ get-model model=$model}" >> "$REPLAY_ACTIONS"
  [ "$method" = "initialize" ] && return 0
  f="$REPLAY_FIXTURE/world/mcp/$(printf '%s' "$model" | tr '/:.' '---').json"
  # A READ with no recording DIES — the harness's standing rule. Falling through to "no bench data"
  # would be the exact false green this fixture exists to prevent: every candidate would come back
  # `unbenched` and the stream would look plausible.
  [ -f "$f" ] || { printf 'replay-bridge: no recorded MCP world for %s (tried %s)\n' "$model" "$f" >&2; exit 9; }
  cat "$f"
}
