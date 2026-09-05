#!/bin/bash
# ── observation point ── `queued` is the array the JOIN derives from `openall`. Post-#1432
# (ADR-122 (2)) `agent/queued` alone is the one release valve, so the agent-fix-less issue must
# be derived into it exactly like an agent-fix+agent/queued issue would be.
n="$(printf '%s' "$queued" | jq -r 'length')"
[ "$n" = "1" ] || { echo "ERROR: expected 1 queued issue, got $n" >&2; exit 1; }
num="$(printf '%s' "$queued" | jq -r '.[0].number')"
[ "$num" = "501" ] && echo "RESULT queued=[#501] agent/queued-only issue derived as queued (ADR-122 (2), #1432)" || \
  (echo "ERROR: expected #501 in queued, got $num" >&2; exit 1)
