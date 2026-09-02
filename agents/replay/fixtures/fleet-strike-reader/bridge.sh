# ── bridge ── the per-repo loop variables the fleet-strike reader holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `dispatchable`, `openall`, `orphans`).
#
# `openall` is the full open-issue list for the repo, fetched far above the block under replay.
# The gh stub serves individual issue comments from world/gh/ files.
#
# The clock is overridden so `now_s` (date -u +%s) is deterministic.
# Non-+%s calls (e.g. +%Y-%m-%dT%H:%M:%SZ for audit timestamps) are recorded and resolved
# from the pinned DATE_TS epoch.
date() {
  # The block calls `date -u +%s` (for now_s) and `date -u +%Y-%m-%dT%H:%M:%SZ` (for audit).
  # Record non-epoch calls so the action stream pins them.
  case "$*" in
    *"+%s") ;;  # epoch call — do not record (deterministic from DATE_TS)
    *) printf 'CALL date %s\n' "$*" >> "$REPLAY_ACTIONS" ;;
  esac
  case "$*" in
    *"+%s") printf '%s' "${DATE_TS:?fixture must pin DATE_TS}" ;;
    *"+%Y-%m-%dT%H:%M:%SZ")
      jq -rn --argjson ts "${DATE_TS:?}" '($ts | strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null || echo "TIMESTAMP" ;;
    *) printf '%s' "${DATE_TS}" ;;
  esac
}

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }

# ────────────────────────────────────────────────────────────────────────────────────────────────
# TICK 1 — first pass against the #326 four-strike world (no prior action).
# All four issues have agent-fix label, no agent/error yet, no fleet-strike-fp: marker.
# DATE_TS=1788285600 (2026-09-01T18:00:00Z, 3h after the last strike — live window).
# Expected: 18 actions (4 label edits + 1 comment + 1 filing + 4+4+4 comment reads).
# ────────────────────────────────────────────────────────────────────────────────────────────────
echo "REACHED: tick 1 — first pass, live world"
DATE_TS=1788285600
# openall: four open issues (#326-#329) all with agent-fix label, no agent/error yet
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"