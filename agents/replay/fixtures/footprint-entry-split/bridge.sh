# ── bridge ── the declared footprint and the changed path, per row (rows/<id>/vars.sh). The
# subject is the ENTRY-SPLITTER both readers share, so the bridge calls the REAL predicates from
# the shipped agents/footprint.sh and agents/touches-check.sh — never a copy of the glob logic.
# `DECLARED` is the raw `Touches:` value (annotation and all); `CHANGED` is one changed path.
. "$REPLAY_WORLD/vars.sh"
. "$REPLAY_ROOT/agents/footprint.sh"
. "$REPLAY_ROOT/agents/touches-check.sh"

# fp_conflict — the scan's ADR-097 footprint hold (does the declared footprint cover the path).
if fp_conflict "$DECLARED" "$CHANGED"; then HOLD=yes; else HOLD=no; fi
# fp_conflict_strict — the pin-only GUARDED pre-dispatch check (same question, no replay exemption).
if fp_conflict_strict "$DECLARED" "$CHANGED"; then STRICT=yes; else STRICT=no; fi
# touches_check — the reviewer's escape set (which changed paths fall outside the footprint).
ESCAPES="$(touches_check "$DECLARED" "$CHANGED")"