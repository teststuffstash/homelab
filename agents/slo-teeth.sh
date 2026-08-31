#!/usr/bin/env bash
# slo-teeth — THE read of the per-stack error budget burn state (FU-104), for every
# reviewer-dispatch site. One implementation, one failure posture, one message.
#
#   bash agents/slo-teeth.sh <repo>                # predicate: exit 0 = proceed, 1 = skip
#   bash agents/slo-teeth.sh --filter r1 r2 …      # stdout = the repos clear to proceed
#
# Reasons always go to STDERR (so --filter's stdout stays a clean repo list); both modes are quiet
# on the ordinary "nothing burnt" path.
#
# WHY THIS FILE EXISTS (homelab#831). The teeth shipped as an inline PromQL curl+filter inside
# review-reflex.sh's tick — ONE of TWO dispatch sites (the backstop). The OTHER site, the primary
# edge path through reviewer-session.sh (github-exporter POST → Argo Events Sensor → review
# WorkflowTemplate), never read it. On a burnt stack a PR still drew a bot review, still collected
# the approving verdict, and the armed auto-merge still fired — exactly the homelab#204 shape one
# lane over.
#
# ALL dispatch sites converge on agents/reviewer-session.sh, so its guard (next to the optout and
# latch guards, which are there for exactly the same reason) is the choke point. reviewer-reflex.sh
# also calls this helper instead of its own inline curl/jq — removing the second copy that is how
# this class of bug is born.
#
# FAIL-OPEN, on purpose, the deliberate INVERSE of reviewer-optout.sh's fail-CLOSED posture.
# For an AVAILABILITY knob the two failures are not symmetric:
#   • skip a review we should have run  → the review path is LEVEL-TRIGGERED (Sensor edge + a */15
#     CronWorkflow backstop + the ~5-min reflex tick), so the next tick with a reachable Prometheus
#     re-picks the PR. Cost: minutes.
#   • park every merge lane because Prometheus is dead → a single-point-of-failure wedges the
#     entire fleet. Availability of the gate < the gate itself.
# So an unreachable Prometheus means PROCEED, loudly — a dead metric is NOT evidence of a burnt
# budget. An unread claim IS not permission to approve; an unreachable metric IS not evidence of
# a burnt budget. These are deliberately asymmetric and the asymmetry is load-bearing.
#
# THE RESIDUAL (the in-flight window). The teeth park dispatch; they do NOT withdraw an approval
# already given and do NOT disarm an armed PR. A PR that already carries a bot approval at head
# with auto-merge armed still merges once it becomes mergeable — which is not only "at the instant
# of burn": such a PR merges whenever CI goes green or the updater brings it current, potentially
# well into the burn.
#
# The budget-burnt state lives ONLY in Prometheus. agents/stacks.json is the committed mirror for
# the repo→stack mapping and is read here; it does NOT carry `slo` — teaching it to would be a
# second copy of the very fact this file exists to read once. Don't.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

PROM_URL="${PROM_URL:-http://192.168.40.13:9090}"

say() { printf 'slo-teeth: %s\n' "$*" >&2; }

usage() { echo "usage: slo-teeth.sh <repo> | --filter <repo>…" >&2; exit 2; }
[ $# -gt 0 ] || usage

MODE="predicate"
if [ "$1" = "--filter" ]; then MODE="filter"; shift; fi
[ $# -gt 0 ] || usage

# ── ONE Prometheus query ────────────────────────────────────────────────────────────────────────
# Both error-diagnosis and result-parsing pass through the SAME response, so a dead Prometheus
# (stderr noise + exit non-zero) and a live one that reports "no burnt stacks" (empty result)
# are distinguished without a second connection attempt.
_prom_exit=0
_prom_stdout=""
_prom_combined=""
_prom_combined="$(curl -fsS --max-time 10 "$PROM_URL/api/v1/query" \
  --data-urlencode 'query=max by (stack) (stack:error_budget_burnt:bool) == 1' 2>/dev/null)" || _prom_exit=$?

BURNT_REPOS=""

if [ "$_prom_exit" -ne 0 ]; then
  # Prometheus query failed — fail-open: proceed loudly
  say "PROMETHEUS QUERY FAILED (exit $_prom_exit) — error budget state UNKNOWN for all stacks;"
  say "  PROCEEDING with dispatch (fail-open, FU-104). A dead Prometheus must never freeze every"
  say "  merge lane. If this repeats, check Prometheus at $PROM_URL."
  # BURNT_REPOS stays empty → all repos proceed
elif printf '%s' "$_prom_combined" | jq -e '.data.result | length > 0' >/dev/null 2>&1; then
  # Query succeeded and at least one stack is burnt
  _burnt_stacks="$(printf '%s' "$_prom_combined" | jq -r '.data.result[].metric.stack' 2>/dev/null | tr '\n' ' ')"
  for s in $_burnt_stacks; do
    BURNT_REPOS="$BURNT_REPOS $(jq -r --arg s "$s" '.stacks[]|select(.name==$s)|.repos[]' "$HERE/stacks.json" 2>/dev/null | tr '\n' ' ')"
  done
fi
# else: query succeeded but no stacks burnt → BURNT_REPOS stays empty → all repos proceed

allowed() {  # allowed <repo> → 0 clear, 1 parked (reason on stderr)
  case " $BURNT_REPOS " in
    *" $1 "*)
      _stack="$(jq -r --arg r "$1" '.stacks[] | select([.repos[] | if type=="object" then .name else . end] | index($r)) | .name' "$HERE/stacks.json" 2>/dev/null | head -1)"
      say "[$1] PARKED — its stack${_stack:+ '$_stack'} has a burnt error budget (auto-merge lane demoted to human until it recovers, FU-104)"
      return 1;;
    *) return 0;;
  esac
}

if [ "$MODE" = "filter" ]; then
  for r in "$@"; do allowed "$r" && printf '%s\n' "$r"; done
  exit 0
fi
allowed "$1"