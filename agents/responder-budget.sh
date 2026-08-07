#!/usr/bin/env bash
# responder-budget — the daily LLM-triage budget latch for the responder lane (FU-149).
#
# The responder spawns one sonnet session per admitted alert. Until 2026-08-06 the only bound on
# that was FU-113(c)'s cap, which fires when `N_TODAY >= 12` AND `INC_SEEN == 0` — i.e. it blocks a
# NEW incident once twelve are spent, and leaves repeats of an ALREADY-SEEN incident unbounded by
# construction. During the GitHub Actions outage that gap let homelab#111 take three sessions in
# 33 minutes. The subject dedup (FU-133) bounds repeats per RESOURCE; this bounds the DAY.
#
# Same shape as subscription-latch.sh — a launcher-side probe run before spawning — with one
# deliberate difference: this one FAILS CLOSED.
#   - the subscription latch is a burn-saver in front of a limit the PROXY enforces anyway, so an
#     unreachable proxy reading as "clear" costs at most a doomed spawn.
#   - nothing else enforces this budget. If the ledger is unreadable we cannot prove we are under
#     it, and failing open means the exact unbounded burn the latch exists to stop. A blocked
#     triage is visible (marker + meta-alert-crosscheck.sh reports the alert as UNTRIAGED, which
#     is its "the machinery is stuck" signal); an unbounded burn is not.
#
# The counter is DERIVED, not stored: every spawned triage writes `fp-<fp> = "<date>|<incident>"`
# into the responder-seen ledger, so entries whose value starts with "<today>|" ARE the sessions
# launched today. Nothing to reset at midnight and nothing to race — the marker values that mean
# "skipped" (deferred-/cap-/none-/subjdup-/budget-) deliberately do not match this prefix.
#
# exit 0 = clear to spawn. exit 1 = blocked (reason on stderr). Metrics are pushed on BOTH paths,
# because the dashboard's job is to show the budget draining, not only to show it empty.
#
#   Env: RESPONDER_DAILY_MAX=12  RESPONDER_LEDGER_NS=agent-coordinator  RESPONDER_LEDGER_CM=responder-seen
#        PUSHGATEWAY=http://prometheus-pushgateway.monitoring.svc.cluster.local:9091 ("" disables the push)
set -u

NS="${RESPONDER_LEDGER_NS:-agent-coordinator}"
CM="${RESPONDER_LEDGER_CM:-responder-seen}"
MAX="${RESPONDER_DAILY_MAX:-12}"
PGW="${PUSHGATEWAY-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
TODAY="$(date -u +%Y-%m-%d)"
# 00:00Z of the day these numbers describe. Pushed alongside them so the ALERT can tell a stale
# sample from a current one across the date boundary — the metrics only refresh when the responder
# runs, and within a day a stale sample is still ACCURATE (the session count only ever grows), but
# one minute past midnight it is flatly wrong. Found live 2026-08-07 01:05Z: the last push was
# 23:21Z, so the alert was still reporting "no further triage today" 65 minutes into a day whose
# budget had reset to 0/12.
DAY_START=$(( $(date -u +%s) / 86400 * 86400 ))

# Push is best-effort and must never change the verdict: a dead pushgateway is an observability
# fault, not a budget fault. Freshness matters to the alert, so we push on every invocation.
push() { # $1=used $2=remaining $3=blocked $4=probe_ok
  [ -n "$PGW" ] || return 0
  printf '%s\n' \
    "# TYPE responder_triage_sessions_today gauge" \
    "# HELP responder_triage_sessions_today LLM triage sessions the responder has spawned today (UTC)." \
    "responder_triage_sessions_today $1" \
    "# TYPE responder_triage_budget_max gauge" \
    "# HELP responder_triage_budget_max Daily ceiling on spawned triage sessions (RESPONDER_DAILY_MAX)." \
    "responder_triage_budget_max $MAX" \
    "# TYPE responder_triage_budget_remaining gauge" \
    "# HELP responder_triage_budget_remaining Sessions still available today." \
    "responder_triage_budget_remaining $2" \
    "# TYPE responder_triage_blocked gauge" \
    "# HELP responder_triage_blocked 1 = no further LLM triage will be launched today." \
    "responder_triage_blocked $3" \
    "# TYPE responder_triage_probe_ok gauge" \
    "# HELP responder_triage_probe_ok 0 = the budget could not be read, so triage is blocked fail-closed." \
    "responder_triage_probe_ok $4" \
    "# TYPE responder_triage_day_start gauge" \
    "# HELP responder_triage_day_start Unix epoch of 00:00Z of the UTC day these numbers describe — the alert gates on it so a sample cannot outlive its day." \
    "responder_triage_day_start $DAY_START" \
    | curl -fsS --max-time 5 --data-binary @- "$PGW/metrics/job/responder_budget" >/dev/null 2>&1 \
    || echo "responder-budget: pushgateway unreachable ($PGW) — verdict unaffected, dashboard will go stale" >&2
}

json="$(kubectl -n "$NS" get cm "$CM" -o json 2>/dev/null)" || json=""
# An ABSENT ConfigMap is a legitimate cold start (the workflow creates it just after this runs), not
# a probe failure — it means zero sessions today. An unreadable one (RBAC, API down) is different
# and must not be mistaken for zero, which is why the two cases are split.
if [ -z "$json" ]; then
  if kubectl -n "$NS" get cm "$CM" >/dev/null 2>&1; then
    echo "responder-budget: PROBE-FAIL — $NS/$CM exists but could not be read as JSON; blocking triage fail-closed (see the header)" >&2
    push 0 0 1 0
    exit 1
  fi
  echo "responder-budget: ledger $NS/$CM does not exist yet (cold start) — 0 sessions today, clear to spawn" >&2
  push 0 "$MAX" 0 1
  exit 0
fi

used="$(printf '%s' "$json" | jq -r --arg t "$TODAY|" '[(.data // {}) | to_entries[] | select(.value | startswith($t))] | length' 2>/dev/null)" || used=""
case "$used" in
  ''|*[!0-9]*)
    echo "responder-budget: PROBE-FAIL — could not count today's sessions from $NS/$CM; blocking triage fail-closed" >&2
    push 0 0 1 0
    exit 1 ;;
esac

remaining=$(( MAX - used )); [ "$remaining" -lt 0 ] && remaining=0

if [ "$used" -ge "$MAX" ]; then
  echo "responder-budget: BUDGET EXHAUSTED — $used/$MAX LLM triage sessions spawned today (UTC $TODAY); no further sessions will be launched until 00:00Z. Alerts still fire and still route to Home Assistant; raise RESPONDER_DAILY_MAX or fix the storm." >&2
  push "$used" 0 1 1
  exit 1
fi

push "$used" "$remaining" 0 1
echo "responder-budget: $used/$MAX spawned today, $remaining remaining — clear to spawn" >&2
exit 0
