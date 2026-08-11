# ── bridge ── the variables the draw block reads, named exactly as research-fanout.sh sets them
# (ISSUE/CLASS/ARMS/START_SLOT/ROUTER_URL) — a bridge that renames things pins a different clause.
ISSUE="$IN_ISSUE"
CLASS="$IN_CLASS"
ARMS="$IN_ARMS"
START_SLOT="$IN_START_SLOT"
ROUTER_URL="http://openrouter-proxy.replay.invalid:8080"

# The ONE seam the block has: `rf_route`, the POST /route curl. Redefined to serve the RECORDED
# decisions and to record the call — everything else (the slot walk, the dispatch/defer split, the
# no-substitution rule, the arm table) is the shipped code running for real.
#
# The read contract is the stubs' contract: a slot with no recording DIES rather than returning an
# empty body, because an empty body here would make the clause report "router unreachable" and the
# fixture would go green for a reason that has nothing to do with what it pins.
rf_route() {   # rf_route <class> <slot> <session>
  printf 'CALL route class=%s slot=%s jitter=false session=%s\n' "$1" "$2" "$3" >> "$REPLAY_ACTIONS"
  _w="$REPLAY_WORLD/route/slot-$2.json"
  if [ ! -f "$_w" ]; then
    printf 'replay-bridge[rf_route]: no recorded decision for slot %s\n' "$2" >&2
    exit 9
  fi
  cat "$_w"
}
