# ── bridge ── the per-repo loop variables the fleet reader holds by the time the block runs.
# Every name is a SCAN name (`slug`, `repo`, `dispatchable`, `openall`, `orphans`).
#
# The reader ASKS the router for live CELL state (`/router-status` → `pair_cooldowns`,
# `serving_classes`, `generations_24h`). A fixture must never reach the live endpoint — the
# ClusterIP URL answers from inside the loop namespace — so `curl` is stubbed and RECORDED. A row
# declares the router state it wants in `ROUTER_STATUS_JSON` (the payload the endpoint would serve)
# and the unreadable-router condition in `CURL_RC=1` (rule #6: fail-closed and loud).
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
# The clock and the router payload are the row's declared CONDITION; the defaults are the
# "nothing cooled, nothing rode cleanly" world (every class falls to the "us" branch).
DATE_TS="${DATE_TS:-1788285600}"
# (an `if`, not `${VAR:-…}`: a JSON default carries `}` and bash's parameter-expansion parser
# stops at the first one, leaving a stray brace that breaks the function below it)
if [ -z "${ROUTER_STATUS_JSON:-}" ]; then
  ROUTER_STATUS_JSON='{"serving_classes":["auth-storm","provider-5xx","timeout","tool-loop"],"pair_cooldowns":[],"generations_24h":[]}'
fi
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }

# ── stub ── the clock. `now_s` (date -u +%s) is deterministic from DATE_TS; the audit timestamps
# are recorded so the action stream pins them.
date() {
  case "$*" in
    *"+%s") ;;
    *) printf 'CALL date %s\n' "$*" >> "$REPLAY_ACTIONS" ;;
  esac
  case "$*" in
    *"+%s") printf '%s' "${DATE_TS:?fixture must pin DATE_TS}" ;;
    *"+%Y-%m-%dT%H:%M:%SZ") printf '2026-09-01T18:00:00Z' ;;
    *) printf '%s' "${DATE_TS}" ;;
  esac
}

# ── stub ── the router's `/router-status`. ROUTER_STATUS_JSON is the row's declared router state;
# CURL_RC=1 is the unreadable-router condition (rule #6 — never fail INTO a write).
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  [ -n "${ROUTER_STATUS_JSON:-}" ] && printf '%s' "$ROUTER_STATUS_JSON"
  return "${CURL_RC:-0}"
}