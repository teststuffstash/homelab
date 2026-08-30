# ── observation point ── shared across all three retro-push-belt rows.
# PUSH_FAILED is the block's own exit variable; PUSH_WARN is set only in the
# push-fails branch. The marker file is written only when both curls fail.
#
# Three shapes, one per row (the row's `env:` column declares the expected state):
#   PUSH_FAILED=0, no marker — push-ok / push-retry-ok
#   PUSH_FAILED=1, marker present, PUSH_WARN set — push-fails

case "${PUSH_FAILED:-}" in
  0) echo "PUSH_FAILED: 0 — push succeeded (first try or retry)" ;;
  1) echo "PUSH_FAILED: 1 — both curls failed, failure surface activated" ;;
  *) echo "PUSH_FAILED: unset — unexpected" ;;
esac

MARKER="docs/agents/retros/.pushgateway-failed-${DATE}-${STACK}-${RUN}"
if [ -f "$MARKER" ]; then
  echo "MARKER: present — $(cat "$MARKER" | head -1)"
else
  echo "MARKER: absent"
fi

case "${PUSH_WARN:-}" in
  "") echo "PUSH_WARN: empty — no PR body amendment" ;;
  *"PUSHGATEWAY PUSH FAILED"*) echo "PUSH_WARN: contains the ⚠ pushgateway failure warning" ;;
  *) echo "PUSH_WARN: set but does not contain the expected warning" ;;
esac