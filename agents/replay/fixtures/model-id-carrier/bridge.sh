# ── bridge ── launcher state common to every model-id-carrier leg (constants that never differ
# across rows); each row's varying state (MODEL, _decision) is sourced from
# $REPLAY_WORLD/vars.sh — the row's `rows/<id>/vars.sh` overlay.
HERE="$REPLAY_ROOT/agents"
. "$REPLAY_WORLD/vars.sh"

# Shadow python3 to record calls to model_id.py — the absent call (carrier-present row)
# is the probe: a call that silently stopped happening is the drift this fixture exists to catch.
python3() {
  printf 'CALL python3 %s\n' "$*" >> "$REPLAY_ACTIONS"
  command python3 "$@"
}