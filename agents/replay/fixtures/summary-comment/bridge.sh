# ── bridge ── shared across all four summary-comment rows (ADR-103, homelab#210/#607/#630) — the
# simplest shape the harness supports, and unchanged by the table conversion: the bridge is the
# ONLY part. It sources the shipped agents/machine-comment.sh and redefines its one seam, `mc_now`
# — the wall clock, pinned per row via `env: MC_NOW=<ISO8601>` (README §When a clause depends on a
# sourced helper). The `gh` calls stay real and go through the PATH-shim, which is exactly what
# puts the find-or-create decision (POST a new comment vs PATCH the existing one) into the
# asserted action stream.
. "$REPLAY_ROOT/agents/machine-comment.sh"

mc_now() { printf '%s' "${MC_NOW:?fixture must pin MC_NOW}"; }

# The message text is read from the row's own world file (never an `env:` K=V pair — it has
# embedded spaces, which the harness's env column splits on).
MSG="$(cat "$REPLAY_FIXTURE/world/msg.txt")"

# `duplicate-detected` (homelab#607) is the one row that narrates its own scenario to stdout
# before calling mc_event — asserted verbatim in its own expected template — kept behind a
# row-only flag rather than emitted for every row.
if [ "${NARRATE:-0}" = "1" ]; then
  echo "=== TEST: mc_event with duplicate marked comments (homelab#607) ==="
  echo ""
  echo "Scenario: Issue #43 carries TWO agent-summary comments (race condition)"
  echo "  - 5231000042 @ 10:40:38Z (oldest; agent-session.sh, via mc_event)"
  echo "  - 5231000099 @ 10:55:48Z (second writer, direct post, no mc_event)"
  echo ""
  echo "Action: mc_event appends a third event"
  echo ""
fi

mc_event "$IN_SLUG" "$IN_NUMBER" "$KIND" "$MSG"
EXIT_CODE=$?

if [ "${NARRATE:-0}" = "1" ]; then
  echo ""
  echo "=== RESULT ==="
  echo "mc_event exit code: $EXIT_CODE"
fi

printf 'RETURN %s\n' "$EXIT_CODE"

if [ "${NARRATE:-0}" = "1" ]; then
  echo ""
fi

echo "REACHED: end"
