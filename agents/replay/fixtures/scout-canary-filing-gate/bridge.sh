# ── bridge ── the state model-scout.sh holds when it reaches leg 3 (the canary), and nothing
# else: leg 1's diff has already written `candidates.json`, leg 2's rank has already written
# `ranked.json` (recorded in world/scout/ — the post-rank state this family pins FROM). The canary
# I/O seams are shadowed AT THE SEAM (not the transport): the OpenRouterKey CR lifecycle and the
# agent-session.sh ride cannot run here, and recording the seam call + serving the recorded
# AGENT_RUN_STATS line is exactly what the clause under test consumes. `log` writes to STDERR —
# the shipped log does, and canary_one's verdict goes out on stdout inside a command substitution,
# so a stdout log would pollute the captured verdict.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CEILING="0.50"
ORG="teststuffstash"
DIGEST_REPO="homelab"
CANARY_PROJECT="teststuffstash"
MAX_CANARIES="3"
SUPPRESSED_LINE=""
CANARY_BLOCK=""

log() { printf '%s\n' "$*" >&2; }   # shipped `log` stamps a wall clock + writes stderr; keep both

cp "$REPLAY_FIXTURE/world/scout/ranked.json" "$WORK/ranked.json"

# The canary I/O seams, recorded. A ride with no recorded stats DIES — the harness's standing rule:
# serving "no-stats" on an unrecorded model would be the exact false green this family exists to
# prevent (a canary that silently did not run would still produce a clean-looking stream).
scout_canary_mint() { # <id> <is_free> [cleanup] — the OpenRouterKey CR lifecycle is outside this fixture
  local id="$1" is_free="$2" mode="${3:-}"
  if [ "$mode" = "cleanup" ]; then
    printf 'CALL scout_canary_mint model=%s cleanup\n' "$id" >> "$REPLAY_ACTIONS"
  else
    printf 'CALL scout_canary_mint model=%s free=%s\n' "$id" "$is_free" >> "$REPLAY_ACTIONS"
  fi
  return 0
}
scout_canary_ride() { # <id> <is_free> [retry] — serves the recorded AGENT_RUN_STATS line
  local id="$1" is_free="$2" retry="${3:-}" suffix="" f
  [ -n "$retry" ] && suffix=".retry"
  printf 'CALL scout_canary_ride model=%s%s\n' "$id" "${retry:+ retry}" >> "$REPLAY_ACTIONS"
  f="$REPLAY_FIXTURE/world/canary/$(printf '%s' "$id" | tr '/:.' '---')${suffix}.stats"
  [ -f "$f" ] || { printf 'replay-bridge: no recorded canary stats for %s (tried %s)\n' "$id" "$f" >&2; exit 9; }
  cat "$f"
}
rotation_post() { # <source> <entry-json> — the router's /rotation is outside this fixture
  printf 'CALL rotation_post source=%s entry=%s\n' "$1" "$2" >> "$REPLAY_ACTIONS"
}
