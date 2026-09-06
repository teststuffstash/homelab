#!/usr/bin/env bash
# coordinator-scan — the DETERMINISTIC gate in front of the LLM coordinator. The cheap sibling
# of review-reflex.sh: per stack, list open issues/PRs across the stack's repos and answer the boolean
# "is there anything a coordinator TICK would act on?" — and ONLY spawn the LLM coordinator when yes.
# No subscription tokens are ever spent to discover "nothing to do".
#
# Actionability predicate (MUST track agents/coordinator/README.md §State machine — keep in sync):
#   issue: open ∧ `agent/queued`                                      (ready to dispatch — the
#          ONE dispatch precondition, ADR-122 (2), S8 #1432; `agent-fix` is never re-tested here)
#   PR:    open ∧ ¬`major/awaiting-human` ∧ (`major` ∨ `merge-conflict` ∨ reviewDecision=CHANGES_REQUESTED)
#   v2:    issue open ∧ `agent-fix` ∧ `agent/in-progress` ∧ no Running worker pod ∧ no open PR
#          referencing it (C4/C5 — a worker went terminal and nothing re-ticked; pod read via
#          kubectl, probe failures skip the clause rather than fail into a wake). Once that state
#          has PERSISTED past C4C5_PERSIST_S and no merged PR mentions the issue, the scan
#          RECONCILES the label itself — agent/queued back on, agent/in-progress off, audit
#          commented (homelab#155) — because the phantom label also holds every sibling through
#          the ADR-097 footprint intersection. Everything it holds still rides as a unit.
# Deliberately EXCLUDES (so the LLM never wakes for a no-op): human-waiting states (`agent/blocked`,
# `major/awaiting-human`), the `agent/error` anomaly-breaker items (FU-069 — human-first,
# report-only), done/merged, everything on the review-reflex's ARMED track — arming is the
# boundary (docs/agents/merge-path.md) — and queued issues whose declared `Touches:` footprint
# lands on a pin-only-lint GUARDED file (homelab#309, §PIN-ONLY GUARDED PATHS below: report-only,
# no label written, because no PR can deliver them). red-beyond-T = the ci-red clause (FU-115) (guarded checks
# probe — a 403 skips it loudly); rounds-exhausted = the arbitrate clause (both 2026-07-27). Both
# of those two are CURRENCY-gated as well as condition-gated (homelab#198): a condition that holds
# over unchanged PR state is a report line, not a fresh unit — see §PR STATE FINGERPRINT below. The
# per-stack `coordinate-<stack>` CronWorkflows run `--spawn` on their schedules (the level
# backstop); the GLOBAL surface is the switchboard (`--switchboard`, ADR-120) — Sensor-edge only,
# its `coordinator-reflex` cron retired 2026-08-31 (18/18 no-op ticks; nothing to catch).
#
# STACK SOURCE — `stacks_json()` is the single swap-point: TODAY it reads agents/stacks.json; the
# TARGET is the cluster, where each stack's -iac repo owns a Crossplane `AgentStack` claim and this reads
# `kubectl get agentstacks -o json`. Policy (repos/models/tools) then lives in the stack, not here.
# See docs/agents/platform-and-stacks.md.
#
#   bash agents/coordinator-scan.sh            # REPORT: per-stack actionable items + the command to run
#   bash agents/coordinator-scan.sh --spawn    # for each stack with work, spawn a headless coordinator tick
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# >>>REPLAY:config-defaults>>>
# Config defaults that extracted clause blocks depend on. The replay harness (run.sh)
# prepends this block to every composition sourced from coordinator-scan.sh, so a
# `set -u` clause never hits an unbound variable whose default lives outside the block.
# Add new defaults here when a replayed block references them.
ORG="${ORG:-teststuffstash}"
REPO_MAX_WIP="${REPO_MAX_WIP:-3}"   # ADR-097 hard ceiling: concurrent workers per repo. TRACKS rule 1 counts armed PRs per base; was binary WIP=1 until meta-8 proved two dispatchers race inside one scan window (2026-07-21 #55). 3 allows slack for a second worker without unbounded concurrency.
SCAN_AGING_N="${SCAN_AGING_N:-3}"   # #829 / ADR-125 (3): a NEW-WORK unit that has lost this many consecutive LANE dispatches escalates to the front of its lane's walk. 3 = the smallest count that is not one unlucky tick: the #818 evening lost ~45 min, which at the measured ride length is four to five recovery rides, so two losses is ordinary contention and three is a pattern.
ISSUE_LIST_LIMIT="${ISSUE_LIST_LIMIT:-200}"   # homelab#840: gh's unstated 30-result default silently hid queued #110 for 24 days (46 open issues, window floor #840). 200 is well above any repo's open-issue count; the scan prints a loud TRUNCATED warning if the fetch fills the limit.
# <<<REPLAY:config-defaults<<<
STACKS_FILE="${STACKS_FILE:-${HERE}/stacks.json}"
SPAWN=""; [ "${1:-}" = "--spawn" ] && SPAWN=1
# ADR-120: --switchboard = the global Sensor edge's mode. Spawn semantics for the fan-out gates
# (fanout_eligible tests SPAWN), plus the SWITCHBOARD terminal below — resolve/fan out, then
# exit BEFORE any GitHub listing. The global instance never board-scans any more.
SWITCHBOARD=""; [ "${1:-}" = "--switchboard" ] && { SPAWN=1; SWITCHBOARD=1; }
# ADR-097 footprint-intersection dispatch: the predicate lives in a sourceable helper so the
# double-dispatch belt (agents/footprint-test.sh, in ci) exercises the exact code the scan runs.
# Source touches-check.sh which contains fp_norm_entry, fp_pair_conflict, fp_conflict,
# fp_conflict_multi (the core prefix-intersection logic). The same helper is sourced by
# reviewer-session.sh for computing escape sets — zero drift, two callers, one logic home (homelab#379).
. "${HERE}/touches-check.sh"
# ADR-106 (3): the findings-store helpers (burn-down write + checkpoint counts) — the store
# format's ONE home; the coordinator session uses the same file's CLI verbs.
. "${HERE}/goal-findings.sh"

# ── PIN-ONLY GUARDED PATHS — a pre-dispatch routing check (homelab#309) ─────────────────────────
# `scripts/pin-only-lint.sh` refuses any PR that writes anything but a pin line into its carved-out
# files. So a queued issue whose DECLARED footprint lands on one of them cannot be delivered by a
# PR at all: the required `ci` check is structurally red before the worker writes a line, and the
# documented route past it is the operator's direct-to-master push (CODEOWNERS §Carve-outs).
# #299 spent a whole ROUND discovering that. The worker did everything right — shipped the landable
# half as PR#306, posted `AGENT_INFEASIBLE` for the `reflexes-argo.yaml` edit, named the exact line
# for the operator — and every fact needed to know it in advance was on disk at dispatch time. The
# scan already reads each issue's footprint and already HOLDS units on it (ADR-097); this is the
# same predicate against a second, static set, so the routing decision costs a report line instead
# of a session.
#
# READ THE SET, NEVER RE-DECLARE IT. A second copy is the drift bug in the direction that hurts:
# the lint widens, the scan keeps dispatching into the widened set. This is the same one-home read
# the ADR-103 ratchet step already makes in `.github/workflows/ci.yaml` — grep the one line, eval
# it — so there is exactly one definition of GUARDED in the repo and two readers of it.
# >>>REPLAY:guarded-set>>>
PIN_ONLY_LINT="${PIN_ONLY_LINT:-${HERE}/../scripts/pin-only-lint.sh}"
# The set is THIS repo's CI's. A stack repo's `argocd/platform/` footprint is not touching this
# repo's `arc-runners.yaml`, and holding it would be a category error — so the check is scoped to
# the repo the checkout is, overridable for the same reason STACKS_FILE is.
GUARDED_REPO="${GUARDED_REPO:-homelab}"
guarded_paths() {   # → one guarded PATH per line. NO output = could not read (never "none guarded")
  local line="" GUARDED=""
  [ -r "$PIN_ONLY_LINT" ] && line="$(grep -m1 '^GUARDED=' "$PIN_ONLY_LINT" || true)"
  [ -n "$line" ] || return 1
  eval "$line" || return 1
  [ -n "$GUARDED" ] || return 1
  # The lint holds its set as a grep alternation (`a\.yaml|b\.yaml`); the footprint predicate wants
  # plain paths, so split on `|` and drop the regex escapes.
  printf '%s\n' "$GUARDED" | tr '|' '\n' | sed 's/\\\(.\)/\1/g' | grep -v '^[[:space:]]*$'
}
# Read ONCE per scan; the empty-vs-unreadable distinction is made at the use site, where it holds
# work rather than releasing it (rule #6 — never fail INTO a dispatch).
GUARDED_PATHS="$(guarded_paths || true)"
# <<<REPLAY:guarded-set<<<

# ── OPERATOR-LANE PATHS — a pre-dispatch routing check (homelab#1151) ────────────────────────────
# `classify_touches()` in agents/footprint.sh is the ONE machine-readable home for the platform
# lane path tables (docs/agents/iac-lane.md §The platform lane). It returns `codeowner-author`
# for the ❌ operator-author set — paths where authoring takes effect BEFORE a human approves
# (`.github/`, `.agents/`, `devbox.json|lock`, `scripts/`). A queued issue whose declared
# `Touches:` footprint lands on any of these paths is undeliverable by any worker PR — the
# required `ci` check is structurally red before the worker writes a line, and the documented
# route is an operator push to master. The scan must not dispatch into that hole.
#
# ONE DEFINITION, N READERS. The same predicate is used by fix-debounce-argo.yaml's queue-time
# deny (Consumer 2) — the second inline copy that used to live there is collapsed onto this call.
# The governance-lint.sh CI check (`scripts/governance-lint.sh`) remains a separate reader of
# its own GOVERNANCE set for CI-time enforcement; the dispatch-time hold uses classify_touches().
# >>>REPLAY:operator-lane-set>>>
# No set to read — classify_touches() in footprint.sh IS the definition.
# <<<REPLAY:operator-lane-set<<<

# ── GOVERNANCE PATHS — a pre-dispatch routing check (homelab#1070) ────────────────────────────
# `scripts/governance-lint.sh` refuses PRs touching its GOVERNANCE set without specific
# credentials or configurations. So a queued issue whose footprint lands on one of them cannot
# be delivered by a worker PR: the required `ci` check is structurally red before the worker
# writes a line, and the documented route is an operator push to master.
#
# READ THE SET, NEVER RE-DECLARE IT. Same one-greppable-line convention as the GUARDED set: the
# lint's own `GOVERNANCE=` line is the single source of truth. A second copy here would drift.
# >>>REPLAY:governance-set>>>
GOVERNANCE_LINT="${GOVERNANCE_LINT:-${HERE}/../scripts/governance-lint.sh}"
governance_paths() {   # → one governance PATH per line. NO output = could not read (never "none governed")
  local line="" GOVERNANCE=""
  [ -r "$GOVERNANCE_LINT" ] && line="$(grep -m1 '^GOVERNANCE=' "$GOVERNANCE_LINT" || true)"
  [ -n "$line" ] || return 1
  eval "$line" || return 1
  [ -n "$GOVERNANCE" ] || return 1
  # The lint holds its set as a regex alternation (`(a|b)`); split and unescape the same way
  # guarded_paths does: the capture-group form `s/\\\(.\)/\1/g` correctly unescapes any character,
  # not just dots.
  printf '%s\n' "$GOVERNANCE" | sed 's/^\^(//; s/\$)//' | tr '|' '\n' | sed 's/\$//; s/\\\(.\)/\1/g' | grep -v '^[[:space:]]*$'
}
# Read ONCE per scan; the empty-vs-unreadable distinction is made at the use site, where it holds
# work rather than releasing it (rule #6 — never fail INTO a dispatch).
GOVERNANCE_PATHS="$(governance_paths || true)"
# <<<REPLAY:governance-set<<<

# ── SCAN PHASE MARKER (FU-145) ──────────────────────────────────────────────────────────────────
# `AgentCoordinateScanWedged` keyed on POD LIFETIME, and this pod's lifetime is not the thing that
# alert names. When the scan dispatched it used to stream the item session synchronously, so a
# perfectly healthy ride >15m read as a wedge: twice in one hour on 2026-08-06 (the goal-decompose,
# then #30's ride), both healthy, both self-resolving, two false issues minted (#120, #134).
# Evidence, the two remedies ruled OUT (raising the threshold, special-casing goal-decompose) and
# why `fc7e9fb`'s calibration cannot be reused: docs/agents/observability-and-retro.md §Part A″.
# (Since ADR-106 (5) the launcher DETACHES at pod-Ready, so the `dispatch` phase is minutes of
# spin-up at most — the marker machinery stays because the phases are still real, just shorter.)
#
# So the scan PUBLISHES the phase it is in and the alert keys on that instead of on the pod:
#   agent_scan_phase_start_timestamp   epoch at which the CURRENT phase began
#   agent_scan_in_deterministic        1 = deterministic pass, 0 = blocked streaming a session
# Pushed to the pushgateway — the `agent_run_*` precedent (FU-057), same best-effort contract as
# `responder-budget.sh`: a dead gateway is an observability fault and must never change what the
# scan dispatches.
#
# GROUPED BY NAMESPACE, with the pod as a metric LABEL — deliberately not grouped by pod. The
# pushgateway serves every pushed group FOREVER (the lesson AgentRunInfraDeathBurst is still
# carrying), so a per-pod grouping key would leak one group per scan, ~350/day; a per-namespace key
# is overwritten by the next scan in that namespace and a stale marker just names a pod the alert's
# `on(pod)` join no longer matches. One scan per namespace at a time is not an assumption — the
# `coordinator-scan` mutex in the WorkflowTemplate serializes cron + Sensor submissions
# (agents/coordinator/coordinate-argo.yaml). If that mutex ever goes, two concurrent scans in one
# namespace trade markers and the loser falls back to the pod-lifetime branch below — i.e. to
# today's false-positive, never to a missed wedge.
#
# ⚠ NOTHING IS PUSHED BEFORE THE FIRST TRANSITION, and that is the design, not an omission: until
# then the pod has been in the deterministic phase since it started, so pod lifetime IS the phase
# duration and the alert's no-marker branch measures it exactly — including a wedge that dies
# before this script runs at all, which is the shape the alert was built for (2026-08-05,
# homelab#103: zero log bytes, stuck in `git clone`, holding the mutex with twins Pending).
# >>>REPLAY:scan-phase>>>
SCAN_PHASE_PGW="${AGENT_PUSHGATEWAY_URL-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
SCAN_PHASE_POD="${SCAN_PHASE_POD:-${HOSTNAME:-}}"
SCAN_PHASE_NS="${SCAN_PHASE_NS:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo unknown)}"
sp_now() { date -u +%s; }   # replay seam: the wall clock
scan_phase() {   # $1 = dispatch | deterministic — record a phase transition for the wedge alert
  local phase="${1:-}" indet
  case "$phase" in
    dispatch)      indet=0 ;;
    deterministic) indet=1 ;;
    *) echo "scan_phase: unknown phase '${phase}' — nothing pushed" >&2; return 0 ;;
  esac
  # No gateway or no pod identity (a jail/manual run) → no marker, and the alert's no-marker branch
  # is correct for exactly that case. Never a failure: this is a report, not a gate.
  [ -n "$SCAN_PHASE_PGW" ] && [ -n "$SCAN_PHASE_POD" ] || return 0
  printf '%s\n' \
    "# TYPE agent_scan_phase_start_timestamp gauge" \
    "# HELP agent_scan_phase_start_timestamp Unix epoch at which this coordinate scan entered its current phase." \
    "agent_scan_phase_start_timestamp{pod=\"${SCAN_PHASE_POD}\"} $(sp_now)" \
    "# TYPE agent_scan_in_deterministic gauge" \
    "# HELP agent_scan_in_deterministic 1 = running the deterministic pass; 0 = blocked streaming a dispatched session." \
    "agent_scan_in_deterministic{pod=\"${SCAN_PHASE_POD}\"} ${indet}" \
    | curl -fsS --max-time 5 --data-binary @- \
        "${SCAN_PHASE_PGW}/metrics/job/agent_scan_phase/namespace/${SCAN_PHASE_NS}" >/dev/null 2>&1 \
    || echo "scan_phase: pushgateway unreachable (${SCAN_PHASE_PGW}) — dispatch unaffected; AgentCoordinateScanWedged falls back to pod lifetime for this scan" >&2
  return 0
}
# <<<REPLAY:scan-phase<<<

# ── LANES: the serialization unit is (repo, base) — ADR-125 ─────────────────────────────────────
# A LANE is a (repo, base-branch) pair. ADR-125's ground: the serializer exists to avoid the
# merge→behind→dismiss-approval chain, and that chain only runs between PRs sharing a BASE. Work on
# `master` and work on `goal/**` cannot invalidate each other, so queueing one behind the other is
# starvation with no safety purchased by it (goal #278's 361 starved minutes; #818's decompose
# losing ~45 min to a self-regenerating changes-requested stream, 2026-08-23 — homelab#829).
# The clause priority walk below therefore runs ONCE PER LANE instead of once per stack.
#
# WHERE A UNIT'S BASE COMES FROM, and why it is RECORDED here rather than re-read at dispatch:
#   - an ISSUE unit's base is the issue body's `Base:` line, defaulted to the repo's default
#     branch. That is the SAME read the homelab#849 per-base cap already does (`qbase`); this map
#     reuses the existing body, never a second regex — S8 original 1b migrates every `Base:`
#     reader onto agents/issue_body.py, and a new regex here would be a reader it must then delete.
#   - a PR unit's base is `baseRefName`, already on the per-repo `prsjson` fetch.
# Both are known inside the per-repo pass; the dispatch loop runs AFTER that pass, so the pass
# records and the loop reads. Recording costs no API call; re-reading at dispatch would.
#
# THE FALLBACK CHAIN IS FAIL-SAFE: unknown item → the repo's default branch → `master`. An unknown
# lane never invents parallelism; it folds the item into the default-branch lane, which is exactly
# the whole-stack behaviour that shipped before this.
#
# ⚠ The base is stored VERBATIM off `Base:` / `baseRefName`, whitespace-trimmed and nothing else —
# the #849 cap already matches a raw `Base:` value against a raw `baseRefName`, so trimming further
# (backticks, `refs/heads/`) here would make the two disagree about what one lane is. Trimming
# whitespace is not cosmetic: a lane key with a space in it would word-split the walk below.
# >>>REPLAY:unit-lane>>>
UNIT_LANES=""             # newline-joined "repo|item|base"   (item = issue-N / pr-N)
REPO_DEFAULT_BRANCHES=""  # newline-joined "repo|default-branch"

unit_lane_record() {   # unit_lane_record <repo> <item> <base>
  local b="${3:-}"
  b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "$b" ] || return 0
  # A lane key is word-split by the walk, and git refuses a ref name containing whitespace — so a
  # `Base:` line with an internal space is prose, not a branch. Record nothing: the item falls back
  # to the repo's default-branch lane, which is the pre-ADR-125 behaviour for it.
  case "$b" in *[[:space:]]*) return 0;; esac
  UNIT_LANES="${UNIT_LANES}${1}|${2}|${b}
"
}

unit_lane_default_record() {   # unit_lane_default_record <repo> <default-branch>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  REPO_DEFAULT_BRANCHES="${REPO_DEFAULT_BRANCHES}${1}|${2}
"
}

unit_lane_default() {   # unit_lane_default <repo> → its default branch, `master` when unrecorded
  local d
  d="$(printf '%s' "$REPO_DEFAULT_BRANCHES" | awk -F'|' -v r="${1:-}" '$1 == r { print $2; exit }')"
  printf '%s' "${d:-master}"
}

unit_lane_of() {   # unit_lane_of <repo> <item> → the lane's base branch (never empty)
  local b
  b="$(printf '%s' "$UNIT_LANES" | awk -F'|' -v r="${1:-}" -v i="${2:-}" '$1 == r && $2 == i { print $3; exit }')"
  [ -n "$b" ] || b="$(unit_lane_default "${1:-}")"
  printf '%s' "$b"
}

# The WALK ORDER over lanes. Repos come in EMISSION order and lanes are ordered WITHIN a repo by
# their oldest item: GitHub numbers issues and PRs out of ONE per-repo sequence, so a lower number
# IS an older item. Across repos the same comparison is meaningless (two sequences), which is why
# repos are grouped rather than globally sorted — a global number sort would interleave two repos
# on a number that means nothing between them. Ties (only reachable when an item id does not parse)
# put the repo's DEFAULT-BRANCH lane first, then sort by lane key, so the order is total and the
# walk is reproducible from the unit list alone.
unit_lane_keys() {   # unit_lane_keys <units-blob> → "repo|base" lines, in walk order
  local ln clause rest repo item base num rows=""
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    clause="${ln%%|*}"; rest="${ln#*|}"; repo="${rest%%|*}"; rest="${rest#*|}"; item="${rest%%|*}"
    [ -n "$clause" ] && [ -n "$repo" ] && [ -n "$item" ] || continue
    base="$(unit_lane_of "$repo" "$item")"
    num="${item##*-}"
    case "$num" in ''|*[!0-9]*) num=999999999;; esac
    rows="${rows}${repo}	${base}	${num}	$( [ "$base" = "$(unit_lane_default "$repo")" ] && echo 0 || echo 1 )
"
  done <<EOF
$(printf '%b' "${1:-}")
EOF
  printf '%s' "$rows" | awk -F'\t' '
    NF < 4 { next }
    {
      key = $1 "|" $2
      if (!($1 in ridx)) ridx[$1] = ++rn
      if (!(key in seen)) { seen[key] = 1; ord[key] = ridx[$1]; minnum[key] = $3 + 0; isdef[key] = $4 + 0; keys[++n] = key }
      else if ($3 + 0 < minnum[key]) minnum[key] = $3 + 0
    }
    END { for (i = 1; i <= n; i++) { k = keys[i]; printf "%d\t%d\t%d\t%s\n", ord[k], minnum[k], isdef[k], k } }
  ' | sort -t'	' -k1,1n -k2,2n -k3,3n -k4,4 | cut -f4
}

unit_lane_units() {   # unit_lane_units <units-blob> <repo> <base> → the unit lines in that lane
  local ln clause rest repo item
  while IFS= read -r ln; do
    [ -n "$ln" ] || continue
    clause="${ln%%|*}"; rest="${ln#*|}"; repo="${rest%%|*}"; rest="${rest#*|}"; item="${rest%%|*}"
    [ -n "$clause" ] && [ -n "$repo" ] && [ -n "$item" ] || continue
    [ "$repo" = "${2:-}" ] || continue
    [ "$(unit_lane_of "$repo" "$item")" = "${3:-}" ] || continue
    printf '%s\n' "$ln"
  done <<EOF
$(printf '%b' "${1:-}")
EOF
}
# <<<REPLAY:unit-lane<<<
# ── ITEM CLASS EXPORT (homelab#892) — per-tick derived class → pushgateway ─────────────────────
# The scan classifies every open issue/PR it sees into one of the derived classes below. At the
# end of each stack's pass, the class map is pushed to the pushgateway (job `agent_board`, grouped
# per namespace) so `board.sh --machine` can consume it from Prometheus instead of re-deriving it.
# Group-replace per tick (FU-176 semantics): a closed item drops off at the next tick, and a quiet
# tick that empties the group is not a health signal.
#
# Classes (low-cardinality enum, v1):
#   riding, phantom, strike-held, parked-blocked, parked-infeasible,
#   arbitrate-standing, queued-held, queued-held-by-ghost, queued-ready,
#   deferred-capacity, guarded-path, orphan-unarmed, container, backlog-aggregate,
#   footprint-held, cap-held, blockpark
# who ∈ operator | machine | none
# >>>REPLAY:item-class>>>
# Per-pass accumulator: newline-joined lines "repo|item|class|who|base" (ADR-125 lane label)
# Gets flushed once after the stacks loop via item_class_flush.
ITEM_CLASS_ROWS=""

item_class_push() {   # accumulate one item class row for batch push
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}" base="${5:-}"
  # ADR-125 per-lane famine gauge: every row carries the item's LANE base, so a starved lane is a
  # query (`agent_item_class{class="queued-ready"} by (base)`) instead of an anecdote. The base is
  # OPTIONAL at the call site on purpose, and every caller passes it as `${var:-}` for a second
  # reason: a replay composition runs ONE extracted block without the per-repo pass that assigns
  # `default_branch`/`qbase`, and a bare `$var` there is an unbound-variable death under `set -u`.
  # Guarding at the call site keeps the fixtures' bridges free of scaffolding they would otherwise
  # have to declare (and which the ADR-103 pin-vacuity gate would then read as a pin claim). In
  # production both variables are always assigned before these lines, so the guard never degrades — `unit_lane_of` is the ONE resolution home (record at
  # emission, fall back to the repo default branch, then `master`), so a caller only passes it
  # explicitly where it holds a better answer than the map: the queued clause's own `$qbase`, and
  # the aggregate/container rows, which are not one item's lane and take the default branch.
  [ -n "$base" ] || base="$(unit_lane_of "$repo" "$item")"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|${base}\n"
}

item_class_flush() {   # batch-push all accumulated rows, carrying first-transition timestamps
  [ -n "$SCAN_PHASE_PGW" ] && [ -n "$SCAN_PHASE_POD" ] || return 0
  [ -z "$ITEM_CLASS_ROWS" ] && return 0

  local now rows_body metrics_before metric_line repo item class who base since_ts ts_line
  now="$(sp_now)"

  # Query pushgateway to get existing metrics for timestamp carry-over (GET the group's current state)
  # The pushgateway persists every pushed group until it is replaced, so we can read back the last tick's
  # timestamp values and preserve them for unchanged (item, class) pairs.
  metrics_before="$(curl -fsS --max-time 5 \
    "${SCAN_PHASE_PGW}/metrics?job=agent_board&namespace=${SCAN_PHASE_NS}" 2>/dev/null || echo "")"

  # Build the new exposition batch, preserving timestamps for unchanged items
  rows_body="# TYPE agent_item_class gauge
# HELP agent_item_class 1 = the scan classified this item in this class this tick.
# TYPE agent_item_class_since_timestamp_seconds gauge
# HELP agent_item_class_since_timestamp_seconds Unix epoch at which this item was classified into this class.
"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|' read -r repo item class who base <<<"$line"
    [ -n "$repo" ] && [ -n "$item" ] && [ -n "$class" ] && [ -n "$who" ] || continue
    # A row with no base is a caller that predates the lane map, not a reason to drop the row:
    # fall back to the repo default branch so the series never loses a member to a missing label.
    [ -n "$base" ] || base="$(unit_lane_default "$repo")"

    # Look up the timestamp from the previous tick (if the item+class pair existed and is unchanged)
    # Extract from metrics_before: agent_item_class_since_timestamp_seconds{...repo="X",item="Y",class="Z",...} VALUE
    if [ -n "$metrics_before" ]; then
      # ⚠ The carry-over must match on the FULL label set the row is pushed with — `base` included.
      # A since-timestamp looked up on four of five labels would survive a lane change and report
      # the item as having been in its new lane since before it moved (ADR-125 per-lane rows).
      ts_line="$(printf '%s' "$metrics_before" | grep -F "agent_item_class_since_timestamp_seconds" \
        | grep "repo=\"${repo}\"" | grep "item=\"${item}\"" | grep "class=\"${class}\"" \
        | grep "who=\"${who}\"" | grep "base=\"${base}\"" | sed 's/.*} //' | head -1 || true)"
    else
      ts_line=""
    fi

    # Use existing timestamp if found; otherwise use now (first transition)
    case "$ts_line" in
      *[0-9]*) since_ts="$ts_line" ;;
      *) since_ts="$now" ;;
    esac

    rows_body="${rows_body}agent_item_class{repo=\"${repo}\",item=\"${item}\",class=\"${class}\",who=\"${who}\",base=\"${base}\"} 1
agent_item_class_since_timestamp_seconds{repo=\"${repo}\",item=\"${item}\",class=\"${class}\",who=\"${who}\",base=\"${base}\"} ${since_ts}
"
  done <<<"$(printf '%b' "$ITEM_CLASS_ROWS")"

  # Do ONE batched POST for this (tick, namespace) pair
  printf '%s' "$rows_body" \
    | curl -fsS --max-time 5 --data-binary @- \
        "${SCAN_PHASE_PGW}/metrics/job/agent_board/namespace/${SCAN_PHASE_NS}" >/dev/null 2>&1 \
    || true   # pushgateway unreachable — observability fault, never a dispatch blocker

  ITEM_CLASS_ROWS=""
}
# <<<REPLAY:item-class<<<
# NO-OP ROUND PREDICATE — shared by the ci-red clause (FU-115b) and changes-requested (FU-147).
# Input: `gh pr view N --json comments,commits`. Prints "1" when the LAST completed round pushed
# nothing. Defined once because two copies WILL drift, and this one was already wrong twice:
#   (1) it read `.commits[]?.commit.committedDate` — but that field is TOP-LEVEL in gh output, so
#       every commit was null, $head was "", and the `$head == ""` branch fired "no-op" on every
#       PR it ever saw. Never observed only because no ci-red PR reached a completed round since
#       2026-08-02 (zero agent/arbitrate labels fleet-wide, zero of its comments in search).
#   (2) COUNTING is the fix, not comparison: a SUCCESSFUL round pushes its commit and only THEN
#       posts stats, so `newest_stats > newest_commit` is true for good rounds too. The round that
#       produced the newest commit posts exactly ONE stats comment after it — so a SECOND one
#       means a later round finished without pushing. Hence `>= 2`.
# Verified against circles PR#39 real history: final state (r6 pushed) -> no; state after r3 (the
# real truncation no-op) -> YES; state after r4 (real push) -> no. Merge commits excluded (the
# updater BEHIND merges are not round output — the nine-review-loop lesson).
#
# ── THE ROUND EVIDENCE, TWO CHANNELS ────────────────────────────────────────────────────────────
# Three clauses in this file count completed fix rounds off "one 🤖 Agent run stats comment per
# round" — the no-op predicate below, the per-PR `attempts` counter, and the issue-keyed ceiling.
# ADR-103/#210 moves that table off the timeline onto the `agent-ride` check-run plus ONE line
# appended to a single `<!-- agent-summary -->` comment, so "one round = one more comment" stops
# being true and a shape-only reader silently counts ZERO. That is not a cosmetic regression: at
# attempts=0 the ci-red clause never reaches RED_ROUNDS_MAX, never escalates to arbitrate, and
# re-dispatches the same red input forever — the exact livelock FU-115 built the cap to bound.
#
# So this def reads BOTH channels and is the ONLY place either shape is matched:
#   new — `<!-- agent-event kind=stats ts=… -->` markers inside the summary comment, one per round;
#   old — a whole comment containing "Agent run stats", timestamped by the comment itself.
# A UNION, not a replacement, and it stays one for as long as both emitters can post. The primary
# emitter is agent-finalize in the POD (agent-runtime#62, not yet landed); only the launcher
# fallback moves in this repo. Until the cross-repo half merges, a single PR can carry rounds in
# both shapes, and a reader that picked one would under-count either the old rides or the new.
# Delete the old branch when agent-runtime#62 has shipped AND no open PR still carries the shape —
# not before, and not by assuming the timeline is clean.
# >>>REPLAY:round-evidence>>>
STATS_TS_DEF='def stats_ts: [ .comments[]? | (.body // "") as $b
  | if ($b | startswith("<!-- agent-summary -->"))
    then [ $b | scan("<!-- agent-event kind=stats ts=([^ ]+) -->")[0] ]
    elif ($b | test("Agent run stats")) then [ .createdAt ]
    else [] end | .[] ];'
# FU-147 (homelab#868): the re-label must not fire over a NEWER arbitration ruling. The 12:18
# re-fire on PR#862 re-read "stats without commits" minutes after the 12:15 arbitration had
# already ruled that same round a strike — the predicate had no notion of an arbitration event
# newer than the evidence it was built on. So the no-op predicate now also requires that the
# newest no-op stats marker POST-DATES the newest arbitration event (an "ARBITRATE" comment).
# An arbitration event newer than the stats marker means the ruling already covered this round;
# re-labelling would re-dispatch the same escalation the ruling just resolved.
NOOP_ROUND_JQ="${STATS_TS_DEF}"'
  ([.commits[]? | select((.messageHeadline // "" | startswith("Merge branch")) | not) | .committedDate] | max // "") as $head
  | ([ stats_ts[] | select($head == "" or . > $head) ] | length) as $after
  | ([ .comments[]? | select((.body // "") | startswith("ARBITRATE")) | .createdAt ] | max // "") as $arb_ts
  | ([ stats_ts[] | select($head == "" or . > $head) ] | max // "") as $newest_noop_ts
  | if $after >= 2 and ($arb_ts == "" or $newest_noop_ts > $arb_ts) then "1" else "" end'
# <<<REPLAY:round-evidence<<<
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# FU-199 / #1240 CAP SPLIT: codeowner-parked PRs (bot-approved ∧ REVIEW_REQUIRED) count
# against their own larger bound so parked nits never freeze the dispatch lane.
REPO_BLOCKPARK_CAP="${REPO_BLOCKPARK_CAP:-10}"

# ── PR STATE FINGERPRINT (homelab#198) ────────────────────────────────────────────────────────
# The arbitrate, ci-red and merge-conflict (homelab#595) DISPATCH legs are level-triggered off a
# label / a red rollup, so they re-emit their unit every scan for as long as that condition holds
# — existence, not currency.
# Live 2026-08-09 (oracle-fleet PR#234): five coordinator rides in ~30 minutes against BYTE-
# IDENTICAL state (same head, same red `e2e`, same stale CHANGES_REQUESTED, a `gh run rerun` 403),
# each correctly ruling "no change, escalation stands" and exiting. The anomaly breaker latched
# `agent/error` on the 4th — correctly, but a belt is not a guard: four opus rides had already
# been spent to conclude nothing.
#
# So the emission gains CURRENCY, keyed on a fingerprint of the state a ride would actually read:
#   head sha | reviewDecision | every check's conclusion | newest verdict's submittedAt
# Nothing else — a comment (including OUR marker and the coordinator's own ruling prose) must not
# move the hash, or the debounce disarms itself on the very ride it is debouncing. In-flight checks
# normalize to PENDING so a re-run reads as one state change, not one per polled sample.
#
# The marker is a `state-fp:<hash>` line in a PR comment, written at DISPATCH time by the block at
# the bottom of this script — deliberately NOT at emission time. The scan emits many units and
# dispatches exactly ONE (the priority loop): marking at emission would silently retire an
# arbitrate unit that lost the race to a higher-priority clause and never rode at all.
# FAIL-OPEN throughout, matching this file's guarded-probe posture: an unreadable probe or a
# missing hasher yields an empty fingerprint, which can never equal a recorded one, so the clause
# behaves exactly as it did before this guard existed. The breaker stays as the backstop for
# fingerprint BUGS (a hash that moves on its own re-arms the churn this guard removes).
# The five blocks below carry `>>>REPLAY:<name>>>>` sentinels: agents/state-fp-replay.sh EXTRACTS
# and executes them against fixtures (homelab#201, the rail-degrade-replay pattern) rather than
# transcribing them, so the pin cannot drift from this code. Moving a block is fine; dropping a
# sentinel is not — the harness exits 3 and says which one it could not find.
# >>>REPLAY:state-fp-jq>>>
STATE_FP_JQ='[ "head=" + (.headRefOid // "")
  , "review=" + (.reviewDecision // "NONE")
  , "checks=" + ([ .statusCheckRollup[]?
                   | ((.name // .context // "?") + "="
                      + (((.conclusion // .state) // "") | if . == "" then "PENDING" else . end)) ]
                 | sort | join(","))
  , "verdict=" + ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                    | .submittedAt ] | max // "")
  ] | join("|")'
# ci-red clause fingerprint (homelab#1108): same as STATE_FP_JQ but folds each check's startedAt
# into the checks line, so a CI rerun (same head_sha, new startedAt) changes the hash and the
# debounce releases. Deliberately NOT used by arbitrate — per-check churn was re-arming arbitrate
# as noise (homelab#1011); the two clauses want different sensitivity, which is itself the finding.
STATE_FP_JQ_CIRED='[ "head=" + (.headRefOid // "")
  , "review=" + (.reviewDecision // "NONE")
  , "checks=" + ([ .statusCheckRollup[]?
                   | ((.name // .context // "?") + "="
                      + (((.conclusion // .state) // "") | if . == "" then "PENDING" else . end)
                      + "@" + (.startedAt // "")) ]
                 | sort | join(","))
  , "verdict=" + ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                    | .submittedAt ] | max // "")
  ] | join("|")'
# arbitrate clause fingerprint (homelab#1011): narrower than STATE_FP_JQ — drops per-check
# conclusions (PR#1003's mover — checks completing one at a time inside a rollup are not
# arbitration-relevant) and narrows head= to the newest NON-merge commit (PR#1030's mover —
# the updater merging master rewrites head unconditionally, reusing the NOOP_ROUND_JQ idiom).
STATE_FP_JQ_ARBITRATE='[ "head=" + ([ .commits[]? | select((.messageHeadline // "" | startswith("Merge branch")) | not) | .oid ] | last // "")
  , "review=" + (.reviewDecision // "NONE")
  , "verdict=" + ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
                    | .submittedAt ] | max // "")
  ] | join("|")'
# Newest recorded marker, by comment createdAt — `last` on the raw list would trust gh ordering.
# Supports BOTH old format (state-fp:<hash>) and new format (state-fp:<clause>:<hash>) for backwards compatibility.
STATE_FP_LAST_JQ='([ .comments[]? | select((.body // "") | test("state-fp:([a-z-]+:)?[0-9a-f]{6,64}")) ]
  | sort_by(.createdAt) | last // {})
  | (((.body // "") | scan("state-fp:(?:[a-z-]+:)?([0-9a-f]{6,64})") | .[0]) // "")'

# Clause-scoped state-fp reader: helper to extract clause-scoped state-fp markers.
# Takes a clause name as an argument and returns the hash from state-fp:<clause>:<hash>,
# falling back to state-fp:<hash> (old format) if no clause-scoped marker exists.
# Called from pr_state_fp_pair when a clause is specified.
state_fp_for_clause() {
  local clause="${1:?}" fp_probe="${2:?}"
  local clause_marker hash
  # Try to find clause-scoped marker first: state-fp:<clause>:<hash>
  clause_marker="$(printf '%s' "$fp_probe" | jq -r --arg c "$clause" \
    '([ .comments[]? | select((.body // "") | test("state-fp:" + $c + ":[0-9a-f]{6,64}")) ]
      | sort_by(.createdAt) | last // {})
     | (((.body // "") | scan("state-fp:" + $c + ":([0-9a-f]{6,64})") | .[0]) // "")' 2>/dev/null)" || clause_marker=""
  if [ -n "$clause_marker" ]; then
    printf '%s' "$clause_marker"
    return 0
  fi
  # Fall back to old format: state-fp:<hash> (backwards compatibility)
  hash="$(printf '%s' "$fp_probe" | jq -r \
    '([ .comments[]? | select((.body // "") | test("state-fp:[0-9a-f]{6,64}")) ]
      | sort_by(.createdAt) | last // {})
     | (((.body // "") | [ scan("state-fp:([0-9a-f]{6,64})") ] | last | .[0]) // "")' 2>/dev/null)" || hash=""
  printf '%s' "$hash"
  return 0
}
# <<<REPLAY:state-fp-jq<<<

# pr_state_fp_pair <slug> <pr> [clause] → "<current>|<recorded>", either side empty when unknown.
# ONE probe answers both halves, so the comparison can never straddle two snapshots of the PR.
# When clause is "ci-red" uses STATE_FP_JQ_CIRED (includes check startedAt — homelab#1108) so a
# CI rerun changes the fingerprint; "arbitrate" uses STATE_FP_JQ_ARBITRATE (drops per-check
# conclusions and narrows head to the newest non-merge commit — homelab#1011); other clauses use
# STATE_FP_JQ. Always exits 0: under `set -e` a probe failure here must skip the guard, never
# kill the scan.
# >>>REPLAY:state-fp-pair>>>
pr_state_fp_pair() {
  # Declared on their own line, never `local x="$(cmd)"` — that form makes `local` the command
  # whose status is tested, so the `|| fallback` and `set -e` both read the wrong exit code.
  local fp_probe fp_raw fp_prev fp_cur fp_jq pr_json clause
  # Use pre-fetched JSON if provided and valid. When the 4th argument IS provided (even if
  # empty — the hoisted fetch failed), treat it as the probe result rather than falling back
  # to a second fetch (homelab#1211). When it is NOT provided, fetch independently.
  if [ "${4+set}" = "set" ]; then
    pr_json="$4"
    if [ -n "$pr_json" ] && jq -e . >/dev/null 2>&1 <<<"${pr_json:-null}"; then
      fp_probe="$pr_json"
    else
      fp_probe=''
    fi
  else
    fp_probe="$(gh pr view "$2" --repo "$1" \
        --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments,commits 2>/dev/null)" || fp_probe=''
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"${fp_probe:-null}"; then printf '%s|%s\n' '' ''; return 0; fi
  clause="${3:-}"
  case "$clause" in
    ci-red)    fp_jq="$STATE_FP_JQ_CIRED" ;;
    arbitrate) fp_jq="$STATE_FP_JQ_ARBITRATE" ;;
    *)         fp_jq="$STATE_FP_JQ" ;;
  esac
  fp_raw="$(printf '%s' "$fp_probe" | jq -r "$fp_jq" 2>/dev/null)" || fp_raw=''
  # Clause-scoped state-fp read: if a clause is provided, use the clause-scoped reader
  if [ -n "$clause" ]; then
    fp_prev="$(state_fp_for_clause "$clause" "$fp_probe")" || fp_prev=''
  else
    fp_prev="$(printf '%s' "$fp_probe" | jq -r "$STATE_FP_LAST_JQ" 2>/dev/null)" || fp_prev=''
  fi
  fp_cur=''
  # `sha256sum` is coreutils, which this script already requires (`date -u -d`), but a missing
  # hasher must degrade to "no fingerprint" rather than abort the stack's whole scan.
  [ -n "$fp_raw" ] && fp_cur="$(printf '%s' "$fp_raw" | sha256sum 2>/dev/null | cut -c1-12)"
  case "$fp_cur" in *[!0-9a-f]*|'') fp_cur='';; esac
  printf '%s|%s\n' "$fp_cur" "$fp_prev"
  return 0
}
# <<<REPLAY:state-fp-pair<<<

# ── BLOCKED-ON PREDICATE (homelab#1188) ────────────────────────────────────────────────────────
# A terminal ruling may record what it waits on via a `blocked-on:` marker anchored at the start
# of a comment (like every other marker in this lane — `AGENT_STRIKE:`, `AGENT_INFEASIBLE:`,
# `state-fp:`). The scan suppresses re-dispatch while that predicate holds.
#
# Grammar: `blocked-on: <kind>=<ref>` with `kind ∈ {human, issue, pr}`.
#   - `blocked-on: human`              → waiting on a human (no new review/comment since marker)
#   - `blocked-on: issue=<number>`     → waiting on issue #number to close
#   - `blocked-on: pr=<number>`        → waiting on PR #number to merge/close
#
# The marker is read from the PR's comments (newest by createdAt). While the marker is present
# AND its named blocker is still unresolved, the clause reports instead of dispatching — the same
# report-vs-dispatch shape the `state-fp:` debounce already has.
#
# >>>REPLAY:blocked-on-jq>>>
# Extract the newest blocked-on marker from PR comments (anchored at start of comment body).
BLOCKED_ON_JQ='([ .comments[]? | select((.body // "") | test("^blocked-on: (human|issue=[0-9]+|pr=[0-9]+)")) ]
  | sort_by(.createdAt) | last // {})
  | ((.body // "") | capture("^blocked-on: (?<kind>human|issue=[0-9]+|pr=[0-9]+)") | .kind // "")'
# <<<REPLAY:blocked-on-jq<<<

# pr_blocked_on_check <slug> <pr> [pr_json] → "blocked|<reason>" or "clear".
# ONE probe reads the marker and checks the blocker state. Fail-open throughout: an unreadable
# probe or missing marker yields "clear" (pre-#1188 behaviour — dispatch proceeds).
# When a 3rd argument (pre-fetched PR JSON) is provided, it is used instead of fetching — the
# caller has already fetched the superset for pr_state_fp_pair (homelab#1211).
# >>>REPLAY:blocked-on-check>>>
pr_blocked_on_check() {
  local slug="${1:?}" pr="${2:?}" pr_json marker kind ref probe rc
  # Use pre-fetched JSON if provided and valid. When the 3rd argument IS provided (even if
  # empty — the hoisted fetch failed), treat it as the probe result rather than falling back
  # to a second fetch (homelab#1211). When it is NOT provided, fetch independently.
  if [ "${3+set}" = "set" ]; then
    pr_json="$3"
    if [ -n "$pr_json" ] && jq -e . >/dev/null 2>&1 <<<"${pr_json:-null}"; then
      probe="$pr_json"
    else
      probe=''
    fi
  else
    probe="$(gh pr view "$pr" --repo "$slug" --json comments,reviews 2>/dev/null)" || probe=''
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"${probe:-null}"; then printf 'clear\n'; return 0; fi
  marker="$(printf '%s' "$probe" | jq -r "$BLOCKED_ON_JQ" 2>/dev/null)" || marker=''
  [ -n "$marker" ] || { printf 'clear\n'; return 0; }
  kind="${marker%%=*}"
  ref="${marker#*=}"
  # If ref equals kind (no '=' separator), it's a bare kind like "human"
  [ "$ref" = "$marker" ] && ref=""
  case "$kind" in
    human)
      # Check if there's been any human review or comment since the marker was written.
      # Read the marker's timestamp and compare against the newest review/comment.
      # `gh pr view --json comments,reviews` populates ONLY `.author.login` on comment/review
      # authors — there is no `.author.is_bot` here (that exists on issue/PR-LEVEL author objects,
      # which is what lines 1662/1672 read). And WORKER_AUTHOR's default is the `app/`-prefixed
      # form, which never equals a comment author login. So normalize to the comment-author form
      # and exclude the loop's own identities by login.
      local marker_ts newest_ts wa_login rv_login
      wa_login="${WORKER_AUTHOR:-app/homelab-agents-1234}"; wa_login="${wa_login#app/}"; wa_login="${wa_login%\[bot\]}"
      rv_login="${REVIEWER_AUTHOR:-homelab-reviewer}"; rv_login="${rv_login%\[bot\]}"
      marker_ts="$(printf '%s' "$probe" | jq -r '[.comments[]? | select((.body // "") | test("^blocked-on: human")) | .createdAt] | max // ""' 2>/dev/null)" || marker_ts=''
      [ -n "$marker_ts" ] || { printf 'clear\n'; return 0; }
      # A HUMAN review or a HUMAN non-marker comment clears the block — the README's own
      # Resolution rule. Reviews carry `submittedAt`, comments `createdAt`; an entry with no
      # resolvable author does not count as human engagement.
      newest_ts="$(printf '%s' "$probe" | jq -r --arg wa "$wa_login" --arg rv "$rv_login" '
        [ (.comments[]? | select(((.body // "") | test("^blocked-on: human")) | not)
                        | select((.author.login // "") != "" and (.author.login != $wa) and (.author.login != $rv))
                        | .createdAt),
          (.reviews[]?  | select((.author.login // "") != "" and (.author.login != $wa) and (.author.login != $rv))
                        | .submittedAt) ]
        | map(select(. != null)) | max // ""' 2>/dev/null)" || newest_ts=''
      # If there's a non-marker entry newer than the marker, a human has engaged
      if [ -n "$newest_ts" ] && [[ "$newest_ts" > "$marker_ts" ]] 2>/dev/null; then
        printf 'clear\n'
      else
        printf 'blocked|human\n'
      fi
      return 0
      ;;
    issue)
      # Check if the issue is still open
      local state
      state="$(gh issue view "$ref" --repo "$slug" --json state --jq '.state' 2>/dev/null)" || state=''
      case "$state" in
        OPEN) printf 'blocked|issue=%s\n' "$ref";;
        *)    printf 'clear\n';;
      esac
      return 0
      ;;
    pr)
      # Check if the PR is still open
      local pr_state
      pr_state="$(gh pr view "$ref" --repo "$slug" --json state --jq '.state' 2>/dev/null)" || pr_state=''
      case "$pr_state" in
        OPEN) printf 'blocked|pr=%s\n' "$ref";;
        *)    printf 'clear\n';;
      esac
      return 0
      ;;
    *)
      printf 'clear\n'
      return 0
      ;;
  esac
}
# <<<REPLAY:blocked-on-check<<<

# homelab#155 belt: how long a phantom `agent/in-progress` (no pod, no PR) must PERSIST before the
# scan reconciles the label itself. One full scan interval is the */30 per-stack coordinate-<stack> cron
# (agents/coordinator/reflexes-argo.yaml); 15 min is that plus margin for cron jitter and the
# doorbell, so the belt can never actuate on the same instant of state it first observed. The
# asymmetry sets the default: a phantom held one extra pass costs 10 minutes, a wrongly cleared
# label costs a duplicate ride on live work.
C4C5_PERSIST_S="${C4C5_PERSIST_S:-900}"

# kubectl for the v2 (C4/C5) predicate — same resolution as agent-session.sh: jail → tofu/kubeconfig;
# in-cluster (the coordinator-reflex CronJob) → the pod ServiceAccount (KUBE empty).
if [ -f "${HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"; else KUBE=""; fi

KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"

# SESSION-POD JANITOR (2026-07-24 — the 118-pod audit): coordinator item/tick pods and reviewer
# pods are bare `kubectl create` pods (the pod-name idempotency design) — nothing TTLs them, and
# the reviewer launcher's "remove the pod:" line was a manual instruction nobody ran (55+33 in
# agent-coordinator, 30 in oracle-agents). Each scan janitors its OWN namespace: terminal
# session pods >24h (incident-forensics window; transcripts/stats upload in-pod before exit).
# No PVCs on these — clutter, not the scratch-pool hazard — but clutter compounds.
OWN_NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
if [ -n "$OWN_NS" ]; then
  for c in $("$KUBECTL" $KUBE -n "$OWN_NS" get pods -o json 2>/dev/null | jq -r --arg now "$(date -u +%s)" '
      .items[]
      | select(.status.phase == "Succeeded" or .status.phase == "Failed")
      | select(.metadata.name | test("^(coordinator|reviewer)-"))
      | select((.metadata.creationTimestamp | fromdateiso8601) < (($now | tonumber) - 86400))
      | .metadata.name' 2>/dev/null); do
    echo "janitor: deleting terminal session pod ${OWN_NS}/${c} (>24h; transcripts are in S3)"
    "$KUBECTL" $KUBE -n "$OWN_NS" delete pod "$c" --ignore-not-found >/dev/null 2>&1 || true
  done
fi

# ── DOORBELL COLLAPSE (ADR-106 (5) — the goal-#278 convoy) ──────────────────────────────────────
# Argo collapses nothing: every /coordinate ring became one `generateName` Workflow queued on the
# `coordinator-scan` mutex, and the goal night turned ~100–150 rings into 56 Pending workflows
# draining serially — a fresh edge queued BEHIND stale wakes (ADR-093 regression; the CronJob era
# collapsed via fixed-name `kubectl create`). The collapse is RECEIVER-side, not Sensor-side:
# a fixed name at the Sensor silently drops any ring that lands while a same-named workflow is
# Running or awaiting TTL — each a lost edge the cron must service, i.e. a defect by 017790c's
# accounting. Instead, at scan start — STRICTLY BEFORE the first GitHub listing — this scan
# absorbs every PENDING sibling ring in its namespace: any state that caused those rings is by
# definition older than this moment and therefore visible to the re-list that follows; any ring
# arriving AFTER the sweep creates a fresh workflow that survives and runs next. Zero lost edges.
#   - FULL scans only. A unit fast-path scan (SCAN_UNIT set) is NARROWER than a pending full
#     sweep — absorbing one would silently drop work (rule #6).
#   - Name prefix `coordinate` catches the Sensor's `coordinate-`/`coordinate-perstack-` and the
#     per-stack `coordinate-<stack>` cron children; it deliberately misses `switchboard-*`
#     (the ADR-120 global runs — seconds-long resolvers, nothing to absorb), `review-*`,
#     `janitor-*` — those are different functions, not rings.
#   - Fail-open, loudly: an unreadable list or refused delete absorbs nothing and the extra
#     workflow just runs behind the mutex — today's behavior, never a lost edge.
#   - The list is LABEL-SCOPED to non-terminal workflows (`workflows.argoproj.io/completed!=true`
#     — the controller stamps `completed=true` on every Succeeded/Failed/Error workflow; a ring
#     the controller has not touched yet carries no label at all and `!=true` matches it too).
#     An unscoped `get workflows -o json` returns the namespace's whole RETAINED history — in
#     agent-coordinator that is ~1,000 review/respond runs under the 7d TTL, 53 MB of JSON
#     held in a bash variable and then parsed by jq: 450–500 Mi resident, over the switchboard
#     pod's 512 Mi limit. 153 consecutive switchboard runs OOMKilled 2026-09-05/06 on exactly
#     this line, silently (docs/incidents/2026-09-06-switchboard-oom-silent-failures.md). The
#     jq phase filter below stays as the belt — the replay stub drops the selector from its key.
# >>>REPLAY:doorbell-collapse>>>
DOORBELL_WF_SELF="${DOORBELL_WF_SELF:-${HOSTNAME:-}}"
absorb_pending_rings() {
  case "${SCAN_UNIT:-}" in ""|"-") ;; *) return 0;; esac
  [ -n "$SPAWN" ] || return 0
  [ -n "$DOORBELL_WF_SELF" ] || return 0
  local ns raw names n
  ns="${SCAN_PHASE_NS:-}"
  { [ -n "$ns" ] && [ "$ns" != "unknown" ]; } || return 0   # jail/manual run — no workflow world
  if ! raw="$("$KUBECTL" $KUBE -n "$ns" get workflows -l 'workflows.argoproj.io/completed!=true' -o json 2>/dev/null)" \
     || ! jq -e . >/dev/null 2>&1 <<<"${raw:-null}"; then
    echo "doorbell-collapse: workflow list PROBE-FAILED in ${ns} — absorbing nothing (extra wakes just queue)" >&2
    return 0
  fi
  # No .status yet (the controller hasn't touched it) counts as Pending — that is the freshest
  # kind of sibling ring and exactly the one worth absorbing.
  names="$(jq -r --arg self "$DOORBELL_WF_SELF" '.items[]?
      | select((.metadata.name // "") != $self)
      | select((.metadata.name // "") | startswith("coordinate"))
      | select((.status.phase // "Pending") == "Pending")
      | .metadata.name' <<<"$raw" 2>/dev/null)" || names=""
  for n in $names; do
    if "$KUBECTL" $KUBE -n "$ns" delete workflow "$n" --ignore-not-found >/dev/null 2>&1; then
      echo "doorbell-collapse: absorbed pending ring ${ns}/${n} — this scan's re-list covers it"
    else
      echo "doorbell-collapse: could not delete ${ns}/${n} (RBAC?) — it runs behind the mutex instead" >&2
    fi
  done
  return 0
}
# <<<REPLAY:doorbell-collapse<<<
absorb_pending_rings

# ── DISPATCH PHASE TIMINGS — the rows ABOVE the launcher (FU-160 coordinator half, homelab#319) ──
# `agent_run_phase_seconds` (agents/agent-session.sh, homelab#287) opens at `dispatch-gates`, which
# is the moment the LAUNCHER starts. Everything before that stayed archaeology, and it is not
# small: in the reconstructed specimen (docs/spikes/ride-latency-breakdown.md) the dispatch chain
# is 2m16s of an 8m46s ride, its single biggest line 51s of coordinator pod spin-up — the shape
# that presents as "the loop feels slow" and as nothing else. These are the COORDINATOR's
# timestamps, which is exactly why the launcher half could not emit them.
#
#   agent_dispatch_phase_seconds{phase=ring-to-scan|scan}                        ← here
#   agent_dispatch_phase_seconds{phase=coordinator-spinup|coordinator-session}   ← coordinator-session.sh
#
# ITS OWN METRIC NAME, not the launcher's, and the reasons compound:
#   (1) HELP is per metric NAME. A third emitter pushing `agent_run_phase_seconds` with a third
#       HELP string is an exposition-level inconsistency the pushgateway resolves by picking a
#       winner and logging it (prometheus/pushgateway#194) — and the honest text for these rows is
#       not the launcher's ("this ride spent … in one LAUNCHER-owned phase").
#   (2) These rows are per STACK, not per ride. The scan runs BEFORE an item is picked, so there is
#       no (project, issue, round) tuple for it to carry; folding two denominators into one
#       `by (phase)` aggregate yields a fleet p50 that means nothing.
#   (3) AgentRunPhaseSlow's guards do not inherit sensibly — the note beside it in
#       argocd/resources/pushgateway/prometheusrule.yaml says which guard fails how.
#
# GROUPED BY (project, role), `project` = the stack's MAIN repo — the FU-061 convention the
# transcript manifests already use (main repo, never the stack name). One group per stack per
# emitter, overwritten by the next dispatch: the pushgateway serves every pushed group FOREVER, so
# a per-dispatch key would leak one group per ride (the lesson `agent_scan_phase`'s namespace key
# is already carrying). TWO groups, not one, because the scan and coordinator-session.sh are two
# PROCESSES and a POST replaces a metric name within a group — share a group and one of them
# silently deletes the other's rows.
#
# Best-effort throughout, exactly like `scan_phase` above: a metrics sink being down is an
# observability fault and must never defer or fail a dispatch.
# >>>REPLAY:dispatch-phase>>>
DISPATCH_PHASE_PGW="${AGENT_PUSHGATEWAY_URL-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
DISPATCH_PHASE_POD="${SCAN_PHASE_POD:-${HOSTNAME:-}}"
DISPATCH_PHASE_NS="${SCAN_PHASE_NS:-$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo unknown)}"
DISPATCH_PHASE_WAKE=""       # "<source>|<ring-epoch>" — probed at most once per scan (retried while unreadable)
DISPATCH_PHASE_WARNED=""
dp_now() { date -u +%s; }    # replay seam: the wall clock
# replay seam: HOW THIS SCAN WAS WOKEN, read off its own Workflow object rather than plumbed
# through the CronWorkflow spec — that spec lives in agents/coordinator/, which pin-only-lint guards
# and which homelab#309 holds this issue's whole footprint on. `creationTimestamp` is the moment the
# Sensor (or the cron) submitted the Workflow, so the row it feeds includes the `coordinator-scan`
# mutex wait, the schedule, the image pull and container start — all of it, deliberately: that IS
# dispatch latency, whatever caused it. Argo names a single-template Workflow's pod after the
# workflow (`coordinate-perstack-mnhzm`, the spike's specimen), so the pod name is the key; if that
# naming ever changes the read misses, the row is simply absent, and nothing else moves.
#
# THE WAKE SOURCE decides two things (017790c: ALL events have doorbells, cron demoted to failure
# detector — MEASURED, not promised): a cron-submitted Workflow carries the controller's
# `workflows.argoproj.io/cron-workflow` label and its creationTimestamp is a schedule, not a ring,
# so (1) the `ring-to-scan` row is emitted for EDGE wakes only — a row exists ⇔ edge-woken — and
# (2) each dispatch stamps an epoch-valued wake gauge below, TWO metric NAMES rather than one
# `source` label because a pushgateway POST replaces per metric name within a group: one name per
# source is what lets an edge dispatch land without deleting the record of the last cron one.
# `changes()` over an epoch gauge counts dispatches, so "% edge-woken" is a query and a recurring
# cron-woken dispatch is an alert (AgentDispatchCronWoken), not an anecdote.
dp_wake() {   # → "edge|<ring-epoch>" | "cron|" | "" (unreadable — the caller retries next dispatch)
  local raw cron ts
  [ -n "$DISPATCH_PHASE_POD" ] || return 0
  raw="$("$KUBECTL" $KUBE -n "$DISPATCH_PHASE_NS" get workflow "$DISPATCH_PHASE_POD" -o json 2>/dev/null)" || return 0
  jq -e . >/dev/null 2>&1 <<<"${raw:-null}" || return 0
  cron="$(jq -r '.metadata.labels["workflows.argoproj.io/cron-workflow"] // ""' <<<"$raw" 2>/dev/null)" || cron=""
  if [ -n "$cron" ]; then printf 'cron|'; return 0; fi
  ts="$(jq -r '(.metadata.creationTimestamp // "") | select(. != "") | fromdateiso8601' <<<"$raw" 2>/dev/null)" || ts=""
  printf 'edge|%s' "$ts"
}
# TWO marks, and conflating them is the bug this comment exists to prevent. `SECONDS` is bash's own
# count since this shell started, so T0 is the SCRIPT's start rather than this line — the janitor
# and the guarded-set read above are part of the deterministic pass and belong inside the number.
# T0 is the RIGHT edge of the ring row and never moves; MARK is the left edge of the open `scan`
# segment and moves at every dispatch (see below).
DISPATCH_PHASE_T0="$(( $(dp_now) - SECONDS ))"
DISPATCH_PHASE_MARK="$DISPATCH_PHASE_T0"
dispatch_phase() {   # $1 = the stack's MAIN repo — publish the scan-side rows, at a dispatch
                     # $2 = clause (queued-dispatch / changes-requested / ci-red / …) — keys the per-clause wake series (homelab#459)
                     # $3 = unit class, BARE (`fix` / `goal` — :1642 defaults it; never `task/fix`) — populated on queued-dispatch/c4c5 only
                     # $4 = the dispatched unit's LANE base (ADR-125) — keys the per-lane wake series; empty = unkeyed (the pre-ADR-125 group)
  local project="${1:-}" clause="${2:-}" ukind="${3:-}" ubase="${4:-}" now ring family="" wake="" cseg="" useg="" bseg=""
  now="$(dp_now)"
  # The per-clause breakdown (homelab#459 — the FU-168 emitter hunt) rides a SECOND push below
  # whose GROUPING KEY carries the dimensions. It cannot be body labels on any shared-group
  # metric: pushgateway replacement scope is (grouping key, metric name) — a POST replaces every
  # stored sample sharing a metric NAME within the group, irrespective of label values, so two
  # consecutive dispatches with different clauses would evict each other (the PR#1192 round-3
  # arbitration; the same FU-176 semantics iac-lane.md documents). Per-(clause, unit) groups make
  # each series its own group — sticky, so `topk by (clause)` is meaningful over a window.
  # Guard, not ceremony: production values are fixed clause slugs and the bare class, but a path
  # segment must never be empty or carry `/`, so strip to [A-Za-z0-9._-] and drop what's left empty.
  cseg="$(printf '%s' "$clause" | tr -cd 'A-Za-z0-9._-')"
  [ -n "$ukind" ] && useg="$(printf '%s' "$ukind" | tr -cd 'A-Za-z0-9._-')"
  # ADR-125 per-lane famine gauge. The base rides the GROUPING KEY, never a body label, for the
  # same pushgateway reason the two wake metric NAMES exist: a POST replaces every sample sharing
  # a metric name within a group irrespective of label values, so a `base` body label would make a
  # master-lane dispatch EVICT the goal lane's last stamp — and `changes()` over an evicted gauge
  # undercounts exactly the dispatches this alert is built to count. A key segment cannot contain
  # `/`, and a goal lane base is `goal/<n>`: `/` → `-` FIRST, then the same strip as the others, so
  # `goal/278` and `goal-278` are one lane's key only if they were one lane's branch (they are not:
  # `-` is legal in a branch name, but two branches differing solely in `/`-vs-`-` at the same
  # position do not occur in this scheme — `goal/<n>` is minted by the launcher, ADR-102).
  [ -n "$ubase" ] && bseg="$(printf '%s' "$ubase" | tr '/' '-' | tr -cd 'A-Za-z0-9._-')"
  # A scan that dispatches twice (the global instance sweeping two stacks) measures the SECOND
  # dispatch from the first one's end, not from the pod's start — otherwise stack B's `scan` row
  # would carry stack A's whole streamed session. The mark moves whether or not anything is
  # published, so a gateway-less run cannot fold two dispatches into one number.
  local scan=$(( now - DISPATCH_PHASE_MARK )); DISPATCH_PHASE_MARK="$now"
  # No gateway (explicitly disabled) or no project (a caller with nothing to key on) → nothing is
  # published. Never a failure: this is a report, not a gate.
  [ -n "$DISPATCH_PHASE_PGW" ] && [ -n "$project" ] || return 0
  [ -n "$DISPATCH_PHASE_WAKE" ] || DISPATCH_PHASE_WAKE="$(dp_wake)"
  if [ "${DISPATCH_PHASE_WAKE%%|*}" = "edge" ] && [ -n "${DISPATCH_PHASE_WAKE#edge|}" ]; then
    # T0, NOT the moving mark: this row is "how long from the doorbell until the scan pod was
    # running", a property of the POD. Measuring it to the mark instead would make a second
    # dispatch report the ring as having happened one whole session earlier than it did.
    ring=$(( DISPATCH_PHASE_T0 - ${DISPATCH_PHASE_WAKE#edge|} ))
    # A ring AFTER the pod started is a clock disagreement, not a negative duration. Clamp: a
    # gauge that goes negative is the AgentRunNegativeCost class, and it is never informative.
    [ "$ring" -ge 0 ] || ring=0
    family="agent_dispatch_phase_seconds{phase=\"ring-to-scan\"} ${ring}
"
  fi
  # Both rows ride ONE POST, so unlike the launcher's family there is nothing to accumulate — the
  # push that carries `scan` carries `ring-to-scan` beside it or the row does not exist at all.
  # NEWLINE-TERMINATED, and that is not cosmetic: the exposition format is line-oriented and a body
  # whose last sample has no trailing newline is a parse error, so the whole push would 400. The
  # launcher's accumulator gets this for free by appending; a single-shot family has to say it.
  family="${family}agent_dispatch_phase_seconds{phase=\"scan\"} ${scan}
"
  # The 017790c invariant rows (rationale at dp_wake): the wake source of THIS dispatch, as an
  # epoch so `changes()` counts dispatches. An unreadable Workflow (a jail run) stamps neither —
  # absence of both is "not measured", never "edge".
  # ⚠ The JANITOR tick stamps NEITHER (homelab#459, 2026-08-23): it is report-only BY DESIGN — no
  # doorbell exists for "run the periodic janitor", so its cron label is not a missed edge. Before
  # this gate every janitor pass contributed one guaranteed "dead doorbell edge" sample (the cron
  # gauge's own HELP), leaving AgentDispatchCronWoken one tolerated race away from firing on any
  # janitor day. The phase-timing rows above still ship — those ARE meaningful for the janitor.
  if [ "${SCAN_JANITOR:-}" != "1" ]; then
  case "${DISPATCH_PHASE_WAKE%%|*}" in
    edge) wake="# TYPE agent_dispatch_edge_woken_timestamp gauge
# HELP agent_dispatch_edge_woken_timestamp Epoch of this stack's last EDGE-woken dispatch (017790c: changes() over this counts them).
agent_dispatch_edge_woken_timestamp ${now}
" ;;
    cron) wake="# TYPE agent_dispatch_cron_woken_timestamp gauge
# HELP agent_dispatch_cron_woken_timestamp Epoch of this stack's last CRON-woken dispatch — each one is a dead doorbell edge with an id (017790c).
agent_dispatch_cron_woken_timestamp ${now}
" ;;
  esac
  fi
  printf '%s\n%s\n%s%s' \
    "# TYPE agent_dispatch_phase_seconds gauge" \
    "# HELP agent_dispatch_phase_seconds Seconds one dispatch spent in a COORDINATOR-owned phase above the launcher (FU-160)." \
    "$family" \
    "$wake" \
    | curl -fsS --max-time 5 --data-binary @- \
        "${DISPATCH_PHASE_PGW}/metrics/job/agent_dispatch_phase/project/${project}/role/coordinator-scan${bseg:+/base/${bseg}}" >/dev/null 2>&1 \
    || { [ -n "$DISPATCH_PHASE_WARNED" ] \
           || echo "dispatch_phase: pushgateway unreachable (${DISPATCH_PHASE_PGW}) — dispatch unaffected; this scan contributes no agent_dispatch_phase_seconds (a jail run lands here: the ClusterIP does not cross the BGP boundary)" >&2
         DISPATCH_PHASE_WARNED=1; }
  # The per-clause wake series (homelab#459): own metric name, NO body labels — the dimensions
  # live in the grouping key, so each (project, clause, unit) is its own group and pushes never
  # evict a sibling clause's sample. Janitor-exempt exactly like the wake stamps above (report-only
  # by design — its cron label is not a missed edge). Unit segment only where the class is known
  # (queued-dispatch/c4c5; 3-field merge-path units carry none). Failure is already named once by
  # the main push's warn-latch — a second warning per dispatch would be the #103 noise floor.
  if [ -n "$cseg" ] && [ "${SCAN_JANITOR:-}" != "1" ]; then
    local wurl="${DISPATCH_PHASE_PGW}/metrics/job/agent_dispatch_phase/project/${project}/role/coordinator-scan/clause/${cseg}"
    [ -n "$useg" ] && wurl="${wurl}/unit/${useg}"
    [ -n "$bseg" ] && wurl="${wurl}/base/${bseg}"
    printf '%s\n%s\n%s\n' \
      "# TYPE agent_dispatch_wake_clause_timestamp gauge" \
      "# HELP agent_dispatch_wake_clause_timestamp Epoch of this stack's last dispatch for this clause (homelab#459 — clause/unit ride the grouping key, one sticky series per (project, clause, unit))." \
      "agent_dispatch_wake_clause_timestamp ${now}" \
      | curl -fsS --max-time 5 --data-binary @- "$wurl" >/dev/null 2>&1 || true
  fi
  return 0
}
# <<<REPLAY:dispatch-phase<<<

# The ONE source of the stack list (FU-048): cluster `AgentStack` claims first, stacks.json for
# stacks not yet migrated (cluster wins per stack name). PROBE-FIRST (meta-5 principle): a failed
# kubectl read is PROBE-FAILED — warn loudly + fall back to the file, never silently drop a
# migrated stack (migrated entries stay in stacks.json as the belt until the in-cluster reflex
# path is verified reading claims). Cached: one cluster read per scan.
STACKS_CACHE=""
stacks_json() {
  [ -n "$STACKS_CACHE" ] && { printf '%s' "$STACKS_CACHE"; return; }
  local file cluster
  file="$(cat "$STACKS_FILE")"
  if cluster="$($KUBECTL $KUBE get agentstacks.platform.teststuff.net -o json 2>/dev/null)"; then
    STACKS_CACHE="$(jq -n --argjson c "$cluster" --argjson f "$file" '
      (($c.items // []) | map({
        name: .metadata.name,
        repos: [.spec.repos[].name],
        mainRepo: (.spec.mainRepo // "homelab"),
        coordinatorModel: (.spec.coordinatorModel // "sonnet"),
        workerModel: .spec.workerModel,
        workerModelFallbacks: (.spec.workerModelFallbacks // []),
        # FU-080 per-stack autonomy knob: only spawn the LLM coordinator for a stack that opted in
        # (default false). Graduated autonomy — enable a proven stack while newer ones stay off.
        coordinatorEnabled: (.spec.coordinator.enabled // false),
        # ADR-096 P4 per-stack knob (2026-08-03): shadow|authoritative|off; chainless stacks
        # (no workerModel) declare authoritative — the launcher enforces.
        routerMode: (.spec.routerMode // "shadow"),
        modelDeny: (.spec.modelDeny // []),
        # FU-080 cutover: a graduated stack is OWNED by its own per-stack loop (coordinate-<stack>
        # in <stack>-agents + the doorbell edge); the GLOBAL scan skips it below so the two never
        # double-run. Default false — perStack renders the loop, graduated retires the global belt.
        graduated: ((.spec.loop.graduated) // false),
        # repos whose fixer declared docker=true: dispatch their workers with
        # agent-session.sh --docker (kata microVM + dind — the CI-gate runtime choice)
        dockerRepos: [.spec.repos[] | select(.fixer.docker == true) | .name],
        # ADR-094 dispatchability predicate: only repos with a fixer block can run workers —
        # a context-only repo (oracle-iac) becomes a VISIBLE predicate, not an implicit
        # clone-but-cant-work state. Absent from the file fallback → null → treated as unknown
        # (all repos dispatchable — the belt stays permissive, never silently narrower).
        fixerRepos: [.spec.repos[] | select(.fixer) | .name]
      })) as $claims
      | {stacks: ($claims + [$f.stacks[] | select(.name as $n | $claims | all(.name != $n))])}
    ')"
  else
    echo "WARN coordinator-scan: agentstacks read PROBE-FAILED — stack list from ${STACKS_FILE} only" >&2
    STACKS_CACHE="$file"
  fi
  printf '%s' "$STACKS_CACHE"
}
# Populate the cache HERE, in the main shell — every later call sites inside $(…) subshells, where
# an assignment would not survive. One cluster read per scan, not one per jq lookup.
STACKS_CACHE="$(stacks_json)"

# ── FU-144 RECEIVER-SIDE FAN-OUT (ruled 2026-08-12; builds with the collapse per ADR-106 (5)) ───
# An emitter that edits a repo must not need to know stack mechanics — `{repo}` is the honest
# payload (the two live holdouts: renovate.yaml `{"repo":"all"}`, devbox-update.yaml
# `{"repo":"<repo>"}`). Before this, such a ring woke the GLOBAL scan, which printed
# "graduated — skipped" for every stack and dispatched nothing (circles#29 waited out the cron,
# 8m35s measured). Now the RECEIVER resolves: the global scan maps repo → {stack, loop_ns} off
# stacks_json() — the AgentStack claims merged over the committed mirror, the same one source the
# scan already trusts (generating the mirror FROM claims stays FU-049) — and re-rings /coordinate
# with the resolved pair, so the per-stack trigger fires and the stack's own loop takes it.
# Loop-break, twice over: the re-ring carries loop_ns, so the junk global workflow it also spawns
# (a graduated POST satisfies both Sensor deps, the tolerated shape) arrives with SCAN_RING_NS
# set and fans out nothing — and the collapse above absorbs it while Pending anyway. Gates:
#   - EDGE-woken scans only (dp_wake): the cron backstop fanning out would re-launder every
#     */10 tick as a fresh edge and the 017790c metric would read 100% edge-woken while lying.
#   - SCAN_RING_NS empty/"-" only: an emitter that already carried loop_ns was already routed.
#   - Latch-gated like every ring (coordinate-ring.sh is the reference): a woken scan could only
#     dispatch work that defers for the same reason. Fail-open — an unreadable latch rings.
# >>>REPLAY:doorbell-fanout>>>
AGENT_LOOP_WEBHOOK="${AGENT_LOOP_WEBHOOK:-http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000}"
FANOUT_LATCH=""; FANOUT_LATCH_SAID=""
fanout_clear() {   # seam: the FU-088 latch probe (fail-open by the script's own design)
  SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh" 2>/dev/null
}
fanout_eligible() {   # the gates common to both call sites; caller passes nothing
  [ -n "$SPAWN" ] || return 1
  [ -z "${SCAN_STACK:-}" ] || return 1                       # per-stack instances never fan out
  case "${SCAN_RING_NS:-}" in ""|"-") ;; *) return 1;; esac  # emitter already carried loop_ns
  [ -n "$DISPATCH_PHASE_WAKE" ] || DISPATCH_PHASE_WAKE="$(dp_wake)"
  case "$DISPATCH_PHASE_WAKE" in edge*) ;; *) return 1;; esac
  if [ -z "$FANOUT_LATCH" ]; then
    if fanout_clear; then FANOUT_LATCH=clear; else FANOUT_LATCH=latched; fi
  fi
  if [ "$FANOUT_LATCH" != "clear" ]; then
    # Once per scan, not once per skipped stack — a line per stack is the noise floor that hid
    # a spinning Sensor for ~50 minutes (homelab#103).
    if [ -z "$FANOUT_LATCH_SAID" ]; then
      echo "  fan-out: SKIPPED — subscription latched; a woken scan would only re-defer (cron backstop owns it)"
      FANOUT_LATCH_SAID=1
    fi
    return 1
  fi
  return 0
}
fanout_ring() {   # $1 = stack, $2 = unit ("-"/empty = none) — one POST, the resolved pair
  local body
  body="{\"stack\":\"$1\",\"loop_ns\":\"$1-agents\",\"unit\":\"${2:--}\"}"
  if curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$body" \
       "${AGENT_LOOP_WEBHOOK}/coordinate" >/dev/null 2>&1; then
    echo "  fan-out: doorbell rung for graduated stack $1 (${body})"
  else
    echo "  fan-out: RING FAILED for $1 — its */30 cron backstop owns the edge (a defect if recurring, 017790c)" >&2
  fi
  return 0
}
fanout_stack() {   # $1 = a graduated stack the global scan is skipping — ring it iff in scope
  fanout_eligible || return 0
  # Repo scope: "all"/empty rings every graduated stack; a named repo rings only its stack.
  case "${SCAN_REPO:-all}" in
    all|"") ;;
    *) stacks_json | jq -e --arg n "$1" --arg r "${SCAN_REPO}" \
         '.stacks[]|select(.name==$n)|.repos|index($r)' >/dev/null 2>&1 || return 0 ;;
  esac
  fanout_ring "$1" "-"
}
capacity_fanout_ring() {   # $1 = stack, $2 = rail — re-ring a graduated stack with capacity source
  local body
  body="{\"source\":\"capacity\",\"rail\":\"$2\",\"stack\":\"$1\",\"loop_ns\":\"$1-agents\"}"
  if curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$body" \
       "${AGENT_LOOP_WEBHOOK}/coordinate" >/dev/null 2>&1; then
    echo "  capacity-fan-out: doorbell re-rung for graduated stack $1 rail $2 (${body})"
  else
    echo "  capacity-fan-out: RING FAILED for $1 — no fallback for capacity rings (a defect if recurring)" >&2
  fi
  return 0
}
capacity_fanout_stacks() {   # $1 = rail — re-ring every graduated stack for a capacity transition
  local stack_name
  fanout_eligible || return 0
  for stack_name in $(stacks_json | jq -r '.stacks[]|select(.graduated // false)|.name'); do
    capacity_fanout_ring "$stack_name" "$1"
  done
}
fanout_graduated_stack() {   # $1 = stack — ring if not in capacity fan-out mode (issue#779 fix)
  [ "${SCAN_SOURCE:-}" != "capacity" ] || return 0
  fanout_stack "$1"
}

# issue#779: capacity doorbell fan-out — re-ring every graduated stack for a capacity transition
case "${SCAN_SOURCE:-}" in capacity)
  if [ -n "${SCAN_RAIL:-}" ]; then
    echo "capacity doorbell: ringing every graduated stack for $SCAN_RAIL cleared"
    capacity_fanout_stacks "$SCAN_RAIL"
    # Capacity rings are informational re-rings; a ring alone doesn't stop the main scan
    # (each per-stack coordinator probes its own subscription latch)
  fi
;; esac
# <<<REPLAY:doorbell-fanout<<<

# ── SWITCHBOARD TERMINAL (ADR-120, homelab#994) ────────────────────────────────────────────────
# The global instance is a RESOLVER, not a coordinator: with every stack graduated it may only
# (1) drop a ring the Sensor already routed per-stack (the #994 junk shape — 92% of global runs
# were full board sweeps that dispatched nothing by construction), (2) finish after the capacity
# fan-out above, (3) delegate a repo-dumb unit ring to its stack's own loop (FU-144), or
# (4) fan a repo-dumb full ring out to the graduated stacks. It NEVER lists GitHub. A dropped or
# ineligible ring costs nothing durable — the per-stack */30 crons re-derive all real work (the
# level-triggered failure detector; the global cron that used to shadow them retired with this).
# >>>REPLAY:switchboard>>>
if [ -n "${SWITCHBOARD:-}" ]; then
  case "${SCAN_SOURCE:-}" in capacity)
    echo "switchboard: capacity fan-out complete — no board scan (ADR-120)"; exit 0
  ;; esac
  case "${SCAN_RING_NS:-}" in ""|"-") ;; *)
    echo "switchboard: ring already carried loop_ns=${SCAN_RING_NS} — the perstack trigger routed it; nothing to do (homelab#994)"; exit 0
  ;; esac
  if [ "${SCAN_UNIT:-"-"}" != "-" ]; then
    swb_repo="$(printf '%s' "$SCAN_UNIT" | cut -d'|' -f2)"
    swb_stack="$(stacks_json | jq -r --arg r "$swb_repo" '[.stacks[]|select(.repos|index($r))|.name]|first // ""')"
    if [ -n "$swb_stack" ] && [ "$(stacks_json | jq -r --arg n "$swb_stack" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
      if fanout_eligible; then
        fanout_ring "$swb_stack" "$SCAN_UNIT"
      else
        echo "switchboard: unit ring for ${swb_stack} not fan-out-eligible (latched/unreadable wake) — its per-stack cron re-derives the work"
      fi
    else
      echo "switchboard: unit ring for repo ${swb_repo} resolves to no graduated stack — dropped (per-stack crons re-derive real work)" >&2
    fi
    exit 0
  fi
  for swb_stack in $(stacks_json | jq -r '.stacks[].name'); do
    if [ "$(stacks_json | jq -r --arg n "$swb_stack" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
      fanout_graduated_stack "$swb_stack"
    else
      echo "⚠ switchboard: stack ${swb_stack} is NOT graduated — the global board scan retired with ADR-120, so NO scan path serves it; set loop.perStack/graduated on its claim or it gets no coordination" >&2
    fi
  done
  exit 0
fi
# <<<REPLAY:switchboard<<<

# FU-085/FU-086(1) compound: an edge that already KNOWS its unit (a reviewer verdict is
# item-shaped — reviewer-session.sh computes `changes-requested|repo|pr-N` in SCRIPT code,
# never the LLM) skips the full multi-repo sweep. The fast path re-validates everything it
# relies on, scoped to the one item; ANY doubt returns 1 and the caller falls through to the
# FULL scan (rule #6 — the compound may only ever be cheaper, never weaker). v1 whitelist:
# changes-requested — the high-volume edge; in-flight clauses are exempt from the ADR-097
# new-work predicates (footprint/PR-cap), so the scoped checks match the main path exactly:
# breaker label, capacity latch, WIP probe.
# >>>REPLAY:unit-fast-path>>>
fast_unit_dispatch() {
  fu="$1"
  fclause="${fu%%|*}"; frest="${fu#*|}"; frepo="${frest%%|*}"; fitem="${frest#*|}"
  # Accept changes-requested (PR-shaped) OR goal-decompose/goal-checkpoint (issue-shaped).
  # The goal clauses open new work (decompose a goal into child issues, or checkpoint a goal's
  # burn-down) — they are NOT fix rounds, so the re-validation below is issue-shaped, not PR-shaped.
  case "$fclause" in
    changes-requested)
      case "$fitem" in pr-[1-9]*) ;; *)
        echo "unit fast-path: malformed item '${fitem}' for clause '${fclause}'"; return 1;;
      esac ;;
    goal-decompose|goal-checkpoint)
      case "$fitem" in issue-[1-9]*) ;; *)
        echo "unit fast-path: malformed item '${fitem}' for clause '${fclause}'"; return 1;;
      esac ;;
    *)
      echo "unit fast-path: clause '${fclause}' not whitelisted"; return 1;;
  esac
  fstack="$(stacks_json | jq -r --arg r "$frepo" '[.stacks[]|select(.repos|index($r))|.name]|first // ""')"
  [ -n "$fstack" ] || { echo "unit fast-path: repo ${frepo} in no stack"; return 1; }
  # Scoping mirrors the main loop: a per-stack instance only serves its own stack; the global
  # instance never touches a graduated stack (its per-stack loop owns it — the doorbell routes
  # graduated events there with loop_ns, so this only rejects mis-routed events).
  if [ -n "${SCAN_STACK:-}" ]; then
    [ "$fstack" = "$SCAN_STACK" ] || { echo "unit fast-path: ${frepo} not in scoped stack ${SCAN_STACK}"; return 1; }
  elif [ "$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
    # FU-144: a repo-dumb unit doorbell for a graduated repo is LEGITIMATE now — resolve and
    # delegate to the stack's own loop (which re-validates everything: delegation, never a
    # weaker check). Ineligible (cron wake / already-routed / latched) keeps the old rejection.
    if fanout_eligible; then
      fanout_ring "$fstack" "$fu"
      echo "unit fast-path: delegated to ${fstack}'s own loop (FU-144 receiver-side fan-out)"
      return 0
    fi
    echo "unit fast-path: ${fstack} graduated — global instance won't dispatch it"; return 1
  fi
  [ "$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')" = "true" ] \
    || { echo "unit fast-path: coordinator.enabled=false for ${fstack}"; return 1; }
  # ── GOAL-DECOMPOSE BRANCH: issue-shaped re-validation ─────────────────────────────────────
  # goal-decompose units carry issue-N items. Re-validate live with an issue-shaped probe that
  # is no weaker than the main scan's predicate for these clauses (homelab#828).
  # Probe failure → full scan decides (conservative, unchanged).
  if [ "$fclause" = "goal-decompose" ]; then
    fijson="$(gh issue view "${fitem#issue-}" --repo "${ORG}/${frepo}" \
      --json state,labels,body 2>/dev/null)" \
      || { echo "unit fast-path: issue probe FAILED"; return 1; }
    [ "$(jq -r .state <<<"$fijson")" = "OPEN" ] || { echo "unit fast-path: issue not open"; return 0; }
    # Must still carry agent/queued (the label that makes it dispatchable).
    jq -e '.labels|map(.name)|index("agent/queued")' >/dev/null <<<"${fijson:-null}" \
      || { echo "unit fast-path: issue no longer agent/queued"; return 0; }
    # Breaker labels: agent/error (FU-069 human-first) and agent/blocked (human-waiting).
    jq -e '.labels|map(.name)|index("agent/error")' >/dev/null <<<"${fijson:-null}" \
      && { echo "unit fast-path: agent/error breaker on the issue — human-first"; return 0; }
    jq -e '.labels|map(.name)|index("agent/blocked")' >/dev/null <<<"${fijson:-null}" \
      && { echo "unit fast-path: agent/blocked on the issue — human-waiting"; return 0; }
    # BREAKER #1 (homelab#828, ported from the main scan's goal-decompose gate): the actor who
    # applied agent/queued must not be a Bot — the loop may not authorise its own goal.
    # Same predicate as the main scan: last `labeled` event for agent/queued, actor.type.
    # Fail-closed: unreadable → refuse (an unreadable authorisation is not an authorisation).
    fqactor="$(gh api "repos/${ORG}/${frepo}/issues/${fitem#issue-}/events" --paginate \
      --jq '[.[] | select(.event=="labeled" and .label.name=="agent/queued")] | last | .actor.type // ""' 2>/dev/null || echo "")"
    if [ "$fqactor" = "Bot" ]; then
      echo "unit fast-path: goal #${fitem#issue-} was queued by a BOT — refusing to dispatch (breaker #1: a human must authorise a goal)"
      return 0
    fi
    if [ -z "$fqactor" ]; then
      echo "unit fast-path: goal #${fitem#issue-}: could not read who applied agent/queued — refusing to dispatch (fail-closed)"
      return 0
    fi
    # Base: line mandatory on task/goal containers (homelab#1053). Mirror the main scan's
    # regex: require at least one character after the colon (homelab#828 r2 finding 2).
    fqbody="$(jq -r '.body // ""' <<<"$fijson")"
    if ! printf '%s' "$fqbody" | grep -qiP '^[ \t]*base:[ \t]*.+' >/dev/null 2>&1; then
      echo "unit fast-path: goal #${fitem#issue-} has no Base: body line — refusing to dispatch"
      return 0
    fi
    # Re-validated. Set fprjson to empty so the PR-specific checks below are skipped.
    fprjson=""
  # ── GOAL-CHECKPOINT BRANCH: issue-shaped re-validation ────────────────────────────────────
  # goal-checkpoint units carry issue-N items. Re-validate live with an issue-shaped probe
  # that is no weaker than the main scan's predicate for this clause (homelab#828).
  # A checkpoint-eligible goal carries task/goal + agent/blocked by design — agent/queued is
  # NOT required and agent/blocked is NOT a breaker for this clause.
  # Probe failure → full scan decides (conservative, unchanged).
  elif [ "$fclause" = "goal-checkpoint" ]; then
    fijson="$(gh issue view "${fitem#issue-}" --repo "${ORG}/${frepo}" \
      --json state,labels 2>/dev/null)" \
      || { echo "unit fast-path: issue probe FAILED"; return 1; }
    [ "$(jq -r .state <<<"$fijson")" = "OPEN" ] || { echo "unit fast-path: issue not open"; return 0; }
    # Must still carry task/goal (the label that makes it a goal).
    jq -e '.labels|map(.name)|index("task/goal")' >/dev/null <<<"${fijson:-null}" \
      || { echo "unit fast-path: issue no longer task/goal"; return 0; }
    # Breaker: agent/error (FU-069 human-first) only. agent/blocked is NOT a breaker for
    # checkpoint — a checkpoint-eligible goal carries agent/blocked by design.
    jq -e '.labels|map(.name)|index("agent/error")' >/dev/null <<<"${fijson:-null}" \
      && { echo "unit fast-path: agent/error breaker on the issue — human-first"; return 0; }
    # Breaker #1 (actor probe) is intentionally SKIPPED for checkpoint: the main scan does
    # not apply it at the checkpoint site, and the fqactor probe reads agent/queued events
    # which a checkpoint-eligible goal never has — an unchanged port would fail-closed on
    # empty and settle every legitimate checkpoint unit (homelab#828 r2 finding 1).
    # Base: check is also skipped — the main scan does not gate Base: at checkpoint.
    # Re-validated. Set fprjson to empty so the PR-specific checks below are skipped.
    fprjson=""
  else
    # ── PR-CLAUSE BRANCH: existing PR-shaped re-validation ──────────────────────────────────
    # Re-validate the item live (at-least-once delivery): still open, still CHANGES_REQUESTED,
    # no breaker label. Probe failure → full scan decides (conservative).
    # `body` rides this existing call for the FU-146 per-item hold below — no extra request.
    fprjson="$(gh pr view "${fitem#pr-}" --repo "${ORG}/${frepo}" --json state,reviewDecision,labels,body,author,headRefName 2>/dev/null)" \
      || { echo "unit fast-path: PR probe FAILED"; return 1; }
  fi
  # PR-specific re-validation checks (only when fprjson is set — i.e., changes-requested clause).
  if [ -n "$fprjson" ]; then
    [ "$(jq -r .state <<<"$fprjson")" = "OPEN" ] || { echo "unit fast-path: PR not open"; return 0; }
    [ "$(jq -r .reviewDecision <<<"$fprjson")" = "CHANGES_REQUESTED" ] || { echo "unit fast-path: verdict moved on"; return 0; }
    # FU-143: an ASSEMBLY PR (head goal/**) with changes-requested is EXCLUDED from fix-round
    # dispatch — a fix round pushes to the PR head, and the head IS the protected goal/**
    # integration branch (the push would be refused). Fall through to the full scan, which
    # emits a goal-checkpoint unit for the goal (trigger=assembly-cr) instead.
    # Checked BEFORE the author gate: the goal-checkpoint emit is author-agnostic (bot or
    # human CHANGES_REQUESTED both route as a NEW child on the goal).
    fhead="$(jq -r '.headRefName // ""' <<<"$fprjson")"
    if [[ "$fhead" == goal/* ]]; then
      echo "unit fast-path: ASSEMBLY PR has changes-requested (FU-143) — falling through to full scan for goal-checkpoint emit"
      return 1
    fi
    # homelab#397 (rule #6 — the compound was WEAKER than the scan on exactly this predicate): the
    # main path scopes changes-requested to the WORKER author (671a053 — the snore#15 per-tick
    # sonnet leak), and the reviewer rings on EVERY verdict citing "the scan re-applies the full
    # predicate". This path re-validated everything BUT author, so each human/jail PR verdict
    # burned a no-mandate session — hot since the PR-lane reversal (#387: #386/#396 both drew one
    # on day one). Guard sits BEFORE the latch/WIP probes: no spend on a unit with no mandate.
    fauthor="$(jq -r '.author.login // ""' <<<"$fprjson")"
    if [ "$fauthor" != "${WORKER_AUTHOR:-app/homelab-agents-1234}" ]; then
      echo "unit fast-path: PR author '${fauthor}' is not the worker lane — no fix-round mandate (homelab#397); settled"
      return 0
    fi
    jq -e '.labels|map(.name)|index("agent/error")' >/dev/null <<<"${fprjson:-null}" \
      && { echo "unit fast-path: agent/error breaker on the PR — human-first"; return 0; }
  fi
  if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
    echo "unit fast-path: capacity limited (FU-088) — no dispatch (cron sweep re-checks)"
    item_class_push "$frepo" "$fitem" "deferred-capacity" "machine"
    return 0
  fi
  # WIP probe, same shape as the main loop (null-strip is load-bearing — issue-96):
  # probe failure pins wip=1 (belt-only), never blocks the in-flight fix round.
  fwip=1
  fpr_issue=""   # PR#480 review: assigned only inside the probe's success block below — an
                 # unguarded read after a FAILED probe is an unbound-variable death for the
                 # WHOLE scan under set -u; initialized here so every later read is safe.
  if FPODS="$("$KUBECTL" $KUBE -n "$frepo" get pods -l app=agent-session,project="$frepo" \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)" \
     && jq -e . >/dev/null 2>&1 <<<"${FPODS:-null}"; then
    flive="$(jq -r '[.items[] | select(([.status.containerStatuses[]? | select(.name == "agent")
        | .state.terminated | select(. != null)] | length) == 0)] | length' <<<"$FPODS")"
    case "${flive:-}" in ''|*[!0-9]*) flive=0;; esac
    if [ "$flive" -ge "$REPO_MAX_WIP" ]; then
      echo "unit fast-path: ${frepo} at WIP ceiling (${flive}) — cron sweep re-checks"; return 0
    fi
    # FU-146 PER-ITEM hold, ported here 2026-08-07. `fc606e2` put it in the MAIN scan path only,
    # and the doorbell takes THIS path — so the hold was bypassed on exactly the high-volume edge
    # it was written for. The WIP check above cannot substitute: it is a COUNT against
    # REPO_MAX_WIP, so one live pod (flive=1 < 3) still dispatches. Proven live in a single
    # window: tick `t967f` dispatched pr-45 while `agent-circles-issue-18-r3` had been Running 13
    # minutes, while the next FULL scan on the same state correctly reported nothing dispatchable.
    # This function's contract is "only ever cheaper, never weaker" (rule #6) — it was weaker.
    # Same predicate and same fail-safes as the main path: no link or no pod probe → fall through
    # unchanged, and the hold needs a LIVE pod so it self-releases and cannot wedge.
    fpr_issue="$(jq -r '(.body // "")
        | (capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' \
        <<<"$fprjson" 2>/dev/null)" || fpr_issue=""
    if [ -n "$fpr_issue" ] \
       && jq -e --arg pat "issue-${fpr_issue}-" \
            '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1 <<<"$FPODS"; then
      echo "unit fast-path: held — a worker is already riding issue #${fpr_issue} (FU-146 per-item); PR ${fitem#pr-}"
      return 0
    fi
    fwip=$((flive + 1))
  fi
  # FU-146 session-currency (the #153 storm): a RUNNING `coordinator-<repo>-<item>` session pod is
  # the item's in-flight work. The doorbell takes this path, so the belt belongs here exactly as in
  # the main loop. Probe the LOOP ns; fail-open to the launcher atomic gate on a dead probe
  # (matches the worker-WIP belt's direction — units flow, the gate refuses, rule #6).
  # Two names to hold on: the PR's OWN session pod (a live changes-requested session for this PR)
  # and the linked issue's session pod (a queued-dispatch session riding the PR's issue — the same
  # shape the main-loop changes-requested hold uses).
  if SESSPODS="$("$KUBECTL" $KUBE -n "${LOOP_NS:-agent-coordinator}" get pods -l app=agent-coordinator \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)" \
     && jq -e . >/dev/null 2>&1 <<<"${SESSPODS:-null}"; then
    if printf '%s' "$SESSPODS" | jq -e --arg p "coordinator-${frepo}-${fitem}" \
          '[.items[]? | (.metadata.name // "") | select(. == $p)] | length > 0' >/dev/null 2>&1; then
      echo "unit fast-path: held — a coordinator session is riding ${frepo} ${fitem} (FU-146 session belt)"
      return 0
    fi
    if [ -n "${fpr_issue:-}" ] \
       && printf '%s' "$SESSPODS" | jq -e --arg p "coordinator-${frepo}-issue-${fpr_issue}" \
            '[.items[]? | (.metadata.name // "") | select(. == $p)] | length > 0' >/dev/null 2>&1; then
      echo "unit fast-path: held — a coordinator session is riding issue #${fpr_issue} (FU-146 session belt); PR ${fitem#pr-}"
      return 0
    fi
  else
    echo "unit fast-path: ⚠ coordinator session-pod probe FAILED — FU-146 session belt off this tick; the launcher atomic gate is the backstop" >&2
  fi
  frepos="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  fmain="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  fmodel="$(stacks_json | jq -r --arg n "$fstack" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
  echo "→ unit fast-path dispatch for ${fstack}: ${frepo} ${fitem} (${fclause}, model ${fmodel}, wip ${fwip})"
  # FU-145/ADR-106 (5): the launcher DETACHES at pod-Ready — the dispatch phase below is pod
  # spin-up only, and the `coordinator-scan` mutex now spans just the deterministic pass (the
  # session pod uploads, pushes its own row, and rings the doorbell itself).
  dispatch_phase "$fmain" "$fclause"   # FU-160: same boundary, the coordinator-owned rows above the launcher
  scan_phase dispatch
  bash "${HERE}/coordinator-session.sh" --stack "$fstack" --repos "${frepos% }" --main-repo "$fmain" \
    --model "$fmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --wip "$fwip" --detach \
    --item "repo=${frepo} item=${fitem} clause=${fclause}"
  scan_phase deterministic
  return 0
}
# <<<REPLAY:unit-fast-path<<<
case "${SCAN_UNIT:-}" in ""|"-") ;; *)
  if [ -n "$SPAWN" ]; then
    if fast_unit_dispatch "$SCAN_UNIT"; then exit 0; fi
    echo "unit fast-path fell through — running the full scan"
  fi
;; esac

any_work=""
resumable_branches=""   # FU-199: space-separated repo#N=branch pairs for goal children with
                        # AGENT_STRIKE: + Resumable branch pushed: — consumed in the dispatch
                        # loop to add work-branch=<branch> to the item. REPO-QUALIFIED keys and
                        # per-stack reset (round-1 review): issue numbers are per-repo, and a
                        # bare-number key let repo A's #N attach its branch to repo B's #N
                        # dispatch later in the same tick — cross-repo resume corruption.

# ── Ratchet clause files (homelab#825, #853) ─────────────────────────────
# CANONICAL LIST IN .github/workflows/ci.yaml:118, ONE HOME.
# Parity assertion below verifies this list matches the regex at runtime.
clause_files="agents/model-scout.sh
agents/coordinator-scan.sh
agents/review-reflex.sh
agents/reviewer-session.sh
agents/reviewer-optout.sh
agents/machine-comment.sh
agents/goal-budget.sh
agents/agent-session.sh
agents/retro-session.sh
agents/argv-guard.sh
agents/coordinator/reflexes-argo.yaml
agents/coordinator/review-argo.yaml
agents/coordinator/reviewer-git.yaml
agents/coordinator/coordinate-argo.yaml
agents/coordinator/responder-argo.yaml
agents/coordinator/retro-argo.yaml
agents/coordinator/fix-debounce-argo.yaml
agents/coordinator/deploy-revert-argo.yaml"

# ── PARITY ASSERTION: clause_files vs ci.yaml ratchet regex (homelab#853) ──
# The canonical ratchet regex lives in .github/workflows/ci.yaml:118 (ONE HOME).
# Reads the regex at runtime so no copy can silently drift. Degrade honestly:
# if ci.yaml is unreadable, report that verification could not be done.
# Computed once (not per-repo) since the fact is platform-wide.
PARITY_ISSUES=""
_pci_yaml=""
if [ -n "${REPLAY_ROOT:-}" ] && [ -f "$REPLAY_ROOT/.github/workflows/ci.yaml" ]; then
  _pci_yaml="$REPLAY_ROOT/.github/workflows/ci.yaml"
elif [ -n "${HERE:-}" ] && [ -f "${HERE}/../.github/workflows/ci.yaml" ]; then
  _pci_yaml="$(cd "${HERE}/.." && pwd)/.github/workflows/ci.yaml"
fi
if [ -n "$_pci_yaml" ]; then
  _pregex=$(grep -E "grep -E.*agents/" "$_pci_yaml" | sed "s/.*grep -E '//;s/'.*//" | head -1)
  if [ -n "$_pregex" ]; then
    _proot="$(dirname "$(dirname "$(dirname "$_pci_yaml")")")"
    while IFS= read -r _pfile; do
      [ -n "$_pfile" ] || continue
      _pfound=0
      while IFS= read -r _pcf; do
        [ -n "$_pcf" ] || continue
        if [ "$_pcf" = "$_pfile" ]; then
          _pfound=1
          break
        fi
      done <<< "$clause_files"
      [ "$_pfound" = 0 ] && PARITY_ISSUES="${PARITY_ISSUES}  PARITY FAIL: \`${_pfile}\` matches ratchet regex but is missing from \`clause_files\`\n"
    done <<< "$(cd "$_proot" && find . -type f -not -path './.git/*' -print | sed 's|^\./||' | grep -E "$_pregex" | sort || true)"
  else
    PARITY_ISSUES="  PARITY FAIL: could not extract ratchet regex from .github/workflows/ci.yaml\n"
  fi
else
  PARITY_ISSUES="  PARITY FAIL: .github/workflows/ci.yaml not found — cannot verify clause_files parity\n"
fi

for name in $(stacks_json | jq -r '.stacks[].name'); do
  # FU-080 perStack: a stack-scoped instance (the coordinate-<stack> CronWorkflow in
  # <stack>-agents sets SCAN_STACK) scans ONLY its own stack; the global reflex keeps sweeping
  # everything as the migration belt.
  [ -n "${SCAN_STACK:-}" ] && [ "$name" != "$SCAN_STACK" ] && continue
  # FU-080 cutover: the GLOBAL instance (SCAN_STACK unset) skips a graduated stack — its own
  # per-stack coordinate loop (cron + doorbell edge) owns it, so scanning here too would double-run
  # (the #134 label-race class). The per-stack instance (SCAN_STACK == name) reaches this line only
  # for its own stack and proceeds. Graduation is retirable in one flag flip (claim loop.graduated).
  # >>>REPLAY:doorbell-fanout-callsite>>>
  if [ -z "${SCAN_STACK:-}" ] \
     && [ "$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
    echo "  [$name] graduated — owned by its per-stack loop; skipped in the global scan" >&2
    # FU-144: skipped is no longer dropped — an edge-woken repo-dumb ring resolves here and
    # re-rings the stack's own loop (gates + rationale at the fan-out block above).
    fanout_graduated_stack "$name"
  fi
  # <<<REPLAY:doorbell-fanout-callsite<<<
  if [ -z "${SCAN_STACK:-}" ] \
     && [ "$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.graduated // false')" = "true" ]; then
    continue
  fi
  repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.repos[]' | tr '\n' ' ')"
  # mainRepo is stack POLICY (the coordinator's cwd) — default homelab for stacks whose
  # deploy/agent knowledge still lives in homelab docs.
  mainrepo="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.mainRepo // "homelab"')"
  items=""; orphans=""; units=""; punits=""; wipmap=""; assembly_cr_prs=""; resumable_branches=""
  # ADR-094 dispatchability: repos with a fixer block (from the claim; null = unknown → permissive)
  fixer_repos="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|(.fixerRepos // ["__ALL__"])[]' | tr '\n' ' ')"
  for repo in $repos; do
    slug="$ORG/$repo"
    case " $fixer_repos" in *" __ALL__ "*|*" $repo "*) dispatchable=1;; *) dispatchable="";; esac
    # gh's built-in --jq keeps this to one repo-read scope — no statusCheckRollup (checks:read) needed.
    # `direction-change` (C10): a human reversed direction (language/architecture) — every carrying
    # item needs a human SWEEP (re-scope the issue / close the PR + delete its branch) BEFORE any
    # dispatch, or the tick works a dead assumption (live 2026-07-09: the TS→Python flip left a
    # CHANGES_REQUESTED PR the scan would happily have burned a round on). Excluded + reported.
    # FU-087/FU-111: native GitHub `blockedBy` edges gate the queue — the machine-readable
    # dependency graph. (The `Depends-on:` body-line reader retired 2026-08-07 after native
    # edges were observed flowing under the App token — circles #30→#31→#32 full lifecycle;
    # the one open body-line holdout, oracle-fleet#84, was migrated to a native edge first.)
    # Level-triggered each scan: any referenced issue still OPEN → the issue is ⏳ queued-blocked
    # (reported, never dispatched; closure is seen next pass — *closed* is the right satisfaction
    # proxy because `Fixes #N` closes on merge). A dep closed as NOT-PLANNED → still actionable
    # but flagged stale (the dependent's premise may have died with it). A direct A↔B cycle →
    # human-first report (agent/error style), not dispatched. A FAILED dep probe blocks
    # CONSERVATIVELY with a PROBE-FAILED marker — rule #6: never fail INTO a dispatch.
    # ONE fetch, two derivations (leg (c)): `queued` is the dispatchable set; `openall` keeps the
    # unfiltered list so the goal lane can find goals that have LEFT agent/queued for the
    # non-dispatchable tracking state. Deriving beats a second call — the App's GraphQL pool is
    # what this loop actually runs out of (FU-084).
    openall_fetch_rc=0
    openall="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,body,isPinned,blockedBy,parent,author 2>/dev/null)" || openall_fetch_rc=$?
    jq -e . >/dev/null 2>&1 <<<"${openall:-null}" || { openall='[]'; openall_fetch_rc=1; }
    if [ "$openall_fetch_rc" != 0 ]; then openall='[]'; fi
    if [ "$(printf '%s' "$openall" | jq 'length' 2>/dev/null || echo 0)" -ge "$ISSUE_LIST_LIMIT" ]; then
      echo "[$repo] ⚠ TRUNCATED: open-issue fetch filled ISSUE_LIST_LIMIT=$ISSUE_LIST_LIMIT — the oldest open issues are INVISIBLE to this scan; raise the limit"
    fi
    # >>>REPLAY:queued-derivation>>>
    queued="$(printf '%s' "$openall" \
      | jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent/queued")) and (($L|index("direction-change"))|not) and (($L|index("agent/error"))|not))] | sort_by(.number)' 2>/dev/null)" || queued='[]'
    jq -e . >/dev/null 2>&1 <<<"${queued:-null}" || queued='[]'
    # <<<REPLAY:queued-derivation<<<
    # In-progress issues once per repo — the C4/C5 clause below AND the ADR-097 footprint
    # predicate (declared `Touches:` body lines; no line = exclusive `*`) read it.
    # NB agent/error stays IN this fetch (an error-flagged in-progress issue still holds its
    # footprint — a human is on it) but is excluded from the C4/C5 clause below: FU-069 makes it
    # invisible to every ACTIONABLE clause (missed on the first item-mode cut — two workers were
    # dispatched INTO a breaker-flagged issue 2026-07-21 before the breaker was cleared).
    # `updatedAt` is fetched for the homelab#155 belt's persistence guard (condition (c)) — read
    # the mergeStateStatus warning by the PR fetch below before touching this list: a selector
    # field that is not in --json comes back absent and silently matches nothing.
    inprog="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,body,updatedAt \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/in-progress")))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"${inprog:-null}" || inprog='[]'
    # review_only (homelab#928): issues with agent/review but NOT agent/in-progress — used by the
    # phantom-label belt inside C4/C5 to detect phantom agent/review labels (no open PR, no merged
    # PR mentioning it, persisted past C4C5_PERSIST_S). Queried here alongside $inprog because the
    # C4/C5 clause is gated by a pod-probe and may be skipped; the variable is cheap and consistent.
    review_only="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,body,updatedAt \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and ($L|index("agent/review")) and (($L|index("agent/in-progress"))|not))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"${review_only:-null}" || review_only='[]'
    # ADR-097: one line per in-progress issue = its declared footprint; missing Touches: → `*`
    # (exclusive). The queued predicate below holds any unit whose footprint intersects a line.
    # Direction 2 of the homelab#822 goal exemption: a `task/goal` issue contributes NO entry to
    # busy_fps, so it does not hold sibling dispatches (cross-reference fp_goal_exempt in
    # agents/footprint.sh — both readers share `task/goal` as the exemption key).
    # >>>REPLAY:busy-fps>>>
    busy_fps="$(printf '%s' "$inprog" | jq -r '.[]
      | select(((.labels|map(.name))|index("task/goal"))|not)
      | ([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(","))
      | if . == "" then "*" else . end')"
    # <<<REPLAY:busy-fps<<<
    # ── FU-143 (contract points 1+2): a goal child cannot self-close ──────────────────────────
    # An OPEN in-progress issue whose body declares `Base: goal/**` and whose referencing PR
    # MERGED into exactly that base is FINISHED work the closing keyword could not close
    # (keywords fire on default-branch merges only). Detected HERE, before C4/C5, because BOTH
    # clauses need the set: C6 emits its closeout unit, and C4/C5 must EXCLUDE it in the same
    # tick — the abandoned-probe reads OPEN PRs only, so merged-into-goal looks abandoned, and
    # c4c5-redispatch OUTRANKS merged-closeout (without the exclusion the closeout unit starves
    # while merged work gets re-ridden). Base:-keyed ON PURPOSE — goal/** only, never "any
    # non-default base": the mirror hazard is agent-runtime#32 (an ordinary stacked PR closing
    # too EARLY), and the goal/ prefix is the same key arming already trusts to carry the
    # ruleset. Design: issue-authoring.md FU-143 section. Probe failures skip LOUDLY (rule #6).
    c6g=""; c6g_nums=""
    # ⚠ Candidate set is DELIBERATELY wider than $inprog: a goal child that lands cleanly in ONE
    # round ends in `agent/review`, not `agent/in-progress` (the scan's review-flip belt moves it
    # at PR-open — MP-T14; historically the launcher performed no such flip). Keying the
    # goal-child leg off $inprog alone made the COMMON case invisible: only a
    # child dragged back to in-progress by a fix round could ever close. circles#32 auto-closed
    # (6 rounds, in-progress) while #40 — one clean round, `agent/review`, PR merged into the goal
    # base — sat open with nothing to claim it. C6's own CLOSED-issue leg has always accepted both
    # states; this leg was the odd one out. $inprog is left ALONE on purpose: it also feeds the
    # ADR-097 footprint holds, and widening those is a different decision.
    goalcand="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,body \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and (($L|index("agent/in-progress")) or ($L|index("agent/review"))))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"${goalcand:-null}" || goalcand='[]'
    goalbased="$(printf '%s' "$goalcand" | jq -r '.[]
      | select(((.labels|map(.name))|index("agent/error"))|not)
      | .number as $n
      | ((((.body // "") | capture("(?m)^[ \\t]*[Bb]ase:[ \\t]*(?<b>goal/[^ \\t\\r\\n]+)") | .b)? // "")) as $b
      | select($b != "") | "\($n)|\($b)"')" || goalbased=""
    # FU-143 SOAK FAILURE, 2026-08-06 — every goal-based in-progress issue, matched or not.
    # C6 below can only claim an issue whose merged PR CITES it; circles#36 merged into
    # goal/29-p0-complete citing only its sibling #31, so #30 fell out of c6g, C4/C5 read
    # "in-progress + no open PR" as abandoned, and re-rode already-merged work. On a goal base the
    # closing keyword is INERT, so nothing motivates the worker to write the reference and nothing
    # checks that it did (agent-runtime#32 — finalize should guarantee the issue link). Until that
    # lands, "no open PR" cannot distinguish MERGED-BUT-UNLINKED from ABANDONED for these issues.
    # So C4/C5 must not guess: holding costs a meta nudge, guessing costs a duplicate ARMED PR onto
    # a protected goal branch that auto-merges. Asymmetric — hold.
    goalbased_nums="$(printf '%s' "$goalbased" | sed 's/|.*//' | tr '\n' ' ')"
    if [ -n "$goalbased" ]; then
      gmerged="$(gh pr list --repo "$slug" --state merged --limit 40 --json number,body,baseRefName 2>/dev/null)" || gmerged='X'
      gopen="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json body --jq '[.[].body // ""]' 2>/dev/null)" || gopen='X'
      if jq -e . >/dev/null 2>&1 <<<"${gmerged:-null}" && jq -e . >/dev/null 2>&1 <<<"${gopen:-null}"; then
        for gb in $goalbased; do
          gn="${gb%%|*}"; gbase="${gb#*|}"
          # ⚠ STRONG LINK REQUIRED, not a bare mention (incident 2026-08-06, the mirror of the
          # soak failure two paragraphs up). A bare `#<n>` cannot tell "the PR that IMPLEMENTS the
          # issue" from "a PR that NAMES it as a sibling seam" — and #29's decomposition RULES
          # REQUIRE seams pinned naming the producing/consuming sibling, so every child cites its
          # siblings by design. circles#36 said "that's the sibling issue (#31)" and one citation
          # did both halves of the damage: #30's closeout starved (ghit=0) AND #31 matched as
          # merged-and-done (ghit=1) while its ride was still RUNNING — a false close would have
          # flipped agent/done, closed the issue, fired goal-review and unblocked #32/#18/#19 on
          # work that does not exist. Asymmetry is the whole argument: a MISSED closeout costs a
          # meta nudge (and is reported below), a FALSE one corrupts the goal's completion state.
          # The keyword set is exactly what agent-runtime#32/#34 makes `finalize` guarantee, so
          # this predicate meets that fix rather than racing it. Until #34's image rolls out
          # nothing matches here — that is INTENDED (hand-close per meta-state), not a regression.
          # ⚠ MUST match what `finalize` accepts, or PRs strand. Found live 2026-08-06 on
          # circles#43: finalize logged "issue link already present (#40) — left alone" because the
          # recipe body carries a line-anchored `Issue: #40` TRAILER, while this guard demanded a
          # verb keyword — so finalize considered the PR linked and C6 refused to close it. A
          # trailer is a strong, structured ownership claim, unlike the prose sibling citation this
          # guard exists to reject ("that is the sibling issue (#31)"); anchoring to line start is
          # what keeps the two apart. Widen HERE rather than narrowing finalize: the authoring side
          # is already deployed fleet-wide and its trailer is the recipes own convention.
          ghit="$(jq -r --arg b "$gbase" --argjson n "$gn" \
            '[.[] | select(.baseRefName == $b)
                  | select((((.body // "") | test("(^|[^a-z])(implements|closes|close[ds]?|fixe[ds]?|fix|resolve[ds]?)[ \\t]+#\($n)\\b"; "i")))
                        or (((.body // "") | test("(?m)^[ \\t]*issue:[ \\t]*#\($n)\\b"; "i"))))] | length' <<<"$gmerged")" || ghit=0
          # Reported, never silent: a merged PR MENTIONS it but no strong link ⇒ ambiguous, held.
          gmention="$(jq -r --arg b "$gbase" --argjson n "$gn" \
            '[.[] | select(.baseRefName == $b) | select((.body // "") | test("#\($n)\\b"))] | length' <<<"$gmerged")" || gmention=0
          gref="$(jq -r --argjson n "$gn" '[.[] | select(test("#\($n)\\b"))] | length' <<<"$gopen")" || gref=0
          # merged PR into the declared base cites the issue AND no OPEN PR still references it
          # (an open follow-up round means live work — not closeable yet)
          if [ "${ghit:-0}" -gt 0 ] && [ "${gref:-0}" -eq 0 ]; then
            c6g="${c6g}${gn}|${gbase}\n"; c6g_nums="${c6g_nums}${gn} "
          elif [ "${gmention:-0}" -gt 0 ] && [ "${ghit:-0}" -eq 0 ]; then
            orphans="${orphans}[$repo] ⛔ issue #${gn} — a merged PR into ${gbase} MENTIONS it but does not IMPLEMENT/CLOSE it (sibling-seam citation, not a closeout). Held: verify by hand, then hand-close. Auto-closeout resumes once agent-runtime#34's finalize ships the \`Implements #${gn}\` line.\n"
          fi
        done
      else
        echo "  [$repo] PROBE_FAILED reading merged/open PRs — FU-143 goal closeout skipped this tick (rule #6)" >&2
      fi
    fi
    # Default branch: a queued issue without a `Base:` body line counts against this.
    # Hoisted above IL-G06 detection block since it's used there.
    default_branch="$(gh repo view "$slug" --json defaultBranch --jq .defaultBranch 2>/dev/null || echo "master")"
    [ -n "$default_branch" ] || default_branch=master
    # >>>REPLAY:il-g06-detect>>>
    # IL-G06 revisit (homelab#1149): an OPEN issue on the default branch whose merged PR carries
    # a strong link (`implements|closes|fixes|resolves #N` or the `Issue:` trailer) is finished
    # work the closing keyword should have closed but did not — the PR used `Implements` instead
    # of `Fixes`, or the issue has no `Base:` line and the keyword was inert. Detected HERE,
    # before C4/C5, because the merged-closeout clause (C6) emits its unit and C4/C5 must EXCLUDE
    # it in the same tick — the abandoned-probe reads OPEN PRs only, so merged work looks
    # abandoned, and c4c5-redispatch OUTRANKS merged-closeout. Strong link only, never a bare
    # mention (the circles#36 asymmetry stands). Probe failures skip LOUDLY (rule #6).
    c6db=""; c6db_nums=""
    # Candidate set: OPEN issues with agent-fix and (agent/in-progress or agent/review) that do
    # NOT carry a `Base: goal/**` line (i.e., default-branch issues). Reuses $goalcand which was
    # already fetched above for the goal-child leg.
    dbcand="$(printf '%s' "$goalcand" | jq -r '.[]
      | select(((.labels|map(.name))|index("agent/error"))|not)
      | .number as $n
      | ((((.body // "") | capture("(?m)^[ \\t]*[Bb]ase:[ \\t]*(?<b>goal/[^ \\t\\r\\n]+)") | .b)? // "")) as $b
      | select($b == "") | "\($n)"')" || dbcand=""
    if [ -n "$dbcand" ]; then
      dbmerged="$(gh pr list --repo "$slug" --state merged --limit 40 --json number,body,baseRefName 2>/dev/null)" || dbmerged='X'
      dbopen="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json body --jq '[.[].body // ""]' 2>/dev/null)" || dbopen='X'
      if jq -e . >/dev/null 2>&1 <<<"${dbmerged:-null}" && jq -e . >/dev/null 2>&1 <<<"${dbopen:-null}"; then
        for dn in $dbcand; do
          # ⚠ STRONG LINK REQUIRED, not a bare mention (same reasoning as the goal-child leg above).
          # A bare `#<n>` cannot tell "the PR that IMPLEMENTS the issue" from "a PR that NAMES it
          # as a sibling seam". The keyword set is exactly what agent-runtime#32/#34 makes
          # `finalize` guarantee, so this predicate meets that fix rather than racing it.
          # ⚠ MUST match what `finalize` accepts, or PRs strand. Same grammar as the goal-child
          # leg: verb keywords OR the line-anchored `Issue:` trailer.
          dhit="$(jq -r --argjson n "$dn" --arg default_branch "$default_branch" \
            '[.[] | select(.baseRefName == $default_branch)
                  | select((((.body // "") | test("(^|[^a-z])(implements|closes|close[ds]?|fixe[ds]?|fix|resolve[ds]?)[ \\t]+#\($n)\\b"; "i")))
                        or (((.body // "") | test("(?m)^[ \\t]*issue:[ \\t]*#\($n)\\b"; "i"))))] | length' <<<"$dbmerged")" || dhit=0
          # Reported, never silent: a merged PR MENTIONS it but no strong link ⇒ ambiguous, held.
          dmention="$(jq -r --argjson n "$dn" --arg default_branch "$default_branch" \
            '[.[] | select(.baseRefName == $default_branch) | select((.body // "") | test("#\($n)\\b"))] | length' <<<"$dbmerged")" || dmention=0
          dref="$(jq -r --argjson n "$dn" '[.[] | select(test("#\($n)\\b"))] | length' <<<"$dbopen")" || dref=0
          # merged PR into the default branch cites the issue AND no OPEN PR still references it
          # (an open follow-up round means live work — not closeable yet)
          if [ "${dhit:-0}" -gt 0 ] && [ "${dref:-0}" -eq 0 ]; then
            c6db="${c6db}${dn}\n"; c6db_nums="${c6db_nums}${dn} "
          elif [ "${dmention:-0}" -gt 0 ] && [ "${dhit:-0}" -eq 0 ]; then
            orphans="${orphans}[$repo] ⛔ issue #${dn} — a merged PR into ${default_branch} MENTIONS it but does not IMPLEMENT/CLOSE it (sibling-seam citation, not a closeout). Held: verify by hand, then hand-close.\n"
          fi
        done
      else
        echo "  [$repo] PROBE_FAILED reading merged/open PRs — IL-G06 default-branch closeout skipped this tick (rule #6)" >&2
      fi
    fi
    # <<<REPLAY:il-g06-detect<<<
    # TRACKS rule 1 (open-PR bound) needs the count BEFORE the queued loop; the merge-path
    # clauses below reuse this same fetch (moved up 2026-08-03, ADR-097 — do not re-fetch).
    # mergeStateStatus is REQUIRED here: the FU-124 nudge below selects on it, and gh returns a
    # field it was not asked for as absent -> jq reads null -> the selector matched nothing, ever
    # (found 2026-08-05; the nudge had been silently falling back to the GitHub cron it exists to
    # stop depending on). Adding a selector field without adding it to --json is the failure mode.
    # ⚠ It happened AGAIN the very next commit to touch a selector: 671a053 (2026-08-02) scoped
    # the changes-requested clause on .author.login WITHOUT adding author here — the clause
    # matched NOTHING for four days (fixed 2026-08-06, with headRefName added for the FU-143
    # goal exclusions in the same breath). When you touch a jq selector, read this fetch first.
    # `body` is fetched for the FU-146 per-item hold: it carries the `Implements #<n>` line that
    # agent-runtime#34 now guarantees, which is the only reliable PR-to-issue key (branch names
    # are not — circles#31 rode `fix/p0-bake-resolution`, #32 rode `fix/32-p0-page-sunburst`).
    prsjson="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,reviewDecision,autoMergeRequest,mergeStateStatus,author,headRefName,body,baseRefName,headRefOid 2>/dev/null)" || prsjson='[]'
    jq -e . >/dev/null 2>&1 <<<"${prsjson:-null}" || prsjson='[]'
    # TRACKS rule 1 counts ARMED PRs only. The bound exists because updater churn is
    # O(open PRs x merges) — and the updater only ever touches armed PRs (the nudge below selects
    # autoMergeRequest != null; un-armed PRs are "invisible to the merge path", FU-079). Counting
    # un-armed PRs charged the budget for work the updater never does: circles' twelve human-gated
    # research/comparison PRs held issue #17 out of dispatch indefinitely, silently, on 2026-08-05.
    # A parked PR awaiting a human is not churn — it is the human gate doing its job.
    # homelab#849: per-base count. Armed PRs against one base do not churn against another base's
    # issues — master merges never re-base a goal/** child, and goal/** merges never re-base a
    # master PR. Map baseRefName → count of armed PRs, as newline-separated "base|count" lines.
    # FU-199 / #1240 CAP SPLIT: only machine-flowing PRs (reviewDecision == "APPROVED") count
    # toward REPO_PR_CAP. Codeowner-parked PRs (reviewDecision == "REVIEW_REQUIRED" AND
    # mergeStateStatus == "BLOCKED") count toward REPO_BLOCKPARK_CAP instead.
    # A park is REVIEW_REQUIRED whether GitHub reports it BLOCKED (current) or BEHIND (master
    # moved and the updater left it — homelab#887's park-skip makes BEHIND the park's steady
    # state); either way it waits on the codeowner and counts here, never against REPO_PR_CAP.
    # >>>REPLAY:per-base-counts>>>
    per_base_armed="$(jq -r '[.[] | select(.autoMergeRequest != null) | select(.reviewDecision == "APPROVED")]
      | group_by(.baseRefName)
      | map("\(.[0].baseRefName)|\(length)")
      | .[]' <<<"$prsjson")"
    per_base_blockpark="$(jq -r '[.[] | select(.autoMergeRequest != null) | select(.reviewDecision == "REVIEW_REQUIRED") | select(.mergeStateStatus == "BLOCKED" or .mergeStateStatus == "BEHIND")]
      | group_by(.baseRefName)
      | map("\(.[0].baseRefName)|\(length)")
      | .[]' <<<"$prsjson")"
    # <<<REPLAY:per-base-counts<<<
    # ── the LANE MAP for this repo (ADR-125) ────────────────────────────────────────────────
    # Recorded HERE because this is the one point in the pass where both sources are already in
    # hand and cost nothing more: `openall` carries every open issue's body (the `Base:` line the
    # #849 cap reads) and `prsjson` carries every open PR's `baseRefName`. The dispatch loop runs
    # after this pass and only READS the map — see §LANES at the top of this file for the shape
    # and the fail-safe fallback chain. No new API call, no second `Base:` regex: the jq below is
    # the same `scan("(?mi)^[ \t]*base:...")` the queued clause already runs on the same bodies.
    # >>>REPLAY:unit-lane-record>>>
    unit_lane_default_record "$repo" "$default_branch"
    while IFS='|' read -r _litem _lbase; do
      [ -n "$_litem" ] || continue
      unit_lane_record "$repo" "$_litem" "${_lbase:-$default_branch}"
    done <<EOF
$(printf '%s' "$openall" | jq -r '.[] | "issue-\(.number)|" + ([.body // "" | scan("(?mi)^[ \\t]*base:[ \\t]*(.+)$")] | flatten | first // "")' 2>/dev/null || true)
$(printf '%s' "$prsjson" | jq -r '.[] | "pr-\(.number)|\(.baseRefName // "")"' 2>/dev/null || true)
EOF
    # <<<REPLAY:unit-lane-record<<<
    # ADR-097 project-WIP predicate (was binary WIP=1; found live meta-8: two dispatchers raced
    # #52 inside one scan window; 2026-07-21 #55: two CRON ticks raced through the phase=Running
    # filter while a kata pod sat Pending — so the probe counts everything non-terminal): the
    # live-pod COUNT feeds the ceiling (hold everything at ≥ REPO_MAX_WIP) and the AGENT_WIP_LIMIT
    # the dispatch passes down (live+1 — the launcher pre-flight belt matches the raise, and a
    # stale count only ever DEFERS: the belt refuses, the next scan recomputes).
    # Probe-first: a FAILED pod probe leaves the units flowing at wip_allow=1 (belt-only — the
    # parallel raise NEVER rides a dead probe; rule #6).
    # Fixerless (context-only) repos never run workers and have no ns RBAC — probing them is a
    # guaranteed per-tick FAILED warning (snore-recorder, 2026-08-02), so skip, don't probe.
    # WIPPODS_JSON MUST reset with them (FU-146, 2026-08-06): it is only assigned inside the elif
    # below, so a repo with no dispatchable work leaves the PREVIOUS repo pods in scope. Nothing
    # read it across repos before the per-item hold did; resetting closes that hole at the source.
    wip_busy=""; wip_allow=1; WIPPODS_JSON=""
    if [ -z "$dispatchable" ]; then
      :
    elif WIPPODS_JSON="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
          --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)"; then
      jq -e . >/dev/null 2>&1 <<<"${WIPPODS_JSON:-null}" || WIPPODS_JSON='{"items":[]}'
      # ZOMBIE REAP belt (2026-07-21 — the 3-day post-#56 stall): a pod whose agent container
      # terminated but whose sidecar lives (pre-native-sidecar dind) is phase=Running yet holds
      # no work — it wedges this hold AND the launcher WIP=1 forever. Reap when the agent
      # finished >30min ago (in-pod bookkeeping/stats/transcripts are long out by then; the
      # margin keeps a just-finished pod readable per the meta-2 rule), and never count it busy.
      for z in $(printf '%s' "$WIPPODS_JSON" | jq -r '.items[]
          | select([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated
                    | select(. != null and (.finishedAt | fromdateiso8601) < (now - 1800))] | length > 0)
          | .metadata.name'); do
        echo "  [$repo] reaping zombie worker ${z} (agent terminated >30m ago; sidecar held the pod Running)"
        "$KUBECTL" $KUBE -n "$repo" delete pod "$z" --ignore-not-found >/dev/null 2>&1 || true
      done
      # NB the null-strip is LOAD-BEARING: a RUNNING agent container yields .state.terminated
      # = null, and [null] has length 1 — without select(.!=null) every Running ride was
      # invisible to this hold (only Pending pods held the queue), so each tick burned a
      # sonnet deferral session against the launcher belt (found 2026-08-02, issue-96 churn).
      live="$(printf '%s' "$WIPPODS_JSON" | jq -r '[.items[]
          | select(([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated
                     | select(. != null)] | length) == 0)] | length')"
      case "${live:-}" in ''|*[!0-9]*) live=0;; esac
      if [ "$live" -ge "$REPO_MAX_WIP" ]; then
        wip_busy=1
      else
        wip_allow=$((live + 1))
      fi
    else
      # Rule #6: a dead probe must not read as calm — the launcher belt still refuses, but say so.
      echo "  [$repo] ⚠ WIP pod probe FAILED (kubectl error) — units flow at wip=1, launcher belt only"
    fi
    # >>>REPLAY:session-belt>>>
    # FU-146 session-currency belt (homelab#153 five-dispatch storm): a RUNNING
    # `coordinator-<repo>-<item-key>` session pod in the LOOP ns means a coordinator ITEM session
    # is riding that unit — hold it everywhere the worker-per-item hold fires. A coordinator
    # session runs 6–10 min of triage before (or without ever) spawning a worker pod, so the
    # worker-only per-item hold is blind to it; that blindness let `queued-dispatch` re-fire while
    # `agent/queued` still stood and let `c4c5-redispatch` read the mid-triage footprint as
    # abandonment (five sessions, one issue, 11 minutes).
    # Probed ONCE per repo in the loop ns (the ns sessions actually run in — `agent-coordinator`
    # for the global scan, `<stack>-agents` under perStack, the same ns the scan pod itself lives
    # in). Probe-failure direction MATCHES the WIP belt: a dead probe does not read as calm, but
    # it must not invent a hold either — units flow and the launcher's atomic gate is the backstop
    # (rule #6, exactly what the wip_busy else-branch above does).
    # `sess_busy` = newline-joined item keys (issue-N / pr-N) with a live session pod; `sess_nums`
    # = space-joined ISSUE numbers only, for the c4c5 selector's `$sess` exclusion.
    sess_busy=""; sess_nums=""
    if [ -z "$dispatchable" ]; then
      :
    elif SESSPODS="$("$KUBECTL" $KUBE -n "${LOOP_NS:-agent-coordinator}" get pods -l app=agent-coordinator \
          --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json 2>/dev/null)"; then
      jq -e . >/dev/null 2>&1 <<<"${SESSPODS:-null}" || SESSPODS='{"items":[]}'
      # Full-name match, not a bare prefix: `coordinator-circles-` must not capture
      # `coordinator-circles-iac-…` (a repo name that is another's prefix).
      sess_busy="$(printf '%s' "$SESSPODS" | jq -r --arg repo "$repo" '
          [.items[]? | (.metadata.name // "")
           | select(test("^coordinator-" + $repo + "-(issue|pr)-[0-9]+$"))
           | sub("^coordinator-" + $repo + "-"; "")] | .[]' 2>/dev/null || true)"
      sess_nums="$(printf '%s\n' "$sess_busy" | sed -n 's/^issue-//p' | tr '\n' ' ')"
    else
      echo "  [$repo] ⚠ coordinator session-pod probe FAILED (kubectl error) — FU-146 session belt off this tick; the launcher atomic gate is the backstop" >&2
    fi
    sess_holds() {   # $1 = item key (issue-N / pr-N); 0 = a coordinator session is riding it
      [ -n "$sess_busy" ] || return 1
      printf '%s\n' "$sess_busy" | grep -qx -- "$1"
    }
    # <<<REPLAY:session-belt<<<
    # Per-repo AGENT_WIP_LIMIT for whatever unit the spawn block picks for this repo (units are
    # stack-pooled there, so carry the per-repo value out of the loop).
    wipmap="${wipmap}${repo} ${wip_allow}\n"
    # COMPLETED-POD JANITOR (2026-07-22 — the #41/#63 scratch-pool exhaustion): a Completed ride
    # pod pins its GENERIC EPHEMERAL docker-lib PVC (20Gi longhorn-scratch each) until the POD
    # object is deleted — 8 kept-for-reading pods held ~160Gi, the pool filled, and every new
    # ride's volume FAULTED at replica-scheduling ("insufficient storage"), wedging pods in Init
    # while both the WIP probe (fail-open) and the launcher belt let more spawn into the trap.
    # Transcripts/stats upload to S3 in-pod before exit. 30min grace (was 2h): on 2026-07-25
    # nine rides inside 2h held 9x20Gi scratch allocations and pushed BOTH bulk-tier disks past
    # the scheduling cap — new scratch PVCs faulted (ReplicaSchedulingFailure) and wedged every
    # subsequent ride+worker Init. The grace only protects log reads; stats/transcripts are in S3.
    # FU-116: Failed pods leak their ephemeral docker-lib PVCs exactly like Succeeded ones (one
    # r1 PVC sat Bound 18h, regressing the #41/#63 scratch-pool-exhaustion fix) — janitor BOTH
    # terminal phases. Failed gets a longer grace (2h vs 30min): a hard-died ride may not have
    # uploaded transcripts, so its pod log is briefly the only forensics.
    for c in $("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
        -o json 2>/dev/null | jq -r '.items[]
        | select(.status.phase == "Succeeded" or .status.phase == "Failed")
        | .status.phase as $p
        | select((.status.startTime // "1970-01-01T00:00:00Z") | fromdateiso8601
                 < (now - (if $p == "Failed" then 7200 else 1800 end)))
        | .metadata.name' 2>/dev/null); do
      echo "  [$repo] janitor: deleting terminal ride pod ${c} (releases its ephemeral scratch PVC)"
      "$KUBECTL" $KUBE -n "$repo" delete pod "$c" --ignore-not-found >/dev/null 2>&1 || true
    done
    # FU-090 visibility slice: bot-authored issues without `agent-fix` are harvested/drafted work
    # awaiting HUMAN triage (TICK-LOG §Loop-safety breaker #1 keeps them inert) — surface them so
    # they never rot silently.
    # ⚠ A POST-LAUNCH BUCKET IS NOT A SPROUT (ADR-102, homelab#207). It is bot-authored and carries
    # no `agent-fix`, so it matches this slice exactly — and it is a CONTAINER, not work. Left in,
    # every goal would add a permanent line to a report whose whole purpose is "these are rotting,
    # triage them", and the report's own instruction (label agent/queued to adopt (ADR-122 (2), #1432)) would
    # dispatch a worker against an issue with nothing to build. Its children are the work, and they
    # appear here on their own when they land inert.
    # ── UNBLOCKED-UNLABELED rides the SAME fetch (homelab#226) ────────────────────────────────
    # ONE `gh issue list`, two derivations — the App's GraphQL pool is what this loop runs out of
    # (FU-084), and the two slices want the same page of issues. The sentinel spans BOTH because
    # the property worth pinning is that an issue lands in exactly ONE class: the sharper line
    # (its gate resolved) must not also appear as a generic 🌱 row, or the promotion buys nothing.
    #
    # WHAT IT CATCHES (the 2026-08-09 miss, homelab#226). oracle-fleet#225 + oracle-iac#322 were
    # filed unlabelled behind oracle-fleet#215 and sat 12h after #215 closed, because nothing
    # anywhere watches "the gate cleared and the issue is still inert": the needs-meta
    # `unlabeled >24h` clause covers PLATFORM repos only, and the 🌱 slice below shows an
    # unlabelled stack issue exactly the same before and after its blockers close.
    #
    # ⚖ REPORT-ONLY, never an auto-queue. The FU-090 human gate is the point (breaker #1); what
    # was missing is VISIBILITY of a resolved gate, not permission to walk through it.
    #
    # NOT AUTHOR-FILTERED, deliberately — and this is the whole lesson of the issue. The 🌱 slice
    # is bot-only, which is precisely why a JAIL-authored chain was invisible to it; an
    # author allowlist here (`is_bot or <the operator's login>`) would re-narrow the same way the
    # 2026-08-08 agent-runtime fix did, and would go silently blind the day a handle changes. The
    # author rides the LINE instead, where a reader can weigh it. The `blockedBy`-edge requirement
    # is what keeps this quiet: the permanent unlabelled residents (Renovate's Dependency
    # Dashboard, the responder's report-only `alert-fp:` records) carry no dependency edges and so
    # can never match, without this clause needing to know their names.
    #
    # `blockedBy` NODES CARRY THEIR OWN `state` on the list read (verified live 2026-08-09 against
    # this repo's #207/#208), so "all blockers closed" costs zero extra calls. The queued loop
    # above still probes each dep with `gh issue view` because it needs what the nodes do NOT
    # carry — `stateReason` (NOT_PLANNED ⇒ stale premise) and the dep's own edges (cycles).
    # >>>REPLAY:sprout-report>>>
    inert="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" \
      --json number,title,author,labels,createdAt,blockedBy 2>/dev/null)" || inert='[]'
    jq -e . >/dev/null 2>&1 <<<"${inert:-null}" || inert='[]'
    # Unlabelled = no `agent*` label at all, the same predicate meta-needs-attention.sh clause 3
    # uses on platform repos (no clause of any kind can reach such an issue). >24h so a chain
    # filed and labelled inside one working session never flickers through the report.
    unb="$(printf '%s' "$inert" | jq -c --arg cutoff "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
      '[ .[]
         | select(([.labels[].name | select(startswith("agent"))] | length) == 0)
         | select((.createdAt // "") < $cutoff)
         | select((((.blockedBy.nodes // []) | length) > 0)
              and (([(.blockedBy.nodes // [])[] | select(.state != "CLOSED")] | length) == 0)) ]' 2>/dev/null)" || unb='[]'
    jq -e . >/dev/null 2>&1 <<<"${unb:-null}" || unb='[]'
    unblines="$(printf '%s' "$unb" | jq -r '.[]
      | "  issue #\(.number) — \(.title) (by \(.author.login // "?"); blockers all closed: \([(.blockedBy.nodes // [])[] | "#\(.number)"] | join(", ")))"' 2>/dev/null)" || unblines=""
    [ -n "$unblines" ] && orphans="${orphans}[$repo] 🔓 UNBLOCKED-UNLABELED — every blocked-by edge is closed and the issue is still unlabelled >24h (FU-090 gate stands: label agent/queued to adopt (ADR-122 (2), #1432), or close it):\n${unblines}\n"
    unbnums="$(printf '%s' "$unb" | jq -c '[.[].number]' 2>/dev/null)" || unbnums='[]'
    # The backlog inventory (homelab#405 → ADR-109): `agent-fix` without any `agent/*` state is
    # ORDINARY BACKLOG — suitable, deliberately unreleased — not an anomaly. The state's real
    # defect was having NO reader (#369 sat adopted-and-buried); the reader it needs is an
    # AGGREGATE (count + oldest), so standing items never re-scroll as per-issue nags (the
    # oracle-fleet track/* set is this state's designed use). Per-issue expansion is the
    # operator's `devbox run board -- <stack> --full`. The oldest is named by DATE, not age —
    # a replayed report must be byte-stable (fixtures pin this line).
    # Predicate unchanged: agent-fix ∧ ¬(any label starting with "agent/").
    # Disjoint from 🌱 by construction (sprout requires ¬agent-fix).
    adopted="$(printf '%s' "$inert" \
      | jq -r '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and (($L|any(startswith("agent/")))|not))]
        | select(length > 0)
        | (sort_by(.createdAt)[0]) as $old
        | "\(length) suitable-unqueued (oldest #\($old.number) since \(($old.createdAt // "unknown")[0:10]))"' 2>/dev/null || true)"
    if [ -n "$adopted" ]; then
      orphans="${orphans}[$repo] ⏸ backlog: ${adopted} — agent-fix without a state label; ordinary backlog (ADR-109), expand: devbox run board -- <stack> --full\n"
      item_class_push "$repo" "aggregate" "backlog-aggregate" "operator" "${default_branch:-}"
    fi
    # FU-090 visibility slice: bot-authored issues without `agent-fix` are harvested/drafted work
    # awaiting HUMAN triage (TICK-LOG §Loop-safety breaker #1 keeps them inert) — surface them so
    # they never rot silently. Anything the clause above already named is EXCLUDED: same issue,
    # sharper line, reported once.
    # ⚠ A POST-LAUNCH BUCKET IS NOT A SPROUT (ADR-102, homelab#207). It is bot-authored and carries
    # no `agent-fix`, so it matches this slice exactly — and it is a CONTAINER, not work. Left in,
    # every goal would add a permanent line to a report whose whole purpose is "these are rotting,
    # triage them", and the report's own instruction (label agent/queued to adopt (ADR-122 (2), #1432)) would
    # dispatch a worker against an issue with nothing to build. Its children are the work, and they
    # appear here on their own when they land inert.
    sprouts="$(printf '%s' "$inert" \
      | jq -r --argjson skip "$unbnums" '[.[]|select((.author.is_bot == true) and (((.labels|map(.name))|index("agent-fix"))|not) and ((.title|startswith("post-launch:"))|not) and (.number as $n | ($skip|index($n)) == null))|"  issue #\(.number) — \(.title) (by \(.author.login))"]|.[]' 2>/dev/null || true)"
    [ -n "$sprouts" ] && orphans="${orphans}[$repo] 🌱 bot-authored, awaiting human triage (FU-090 gate — label agent/queued to adopt (ADR-122 (2), #1432)):\n${sprouts}\n"
    # ── UNBOUND SPROUT BELT (S6 child 4) ──────────────────────────────────────────────────────
    # Report-only class: an OPEN issue that (a) was authored by the loop identity OR carries a
    # line-anchored lineage cue at body head, AND (b) has NO native parent (issue.parent null).
    # Capped at 10 reports/scan. No label, no writes, never auto-link.
    if [ "${openall_fetch_rc:-0}" = 0 ] && jq -e . >/dev/null 2>&1 <<<"${openall:-null}" && jq -e . >/dev/null 2>&1 <<<"${inert:-null}"; then
      unbound="$(printf '%s' "$openall" | jq -r '
        [.[] | .number as $n
         | (.body // "") as $b
         | (.author.is_bot // false) as $is_bot
         | select(.parent == null)
         | (if $is_bot then "bot-authored"
            elif ($b | test("\\AHarvested from ")) then "Harvested from"
            elif ($b | test("\\ASplit off from ")) then "Split off from"
            elif ($b | test("\\ABelt for ")) then "Belt for"
            elif ($b | test("\\ACause: #")) then "Cause: #"
            else "" end) as $cue
         | select($cue != "")
         | "  🧬 UNBOUND SPROUT #\($n) (cue: \($cue)) — \(.title)"
        ] | .[:10] | .[]
      ' 2>/dev/null || true)"
      [ -n "$unbound" ] && orphans="${orphans}[$repo] 🧬 UNBOUND SPROUTS — no native parent; bind to origin or state standalone:\n${unbound}\n"
    else
      orphans="${orphans}[$repo] ⚠ PROBE-FAILED (openall / inert) — unbound-sprout belt skipped this tick (rule #6)\n"
    fi
    # <<<REPLAY:sprout-report<<<
    # ── RETIRED-FORMAT `Depends-on:` lint (homelab#226) ───────────────────────────────────────
    # FU-111 retired the body-line reader on 2026-08-07; the meta seat wrote one on 2026-08-08
    # (oracle-fleet#225) and the sequencing it encoded could never fire, because nothing reads that
    # line any more and nothing said so. Inert prose that LOOKS like a dependency is worse than no
    # dependency at all — the author stops looking. Report-only and level-triggered: it clears when
    # the body is rewritten as a native edge.
    # ⚠ The bullet form is matched on purpose: TICK-LOG 2026-07-30 recorded a markdown-bulleted
    # `- Depends-on:` slipping a `^[ \t]*depends-on:` regex while reading, to a human, exactly like
    # a dependency. A lint that misses the shape that already fooled someone is not a lint.
    # >>>REPLAY:depends-on-retired>>>
    depold="$(printf '%s' "$openall" | jq -r '[.[]
      | select((.body // "") | test("(?mi)^[ \\t]*(?:[-*+][ \\t]*)?depends-on:[ \\t]*\\S"))
      | "  issue #\(.number) — \(.title)"] | .[]' 2>/dev/null)" || depold=""
    [ -n "$depold" ] && orphans="${orphans}[$repo] ⚠ RETIRED FORMAT: a \`Depends-on:\` body line gates NOTHING (FU-111 retired the reader 2026-08-07 — native blocked-by edges are the only reader). Re-author it: gh api -X POST repos/${slug}/issues/<n>/dependencies/blocked_by -F issue_id=<the BLOCKER's numeric id>, then delete the line:\n${depold}\n"
    # <<<REPLAY:depends-on-retired<<<
    # ── BODY-TOUCHES MISMATCH (homelab#808) — report-only ──────────────────────────────────────
    # An issue body may mandate a deliverable path that its own `Touches:` footprint does not
    # reach — "add a shared helper `agents/foo.sh`" with a `Touches:` that names no plausible
    # target prefix. Nothing checks this today. Report-only, no label, no gate: an omitted
    # Touches already means exclusive, and the mismatch may be a deliberate re-scope a human
    # should read, not a machine block.
    # No false positive when a `Touches:` prefix covers the path by directory or glob (e.g.,
    # `agents/` covers `agents/foo.sh`).
    # >>>REPLAY:body-footprint-mismatch>>>
    if [ "${openall_fetch_rc:-0}" = 0 ] && jq -e . >/dev/null 2>&1 <<<"${openall:-null}"; then
      bfm_lines=""
      # Extract Touches footprint and backtick-quoted paths for each issue, then check coverage.
      while IFS='|' read -r bfmn bfmt bfmp; do
        [ -n "$bfmn" ] || continue
        uncovered=""; oldifs="$IFS"; IFS=','
        for path in $bfmp; do
          if ! fp_conflict_strict "$bfmt" "$path"; then
            uncovered="${uncovered} \`${path}\`"
          fi
        done
        IFS="$oldifs"
        [ -n "$uncovered" ] && bfm_lines="${bfm_lines}  issue #${bfmn} — body paths${uncovered} not covered by declared \`Touches:\` (${bfmt})\n"
      done <<< "$(printf '%s' "$openall" | jq -r '
        [.[] | .number as $n
         | (.body // "") as $b
         | select($b != "")
         | (([$b | scan("(?mi)^[ \t]*touches:[ \t]*(.+)$")] | first // []) | first // "") as $touches
         | select($touches != "" and $touches != "*")
         | ([$b | scan("`([a-zA-Z0-9._/*-][a-zA-Z0-9._/*-]+)`") | .[0]] | unique) as $paths
         | select(($paths | length) > 0)
         | "\($n)|\($touches)|\($paths | join(","))"
        ] | .[]
      ' 2>/dev/null || true)"
      [ -n "$bfm_lines" ] && orphans="${orphans}[$repo] 🏷 BODY-TOUCHES mismatch: issue body references paths outside declared footprint (homelab#808 report-only — may be a deliberate re-scope):\n${bfm_lines}\n"
    fi
    # <<<REPLAY:body-footprint-mismatch<<<
    # ── TOUCHES-MALFORMED (homelab#1294) — report-only ──────────────────────────────────────
    # An issue body may use a markdown-bolded `**Touches:**`, bulleted `- Touches:`, or heading
    # `### Touches:` form that the strict ADR-097 grammar (line-anchored `Touches:`) does not
    # parse. The parser sees nothing → the issue is treated as EXCLUSIVE → every queued sibling
    # whose footprint is actually disjoint serializes behind it. The failure is silent: the
    # author BELIEVES a footprint is declared, the scan enforces the opposite.
    #
    # Report-only, never a parse attempt of the malformed form (guessing a footprint is worse
    # than exclusive — the safe default stands). Same probe for `Base:`/`Depends-on:`-like
    # lines is NOT in scope per homelab#1294.
    # >>>REPLAY:touches-malformed>>>
    if [ "${openall_fetch_rc:-0}" = 0 ] && jq -e . >/dev/null 2>&1 <<<"${openall:-null}"; then
      tm_lines=""
      while IFS='|' read -r tmn tml; do
        [ -n "$tmn" ] || continue
        tm_lines="${tm_lines}  ⚠ TOUCHES-MALFORMED: issue #${tmn} declares a footprint the parser cannot read (line: \"${tml}\") — un-bold/un-bullet it or the issue is treated as EXCLUSIVE\n"
      done <<< "$(printf '%s' "$openall" | jq -r '
        [.[] | .number as $n
         | (.body // "") as $b
         | select($b != "")
         # Loose probe: match Touches-like lines that are bolded, bulleted, heading, etc.
         # but NOT the strict grammar (line-anchored unadorned "Touches:").
         | (([$b | scan("(?mi)^[ \\t]*(?:[*_#> -]+)?touches(?:[*_]+)?:[ \\t]*(.+)$")] | first // []) | first // "") as $loose_touches
         | select($loose_touches != "")
         # Strict grammar: line-anchored unadorned "Touches:" — if this matches, the issue
         # is parseable and NOT malformed.
         | (([$b | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | first // []) | first // "") as $strict_touches
         | select($strict_touches == "")
         # Find the exact malformed line for the verbatim quote
         | ([$b | scan("(?im)^[ \\t]*(?:[*_#> -]+)?touches(?:[*_]+)?:[^\\n]*")] | first // "") as $verbatim
         | select($verbatim != "")
         | "\($n)|\($verbatim | gsub("[\\t]"; " ") | gsub("^[ ]+|[ ]+$"; ""))"
        ] | .[]
      ' 2>/dev/null || true)"
      [ -n "$tm_lines" ] && orphans="${orphans}[$repo] ⚠ TOUCHES-MALFORMED: issue body has a Touches-like line the parser cannot read (homelab#1294 report-only — un-bold/un-bullet it or the issue is treated as EXCLUSIVE):\n${tm_lines}\n"
    fi
    # <<<REPLAY:touches-malformed<<<
    # ── CLAUSE-REPLAY PAIRING (homelab#825) — report-only ────────────────────────────────────
    # The ADR-103 ratchet requires any PR changing a clause file must touch agents/replay/**.
    # An issue whose declared `Touches:` reaches any ratchet clause file but does not reach
    # agents/replay/** is structurally under-scoped: the resulting PR would red on the required
    # `ci` check. Report-only, no label, no gate: same rule as body-footprint-mismatch.
    # Clause list is canonical in .github/workflows/ci.yaml:118 (the ratchet definition; check
    # there for drift). Current list extracted from that regex:
    # >>>REPLAY:clause-replay-pairing>>>
    if [ "${openall_fetch_rc:-0}" = 0 ] && jq -e . >/dev/null 2>&1 <<<"${openall:-null}"; then
      crm_lines=""
      # `clause_files` is defined above (hoisted before the per-repo loop) — the
      # parity assertion against ci.yaml's ratchet regex runs once there, not per-repo. See
      # the >>>REPLAY:clause-replay-pairing>>> block before the for-name loop.
      # Emit the parity finding once (on the main repo) rather than repeating for every stack/repo.
      [ "$repo" = "homelab" ] && [ -n "$PARITY_ISSUES" ] && orphans="${orphans}[$repo] 🔗 CLAUSE-LIST PARITY: clause_files list does not match the ratchet regex in ci.yaml (homelab#853):\n${PARITY_ISSUES}\n"

      while IFS='|' read -r crmn crmt; do
        [ -n "$crmn" ] || continue
        # Check if any clause file is covered by the touches footprint
        touched_clause=""
        while IFS= read -r cf; do
          [ -n "$cf" ] || continue
          if fp_conflict_strict "$crmt" "$cf"; then
            touched_clause="$cf"
            break
          fi
        done <<< "$clause_files"

        # If a clause file is touched, check if agents/replay/** is also touched
        if [ -n "$touched_clause" ]; then
          if ! fp_conflict_strict "$crmt" "agents/replay/**"; then
            crm_lines="${crm_lines}  issue #${crmn} — touches clause \`${touched_clause}\` but \`Touches:\` (\`${crmt}\`) does not reach \`agents/replay/**\`\n"
          fi
        fi
      done <<< "$(printf '%s' "$openall" | jq -r '
        [.[] | .number as $n
         | (.body // "") as $b
         | select($b != "")
         | (([$b | scan("(?mi)^[ \t]*touches:[ \t]*(.+)$")] | first // []) | first // "") as $touches
         | select($touches != "" and $touches != "*")
         | "\($n)|\($touches)"
        ] | .[]
      ' 2>/dev/null || true)"
      [ -n "$crm_lines" ] && orphans="${orphans}[$repo] ⚠️ CLAUSE-REPLAY pairing: issue touches a ratchet clause file but does not declare \`agents/replay/**\` (homelab#825 report-only — the PR would red on the ADR-103 ratchet):\n${crm_lines}\n"
    fi
    # <<<REPLAY:clause-replay-pairing<<<
    iss=""; qblocked=""; qcycles=""
    # ⚠ tab is IFS *whitespace*: POSIX read COLLAPSES consecutive tabs, so an empty middle
    # field shifts every later field left (live 2026-07-27: track-less sleep-iac#25's
    # Depends-on landed in qtracks, qdeps read empty → the FU-087 gate silently never ran and
    # the dep-blocked issue dispatched twice). The jq emits "-" placeholders for the four
    # optional fields (Touches, deps, parent, base — the last two joined via FU-114 L3 and
    # homelab#849); normalize them back to empty here. Repro: printf 'a\tb\t\td\n' | read.
    while IFS="$(printf '\t')" read -r qnum qtitle qtouches qdeps qpin qclass qparent qbase; do
      # FU-114 L3: the task class rides the unit (label task/* → .agents/<class>.yaml, default fix)
      [ -n "$qclass" ] || qclass="fix"
      [ -n "$qnum" ] || continue
      # ADR-097: "-" = no Touches: line = exclusive footprint (`*` conflicts with everything —
      # legacy issues keep WIP=1 semantics without backfill).
      [ "$qtouches" = "-" ] && qtouches="*"
      [ "$qdeps" = "-" ] && qdeps=""
      [ "$qparent" = "-" ] && qparent=""
      qbase_raw="$qbase"  # save before defaulting: "-" means absent (homelab#1053)
      [ "$qbase" = "-" ] && qbase=""
      # TRACKS rule 1 per-base (homelab#849): absent `Base:` body line → default branch.
      [ -z "$qbase" ] && qbase="$default_branch"
      blocked=""; stale=""
      for dep in $(printf '%s' "$qdeps" | tr ',' ' '); do
        dnum="${dep##*#}"; dslug="$slug"
        case "$dep" in *"/"*"#"*) dslug="${dep%#*}";; esac
        case "$dnum" in ''|*[!0-9]*) continue;; esac  # not a #N token — ignore, don't guess
        if depjson="$(gh issue view "$dnum" --repo "$dslug" --json state,stateReason,blockedBy 2>/dev/null </dev/null)"; then
          if [ "$(jq -r .state <<<"$depjson")" = "OPEN" ]; then
            blocked="${blocked} ${dslug}#${dnum}"
            # direct 2-cycle: the dependency's own native blockedBy points back at this issue.
            # GitHub may refuse creating such a pair; kept because that refusal is undocumented,
            # and rule #6 says never fail INTO a dispatch.
            if jq -e --arg u "https://github.com/${slug}/issues/${qnum}" \
                 '[((.blockedBy // {}).nodes // [])[] | .url] | index($u) != null' >/dev/null 2>&1 <<<"$depjson"; then
              qcycles="${qcycles}  issue #${qnum} ↔ ${dslug}#${dnum} — mutual blocked-by\n"
            fi
          elif [ "$(jq -r '.stateReason // ""' <<<"$depjson")" = "NOT_PLANNED" ]; then
            stale="${stale} ${dslug}#${dnum}"
          fi
        else
          blocked="${blocked} ${dslug}#${dnum}(PROBE-FAILED)"
        fi
      done
      if [ -n "$blocked" ]; then
        qblocked="${qblocked}  issue #${qnum} — ${qtitle} (waiting${blocked})\n"
        item_class_push "$repo" "issue-${qnum}" "parked-blocked" "operator" "${qbase:-}"
        continue
      fi
      # ── HOLD-CHAIN PROPAGATION (queued-held-by-ghost, #833) ────────────────────────────────
      # A dependency that is CLOSED may itself have open blockers — the hold propagates through
      # the chain. This is the "ghost" hold: the direct dependency is gone, but its own blocker
      # still holds this issue transitively. Check each dependency's blockedBy for open nodes.
      ghost_held=""
      for dep in $(printf '%s' "$qdeps" | tr ',' ' '); do
        dnum="${dep##*#}"; dslug="$slug"
        case "$dep" in *"/"*"#"*) dslug="${dep%#*}";; esac
        case "$dnum" in ''|*[!0-9]*) continue;; esac
        if depjson="$(gh issue view "$dnum" --repo "$dslug" --json state,stateReason,blockedBy 2>/dev/null </dev/null)"; then
          if [ "$(jq -r .state <<<"$depjson")" = "CLOSED" ]; then
            ghost_open="$(printf '%s' "$depjson" | jq -r '[((.blockedBy // {}).nodes // [])[] | select(.state == "OPEN") | .number] | .[]' 2>/dev/null || true)"
            if [ -n "$ghost_open" ]; then
              ghost_held="${ghost_held} ${dslug}#${dnum}(ghost:${ghost_open})"
            fi
          fi
        fi
      done
      if [ -n "$ghost_held" ]; then
        orphans="${orphans}[$repo] ⏳ queued-held-by-ghost — dependency closed but its own blocker still open (hold-chain propagation, #833):\n  issue #${qnum} — ${qtitle} (${ghost_held})\n"
        item_class_push "$repo" "issue-${qnum}" "queued-held-by-ghost" "operator" "${qbase:-}"
        continue
      fi
      # ADR-094 scheduling predicates (deterministic — the LLM never picks):
      if [ -z "$dispatchable" ]; then
        orphans="${orphans}[$repo] ⚠ queued but NOT dispatchable (no fixer block — context-only repo; jail work):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      # ── PIN-ONLY GUARDED PATH (homelab#309) — report, never dispatch ────────────────────────
      # Tested BEFORE the transient holds (footprint / WIP / PR budget) on purpose: this one is
      # STRUCTURAL. A guarded issue must read as "route this to the operator" on every scan, not
      # as "come back later" whenever a sibling happens to be in flight.
      # REPORT-ONLY, NO LABEL WRITE. `agent/blocked` is a human gate, and the guarded overlap may
      # be only PART of the issue's scope (#299: one manifest was landable, one env line was not)
      # — so the line names the file and the route, and a human re-scopes or splits it.
      # >>>REPLAY:guarded-hold>>>
      if [ "$repo" = "$GUARDED_REPO" ]; then
        if [ -z "$GUARDED_PATHS" ]; then
          # Rule #6: never fail INTO a dispatch. The set could not be read (file moved, or its
          # `GUARDED=` line changed shape), so "not guarded" is unknown, not false. Loud and
          # level-triggered — it clears itself on the scan after the read works again.
          orphans="${orphans}[$repo] ⛔ GUARDED-SET PROBE-FAILED — no \`GUARDED=\` line readable at ${PIN_ONLY_LINT} (homelab#309). Holding rather than dispatching blind:\n  issue #${qnum} — ${qtitle}\n"
          continue
        fi
        # The `*` sentinel (no `Touches:` line) conflicts with EVERYTHING by design
        # (agents/footprint.sh), as does any entry whose glob defeats prefix reasoning. Both
        # normalize to the empty prefix and are dropped here: reading them as guarded would stop
        # dispatching every unfootprinted issue in the repo — a far worse loop than the one round
        # this check exists to save. Dropping them costs nothing the ADR-097 hold does not already
        # cover, since an undeclared footprint is exclusive there anyway.
        qdecl=""; ghit=""
        while IFS= read -r fpe; do
          [ -n "$fpe" ] || continue
          if [ -n "$(fp_norm_entry "$fpe")" ]; then qdecl="${qdecl}${fpe},"; fi
        done <<EOF_QDECL
$(printf '%s' "$qtouches" | tr ',' '\n' | tr -d ' \t')
EOF_QDECL
        if [ -n "$qdecl" ]; then
          # fp_conflict_strict, not a grep: the boundary reasoning is the whole point. THIS
          # issue's own `agents/coordinator-scan.sh` must NOT hit
          # `agents/coordinator/reflexes-argo.yaml`. STRICT (no replay exemption) on purpose:
          # this check's invariant is touch-a-guarded-FILE, and the exempting fp_conflict would
          # fail OPEN the day a guarded path lands under agents/replay/ (PR#557 reviewer catch).
          while IFS= read -r gpath; do
            [ -n "$gpath" ] || continue
            if fp_conflict_strict "$qdecl" "$gpath"; then ghit="${ghit} ${gpath}"; fi
          done <<EOF_GUARDED
$GUARDED_PATHS
EOF_GUARDED
        fi
        if [ -n "$ghit" ]; then
          orphans="${orphans}[$repo] ⛔ pin-only GUARDED path — NOT dispatched (a PR may write only a pin line there, so \`ci\` is structurally red; the route is an operator push to master — CODEOWNERS §Carve-outs). Re-scope or split the issue, or hand it to the operator:\n  issue #${qnum} — ${qtitle} (declared: ${qtouches} → guarded:${ghit})\n"
          item_class_push "$repo" "issue-${qnum}" "guarded-path" "operator" "${qbase:-}"
          continue
        fi
      fi
      # <<<REPLAY:guarded-hold<<<
      # ── OPERATOR-LANE PATH (homelab#1151) — report, never dispatch ──────────────────────────
      # Tested BEFORE the transient holds (footprint / WIP / PR budget) on purpose: this one is
      # STRUCTURAL. An operator-lane issue must read as "route this to the operator" on every
      # scan, not as "come back later" whenever a sibling happens to be in flight.
      # REPORT-ONLY, NO LABEL WRITE. Same precedent as the pin-only GUARDED check: the overlap
      # may be only PART of the issue's scope, so the line names the path and the route, and a
      # human re-scopes or splits it.
      # >>>REPLAY:operator-lane-hold>>>
      if [ "$repo" = "$GUARDED_REPO" ]; then
        # classify_touches() returns "codeowner-author" for the ❌ operator-author set
        # (paths that take effect BEFORE a human approves). The `*` sentinel (no Touches: line)
        # normalizes to the empty prefix and is dropped by classify_touches() — reading it as
        # operator-lane would stop dispatching every unfootprinted issue in the repo.
        # Dropping it costs nothing the ADR-097 hold does not already cover, since an undeclared
        # footprint is exclusive there anyway.
        case "$(classify_touches "$qtouches")" in
          codeowner-author)
            orphans="${orphans}[$repo] ⛔ operator-lane path — NOT dispatched (a worker-authored PR diff touching ❌ paths is structurally red — CI runs from the PR branch; the route is an operator push to master). Re-scope or split the issue, or hand it to the operator:\n  issue #${qnum} — ${qtitle} (declared: ${qtouches})\n"
            continue
            ;;
        esac
      fi
      # <<<REPLAY:operator-lane-hold<<<
      # ── GOVERNANCE PATH (homelab#993) — report, never dispatch ──────────────────────────────
      # Tested BEFORE the transient holds (footprint / WIP / PR budget) on purpose: this one is
      # STRUCTURAL. A governance issue must read as "route this to the operator" on every scan,
      # not as "come back later" whenever a sibling happens to be in flight.
      # REPORT-ONLY, NO LABEL WRITE. Same precedent as the pin-only GUARDED check: the overlap
      # may be only PART of the issue's scope, so the line names the file and the route, and a
      # human re-scopes or splits it.
      # >>>REPLAY:governance-hold>>>
      if [ "$repo" = "$GUARDED_REPO" ]; then
        if [ -z "$GOVERNANCE_PATHS" ]; then
          # Rule #6: never fail INTO a dispatch. The set could not be read (file moved, or its
          # `GOVERNANCE=` line changed shape), so "not governed" is unknown, not false. Loud and
          # level-triggered — it clears itself on the scan after the read works again.
          orphans="${orphans}[$repo] ⛔ GOVERNANCE-SET PROBE-FAILED — no \`GOVERNANCE=\` line readable at ${GOVERNANCE_LINT} (homelab#993). Holding rather than dispatching blind:\n  issue #${qnum} — ${qtitle}\n"
          continue
        fi
        # The `*` sentinel (no `Touches:` line) conflicts with EVERYTHING by design
        # (agents/footprint.sh), as does any entry whose glob defeats prefix reasoning. Both
        # normalize to the empty prefix and are dropped here: reading them as governed would stop
        # dispatching every unfootprinted issue in the repo — a far worse loop than the one round
        # this check exists to save. Dropping them costs nothing the ADR-097 hold does not already
        # cover, since an undeclared footprint is exclusive there anyway.
        qdecl=""; ghit=""
        while IFS= read -r fpe; do
          [ -n "$fpe" ] || continue
          if [ -n "$(fp_norm_entry "$fpe")" ]; then qdecl="${qdecl}${fpe},"; fi
        done <<EOF_QDECL
$(printf '%s' "$qtouches" | tr ',' '\n' | tr -d ' \t')
EOF_QDECL
        if [ -n "$qdecl" ]; then
          # fp_conflict_strict, not a grep: the boundary reasoning is the whole point. THIS
          # issue's own `agents/coordinator-scan.sh` must NOT hit `.agents/` (the dot-prefix
          # distinguishes it). STRICT (no replay exemption) on purpose: this check's invariant
          # is touch-a-governance-FILE, and the exempting fp_conflict would fail OPEN the day
          # a governance path lands under agents/replay/.
          while IFS= read -r gpath; do
            [ -n "$gpath" ] || continue
            if fp_conflict_strict "$qdecl" "$gpath"; then ghit="${ghit} ${gpath}"; fi
          done <<EOF_GOVERNANCE
$GOVERNANCE_PATHS
EOF_GOVERNANCE
        fi
        if [ -n "$ghit" ]; then
          orphans="${orphans}[$repo] ⛔ GOVERNANCE path — NOT dispatched (a worker-authored PR diff touching governance paths is structurally red — CI runs from the PR branch; the route is a seat/operator push). Re-scope or split the issue, or hand it to the operator:\n  issue #${qnum} — ${qtitle} (declared: ${qtouches} → governance:${ghit})\n"
          continue
        fi
      fi
      # <<<REPLAY:governance-hold<<<
      # >>>REPLAY:footprint-hold>>>
      # ADR-097 goal exemption (homelab#822): a goal's decompose/checkpoint unit writes
      # no code (it authorises child issues via `gh` and toggles labels, never a PR diff),
      # so the ADR-097 footprint hold — which prevents write-surface conflicts between
      # concurrently dispatched units — is a category error. A goal is exempt in BOTH
      # directions: it is not held by in-progress issues' footprints and does not hold
      # sibling dispatches.
      if fp_goal_exempt "$qclass"; then
        : # skip the ADR-097 footprint hold for goal-class units
      # ADR-097 footprint hold (supersedes the track-label lane hold): a queued unit is held iff
      # its declared footprint intersects ANY in-progress issue's footprint. Undeclared (`*`)
      # conflicts with everything, so a repo with any in-progress work keeps WIP=1 for legacy
      # issues; disjoint declared footprints dispatch in parallel (launcher limit rides wipmap).
      elif fp_conflict_multi "$qtouches" "$(printf '%b' "$busy_fps")"; then
        orphans="${orphans}[$repo] ⏳ footprint held (ADR-097: overlaps an in-progress issue's Touches):\n  issue #${qnum} — ${qtitle} (declared: ${qtouches})\n"
        item_class_push "$repo" "issue-${qnum}" "footprint-held" "operator" "${qbase:-}"
        continue
      fi
      # <<<REPLAY:footprint-hold<<<
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ project WIP at ceiling (${REPO_MAX_WIP} live workers in ${repo} — ADR-097 hard max):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      # >>>REPLAY:session-belt-queued>>>
      # FU-146 session-currency hold (the #153 storm, leg (a)): `agent/queued` persists through a
      # coordinator session's 6–10 min triage, so a plain label-based dispatch re-fires while the
      # first session is still riding. A RUNNING `coordinator-<repo>-issue-<n>` pod is the item's
      # in-flight work — hold the unit (same self-releasing shape as the worker per-item hold: it
      # clears when the session pod goes terminal).
      if sess_holds "issue-${qnum}"; then
        orphans="${orphans}[$repo] ⏳ held (item session in flight) — a coordinator session is riding issue #${qnum} (FU-146):\n  issue #${qnum} — ${qtitle}\n"
        continue
      fi
      # <<<REPLAY:session-belt-queued<<<
      # >>>REPLAY:pr-cap-per-base>>>
      # TRACKS rule 1: NEW work is held while the repo carries ≥ REPO_PR_CAP armed PRs against
      # the SAME base branch as the queued issue (homelab#849). Count per-base: master-based PRs
      # do not hold a goal/**-based issue and vice versa. In-flight recovery clauses (c4c5,
      # merge-conflict, …) are exempt: they REDUCE the count.
      # FU-199 / #1240 CAP SPLIT: per_base_armed counts only machine-flowing PRs
      # (reviewDecision == "APPROVED"). Codeowner-parked PRs count toward REPO_BLOCKPARK_CAP.
      qbase_armed="$(printf '%s' "$per_base_armed" | awk -F'|' -v b="$qbase" '$1 == b {print $2; exit}' || echo 0)"
      if [ "${qbase_armed:-0}" -ge "$REPO_PR_CAP" ]; then
        orphans="${orphans}[$repo] ⏳ PR budget (${qbase_armed} machine-flowing PRs against ${qbase} ≥ cap ${REPO_PR_CAP} — TRACKS rule 1, updater churn):\n  issue #${qnum} — ${qtitle}\n"
        item_class_push "$repo" "issue-${qnum}" "cap-held" "operator" "${qbase:-}"
        continue
      fi
      # FU-199 / #1240 CAP SPLIT: codeowner-parked PRs have their own larger bound.
      qbase_blockpark="$(printf '%s' "$per_base_blockpark" | awk -F'|' -v b="$qbase" '$1 == b {print $2; exit}' || echo 0)"
      if [ "${qbase_blockpark:-0}" -ge "$REPO_BLOCKPARK_CAP" ]; then
        orphans="${orphans}[$repo] ⏳ BLOCKPARK budget (${qbase_blockpark} codeowner-parked PRs against ${qbase} ≥ cap ${REPO_BLOCKPARK_CAP} — FU-199):\n  issue #${qnum} — ${qtitle}\n"
        item_class_push "$repo" "issue-${qnum}" "blockpark" "operator" "${qbase:-}"
        continue
      fi
      # <<<REPLAY:pr-cap-per-base<<<
      if [ -n "$stale" ]; then
        iss="${iss}  issue #${qnum} — ${qtitle} [⚠ dep${stale} closed as not-planned — premise may be dead]\n"
      else
        iss="${iss}  issue #${qnum} — ${qtitle}\n"
      fi
      # FU-110 operator priority = the GitHub issue PIN (`gh issue pin N`): pinned queued issues
      # dispatch before unpinned — board-native, max 3 pins/repo caps the ladder, zero platform
      # surface. A taxonomy label was REJECTED: the claim's IssueLabels set is authoritative
      # ("anything else gets deleted"), so an ad-hoc label self-destructs. All other predicates
      # (deps, lane, WIP) still apply — a pinned blocked issue stays blocked.
      # LEG (c), 2026-08-05 — a GOAL is not a task. `task/goal` routes to the coordinator's
      # DECOMPOSE play instead of a worker recipe, and this branch MUST come before the recipe
      # choice below: `--recipe` is launcher-owned (ADR-094), so a `goal` class would send the
      # launcher looking for `.agents/goal.yaml` and exit FATAL. There is deliberately no such
      # recipe — the item session authors child issues and NO worker pod is created.
      # Why it exists: circles#17 was a goal handed to a builder (nothing distinguished the two),
      # and produced "analysed everything, built nothing" twice with no cap near binding.
      # Design + the forest/trees rule: docs/agents/issue-authoring.md §Leg (c).
      # >>>REPLAY:goal-decompose>>>
      if [ "$qclass" = "goal" ]; then
        # BREAKER #1, moved UP not away (issue-authoring.md §Leg (c)): a goal's children are queued
        # by the coordinator, and the thing that authorises them is that a HUMAN queued the GOAL.
        # That was prose until 2026-08-05 — nothing checked it, so a bot-queued goal would have
        # self-authorised a whole subtree. Now checked, fail-CLOSED.
        # What the actor test can and cannot see: the loop's own writes are `homelab-agents-1234[bot]`
        # (type Bot) while both the operator AND the jail session are `RasmusSoot` (type User) — the
        # jail holds the operator's PAT. So this does NOT distinguish operator from jail, and is not
        # meant to: the jail is operator-delegated. It distinguishes THE LOOP from a person, which
        # is the actual risk — the loop authorising its own goal.
        #
        # ⚠ THIS IS DEFENCE IN DEPTH, NOT THE BOUNDARY (operator ruling 2026-08-05). Do not build on
        # it and do not let it grow. The App already holds issues:write for other reasons, so an
        # author==human check partway through the process is defeatable in principle — a coordinator
        # could have an -iac worker change the rule that constrains it. The REAL defence is
        # CODEOWNERS gating the MERGE: what lands decides what was allowed, and that check cannot be
        # routed around from inside the loop. Kept because it is one API call and fails closed;
        # retire it without hesitation the day it costs more than it buys.
        # Doctrine: docs/agents/issue-authoring.md §Gate the merge, not the launch.
        qactor="$(gh api "repos/${slug}/issues/${qnum}/events" --paginate \
          --jq '[.[] | select(.event=="labeled" and .label.name=="agent/queued")] | last | .actor.type // ""' 2>/dev/null || echo "")"
        if [ "$qactor" = "Bot" ]; then
          orphans="${orphans}[$repo] ⛔ goal #${qnum} was queued by a BOT — refusing to decompose (breaker #1: a human must authorise a goal; the loop may not authorise its own)\n"
          continue
        fi
        if [ -z "$qactor" ]; then
          orphans="${orphans}[$repo] ⛔ goal #${qnum}: could not read who applied agent/queued — refusing to decompose (fail-closed; an unreadable authorisation is not an authorisation)\n"
          continue
        fi
        # ADR-1053 / homelab#1053: Base: is mandatory on task/goal containers (consumer card
        # change 4). A task/goal with agent/queued and no Base: line never reaches a decompose
        # sitting. The refusal comment names the two legal values and links the consumer card.
        # Base: master PASSES (the choice being explicit is the point).
        if [ "$qbase_raw" = "-" ]; then
          orphans="${orphans}[$repo] ⛔ goal #${qnum} has no \`Base:\` body line — a \`task/goal\` container MUST declare a \`Base:\` line (\`Base: master\` or \`Base: goal/<branch>\`). See docs/agents/issue-authoring.md §Creating a Goal — the consumer card.\n"
          continue
        fi
        if [ "$qpin" = "P" ]; then
          punits="${punits}goal-decompose|${repo}|issue-${qnum}\n"
        else
          units="${units}goal-decompose|${repo}|issue-${qnum}\n"
        fi
        item_class_push "$repo" "issue-${qnum}" "container" "machine" "${default_branch:-}"
        continue
      fi
      # <<<REPLAY:goal-decompose<<<
      # FU-090 leg (c) forest/trees: a child's unit carries its GOAL, so the item session re-reads
      # the parent before acting instead of judging the child in isolation. Free — `parent` rides
      # the issue-list call above, no extra request against the App's GraphQL pool. Empty for the
      # ordinary case (no parent), which parses back to the 4-field shape unchanged.
      # >>>REPLAY:queued-classification>>>
      # Classify the queued issue based on blocker status (qdeps is normalized to empty if "-")
      if [ -z "$qdeps" ]; then
        qclass_item="queued-ready"
      else
        qclass_item="queued-held"
      fi
      if [ "$qpin" = "P" ]; then
        punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
      else
        units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
      fi
      item_class_push "$repo" "issue-${qnum}" "$qclass_item" "machine" "${qbase:-}"
      # <<<REPLAY:queued-classification<<<
    done < <(printf '%s' "$queued" | jq -r '.[] | [ .number, .title, (([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(",")) | if . == "" then "-" else . end), ([((.blockedBy // {}).nodes // [])[] | .url | capture("github.com/(?<r>[^/]+/[^/]+)/issues/(?<n>[0-9]+)") | "\(.r)#\(.n)"]
            | unique | join(", ") | if . == "" then "-" else . end), (if .isPinned then "P" else "-" end), ([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/")), (((.parent.number // "") | tostring) | if . == "" then "-" else . end), (([.body // "" | scan("(?mi)^[ \\t]*base:[ \\t]*(.+)$")] | flatten | first // "" | if . == "" then "-" else . end)) ] | @tsv')
    iss="$(printf '%b' "$iss")"  # the emitters below expect newline-joined plain text
    # ── the goal lane (FU-090 leg (c) 2026-08-05; per-closure session DEMOTED by ADR-106 (3) 2026-08-12) ───────────────────────────────────────────────
    # The forest/trees rule's third leg: a goal must be RE-EVALUATED, not merely survive its
    # children. Fires when a child CLOSES — not only when the last one does (operator, 2026-08-05:
    # "there should be some kind of backstop on the goal also ... it will deadlock too much when
    # only child traffic causes the goal to move").
    # Predicate is stateless and level-triggered, the same shape as the reviewer's
    # newest_commit_at test: a child closed MORE RECENTLY than the newest bot comment on the goal.
    # Once the session comments, the goal falls out of the clause until the next child closes.
    # Scoped to repos that actually have an open task/goal — no goal, no extra API calls at all.
    #
    # THE SENTINEL SPANS THE WHOLE LANE (ADR-103 ratchet, homelab#208), selection included, because
    # the thing worth pinning is not any one leg but their INTERACTION: that a non-assembly merge
    # moves nothing, that a goal the lifecycle legs just acted on does not ALSO draw a goal-review
    # unit, and that a repo with no `task/goal` at all makes zero API calls. Extracting a leg on its
    # own would let each of those regress with every fixture still green.
    # >>>REPLAY:goal-lane>>>
    goals="$(printf '%s' "$openall" | jq -r '[.[] | select((.labels|map(.name)|index("task/goal")))] | .[].number' 2>/dev/null || true)"
    if [ -n "$goals" ]; then
      # one call for the whole repo's issues incl. closed — reused for every goal below.
      # `title,labels` ride along for the ADR-102 terminal legs (homelab#208): the close sweep
      # names what survives and the abandoned leg compares-then-writes on `agent/queued`. Extra
      # --json fields are free here (same request) and buying them with a second call would not be.
      kidsall="$(gh issue list --repo "$slug" --state all --limit 300 --json number,title,state,closedAt,parent,labels 2>/dev/null || echo '[]')"
      jq -e . >/dev/null 2>&1 <<<"${kidsall:-null}" || kidsall='[]'
      for g in $goals; do
        # FU-143 point 6: DESCENDANTS, not direct children — a sprout harvested from a child sits
        # at depth 2 (sub-issue of the CHILD), so a direct-children read neither re-fires this
        # clause when a sprout closes nor lets "goal met" see open sprouts. Same bug-shape the
        # budget gate already fixed in agent-session.sh (direct children [14,15] vs actual
        # descendants [14,15,17,18,21]). Fixpoint over the ONE kidsall fetch; the seen-set makes
        # it cycle-safe; depth is bounded (~3) by the reviewer emitting no Follow-ups at ≥2.
        gdesc=""; gfront="$g"
        while [ -n "$gfront" ]; do
          gnext="$(printf '%s' "$kidsall" | jq -r --arg f "$gfront" \
            '(($f | split(" ") | map(select(. != "") | tonumber))) as $F
             | [.[] | select(((.parent.number // 0)) as $p | $F | index($p)) | .number] | .[]' 2>/dev/null | tr '\n' ' ')" || gnext=""
          gnew=""
          for x in $gnext; do
            case " ${gdesc# } $g " in *" $x "*) ;; *) gnew="$gnew $x";; esac
          done
          gfront="${gnew# }"; gdesc="$gdesc$gnew"
        done
        # ── ADR-102 goal lifecycle: the midpoint and the three terminals (homelab#208) ──────────
        # WHAT CHANGED. Until now the goal-review play ruled "goal met" and the assembly PR's
        # `Fixes #<goal>` closed the goal on merge — one machine act deciding both "built as
        # specified" and "the idea works". circles#17 was machine-ruled met 100 minutes before the
        # operator refuted it, and that is not a prompt bug: nothing at merge time can know whether
        # production agrees. So the verdict is renamed ASSEMBLY-COMPLETE and demoted to a MIDPOINT
        # (the goal enters `goal/post-launch` and STAYS OPEN), and the goal closes only on a later
        # VERDICT — `goal/validated`, `goal/reverted`, `goal/abandoned`.
        #
        # WHY DETERMINISTIC AND HERE, not a session play. These four transitions are pure state
        # machine: a label is present, therefore issues close and labels move. ADR-094 says the LLM
        # never picks what a predicate can decide, and ADR-103 says a clause ships with an executed
        # replay — both point at shell, in the one place that already walks a goal's descendant
        # tree. The JUDGMENT stays outside the loop entirely: a human (later the KPI unit) applies
        # the verdict label, and this block only reacts to it.
        #
        # RUNS BEFORE the empty-descendants skip below, on purpose: a goal with no descendants at
        # all is still terminable, and `goal-review` is the clause that must not see it afterwards.
        glab="$(printf '%s' "$openall" | jq -r --argjson n "$g" \
          '[.[] | select(.number == $n) | .labels[].name] | join(" ")' 2>/dev/null || echo "")"
        gbody="$(printf '%s' "$openall" | jq -r --argjson n "$g" \
          '[.[] | select(.number == $n) | (.body // "")] | first // ""' 2>/dev/null || echo "")"
        gverdict=""
        for gv in validated reverted abandoned; do
          case " $glab " in *" goal/$gv "*) gverdict="$gv"; break ;; esac
        done
        gpl=0; case " $glab " in *" goal/post-launch "*) gpl=1 ;; esac
        gacted=""
        if [ -n "$gverdict" ]; then
          # ── TWO FAIL-CLOSED GATES BEFORE ANY TERMINAL WRITE ───────────────────────────────────
          # (1) AUTHORITY. `Verdict-authority: human | kpi` is a per-goal template line (ADR-102).
          # Only `human` is implemented here; the KPI unit is a later oracle-side issue, so a goal
          # that declares anything else is REPORTED and left alone rather than quietly ruled by the
          # wrong authority. Absent line ⇒ `human`, which is the safe default (it demands a person).
          # (2) ACTOR. The same breaker-#1 shape as goal-decompose, for the same reason and with
          # more at stake: this transition CLOSES a goal and, on revert, its whole tree. The App
          # holds issues:write, so nothing but this test stops the loop labelling its own goal
          # `goal/validated` and closing it. Bot ⇒ refuse. UNREADABLE ⇒ refuse (an unreadable
          # authorisation is not an authorisation — rule #6, never fail INTO a write).
          # ⚠ pipe to a REAL jq: `gh --jq` takes only an expression, and behind `|| echo ""` a
          # rejected --arg would yield an empty actor that this test must then treat as refusal.
          gauth="$(printf '%s\n' "$gbody" | awk '/^[ \t]*[Vv]erdict-authority:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/[ \t\r]/, "", v); print tolower(v); exit }')"
          [ -n "$gauth" ] || gauth="human"
          gactor="$(gh api "repos/${slug}/issues/${g}/events" --paginate 2>/dev/null \
            | jq -r --arg L "goal/${gverdict}" \
               '[.[] | select(.event == "labeled" and .label.name == $L)] | last | .actor.type // ""' 2>/dev/null || echo "")"
          if [ "$gauth" != "human" ]; then
            orphans="${orphans}[$repo] ⛔ goal #${g} carries goal/${gverdict} but declares \`Verdict-authority: ${gauth}\` — only \`human\` is implemented (ADR-102, homelab#208; the KPI unit is a later oracle-side issue). NOT actioned.\n"
            gacted="held"
          elif [ "$gactor" != "User" ]; then
            orphans="${orphans}[$repo] ⛔ goal #${g}: goal/${gverdict} was applied by ${gactor:-an UNREADABLE actor} — refusing to terminate (fail-closed: the loop may not rule its own goal; a human applies the verdict).\n"
            gacted="held"
          else
            # ── DESCENDANTS FIRST, THE GOAL LAST — the resumability contract ────────────────────
            # A closed goal drops out of `openall` and this leg never fires for it again. So a pass
            # that died halfway through the descendants with the goal ALREADY closed would strand
            # the remainder forever, with nothing reporting it. Closing the goal last means a
            # partial pass is simply re-run by the next scan, which is also what makes the per-pass
            # cap below safe rather than a silent truncation.
            gcap="${GOAL_TERMINAL_MAX:-20}"; gdone=0; gleft=0; gswept=""
            # TITLE LAST, and that is not cosmetic: `read` with IFS='|' puts every remaining field
            # into the final variable, so a title containing a pipe (they do) can only widen the
            # column that already absorbs the rest. Any other position would shift `dlabels` and
            # silently mis-read the `agent/queued` test one leg down.
            while IFS='|' read -r dn dstate dlabels dtitle; do
              [ -n "$dn" ] || continue
              [ "$dstate" = "OPEN" ] || continue
              case "$gverdict" in
                reverted)
                  # "the tree stays readable history" (ADR-102): CLOSE with an audit comment, never
                  # delete, and `not planned` because the work is not going to happen — the premise
                  # died with the goal. The scan's own stale-dep flag reads that reason downstream.
                  if [ "$gdone" -lt "$gcap" ]; then
                    if gh issue close "$dn" --repo "$slug" --reason "not planned" --comment "🤖 closed with goal #${g}, which was REVERTED (ADR-102 terminal, applied by a human as \`goal/reverted\`). The idea this work served was refuted in production, so its descendants die with it — this is successful refutation, not failure, and the issue stays as readable history. Reopen only if a new goal adopts the premise. Written by \`agents/coordinator-scan.sh\`." >/dev/null 2>&1; then
                      gdone=$((gdone+1))
                    else
                      gleft=$((gleft+1))
                      orphans="${orphans}[$repo] ⚠ goal #${g} revert: could not close descendant #${dn} (gh write refused?) — the goal stays OPEN so the next scan retries\n"
                    fi
                  else
                    gleft=$((gleft+1))
                  fi ;;
                abandoned)
                  # "descendants inert" — NOT closed. An abandoned goal ran out of money before a
                  # verdict; its work may still be worth doing under a refill or another goal, so
                  # the issues survive. What must stop is DISPATCH: a queued descendant of a dead
                  # goal burns a coordinator ride per tick to be refused by the launcher pre-flight,
                  # which is exactly the goal-174 shape. Compare-then-write (label discipline).
                  case " $dlabels " in
                    *" agent/queued "*)
                      if [ "$gdone" -lt "$gcap" ]; then
                        if gh issue edit "$dn" --repo "$slug" --remove-label "agent/queued" >/dev/null 2>&1 \
                           && gh issue comment "$dn" --repo "$slug" --body "🤖 de-queued: goal #${g} was ABANDONED (ADR-102 terminal — budget exhausted before a verdict). The issue is left OPEN and inert on purpose; the work may still be worth doing, but it may not spend a budget that is gone. Re-queue it under a refilled or different goal. Written by \`agents/coordinator-scan.sh\`." >/dev/null 2>&1; then
                          gdone=$((gdone+1))
                        else
                          gleft=$((gleft+1))
                          orphans="${orphans}[$repo] ⚠ goal #${g} abandon: could not de-queue descendant #${dn} (gh write refused?) — the goal stays OPEN so the next scan retries\n"
                        fi
                      else
                        gleft=$((gleft+1))
                      fi ;;
                  esac ;;
                validated)
                  # ── THE CLOSE SWEEP, REPORT-FIRST (⚖ pre-decided on homelab#208) ──────────────
                  # Batch disposition of the bucket's leftovers becomes LEGAL exactly here — and it
                  # stays a PROPOSAL until the goal registry panel exists, because "close 14 issues"
                  # is the one batch act nobody can undo by reading a diff. So: no descendant write
                  # at all on this leg. List what survives, propose a disposition per item from the
                  # labels already in hand, and let the operator confirm.
                  case "$dtitle" in
                    post-launch:*) gswept="${gswept}    #${dn} — ${dtitle} → CONTAINER: close with the goal\n" ;;
                    *) case " $dlabels " in
                         *" agent/queued "*|*" agent/in-progress "*|*" agent/review "*)
                           gswept="${gswept}    #${dn} — ${dtitle} → LIVE: let it finish, or re-home it into another goal (batch re-homing is legal at this sweep)\n" ;;
                         *) gswept="${gswept}    #${dn} — ${dtitle} → INERT: close as superseded, or re-home\n" ;;
                       esac ;;
                  esac ;;
              esac
            done <<<"$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
              '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
               | [.[] | select(.number as $n | $D | index($n))] | sort_by(.number) | .[]
               | [(.number | tostring), .state, ((.labels // []) | map(.name) | join(" ")), (.title // "")] | join("|")' 2>/dev/null || true)"
            if [ "$gleft" -gt 0 ]; then
              # The goal is NOT closed while work remains — see the resumability contract above.
              orphans="${orphans}[$repo] ⏳ goal #${g} goal/${gverdict}: ${gdone} descendant(s) actioned, ${gleft} still to go (cap ${gcap}/scan) — the goal stays OPEN until the tree is done; the next scan continues\n"
              gacted="partial"
            else
              case "$gverdict" in
                validated)
                  greason="completed"
                  gnote="**VALIDATED** — production (or the operator's verdict-in-lieu) confirms the idea. Closed met."
                  [ -n "$gswept" ] && orphans="${orphans}[$repo] 📋 close sweep for VALIDATED goal #${g} (ADR-102 — REPORT-first, the batch action stays operator-confirmed until the goal registry panel exists):\n${gswept}" ;;
                reverted)
                  # The revert POINTER is declared, never guessed. ADR-102 makes the assembly squash
                  # the revert unit, so the pointer is a pin-rollback or a revert commit — both
                  # facts only the person who rolled back holds. A missing line is said plainly.
                  grev="$(printf '%s\n' "$gbody" | awk '/^[ \t]*[Rr]evert:/ { v = $0; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v); print v; exit }')"
                  greason="completed"
                  gnote="**REVERTED** — production refuted the idea, and a refuted goal is a SUCCESSFULLY closed experiment, not a failure (hence \`completed\`, not \`not planned\`). Revert pointer: ${grev:-⚠ NONE DECLARED — add a \`Revert:\` line naming the pin rollback or the revert commit of the assembly squash; this comment is the audit record and it is incomplete without one}. ${gdone} open descendant(s) closed with the goal." ;;
                abandoned)
                  greason="not planned"
                  gnote="**ABANDONED** — budget exhausted before a verdict. Descendants are left OPEN and inert (${gdone} de-queued); refill or re-home them under another goal." ;;
              esac
              if gh issue close "$g" --repo "$slug" --reason "$greason" --comment "$(printf '%s\n' \
                    "🤖 goal terminal: ${gnote}" \
                    "" \
                    "Applied deterministically by \`agents/coordinator-scan.sh\` in reaction to the \`goal/${gverdict}\` label a human placed here — the loop reacts to the verdict, it never rules one (ADR-102, homelab#208)." )" >/dev/null 2>&1; then
                echo "  [$repo] ADR-102 terminal: goal #${g} → ${gverdict}, closed (${greason}); ${gdone} descendant(s) actioned"
                gacted="terminal"
              else
                orphans="${orphans}[$repo] ⚠ goal #${g}: descendants actioned for goal/${gverdict} but the goal itself could not be CLOSED (gh write refused?) — close it by hand; the next scan is idempotent on the descendants\n"
                gacted="partial"
              fi
            fi
          fi
        elif [ "$gpl" = 0 ]; then
          # ── ASSEMBLY-COMPLETE → POST-LAUNCH (the midpoint) ────────────────────────────────────
          # The assembly PR is the one with HEAD `goal/**` (its children have `fix/**` heads and a
          # `goal/**` BASE — the direction is what tells them apart). It is bound to THIS goal by a
          # line-anchored `Assembly-for: #<n>` trailer, the same strong-link shape `finalize` writes
          # as `Issue: #N` and for the identical reason (FU-143 / circles#36): a bare `#<n>` cannot
          # distinguish the PR that ASSEMBLES a goal from one that merely cites it, and here a false
          # match would announce a launch that never happened. No trailer, no transition — and a
          # merged goal/** PR that only MENTIONS the goal is reported rather than silently dropped.
          gmergedpr="$(gh pr list --repo "$slug" --state merged --limit 30 --json number,headRefName,body,mergedAt 2>/dev/null || echo '[]')"
          jq -e . >/dev/null 2>&1 <<<"${gmergedpr:-null}" || gmergedpr='[]'
          gasm="$(printf '%s' "$gmergedpr" | jq -r --argjson n "$g" \
            '[.[] | select((.headRefName // "") | startswith("goal/"))
                  | select((.body // "") | test("(?mi)^[ \\t]*assembly-for:[ \\t]*#\($n)\\b"))]
             | sort_by(.mergedAt // "") | last // {} | (.number // "") | tostring' 2>/dev/null || echo "")"
          case "$gasm" in ''|*[!0-9]*) gasm="" ;; esac
          if [ -z "$gasm" ]; then
            gasm_m="$(printf '%s' "$gmergedpr" | jq -r --argjson n "$g" \
              '[.[] | select((.headRefName // "") | startswith("goal/")) | select((.body // "") | test("#\($n)\\b"))] | length' 2>/dev/null || echo 0)"
            case "$gasm_m" in ''|*[!0-9]*) gasm_m=0 ;; esac
            [ "$gasm_m" -gt 0 ] && orphans="${orphans}[$repo] ⛔ goal #${g}: a merged goal/** PR MENTIONS it but carries no line-anchored \`Assembly-for: #${g}\` trailer — the post-launch transition is HELD (a mention is not an assembly claim). Add the trailer to the PR body, or label the goal by hand.\n"
          else
            # The bucket already exists in the ordinary case — `harvest-disposition` creates it at
            # the first closeout/review, deliberately earlier than this moment (IL-T17). Named here
            # so the comment tells a human where post-launch work goes; absence is not fatal.
            gbuck="$(gh api "repos/${slug}/issues/${g}/sub_issues" 2>/dev/null \
              | jq -r '[.[] | select(.title | startswith("post-launch:")) | .number] | first // ""' 2>/dev/null || true)"
            case "$gbuck" in ''|*[!0-9]*) gbuck="" ;; esac
            # Rendered here, not inline in the body below: `${x:+A}${x:-B}` reads like an if/else
            # and is not one — when x is SET the second expansion yields x itself, so the sentence
            # came out "sub-issue #7777". Two branches, one variable.
            if [ -n "$gbuck" ]; then
              gbucktxt="sub-issue #${gbuck}"
            else
              gbucktxt="the \`post-launch:\` bucket, which the next closeout or review creates under this goal"
            fi
            # LABEL FIRST, COMMENT SECOND, and the comment only on a label that stuck. The write is
            # not atomic and this leg is level-triggered: a landed comment with a failed label
            # re-comments every tick (the duplicate-bot-comment anomaly the FU-069 breaker watches
            # for), while a landed label with a failed comment costs one audit line and stops. Same
            # ORDER-IS-LOAD-BEARING reasoning as the IL-T16 phantom belt.
            if gh issue edit "$g" --repo "$slug" --add-label "goal/post-launch" >/dev/null 2>&1; then
              gh issue comment "$g" --repo "$slug" --body "$(printf '%s\n' \
                "🤖 **assembly-complete** — assembly PR #${gasm} merged. This goal is built as specified." \
                "" \
                "**That is a MIDPOINT, not a verdict** (ADR-102). Assembly-complete measures \"built as specified\"; it says nothing about whether the idea works — circles#17 was machine-ruled met 100 minutes before the operator refuted it, which is why this transition no longer closes anything. The goal is now \`goal/post-launch\` and STAYS OPEN, shipping to production at its own pace against the same \`Budget:\` line." \
                "" \
                "**Where post-launch work goes:** ${gbucktxt}. Children there base \`master\` and carry NO \`Base:\` line — the goal branch dies at the assembly squash, and goal identity is this issue plus its budget, never the branch. Open descendants still carrying a \`Base: goal/**\` line need retargeting to master at the next \`goal-checkpoint\`." \
                "" \
                "**It closes only on a VERDICT**, applied here as a label by this goal's verdict authority (\`Verdict-authority:\`, default \`human\`):" \
                "" \
                "- \`goal/validated\` — production confirms the idea → closed met, and the close sweep lists every surviving descendant with a proposed disposition (report-first; a human confirms the batch)." \
                "- \`goal/reverted\` — production refutes it → closed successfully-refuted, every open descendant closed with it. Roll back FIRST (the assembly squash is the revert unit) and declare the pointer as a \`Revert:\` line on this issue, or the audit record lands incomplete." \
                "- \`goal/abandoned\` — budget out before a verdict → closed not-planned; open descendants stay open but go inert." \
                "" \
                "Written by \`agents/coordinator-scan.sh\` (deterministic — no session judged this, and none can: the judgment is production's, or yours)." )" >/dev/null 2>&1 \
                || orphans="${orphans}[$repo] ⚠ goal #${g}: labelled goal/post-launch but the assembly-complete comment did not land (gh write refused?) — the transition HELD, the audit line is missing; add it by hand\n"
              echo "  [$repo] ADR-102 midpoint: goal #${g} → assembly-complete via PR #${gasm}, labelled goal/post-launch, left OPEN${gbuck:+ (bucket #${gbuck})}"
              gacted="post-launch"
            else
              orphans="${orphans}[$repo] ⚠ goal #${g}: assembly PR #${gasm} merged but \`goal/post-launch\` could not be applied (label missing from the claim taxonomy? gh write refused?) — the goal is stuck pre-launch; the next scan retries\n"
            fi
          fi
        fi
        # A goal this block moved is DONE for this pass: it is closed (terminal), just announced
        # (post-launch), or deliberately held for a human. Any of the three makes further goal
        # bookkeeping this pass noise at best.
        [ -n "$gacted" ] && continue
        [ -z "${gdesc# }" ] && continue
        # ── v1.2 (ADR-106 (3)): the per-closure goal-review SESSION is DEMOTED ──────────────────
        # Goal #278 drew 21 ruling sessions, 13 re-deriving the same "not complete" — so the
        # per-closure tick now costs ZERO tokens: a deterministic burn-down line inside the
        # FINDINGS STORE (agents/goal-findings.sh — ONE machine comment, edited in place). The
        # old `last_bot` debounce is deleted WITH the session it debounced, and it could not have
        # debounced this anyway: a comment PATCH keeps `createdAt`, so the debounce here is
        # compare-then-write (an unchanged burn-down writes nothing).
        # The REASONING tier now runs only where work is CREATED — a `goal-checkpoint` unit on:
        #   (a) ≥ GOAL_CHECKPOINT_N undispositioned store findings (count-keyed marker), or
        #   (b) the child-set completing PRE-launch — the operator's 2026-08-05 deadlock backstop
        #       ("it will deadlock too much when only child traffic causes the goal to move"),
        #       carried over from the retired clause and INDEPENDENT of store readability, or
        #   (c) ≥1 UNDISPOSITIONED tree member (ADR-122 (4), homelab#1419) — a member the
        #       container has never ruled. It WAKES the checkpoint and never counts toward the
        #       completion predicate, so it can never block (b): #1315 held G-G's assembly ~10.5h
        #       precisely because the old predicate counted it.
        # Budget-fraction + pre-verdict triggers are ADR-106's later legs, not built here.
        # An absent/unreadable store reads as counts 0 0 (the comments API swallows both shapes)
        # — trigger (a) simply cannot arm, which is rule #6's direction (never fail INTO a
        # dispatch), while (b) still fires; the next scan retries the read.
        gopen_n="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
          '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
           | [.[] | select(.number as $n | $D | index($n)) | select(.state == "OPEN")] | length' 2>/dev/null || echo "")"
        gclosed_n="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
          '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
           | [.[] | select(.number as $n | $D | index($n)) | select(.state == "CLOSED")] | length' 2>/dev/null || echo "")"
        # Each count validated on its own — concatenation would let ("", "3") read as the
        # valid-looking "3" and fail later as a swallowed arithmetic error (bot review, PR#398).
        case "$gopen_n" in ''|*[!0-9]*) echo "  [$repo] ⚠ goal #${g}: descendant-count probe unreadable — burn-down/checkpoint skipped this pass" >&2; continue ;; esac
        case "$gclosed_n" in ''|*[!0-9]*) echo "  [$repo] ⚠ goal #${g}: descendant-count probe unreadable — burn-down/checkpoint skipped this pass" >&2; continue ;; esac
        # ── TREE-MEMBER DISPOSITIONS, read from the CONTAINER (ADR-122 (4), homelab#1419) ────
        # The completion predicate used to count every open descendant, so ONE inert member
        # bound into the tree held the whole assembly ruling — #1315 held G-G ~10.5h. Disposition
        # is the container's, never the filer's: the store is one machine comment on THIS issue
        # (agents/epic_dispositions.py, `<!-- epic-dispositions v1 -->`), written only by the
        # goal-checkpoint play, the stint closeout act and the bucket create below.
        # ⚠ FU-084 (API pool): this is a SECOND GET of the same comments ENDPOINT `_gf_find`
        # fetches below — the two stores are different markers on the same issue, and folding
        # them into one fetch means reshaping goal-findings.sh's read, which #1419 held out of
        # scope. One extra GET per OPEN goal per tick; fold at the S8 closeout. Note the two
        # reads do NOT pass the same flags: this one is `--paginate --slurp` (see
        # epic_dispositions.py §_parse_comments_payload — bare `--paginate` emits back-to-back
        # JSON documents and is unparseable past 100 comments), while goal-findings.sh still
        # reads bare. Folding them has to settle that first.
        gdisp_json="$(python3 "${HERE}/epic_dispositions.py" read "$slug" "$g" 2>/dev/null)" && gdisp_rc=0 || gdisp_rc=$?
        if [ "${gdisp_rc:-2}" -ne 0 ] || [ -z "$gdisp_json" ]; then
          # rule #6, never fail INTO a dispatch: an unreadable store counts as "no rows" for the
          # COMPLETION predicate (which only ever shrinks the count, so it cannot invent a
          # completion), but trigger (c) below does NOT arm — waking a checkpoint off a blind
          # read is the one direction that costs a ride. The next scan retries.
          gdisp_json='{}'; gdisp_ok=0
          echo "  [$repo] ⚠ goal #${g}: dispositions unreadable — the undispositioned wake (trigger c) is HELD this pass"
        else
          gdisp_ok=1
        fi
        gdisp_ad="$(printf '%s' "$gdisp_json" | jq -r '[to_entries[] | select(.value.disposition == "adopted") | .key] | join(" ")' 2>/dev/null || echo "")"
        gdisp_df="$(printf '%s' "$gdisp_json" | jq -r '[to_entries[] | select(.value.disposition == "deferred") | .key] | join(" ")' 2>/dev/null || echo "")"
        # FU-069 / homelab#933: the post-launch bucket (title starts with "post-launch:") is
        # created at the first harvest/closeout while the goal is still pre-assembly (IL-T17).
        # It is an OPEN descendant, so trigger (b) below would never see gopen_n=0 and the
        # goal would wedge at originals-done forever. The bucket now carries a `deferred
        # by=bucket` ROW (written at its create, below), so the disposition test already
        # excludes it — the TITLE test stays as the belt for every bucket created before that
        # row existed (same convention the harvest-disposition site and the dispatch block use,
        # sprout-report-skips-buckets, IL-T17).
        # ADOPTED-OPEN = an open non-bucket descendant that carries an `adopted` row, OR carries
        # an `agent/*` LIFECYCLE label and no `deferred` row. The label half is deliberate: a
        # lifecycle label means an authoring moment or a human already released the member, so
        # pre-S8 goals need no backfill of rows to keep counting correctly.
        # rule #6 (bot review, PR#1437 r3): an unreadable store forces $AD=[] and $DF=[], which
        # collapses the ADOPTED-OPEN test below to "has a lifecycle label" — an open, unlabeled,
        # UNRULED member (the #1315 shape) would then read as excluded rather than open, turning
        # a transient read failure into a fabricated completion signal. Gate on $gdisp_ok instead:
        # only apply the disposition filter when the store actually read; otherwise fall back to
        # the pre-PR plain open-non-bucket count, so a blind read can only ever look MORE open,
        # never less.
        if [ "$gdisp_ok" = 1 ]; then
          gopen_n_ckpt="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" --arg ad "$gdisp_ad" --arg df "$gdisp_df" \
            '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
             | ($ad | split(" ") | map(select(. != ""))) as $AD
             | ($df | split(" ") | map(select(. != ""))) as $DF
             | ["agent/queued","agent/in-progress","agent/review","agent/blocked","agent/arbitrate","agent/error","agent/done","agent/linked"] as $LC
             | [.[] | select(.number as $n | $D | index($n)) | select(.state == "OPEN") | select(.title | startswith("post-launch:") | not)
                    | select((.number | tostring) as $k
                             | ($AD | index($k)) != null
                               or (($DF | index($k)) == null
                                   and (((.labels // []) | map(.name)) | any(. as $l | ($LC | index($l)) != null))))] | length' 2>/dev/null || echo "")"
        else
          gopen_n_ckpt="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" \
            '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
             | [.[] | select(.number as $n | $D | index($n)) | select(.state == "OPEN") | select(.title | startswith("post-launch:") | not)] | length' 2>/dev/null || echo "")"
        fi
        case "$gopen_n_ckpt" in ''|*[!0-9]*) gopen_n_ckpt="$gopen_n";; esac
        # UNDISPOSITIONED = open, not the bucket, no row, no `agent/*` lifecycle label — the
        # #1315 shape (an inert issue bound into the tree with nobody's judgment on it).
        gundisp_n="$(printf '%s' "$kidsall" | jq -r --arg d "$gdesc" --arg ad "$gdisp_ad" --arg df "$gdisp_df" \
          '(($d | split(" ") | map(select(. != "") | tonumber))) as $D
           | ($ad | split(" ") | map(select(. != ""))) as $AD
           | ($df | split(" ") | map(select(. != ""))) as $DF
           | ["agent/queued","agent/in-progress","agent/review","agent/blocked","agent/arbitrate","agent/error","agent/done","agent/linked"] as $LC
           | [.[] | select(.number as $n | $D | index($n)) | select(.state == "OPEN") | select(.title | startswith("post-launch:") | not)
                  | select((.number | tostring) as $k | ($AD | index($k)) == null and ($DF | index($k)) == null)
                  | select(((.labels // []) | map(.name)) | any(. as $l | ($LC | index($l)) != null) | not)] | length' 2>/dev/null || echo "")"
        case "$gundisp_n" in ''|*[!0-9]*) gundisp_n=0;; esac
        set -- $gdesc; gtotal_n=$#
        _gf_find "$slug" "$g" && gf_rc=0 || gf_rc=$?
        gfbody="$GF_BODY"
        gbd="${gopen_n} open / ${gclosed_n} closed of ${gtotal_n} descendants"
        gcur="$(printf '%s\n' "$gfbody" | awk '/^burn-down:/{sub(/^burn-down: /,""); print; exit}')"
        # gf_rc=2 (comments UNREADABLE) skips the write outright: the `-` sentinel means
        # CONFIRMED absent, and a blind create risks a second store comment (PR#398 r2).
        if [ "$gcur" != "$gbd" ] && [ "${gf_rc:-2}" != "2" ]; then
          gf_burndown "$slug" "$g" "$gbd" "${GF_ID:--}" "$gfbody" >/dev/null 2>&1 \
            || echo "  [$repo] ⚠ goal #${g}: burn-down write refused — store stale, checkpoint counting unaffected" >&2
        fi
        gcounts="$(printf '%s\n' "$gfbody" | gf_parse_counts)"
        gtot="${gcounts% *}"; gdisp="${gcounts#* }"
        gundisp=$(( gtot - gdisp ))
        gck=""
        [ "$gundisp" -ge "${GOAL_CHECKPOINT_N:-5}" ] && gck="findings ${gundisp} undispositioned"
        if [ "$gopen_n_ckpt" -eq 0 ] && [ "$gclosed_n" -gt 0 ] && [ "$gpl" -eq 0 ]; then
          gck="${gck:+${gck} + }child-set complete pre-launch"
        fi
        # Trigger (c) — ADR-122 (4): an undispositioned member WAKES the checkpoint and never
        # blocks it. It is deliberately NOT part of gopen_n_ckpt, so (b) still fires alongside
        # it: the container is asked to RULE the member, not to wait on it.
        if [ "$gdisp_ok" = 1 ] && [ "$gundisp_n" -gt 0 ]; then
          gck="${gck:+${gck} + }members ${gundisp_n} undispositioned"
        fi
        if [ -n "$gck" ]; then
          echo "  [$repo] goal #${g}: CHECKPOINT due (${gck}; store ${gtot} total / ${gdisp} dispositioned)"
          units="${units}goal-checkpoint|${repo}|issue-${g}\n"
          item_class_push "$repo" "issue-${g}" "container" "machine" "${default_branch:-}"
        fi
      done
    fi
    # ── BARE TREE MEMBERS OF OPEN GOALS — the walk RETIRED 2026-09-05 (ADR-122 (1)) ─────────
    # Filing is inert, no exceptions: no reader queues an issue from its SHAPE. A tree member
    # without `agent/queued` is the CONTAINER's to dispose (docs/agents/issue-authoring.md
    # §The lineage contract rule 9 — `undispositioned | adopted | deferred`, built in S8), never
    # the scan's to queue. History: homelab#1153 → PR#1242 → #1249 (three misfires in one tick).
    # <<<REPLAY:goal-lane<<<
    [ -n "$qblocked" ] && orphans="${orphans}[$repo] ⏳ queued-blocked (FU-087 native blocked-by; closure is seen next scan):\n${qblocked}"
    [ -n "$qcycles" ] && orphans="${orphans}[$repo] ⚠ blocked-by CYCLE (FU-087) — human-first, neither side dispatched:\n${qcycles}"
    swept="$(gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels \
      --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("direction-change"))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    [ -n "$swept" ] && orphans="${orphans}[$repo] ⚠ direction-change — human sweep needed BEFORE dispatch:\n${swept}\n"
    # FU-069(a): `agent/error` = the anomaly circuit-breaker (merge-path.md §Runaway dispatch) —
    # HUMAN-FIRST, excluded from every actionable clause above/below. Reported so it never rots
    # silently, but a tick must not touch it (no dispatch, no relabel, no arbitration).
    errs="$( { gh issue list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels \
        --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("agent/error"))|"  issue #\(.number) — \(.title)"]|.[]' 2>/dev/null || true; \
      gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels \
        --jq '[.[]|(.labels|map(.name)) as $L|select($L|index("agent/error"))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true; } )"
    [ -n "$errs" ] && orphans="${orphans}[$repo] ⚠ agent/error (anomaly breaker, FU-069) — human-first, NOT dispatched:\n${errs}\n"
    # `major` is now set on Renovate majors too (renovate-global.json), so gate the major clause on
    # UN-ARMED — an armed PR is the review reflex's, never the coordinator's (arming is the boundary).
    # (prsjson fetched ABOVE the queued loop since ADR-097 — the open-PR cap reads it first.)
    prs="$(printf '%s' "$prsjson" | jq -r '[.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and ((($L|index("major")) and (.autoMergeRequest==null)) or ($L|index("merge-conflict")) or (.reviewDecision=="CHANGES_REQUESTED")))|"  PR #\(.number) — \(.title)"]|.[]')"
    # FU-124: an ARMED PR stuck BEHIND relies on GitHub's cron sweeper as its sole updater
    # trigger for the LAST open PR, and GitHub drops scheduled runs (sleep#100 hung ~1h).
    # DETERMINISTIC nudge: call the update-branch API directly — idempotent at GitHub (422 =
    # already current), self-limiting (a nudged PR stops being BEHIND), FAIL-LOUD on 403 (a
    # token-scope gap must be visible, not silent). No LLM, no unit, no session.
    # >>>REPLAY:fu124-nudge>>>
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|select((.autoMergeRequest!=null) and (.mergeStateStatus=="BEHIND"))|.number'); do
      u_oid="$(printf '%s' "$prsjson" | jq -r --argjson u "$u" '.[]|select(.number==$u)|.headRefOid//""')"
      if gh api -X PUT "repos/${slug}/pulls/${u}/update-branch" \
        ${u_oid:+-f expected_head_sha="$u_oid"} >/dev/null 2>&1; then
        echo "  [$repo] FU-124: nudged updater — update-branch on armed BEHIND PR #${u}"
      else
        echo "  [$repo] FU-124: update-branch on PR #${u} failed (422 = race safe; other = investigate) — updater cron remains the backstop"
      fi
    done
    # <<<REPLAY:fu124-nudge<<<
    # ADR-094 units: each predicate row IS an action class — (clause, repo, item), the LLM never picks.
    # AUTHOR-scoped (2026-08-02, found live on snore#15): the fix-round play only has a mandate
    # over WORKER-authored PRs (same WORKER_AUTHOR scope as the reflex's C9). A human/operator PR
    # with CHANGES_REQUESTED stays on the report surface above — before this filter, every tick
    # dispatched a session that re-concluded "human PR, no mandate" (a per-tick sonnet leak, the
    # same absorbing-belt class as the WIP-hold jq-null bug).
    # >>>REPLAY:changes-requested-gate>>>
    # FU-143: an ASSEMBLY PR (head goal/**) with changes-requested is EXCLUDED from fix-round
    # dispatch — a fix round pushes to the PR head, and the head IS the protected goal/**
    # integration branch (the push would be refused). Instead, emit a goal-checkpoint unit
    # for the goal referenced by the Assembly-for: #<n> trailer (trigger=assembly-cr).
    # Debounced with state-fp: marker (homelab#198). Excludes agent/error and agent/blocked
    # PRs as every clause does.
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|select(((.headRefName // "")|startswith("goal/")) and (.reviewDecision=="CHANGES_REQUESTED"))|.number'); do
      # Breaker labels: agent/error (FU-069 human-first) and agent/blocked (human-waiting).
      if printf '%s' "$prsjson" | jq -e --argjson n "$u" '[.[]|select(.number==$n)|.labels[].name] | index("agent/error") != null' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ ASSEMBLY PR #${u} has changes-requested but carries agent/error — human-first (FU-143)\n"
        continue
      fi
      if printf '%s' "$prsjson" | jq -e --argjson n "$u" '[.[]|select(.number==$n)|.labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ ASSEMBLY PR #${u} has changes-requested but carries agent/blocked — human-waiting (FU-143)\n"
        continue
      fi
      # Extract the line-anchored Assembly-for: #<n> trailer from the PR body (same strong-link
      # shape the goal-lane post-launch transition keys on — IL-T18).
      g="$(printf '%s' "$prsjson" | jq -r --argjson n "$u" '.[]|select(.number==$n)|(.body//"")|capture("(?mi)^[ \\t]*assembly-for:[ \\t]*#(?<g>[0-9]+)\\b")|.g' 2>/dev/null || echo "")"
      case "$g" in ''|*[!0-9]*)
        # v1.3 themed assembly discriminator (homelab#1229): a goal/** HEAD whose body carries
        # `Fixes #<level-2>` where the level-2 is a task/goal descendant routes to the goal
        # ancestor via goal_resolve_ancestor. The themed shape (Goal #1162) deliberately has
        # NO Assembly-for: trailer — the Fixes keyword closes the theme container on merge.
        g="$(printf '%s' "$prsjson" | jq -r --argjson n "$u" '.[]|select(.number==$n)|(.body//"")|capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)")|.i' 2>/dev/null || echo "")"
        case "$g" in ''|*[!0-9]*)
          orphans="${orphans}[$repo] ⚠ ASSEMBLY PR #${u} has changes-requested but no line-anchored \`Assembly-for: #<n>\` trailer — cannot route to a goal; report-only (FU-143)\n"
          continue
        ;; esac
        # Resolve the goal ancestor from the Fixes-referenced issue.
        command -v goal_resolve_ancestor >/dev/null 2>&1 || . "${HERE}/goal-budget.sh"
        goal_resolve_ancestor "$slug" "$g"
        if [ -z "$GB_GOAL" ]; then
          orphans="${orphans}[$repo] ⚠ ASSEMBLY PR #${u} has changes-requested and \`Fixes #${g}\` but #${g} is not a task/goal descendant — cannot route to a goal; report-only (FU-143)\n"
          continue
        fi
        g_fixes="$g"
        g="$GB_GOAL"
        echo "  [$repo] ASSEMBLY PR #${u} has changes-requested — resolved goal #${g} from v1.3 themed shape (\`Fixes #${g_fixes}\` → goal_resolve_ancestor, homelab#1229)"
      ;; esac
      # state-fp debounce: one ride per verdict state (homelab#198).
      afp="$(pr_state_fp_pair "$slug" "$u" assembly-cr)"; afp_prev="${afp#*|}"; afp_cur="${afp%%|*}"
      if [ -n "$afp_cur" ] && [ "$afp_cur" = "$afp_prev" ]; then
        orphans="${orphans}[$repo] ⏳ ASSEMBLY PR #${u} changes-requested DEBOUNCED — state unchanged since the last goal-checkpoint emit for goal #${g} (\`state-fp:assembly-cr:${afp_cur}\`, homelab#198). The assembly PR still has CHANGES_REQUESTED and the goal-checkpoint unit was already emitted; a human (or new content) is the next mover.\n"
        continue
      fi
      # Emit a goal-checkpoint unit for the goal (trigger=assembly-cr).
      echo "  [$repo] ASSEMBLY PR #${u} has changes-requested (FU-143) — emitting goal-checkpoint for goal #${g} (trigger=assembly-cr)"
      units="${units}goal-checkpoint|${repo}|issue-${g}\n"
      item_class_push "$repo" "issue-${g}" "container" "machine" "${default_branch:-}"
      # Carry the assembly PR number to the dispatch site via a side map (not the unit tuple,
      # whose 4th field is uclass and 5th is uparent). Written at emission, consumed at the
      # confirmed-dispatch site (>>>REPLAY:dispatch-marker>>>) where the state-fp marker is
      # recorded — the debounce write must gate on confirmed selection, not on emission, or a
      # higher-priority clause winning the same tick silently sinks the goal-checkpoint forever.
      assembly_cr_prs="${assembly_cr_prs} ${repo}:issue-${g}:${u}"
    done
    for u in $(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and (($L|index("agent/blocked"))|not) and (.reviewDecision=="CHANGES_REQUESTED") and (.author.login==$wa) and (((.headRefName // "")|startswith("goal/"))|not))|.number'); do
      # ADR-094 project-WIP hold, same rationale as the queued gate above (meta-9, 2026-07-21:
      # while #60's fix round ran, every tick woke a redundant judge whose dispatch the launcher's
      # WIP=1 pre-flight would refuse — the Running worker IS this unit's in-flight work; C4/C5
      # re-emits if it dies, and the next bot verdict retires the clause).
      # FU-146 PER-ITEM hold (2026-08-06). The project-wide hold below was written when
      # REPO_MAX_WIP was 1, where "a worker is Running here" and "a worker is Running on THIS PR"
      # were the same sentence. ADR-097 raised the cap to 3 and silently made it a no-op for its
      # stated purpose: measured on circles PR#39, every tick AND doorbell re-emitted this unit
      # while its own fix round rode — ~59 of 71 coordinator sessions did nothing, and 13 of that
      # PR 22 comments were bot noise a human has to read past.
      # Key on the PR own linked issue vs the live ride pod names (agent-<stack>-issue-<n>-r<k>).
      # FAIL-SAFE BY CONSTRUCTION: no link found, or no pod probe this tick, falls through to the
      # project-wide behaviour unchanged — so this can only ADD holds, never remove one. And the
      # hold is conditioned on a LIVE pod, so it self-releases when that pod exits; it cannot wedge.
      pr_issue="$(printf '%s' "$prsjson" | jq -r --argjson n "$u" '.[] | select(.number == $n)
          | (.body // "")
          | (capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' 2>/dev/null)" || pr_issue=""
      if [ -n "$pr_issue" ] && [ -n "$WIPPODS_JSON" ] \
         && printf '%s' "${WIPPODS_JSON:-null}" | jq -e --arg pat "issue-${pr_issue}-" \
              '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ changes-requested held — a worker is already riding issue #${pr_issue} (FU-146 per-item):\n  PR #${u}\n"
        continue
      fi
      # FU-146 session-currency (the #153 storm, leg (a) for the PR lanes): a coordinator session
      # riding the linked issue is that item's in-flight work — same self-releasing shape.
      if sess_holds "issue-${pr_issue}"; then
        orphans="${orphans}[$repo] ⏳ changes-requested held (item session in flight) — a coordinator session is riding issue #${pr_issue} (FU-146):\n  PR #${u}\n"
        continue
      fi
      # BLOCKED-SOURCE hold (2026-08-07): an `agent/blocked` source issue is a HUMAN gate (budget
      # refusal, design decision) — re-judging its PR cannot move it and burned one sonnet judge
      # per cycle on circles PR#58 (AGENT_BUDGET_REFUSED, two sessions in 25 min). Fail-safe like
      # the hold above: no link, or issue not in openall → falls through unchanged; self-releases
      # the tick after the human clears the label (openall is re-fetched every tick).
      if [ -n "$pr_issue" ] \
         && printf '%s' "${openall:-null}" | jq -e --argjson n "$pr_issue" \
              '[.[] | select(.number == $n) | .labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ changes-requested held — source issue #${pr_issue} is agent/blocked (human-gated):\n  PR #${u}\n"
        continue
      fi
      if [ -n "$wip_busy" ]; then
        orphans="${orphans}[$repo] ⏳ changes-requested trigger held (project WIP at ${REPO_MAX_WIP} in ${repo}):\n  PR #${u}\n"
        continue
      fi
      # FU-147: the SAME no-op detection FU-115b gives the ci-red path. A fix round that completes
      # without pushing is otherwise invisible here, and the clause simply re-dispatches an
      # identical round forever. Live case that motivated it: circles#32 r3 died on a
      # goose-32602 truncation, reported `exit_status: clean`, banked nothing, and only a human
      # asking "where is the commit?" caught it. Reached only with NO live worker (both holds
      # above ran first), so a running round is never mistaken for a finished one.
      # Also carries the reviewable_again probe (homelab#975): reviews added to the same fetch.
      cr_probe="$(gh pr view "$u" --repo "$slug" --json comments,commits,reviews 2>/dev/null)" || cr_probe=''
      # blocked-on predicate (homelab#1188): if a terminal ruling recorded a blocker and it is
      # still unresolved, report instead of dispatch (homelab#1427).
      cr_boc="$(pr_blocked_on_check "$slug" "$u" "$cr_probe")"
      case "$cr_boc" in
        blocked|blocked\|*)
          orphans="${orphans}[$repo] ⏳ changes-requested BLOCKED-ON — PR #${u}: a terminal ruling recorded \`blocked-on: ${cr_boc#blocked|}\` and the blocker is still unresolved (homelab#1188). No ride is spent to re-derive the same answer.\n"
          continue
          ;;
      esac
      # reviewable_again hold (homelab#975): a fix round that pushed a new commit is the
      # reviewer's work item, not the coordinator's — the next bot verdict retires the clause.
      # Same predicate as review-reflex.sh:279 (newest non-merge commit > newest
      # APPROVED/CHANGES_REQUESTED review). Fail-safe: a failed or empty probe falls through.
      cr_reviews=""
      if [ -n "$cr_probe" ]; then
        cr_reviews="$(printf '%s' "$cr_probe" | jq -r '
          def newest_review_at:
            ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .submittedAt ] | max) // "";
          def newest_commit_at:
            ([ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not) | .committedDate ] | max) // "";
          if newest_commit_at != "" and newest_commit_at > newest_review_at then "held" else "" end
        ' 2>/dev/null)" || cr_reviews=""
      fi
      if [ -n "$cr_reviews" ]; then
        head8="$(printf '%s' "$cr_probe" | jq -r '([.commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not)] | sort_by(.committedDate) | last | .oid) // ""' 2>/dev/null | head -c8)"
        orphans="${orphans}[$repo] ⏳ changes-requested held (re-review pending — round pushed ${head8}):\n  PR #${u}\n"
        continue
      fi
      cr_noop=""
      if [ -n "$cr_probe" ]; then
        cr_noop="$(printf '%s' "$cr_probe" | jq -r "$NOOP_ROUND_JQ" 2>/dev/null)" || cr_noop=""
      fi
      if [ -n "$cr_noop" ]; then
        gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
          && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (changes-requested no-op round, FU-147): the last completed fix round posted its run stats without pushing a commit, so the reviewer findings are untouched and another identical round cannot converge. The coordinator arbitrate unit rules per the escalation table." >/dev/null 2>&1 \
          && orphans="${orphans}[$repo] ⚠ changes-requested NO-OP round → agent/arbitrate: PR #${u} (a completed round pushed nothing)\n" \
          || orphans="${orphans}[$repo] ⚠ changes-requested no-op arbitrate FAILED to label PR #${u} — human check\n"
        continue
      fi
      units="${units}changes-requested|${repo}|pr-${u}\n"
      item_class_push "$repo" "pr-${u}" "riding" "machine"
    done
    # <<<REPLAY:changes-requested-gate<<<
    # merge-conflict (MP-T06, homelab#595): the updater labels a PR `merge-conflict` when its
    # update-branch API call 422s on a DIRTY head. WORKER_AUTHOR-scoped, mirroring the
    # changes-requested clause above (671a053): the fix-round play only has a mandate over
    # WORKER-authored PRs — a seat-authored (operator-lane) conflict is the author's own push to
    # resolve, and every re-dispatch is a session that re-concludes exactly that. Live 2026-08-19:
    # #585's wave→stint rename ran #586 DIRTY and burned one ride per tick (09:13:35Z, 09:36Z) on
    # byte-identical state, preempting queued work each time. The seat-authored case stays on the
    # report surface (orphans here + the board's §FIX) so scoping it out of the unit list makes it
    # visible rather than merely undispatched. The worker-authored case carries the #198 currency
    # check (same fingerprint pair as arbitrate/ci-red), so an unchanged conflict emits a report
    # line instead of a ride. A THIRD leg (homelab#602): a PR whose `.author` is `null` (deleted/
    # suspended GitHub account) matches NEITHER predicate and would otherwise vanish from both
    # surfaces. Report-only — the account's lane is unknowable, so dispatching would risk the #595
    # per-tick leak on a PR that might have been seat-authored; the catch-all line keeps it in a
    # human's sight instead of silent.
    # >>>REPLAY:merge-conflict-gate>>>
    for u in $(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED") and (.author != null) and (.author.login != $wa))|.number'); do
      orphans="${orphans}[$repo] ⚠ merge-conflict PR #${u} is seat-authored (operator lane) — the author's own push is the next mover; no machine fix-round mandate (homelab#595)\n"
    done
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED") and (.author == null))|.number'); do
      orphans="${orphans}[$repo] ⚠ merge-conflict PR #${u} has a NULL author (deleted/suspended GitHub account) — the account's lane is unknowable, so no machine fix-round is dispatched; a human owns the next mover (homelab#602)\n"
    done
    # Fetch PR JSON ONCE for merge-conflict clause to share between pr_blocked_on_check and pr_state_fp_pair (homelab#1211).
    mfp_prjson="$(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED") and (.author.login==$wa)) | @json' | head -1)" || mfp_prjson=''
    for u in $(printf '%s' "$prsjson" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not) and ($L|index("merge-conflict")) and (.reviewDecision!="CHANGES_REQUESTED") and (.author.login==$wa))|.number'); do
      # Fetch PR JSON for this specific PR with all needed fields for state-fp and blocked-on checks
      pr_json_mf="$(gh pr view "$u" --repo "$slug" --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments,commits 2>/dev/null)" || pr_json_mf=''
      # FU-146 PER-ITEM hold: same as ci-red — check if a worker pod is already riding this PR's source issue
      mf_issue="$(printf '%s' "$pr_json_mf" | jq -r '(.body // "")
          | (capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' 2>/dev/null)" || mf_issue=""
      if [ -n "$mf_issue" ] && [ -n "$WIPPODS_JSON" ] \
         && printf '%s' "${WIPPODS_JSON:-null}" | jq -e --arg pat "issue-${mf_issue}-" \
              '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ merge-conflict held — a worker is already riding issue #${mf_issue} (FU-146 per-item):\n  PR #${u}\n"
        continue
      fi
      # BLOCKED-SOURCE hold: check if the source issue is agent/blocked (human-gated)
      if [ -n "$mf_issue" ] \
         && printf '%s' "${openall:-null}" | jq -e --argjson n "$mf_issue" \
              '[.[] | select(.number == $n) | .labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
        orphans="${orphans}[$repo] ⏳ merge-conflict held — source issue #${mf_issue} is agent/blocked (human-gated):\n  PR #${u}\n"
        continue
      fi
      # BLOCKED-ON hold: check if the PR has a blocked-on marker
      mf_boc="$(pr_blocked_on_check "$slug" "$u" "$pr_json_mf")"
      case "$mf_boc" in
        blocked*)
          reason="${mf_boc#blocked|}"
          orphans="${orphans}[$repo] ⏳ merge-conflict held — PR #${u} is blocked-on: ${reason}\n"
          continue
          ;;
      esac
      mfp="$(pr_state_fp_pair "$slug" "$u" "merge-conflict" "$pr_json_mf")"; mfp_prev="${mfp#*|}"; mfp_cur="${mfp%%|*}"
      if [ -n "$mfp_cur" ] && [ "$mfp_cur" = "$mfp_prev" ]; then
        orphans="${orphans}[$repo] ⏳ merge-conflict DEBOUNCED — PR #${u}: head, checks, reviewDecision and newest verdict are all unchanged since the last merge-conflict dispatch (\`state-fp:merge-conflict:${mfp_cur}\`, homelab#198). The conflict stands and a round was already dispatched at this exact input — a human (or new content) is the next mover, so no ride is spent to re-derive it.\n"
        continue
      fi
      units="${units}merge-conflict|${repo}|pr-${u}\n"
      item_class_push "$repo" "pr-${u}" "parked-infeasible" "machine"
    done
    # <<<REPLAY:merge-conflict-gate<<<
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("major/awaiting-human"))|not) and (($L|index("agent/error"))|not) and ($L|index("major")) and (.autoMergeRequest==null) and (.reviewDecision!="CHANGES_REQUESTED") and (($L|index("merge-conflict"))|not))|.number'); do
      units="${units}unarmed-major|${repo}|pr-${u}\n"
      item_class_push "$repo" "pr-${u}" "orphan-unarmed" "machine"
    done
    # BACKSTOP (FU-079, generalizes the old dep-only clause): an un-armed open PR that no lane owns
    # is invisible to the ENTIRE merge path — the updater, review reflex, and auto-merge all key on
    # armed PRs (by design), so it stalls silently (live: oracle-fleet#16, a stacked PR born
    # un-armed, stuck at ci "Expected" then BEHIND). Owned lanes excluded: automerge/deps-review
    # (their reflexes arm), un-armed `major` + merge-conflict + CHANGES_REQUESTED (coordinator
    # actionable, above), major/awaiting-human (parked on a human by design), agent/error
    # (human-first). Report-only: the fix is `gh pr merge --auto` or an explicit parking label —
    # arm-at-open is operator discipline (merge-path.md).
    orph="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,reviewDecision,autoMergeRequest \
      --jq '[.[]|(.labels|map(.name)) as $L|select((.autoMergeRequest==null)
        and (([$L[]|select(.=="automerge" or .=="deps-review" or .=="major" or .=="major/awaiting-human" or .=="merge-conflict" or .=="agent/error")]|length)==0)
        and (.reviewDecision!="CHANGES_REQUESTED"))|"  PR #\(.number) — \(.title)"]|.[]' 2>/dev/null || true)"
    # v2 (FU-050, C4/C5): an `agent/in-progress` issue whose worker went TERMINAL is a silent stall
    # until someone re-ticks — this was meta-only work all through meta-session 2. actionable =
    # in-progress ∧ no Running worker pod in the project ns ∧ no OPEN PR referencing the issue (an
    # open PR means the merge-path reflexes own it; `agent/blocked` is excluded by the selector
    # below rather than assumed away — see the note on it there).
    # A kubectl probe failure is reported and SKIPS the clause — it never fails INTO a wake
    # (rule #6); the launcher pre-flight is the double-dispatch belt either way.
    v2=""
    if [ "$(printf '%s' "$inprog" | jq 'length')" -gt 0 ]; then
      # ── THE REVIEW-FLIP BELT (homelab#501 / MP-T14): in-progress → review at PR-open ──────────
      # Operator ruling 2026-08-18, direction (b): the footprint releases at PR-open BY DESIGN.
      # The ADR-097 hold's only job is preventing two LIVE workers in one file; once the PR is open
      # the worker is dead and the "occupation" is durable branch state, which the merge path is
      # DESIGNED to absorb (strict up-to-date, updater serialization, the merge-conflict judgment
      # lane; the ≤3-open-PR cap bounds the churn). The documented lifecycle moves an issue to
      # `agent/review` at PR-open, and nothing implemented that flip — the release was a coin-flip
      # on whether a coordinator session happened to visit the item (2026-08-18: #477/#450 held
      # 9-10h while every PR sat codeowner-parked; the unused half of #477's declaration held
      # #478/#479 out of dispatch). This belt makes the flip DETERMINISTIC; finalize is the CAUSE
      # half (agent-runtime, filed separately) and the belt covers finalize failures forever (the
      # IL-G07 pattern: belt and cause are separate items by design).
      # The predicate is the STRONG link, same grammar as C6's goal-child closeout: a bare mention
      # cannot tell "the PR that IMPLEMENTS the issue" from "a PR that NAMES it as a sibling seam"
      # (the 2026-08-06 circles#36 lesson), so a sibling citation must NOT flip the label. Closed
      # PRs are invisible here by construction (prsjson is the OPEN list) — a PR merged yesterday
      # cannot release today's footprint; the merged-closeout clause owns that state.
      # >>>REPLAY:review-flip-belt>>>
      # `busy_fps` above already read $inprog, so THIS tick still holds a flipped issue's footprint
      # (level-triggered: the next scan sees agent/review). C4/C5 below runs on the same stale
      # $inprog, but its selector already excludes any issue an open PR references (the bare-mention
      # test) — a strong link IS a bare mention, so a flipped issue falls out of every derivation
      # with no extra exclusion.
      # agent/error (human-first breaker) and agent/blocked (human gate) are excluded — a relabel
      # must never move an issue out of a HUMAN-OWNED state.
      # ⚠ The re-read proves the END STATE before the audit comment: `gh issue edit` is not atomic,
      # and with NEITHER label the issue is invisible to every clause (IL-T16's lesson, oracle#193).
      # `set -euo pipefail`: the `if` + `|| true` keep a refused write a REPORTED write.
      flip_done=""
      if printf '%s' "${prsjson:-null}" | jq -e 'type == "array"' >/dev/null 2>&1; then
        flip_cands="$(printf '%s' "$inprog" | jq -r --argjson prs "$prsjson" '
          [.[] | (.labels|map(.name)) as $L
                | select((($L|index("agent/error"))|not) and (($L|index("agent/blocked"))|not))
                | .number as $n
                | select([$prs[] | select(((.body // "") | test("(^|[^a-z])(implements|closes|close[ds]?|fixe[ds]?|fix|resolve[ds]?)[ \\t]+#\($n)\\b"; "i"))
                                   or ((.body // "") | test("(?m)^[ \\t]*issue:[ \\t]*#\($n)\\b"; "i")))] | length > 0)
                | "\($n)"] | .[]')" 2>/dev/null || flip_cands=""
        for fcn in $flip_cands; do
          fok=""
          # IL-T16 write discipline: add agent/review FIRST, remove agent/in-progress SECOND,
          # then RE-READ and prove the end state — the audit comment is posted only against a
          # state we verified.
          if gh issue edit "$fcn" --repo "$slug" --add-label agent/review >/dev/null 2>&1; then
            gh issue edit "$fcn" --repo "$slug" --remove-label agent/in-progress >/dev/null 2>&1 || true
          fi
          fend="$(gh issue view "$fcn" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
          case ",${fend}," in
            *",agent/review,"*) case ",${fend}," in *",agent/in-progress,"*) : ;; *) fok=1;; esac;;
          esac
          if [ -n "$fok" ]; then
            gh issue comment "$fcn" --repo "$slug" --body "$(printf '%s\n' \
              "🤖 **\`agent/in-progress\` → \`agent/review\` — footprint released at PR-open** (deterministic scan belt, homelab#501 / MP-T14)." \
              "" \
              "An OPEN PR strongly references \`#${fcn}\` (\`implements\`/\`closes\`/\`fixes\`/\`resolves\`, or the line-anchored \`Issue:\` trailer), so this issue's work has left the worker pod and become durable branch state. The issue-label lifecycle moves it to \`agent/review\` here, deterministically — it no longer depends on a coordinator session happening to visit the item." \
              "" \
              "This releases the issue's ADR-097 footprint and its WIP slot. Concurrent same-file PRs are a state the merge path is designed to absorb (strict up-to-date, updater serialization, the merge-conflict judgment lane) — the codeowner gate no longer freezes sibling dispatch." )" >/dev/null 2>&1 || true
            flip_done="${flip_done}${fcn} "
            orphans="${orphans}[$repo] ✓ issue #${fcn} flipped \`agent/in-progress\` → \`agent/review\` (open PR strongly references it — deterministic scan belt, homelab#501/MP-T14): footprint released at PR-open by design\n"
          else
            orphans="${orphans}[$repo] ⛔ review-flip FAILED or landed HALF-APPLIED on issue #${fcn} — labels are now [${fend}]. Fix by hand: it wants \`agent/review\` and NOT \`agent/in-progress\`.\n"
          fi
        done
      else
        orphans="${orphans}[$repo] ⚠ review-flip belt HELD — the open-PR read is unreadable this tick (rule #6: never fail INTO a write); no flips\n"
      fi
      # <<<REPLAY:review-flip-belt<<<
      if PODS="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" \
            --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers 2>/dev/null)"; then
        if [ -z "$PODS" ]; then
          # >>>REPLAY:c4c5-bodies-probe>>>
          if BODIES="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json body --jq '[.[].body]' 2>/dev/null)"; then
            # The open-PR body probe is guarded the same way its kubectl sibling above is: a probe
            # failure is REPORTED (`⚠ PROBE_FAILED (open PRs)`) and the WHOLE clause is skipped for
            # this repo this tick — it must never fail INTO a wake (rule #6). An empty array is the
            # ONLY "no open PRs" signal, nothing else (homelab#488): `gh pr list` degraded to `[]` on
            # a transient 503 made every in-progress issue read as an abandoned ride, and the belt
            # re-queued work a live PR already owned (homelab#405, the 18:00:53Z tick).
            # ONE selector, FOUR derivations (the infeasible terminal, the belt, the report line,
            # the unit) — this is conditions (a)+(b) of the abandoned-ride predicate and the copies
            # MUST NOT drift.
            # FU-143 point 2: the merged-into-goal set is NOT abandoned — excluded here (and so in
            # every derivation) or c4c5-redispatch, which outranks merged-closeout, re-rides merged
            # work every tick while the closeout unit starves. Detection block above.
            # ⚠ Kept SINGLE-quoted and concatenated as `jq "$C4C5_SEL"'|…'`. Pasting it into a
            # double-quoted jq program would eat one backslash and turn the `\\b` word boundary into
            # jq's `\b` BACKSPACE — the reference test would then match nothing and every
            # in-progress issue would read as abandoned. Variable expansion does no such thing.
            # `agent/blocked` is excluded for the same reason `agent/error` is, and the old comment
            # four lines up ("blocked issues never carry in-progress") is exactly the assumption that
            # made it unnecessary — an assumption, not a guard. A human (or the infeasible terminal
            # below, mid-write) can hold BOTH labels for a tick, and re-dispatching a human-gated
            # issue is the one thing C4/C5 must never do (retro r3 F4, homelab#257).
            # >>>REPLAY:c4c5-selector>>>
            C4C5_SEL='.[] | (.labels|map(.name)) as $L
               | select((($L|index("agent/error"))|not) and (($L|index("agent/blocked"))|not))
               | .number as $n
               | select((($cg | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select((($gb | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select((($db | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select((($sess | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)'
            # <<<REPLAY:c4c5-selector<<<
            # ── THE INFEASIBLE TERMINAL (retro r3 F4, homelab#257) ────────────────────────────────
            # A worker that correctly rules the deliverable NOT IMPLEMENTABLE AS WRITTEN — a path in
            # its recipe's ban list, a resource outside the pod (cluster, live API creds, a
            # sibling-repo checkout) — ends without pushing. That honest answer used to be
            # INDISTINGUISHABLE FROM A CRASH: no branch, no PR, `agent/in-progress` still on, so the
            # C4/C5 predicate below read it as an abandoned ride and either the belt re-queued it or
            # the unit spent an LLM tick to re-dispatch the same impossible task. oracle-fleet#66 is
            # the worked case: `AGENT_STRIKE … error_class=unknown`, and the coordinator had to
            # override the mechanical c4c5-redispatch clause BY HAND.
            # The marker makes it first-class: one comment whose FIRST characters are exactly
            # `AGENT_INFEASIBLE: <path/resource>` (the producer half is the recipe paragraph in each
            # repo's `.agents/fix.yaml`), and the scan parks the issue on `agent/blocked` — a human
            # gate — instead of re-riding it.
            # Three properties are load-bearing:
            #   • ANCHORED at the start of a comment body, never a substring. This issue's own title
            #     contains the marker, and a human quoting it writes `> AGENT_INFEASIBLE: …`; an
            #     unanchored read would make "talks about the terminal" mean "IS the terminal" — the
            #     same defect the fix-debounce lane's `alert-fp:` test was fixed for (homelab#244).
            #   • ISSUE COMMENTS ONLY, never the body: the body is written by the human who filed it.
            #   • THE MARKER ALONE SUPPRESSES THE REDISPATCH, whether or not the label write lands.
            #     A failed/half-applied write is reported loudly and the issue still leaves the unit
            #     list: re-riding a task a worker has already proven impossible costs a paid session
            #     to re-derive a known answer, which is strictly worse than a report line. An
            #     UNREADABLE probe is the other way round (rule #6, never fail INTO a write): the
            #     issue keeps today's behaviour, belt and unit included.
            # >>>REPLAY:infeasible-terminal>>>
            infeas_done=""
            for icand in $(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" \
                --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" --arg db "${c6db_nums:-}" --arg sess "${sess_nums:-}" "$C4C5_SEL"' | "\($n)"'); do
              icmt="$(gh api "repos/${slug}/issues/${icand}/comments?per_page=100" 2>/dev/null)" || icmt=""
              # `type == "array"`, not a bare `jq -e .`: an error OBJECT is truthy, and `.[]` over it
              # feeds `(.body // "")` a string, which is a jq ERROR — inside `imark="$(…)"` under
              # `set -euo pipefail` that aborts the ENTIRE scan mid-repo, starving every later clause
              # and every other stack. The same shape the belt's `if`/`|| true` exist for.
              if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${icmt:-null}"; then   # :-null, not :- — jq 1.6 exits 0 on EMPTY input, silencing this PROBE_FAILED line (homelab#377)
                orphans="${orphans}[$repo] ⚠ PROBE_FAILED reading issue #${icand}'s comments — the infeasible-terminal check was SKIPPED for it this tick; it keeps today's C4/C5 behaviour (rule #6)\n"
                continue
              fi
              # `first // ""` — a worker posts the marker once; if a second one exists the first is
              # the one that ended the ride. jq's `^` is string-start (no "m" flag), which IS the
              # anchor this wants: the marker opens the comment or it does not count.
              imark="$(jq -r '[.[] | (.body // "") | select(test("^AGENT_INFEASIBLE:"))] | first // ""' <<<"$icmt")"
              if [ -z "$imark" ]; then
                # The read window is ONE page. A marker past comment 100 is invisible, and this
                # clause's whole value is that it is not guessed at — so the bound is REPORTED rather
                # than left to look like "no marker". Fall-through is today's behaviour, not a new
                # failure: the issue keeps its belt and its unit.
                if [ "$(jq -r 'length' <<<"$icmt" 2>/dev/null || echo 0)" -ge 100 ]; then
                  orphans="${orphans}[$repo] ⚠ issue #${icand} has ≥100 comments — the infeasible-terminal read is one page, so a marker beyond it was NOT seen. Unchanged C4/C5 handling below; check the thread's tail by hand before acting on it.\n"
                fi
                continue
              fi
              # The payload is the REST of the marker line. Empty is still a terminal — the worker
              # declared infeasibility and simply did not name the thing — so it parks and the
              # report says the name is missing, rather than falling through to a re-ride.
              ipay="$(jq -rn --arg m "$imark" '$m | split("\n")[0] | ltrimstr("AGENT_INFEASIBLE:")
                      | sub("^[ \t]+"; "") | .[0:200]')"
              [ -n "$ipay" ] || ipay="(no path/resource named — ask the worker's transcript)"
              infeas_done="${infeas_done}${icand} "
              # ⚠ Same non-atomic write as the belt below, same order for the same reason: ADD the
              # new lifecycle label FIRST, remove `agent/in-progress` SECOND, then RE-READ and prove
              # the end state. With neither label the issue is invisible to every clause.
              if gh issue edit "$icand" --repo "$slug" --add-label agent/blocked >/dev/null 2>&1; then
                gh issue edit "$icand" --repo "$slug" --remove-label agent/in-progress >/dev/null 2>&1 || true
              fi
              iend="$(gh issue view "$icand" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
              iok=""
              case ",${iend}," in
                *",agent/blocked,"*) case ",${iend}," in *",agent/in-progress,"*) : ;; *) iok=1;; esac;;
              esac
              if [ -n "$iok" ]; then
                gh issue comment "$icand" --repo "$slug" --body "$(printf '%s\n' \
                  "🤖 **\`AGENT_INFEASIBLE\` — parked \`agent/blocked\` for a human** (deterministic scan, retro r3 F4 / homelab#257)." \
                  "" \
                  "The worker ruled this **not implementable as written** and ended without pushing, naming:" \
                  "" \
                  "> ${ipay}" \
                  "" \
                  "That is a VERDICT, not a crash, so it does not go back through \`c4c5-redispatch\`: re-riding it would spend another paid session to re-derive an answer the loop already has. Labels moved \`agent/in-progress\` → \`agent/blocked\`, which also frees the repo WIP slot and releases every sibling this issue's \`Touches:\` footprint was holding (ADR-097)." \
                  "" \
                  "**A human is the next mover.** Either re-scope the issue so the deliverable is inside a fix-class worker's reach (recipe path tiers + what the pod can actually see), or do the named part by hand — then remove \`agent/blocked\` and re-queue. Re-queueing it unchanged will simply reach the same verdict." )" >/dev/null 2>&1 || true
                orphans="${orphans}[$repo] ⛔ INFEASIBLE — issue #${icand} parked \`agent/blocked\` (worker: ${ipay}). NOT re-dispatched: a human must re-scope it or do that part by hand (retro r3 F4).\n"
              else
                orphans="${orphans}[$repo] ⛔ INFEASIBLE — issue #${icand} declared \`AGENT_INFEASIBLE: ${ipay}\`, but the label write FAILED or landed HALF-APPLIED — labels are now [${iend}]. Fix by hand: it wants \`agent/blocked\` and NOT \`agent/in-progress\`. The redispatch is suppressed either way (a proven-impossible task is not re-ridden on the strength of a label write).\n"
              fi
            done
            # <<<REPLAY:infeasible-terminal<<<
            # ── THE BELT (homelab#155): RECONCILE the phantom label, do not only report it ────────
            # A phantom `agent/in-progress` starves far more than its own issue: it counts against
            # REPO_MAX_WIP and holds every SIBLING through the ADR-097 footprint intersection
            # ("overlaps an in-progress issue's Touches"). Six of them across two stacks idled
            # oracle+circles for ~3h on 2026-08-08 and were cleared BY HAND — found only because the
            # operator asked why nothing was running. agent-runtime#36 owns the CAUSE (finalize must
            # run on every exit path); this is the BELT, because causes recur in new shapes (deadline
            # reap, node loss, OOM) and a belt catches every shape.
            # Two more holds before it writes, both fail-SAFE — an unreadable probe HOLDS, it never
            # clears (rule #6: never fail INTO a write):
            #   (c) PERSISTENCE. Nothing in a dispatch is transactional: the coordinator applies
            #       `agent/in-progress` and THEN creates the pod, and finalize opens the PR from
            #       inside a pod that is still Running. So a scan can land mid-transition and see
            #       (a)+(b) on perfectly live work. Two anchors, BOTH must be older than
            #       C4C5_PERSIST_S: the issue has been quiet (`updatedAt` — the label write that
            #       starts a ride bumps it, so this covers the dispatch race), and no agent-session
            #       pod for THIS issue went terminal recently (covers the finalize race, where the
            #       pod exits a beat before its PR appears).
            #   (d) NO MERGED PR mentions the issue. `Fixes #N` closes on a master merge so the
            #       normal case never reaches here — but a PR merged with a NON-closing reference
            #       leaves exactly this state, and re-queueing it re-rides finished work (the
            #       FU-143 lesson, one lane over). A bare mention is enough to hold: holding costs a
            #       report line, guessing costs a duplicate ride.
            # Anything the belt HOLDS keeps today's behaviour exactly — reported, and the
            # c4c5-redispatch unit still rides, so the LLM tick stays the path for every case the
            # belt will not touch by itself. Anything it CLEARS leaves the unit list: the issue is an
            # ordinary `agent/queued` item again and the normal dispatch path (with its footprint,
            # WIP and PR-cap gates) owns it on the next pass — no LLM tick spent to say "re-run it".
            c4c5_cleared=""
            c4c5_cands=""
            # An issue the infeasible terminal already parked is NOT a phantom label: the belt would
            # re-queue it to `agent/queued` and hand it straight back to dispatch, undoing the human
            # gate it was just given. Excluded here, and from both derivations below, via the same
            # `$done` list the belt's own clears use.
            [ -n "$dispatchable" ] && c4c5_cands="$(printf '%s' "$inprog" \
              | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" --arg db "${c6db_nums:-}" --arg sess "${sess_nums:-}" \
                --arg done "${infeas_done:-}" \
                "$C4C5_SEL"' | select((($done | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
                 | "\($n)|\(.updatedAt // "")"')"
            if [ -n "$c4c5_cands" ]; then
              now_s="$(date -u +%s)"
              # A SECOND pod probe on purpose: the live one above is the tested condition-(a)
              # predicate and stays byte-for-byte what it was. This one wants the TERMINAL pods it
              # filters out, with their finish times. Both probes failing is the same story — hold.
              TPODS="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session,project="$repo" -o json 2>/dev/null)" || TPODS=""
              c4c5_merged="$(gh pr list --repo "$slug" --state merged --limit 40 --json body --jq '[.[].body // ""]' 2>/dev/null)" || c4c5_merged=""
              if ! jq -e . >/dev/null 2>&1 <<<"${TPODS:-null}" || ! jq -e . >/dev/null 2>&1 <<<"${c4c5_merged:-null}"; then
                orphans="${orphans}[$repo] ⚠ PROBE_FAILED (terminal pods / merged PRs) — the phantom-label belt held every candidate this tick; the C4/C5 report + unit below are unaffected (rule #6)\n"
              else
                for cand in $c4c5_cands; do
                  cn="${cand%%|*}"; cupd="${cand#*|}"
                  # jq parses the timestamps, not `date -d` — same reader the pod janitor at the top
                  # of this file uses, and it does not assume GNU date in the scan image. An
                  # UNPARSEABLE stamp yields -1, which is < the window, so it holds.
                  cage="$(jq -rn --arg t "$cupd" --argjson now "$now_s" \
                    '($t | fromdateiso8601? // null) as $s | if $s == null then -1 else ($now - $s) end' 2>/dev/null || echo -1)"
                  case "$cage" in ''|*[!0-9-]*) cage=-1;; esac
                  if [ "$cage" -lt "$C4C5_PERSIST_S" ]; then
                    orphans="${orphans}[$repo] ⏳ phantom-label belt HELD — issue #${cn} was touched $(( cage < 0 ? 0 : cage / 60 ))m ago (< the ${C4C5_PERSIST_S}s transition-race guard, or an unreadable timestamp); re-checked next scan\n"
                    continue
                  fi
                  # Pod-transition anchor. No matching terminal pod at all ⇒ nothing recent to race
                  # with (the big sentinel); a jq/read failure ⇒ 0 ⇒ held.
                  ctage="$(jq -r --arg pat "issue-${cn}-" --argjson now "$now_s" \
                    '[ .items[]? | select((.metadata.name // "") | contains($pat))
                       | .status.containerStatuses[]?.state.terminated.finishedAt // empty
                       | fromdateiso8601? // empty ] | max as $m
                     | if $m == null then 999999999 else ($now - $m) end' <<<"$TPODS" 2>/dev/null || echo 0)"
                  case "$ctage" in ''|*[!0-9-]*) ctage=0;; esac
                  if [ "$ctage" -lt "$C4C5_PERSIST_S" ]; then
                    orphans="${orphans}[$repo] ⏳ phantom-label belt HELD — issue #${cn}: a worker pod for it went terminal $(( ctage / 60 ))m ago (< the ${C4C5_PERSIST_S}s guard — finalize may still be landing its PR)\n"
                    continue
                  fi
                  if [ "$(jq -r --argjson nn "$cn" '[.[] | select(test("#\($nn)\\b"))] | length' <<<"$c4c5_merged" 2>/dev/null || echo 1)" -gt 0 ]; then
                    orphans="${orphans}[$repo] ⛔ phantom-label belt HELD — issue #${cn} is mentioned by a MERGED PR: this may be finished work whose reference did not close it, not an abandoned ride. Re-queueing it would re-ride merged work — verify by hand (the c4c5-redispatch unit still carries it to the tick).\n"
                    continue
                  fi
                  # ⚠ ORDER IS LOAD-BEARING, and `gh issue edit --add-label X --remove-label Y` is
                  # NOT atomic: if the add fails while the remove lands, the issue holds no lifecycle
                  # label at all and goes invisible to EVERY clause. That is precisely how the
                  # 2026-08-08 hand-clear lost oracle#193 a second time. Add `agent/queued` FIRST,
                  # remove `agent/in-progress` SECOND, then RE-READ and prove the end state — the
                  # audit comment is posted only against a state we verified.
                  # The re-read runs on BOTH legs: a half-applied write is exactly the state that
                  # needs reporting ACCURATELY, and "the edit returned non-zero" says nothing about
                  # which of the two landed.
                  # ⚠ `set -euo pipefail` is on: a bare `A && B` whose result is non-zero is NOT in a
                  # condition context and would ABORT THE WHOLE SCAN mid-write — every later clause
                  # and every other repo in the stack silently starved by one failed label edit.
                  # (Caught in the fixture harness, exit 1 right after the failing edit.) The `if`
                  # and the `|| true` are what keep a refused write a REPORTED write.
                  cok=""
                  if gh issue edit "$cn" --repo "$slug" --add-label agent/queued >/dev/null 2>&1; then
                    gh issue edit "$cn" --repo "$slug" --remove-label agent/in-progress >/dev/null 2>&1 || true
                  fi
                  cend="$(gh issue view "$cn" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
                  case ",${cend}," in
                    *",agent/queued,"*) case ",${cend}," in *",agent/in-progress,"*) : ;; *) cok=1;; esac;;
                  esac
                  if [ -n "$cok" ]; then
                    gh issue comment "$cn" --repo "$slug" --body "$(printf '%s\n' \
                      "🤖 **Phantom \`agent/in-progress\` cleared — re-queued \`agent/queued\`** (deterministic scan belt, homelab#155)." \
                      "" \
                      "Audit, as of \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`:" \
                      "" \
                      "- **No worker pod.** \`kubectl -n ${repo} get pods -l app=agent-session,project=${repo} --field-selector=status.phase!=Succeeded,status.phase!=Failed\` returned nothing, and no \`agent-session\` pod named for this issue went terminal within the last $(( C4C5_PERSIST_S / 60 ))m." \
                      "- **No open PR** references \`#${cn}\` (every open PR body in \`${slug}\` was checked), and no merged PR mentions it either." \
                      "- **The state persisted.** The issue had been untouched for $(( cage / 60 ))m — past the $(( C4C5_PERSIST_S / 60 ))m guard, which is one full scan interval plus margin, so this is not a pod-transition race." \
                      "" \
                      "The label was starving more than this issue: it counted against the repo WIP ceiling and held every sibling whose \`Touches:\` intersect it (ADR-097). The cause of the missing finalize is agent-runtime#36; this belt only reconciles the state it left behind." \
                      "" \
                      "If a ride really is live, its pod is what proves it — the clause holds as soon as one is visible. Re-applying \`agent/in-progress\` by hand with no pod behind it will simply be cleared again after the guard window." )" >/dev/null 2>&1 || true
                    c4c5_cleared="${c4c5_cleared}${cn} "
                    orphans="${orphans}[$repo] ⚠ phantom \`agent/in-progress\` RECONCILED → \`agent/queued\`: issue #${cn} (no live pod, no open PR, state persisted $(( cage / 60 ))m — audit commented; homelab#155). Frees its ADR-097 footprint + a WIP slot; dispatch resumes on the next pass.\n"
                  else
                    orphans="${orphans}[$repo] ⛔ phantom-label reconcile FAILED or landed HALF-APPLIED on issue #${cn} — labels are now [${cend}]. Check by hand: with NEITHER label the issue is invisible to every clause; with BOTH it still holds its footprint. The issue keeps its c4c5-redispatch unit either way.\n"
                  fi
                done
              fi
            fi
            # >>>REPLAY:review-phantom-belt>>>
            # ── THE BELT (homelab#928): RECONCILE the phantom `agent/review` label ──────────────
            # A phantom `agent/review` is a terminal sink invisible to every scan class: the issue
            # holds `agent/review` but no open PR references it (the PR was closed/merged without
            # the label being cleaned up, or the review-flip belt flipped it and the PR was then
            # closed without merging). homelab#778 sat 18h56m in this state until a goal checkpoint
            # hand-corrected it — the stall held goal #775's flip criterion. IL-T16 reconciles the
            # identical phantom mode for `agent/in-progress`; this belt extends the same predicate
            # to `agent/review`, verbatim shape, restoring `agent/queued`.
            # Two holds before it writes, both fail-SAFE — an unreadable probe HOLDS, it never
            # clears (rule #6: never fail INTO a write):
            #   (c) PERSISTENCE. The issue must have been quiet (`updatedAt`) past C4C5_PERSIST_S
            #       to avoid racing with the review-flip belt or a PR that just landed.
            #   (d) NO MERGED PR mentions the issue. A PR merged with a NON-closing reference
            #       leaves exactly this state, and re-queueing it re-rides finished work (the
            #       FU-143 lesson, one lane over). A bare mention is enough to hold: holding costs a
            #       report line, guessing costs a duplicate ride.
            # Anything the belt HOLDS keeps today's behaviour exactly — reported, and the
            # merged-closeout unit (C6) still carries it. Anything it CLEARS becomes an ordinary
            # `agent/queued` item again and the normal dispatch path owns it on the next pass.
            review_phantom_cleared=""
            review_phantom_cands=""
            # review_only is queried above the C4/C5 clause (same as $inprog) and provided by the
            # bridge in replay. The jq validation is the same guard $inprog uses.
            jq -e . >/dev/null 2>&1 <<<"${review_only:-null}" || review_only='[]'
            # a human gate is never re-dispatched — agent/blocked and agent/error are never re-queued
            # by the belt (mirrors C4C5_SEL); a re-queue would hand a human-held issue back to dispatch
            [ -n "$dispatchable" ] && review_phantom_cands="$(printf '%s' "$review_only" \
              | jq -r --argjson bodies "$BODIES" --arg done "${c4c5_cleared:-}${infeas_done:-}" \
                '[.[] | (.labels|map(.name)) as $L
                       | select((($L|index("agent/error"))|not) and (($L|index("agent/blocked"))|not))
                       | (.number|tostring) as $n
                       | select((($done | split(" ") | map(select(. != ""))) | index($n)) | not)
                       | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
                       | "\($n)|\(.updatedAt // "")"] | .[]')"
            if [ -n "$review_phantom_cands" ]; then
              now_s="$(date -u +%s)"
              review_merged="$(gh pr list --repo "$slug" --state merged --limit 40 --json body --jq '[.[].body // ""]' 2>/dev/null)" || review_merged=""
              if ! jq -e . >/dev/null 2>&1 <<<"${review_merged:-null}"; then
                orphans="${orphans}[$repo] ⚠ PROBE_FAILED (merged PRs) — the agent/review phantom-label belt held every candidate this tick (rule #6)\n"
              else
                for cand in $review_phantom_cands; do
                  rcn="${cand%%|*}"; rcupd="${cand#*|}"
                  # jq parses the timestamps — same reader the pod janitor uses. An UNPARSEABLE
                  # stamp yields -1, which is < the window, so it holds.
                  rcage="$(jq -rn --arg t "$rcupd" --argjson now "$now_s" \
                    '($t | fromdateiso8601? // null) as $s | if $s == null then -1 else ($now - $s) end' 2>/dev/null || echo -1)"
                  case "$rcage" in ''|*[!0-9-]*) rcage=-1;; esac
                  if [ "$rcage" -lt "$C4C5_PERSIST_S" ]; then
                    orphans="${orphans}[$repo] ⏳ agent/review phantom-label belt HELD — issue #${rcn} was touched $(( rcage < 0 ? 0 : rcage / 60 ))m ago (< the ${C4C5_PERSIST_S}s transition-race guard, or an unreadable timestamp); re-checked next scan\n"
                    continue
                  fi
                  if [ "$(jq -r --argjson nn "$rcn" '[.[] | select(test("#\($nn)\\b"))] | length' <<<"$review_merged" 2>/dev/null || echo 1)" -gt 0 ]; then
                    orphans="${orphans}[$repo] ⛔ agent/review phantom-label belt HELD — issue #${rcn} is mentioned by a MERGED PR: this may be finished work whose reference did not close it, not an abandoned review. Re-queueing it would re-ride merged work — verify by hand.\n"
                    continue
                  fi
                  # ⚠ ORDER IS LOAD-BEARING, and `gh issue edit --add-label X --remove-label Y` is
                  # NOT atomic: if the add fails while the remove lands, the issue holds no lifecycle
                  # label at all and goes invisible to EVERY clause. Add `agent/queued` FIRST,
                  # remove `agent/review` SECOND, then RE-READ and prove the end state.
                  # ⚠ `set -euo pipefail` is on: a bare `A && B` whose result is non-zero is NOT in a
                  # condition context and would ABORT THE WHOLE SCAN mid-write. The `if` and the
                  # `|| true` are what keep a refused write a REPORTED write.
                  rok=""
                  if gh issue edit "$rcn" --repo "$slug" --add-label agent/queued >/dev/null 2>&1; then
                    gh issue edit "$rcn" --repo "$slug" --remove-label agent/review >/dev/null 2>&1 || true
                  fi
                  rend="$(gh issue view "$rcn" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
                  case ",${rend}," in
                    *",agent/queued,"*) case ",${rend}," in *",agent/review,"*) : ;; *) rok=1;; esac;;
                  esac
                  if [ -n "$rok" ]; then
                    gh issue comment "$rcn" --repo "$slug" --body "$(printf '%s\n' \
                      "🤖 **Phantom \`agent/review\` cleared — re-queued \`agent/queued\`** (deterministic scan belt, homelab#928)." \
                      "" \
                      "Audit, as of \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`:" \
                      "" \
                      "- **No open PR** references \`#${rcn}\` (every open PR body in \`${slug}\` was checked), and no merged PR mentions it either." \
                      "- **The state persisted.** The issue had been untouched for $(( rcage / 60 ))m — past the $(( C4C5_PERSIST_S / 60 ))m guard, which is one full scan interval plus margin, so this is not a review-flip race." \
                      "" \
                      "The label was a terminal sink invisible to every scan class: the issue held \`agent/review\` but no open PR existed to review. Re-queueing it as \`agent/queued\` makes it visible to dispatch again." \
                      "" \
                      "If a PR really is open, its body is what proves it — the clause holds as soon as one references the issue. Re-applying \`agent/review\` by hand with no PR behind it will simply be cleared again after the guard window." )" >/dev/null 2>&1 || true
                    review_phantom_cleared="${review_phantom_cleared}${rcn} "
                    orphans="${orphans}[$repo] ⚠ phantom \`agent/review\` RECONCILED → \`agent/queued\`: issue #${rcn} (no open PR, state persisted $(( rcage / 60 ))m — audit commented; homelab#928). Frees its ADR-097 footprint; dispatch resumes on the next pass.\n"
                  else
                    orphans="${orphans}[$repo] ⛔ agent/review phantom-label reconcile FAILED or landed HALF-APPLIED on issue #${rcn} — labels are now [${rend}]. Check by hand: with NEITHER label the issue is invisible to every clause; with BOTH it still holds its footprint.\n"
                  fi
                done
              fi
            fi
            # <<<REPLAY:review-phantom-belt<<<
            # >>>REPLAY:c4c5-derivations>>>
            v2="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" --arg db "${c6db_nums:-}" --arg sess "${sess_nums:-}" \
              --arg done "${c4c5_cleared:-}${infeas_done:-}" \
              "$C4C5_SEL"' | select((($done | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | "  issue #\($n) — \(.title) [in-progress, worker terminal, no PR → C4/C5 re-tick]"')"
            # The held goal children get their OWN report line — silence here is what let the first
            # one through. This is a REPORT, never a unit: a human/meta decides merged-vs-abandoned.
            # >>>REPLAY:c4c5-ambig-decidable>>>
            # FU-199: a goal child whose newest AGENT_STRIKE: comment carries a Resumable branch
            # pushed: <branch> line IS DECIDABLE — emit an ordinary C4/C5 unit carrying the branch
            # so the session resumes with --work-branch <branch> (never a restart). No strike / no
            # resumable branch ⇒ hold exactly as today. Loop guard: a resumed round that strikes
            # again with the same (model, error_class) pair follows the existing second-strike rule
            # (the agent/error STRIKE-channel path) — the narrowed hold must not create a
            # strike→resume→strike loop.
            ambig="$(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" --arg db "${c6db_nums:-}" --arg sess "${sess_nums:-}" \
              '.[] | select(((.labels|map(.name))|index("agent/error"))|not) | .number as $n
               | select((($cg | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select((($gb | split(" ") | map(select(. != ""))) | index(($n|tostring))))
               | select((($sess | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
               | select(([$bodies[] | select(test("#\($n)\\b"))] | length) == 0)
               | "  issue #\($n) — \(.title) [goal child, worker terminal, no open PR, and NO merged PR cites it — merged-but-unlinked or abandoned? C4/C5 HELD (FU-143 / agent-runtime#32). Verify against the goal branch, then close it or re-queue it by hand.]"')"
            # For each ambiguous issue, check if the newest AGENT_STRIKE: comment carries a
            # Resumable branch pushed: line — if so, the state IS DECIDABLE.
            ambig_decidable=""
            if [ -n "$ambig" ]; then
              while IFS= read -r ambig_line; do
                ambig_n="$(printf '%s' "$ambig_line" | sed -n 's/^  issue #\([0-9]\+\).*/\1/p')"
                [ -n "$ambig_n" ] || continue
                icmt="$(gh api "repos/${slug}/issues/${ambig_n}/comments?per_page=100" 2>/dev/null)" || icmt=""
                if jq -e 'type == "array"' >/dev/null 2>&1 <<<"${icmt:-null}"; then
                  # Find the NEWEST AGENT_STRIKE: comment (last in the array, which is
                  # oldest-first). Anchored at start-of-comment, never a substring — same
                  # discipline as AGENT_INFEASIBLE: (homelab#257).
                  strike="$(jq -r '[.[] | (.body // "") | select(test("^AGENT_STRIKE:"))] | last // ""' <<<"$icmt")"
                  if [ -n "$strike" ]; then
                    branch="$(jq -rn --arg s "$strike" '
                      $s | if test("Resumable branch pushed:") then
                        (split("\n")[] | select(test("Resumable branch pushed:"))
                         | sub(".*Resumable branch pushed:[ \t]*"; "") | .[0:200])
                      else "" end
                    ')"
                    if [ -n "$branch" ]; then
                      ambig_decidable="${ambig_decidable}${ambig_n} "
                      # repo-qualified key: issue numbers are only unique per repo
                      resumable_branches="${resumable_branches}${repo}#${ambig_n}=${branch} "
                    fi
                  fi
                fi
              done <<< "$ambig"
            fi
            # Rebuild ambig without the decidable issues
            if [ -n "$ambig_decidable" ]; then
              ambig_filtered=""
              while IFS= read -r ambig_line; do
                ambig_n="$(printf '%s' "$ambig_line" | sed -n 's/^  issue #\([0-9]\+\).*/\1/p')"
                case " $ambig_decidable " in *" $ambig_n "*) ;; *) ambig_filtered="${ambig_filtered}${ambig_line}\n";; esac
              done <<< "$ambig"
              ambig="$(printf '%b' "$ambig_filtered")"
            fi
            # <<<REPLAY:c4c5-ambig-decidable<<<
            if [ -n "$ambig" ]; then
              orphans="${orphans}[$repo] ⛔ goal child in an undecidable state — C4/C5 held rather than guessing:\n${ambig}\n"
              # Push the weak-link class for each ambiguous issue (#833, who=operator)
              while IFS= read -r ambig_line; do
                ambig_n="$(printf '%s' "$ambig_line" | sed -n 's/^  issue #\([0-9]\+\).*/\1/p')"
                [ -n "$ambig_n" ] && item_class_push "$repo" "issue-${ambig_n}" "strike-held" "operator"
              done <<< "$ambig"
            fi
            if [ -n "$dispatchable" ]; then
              # An issue the belt RE-QUEUED is deliberately excluded: it is a plain queued item now,
              # and emitting the unit too would race the queued lane onto the same issue. An issue
              # the INFEASIBLE terminal parked is excluded for the opposite reason — it is human-
              # gated, and the whole point of the marker is that this unit must never carry it.
              for u in $(printf '%s' "$inprog" | jq -r --argjson bodies "$BODIES" --arg cg "${c6g_nums:-}" --arg gb "${goalbased_nums:-}" --arg db "${c6db_nums:-}" --arg sess "${sess_nums:-}" \
                  --arg done "${c4c5_cleared:-}${infeas_done:-}" \
                  "$C4C5_SEL"' | select((($done | split(" ") | map(select(. != ""))) | index(($n|tostring))) | not)
                   | "\($n)|\([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/"))"'); do
                units="${units}c4c5-redispatch|${repo}|issue-${u%%|*}|${u#*|}\n"
                item_class_push "$repo" "issue-${u%%|*}" "phantom" "machine"
              done
            fi
            # Add resumable (decidable) goal children to dispatchable units — they were excluded
            # from the C4C5_SEL above by the goal-based filter, so they need their own loop.
            if [ -n "$ambig_decidable" ]; then
              for ad_n in $ambig_decidable; do
                ad_class="$(printf '%s' "$inprog" | jq -r --arg n "$ad_n" '
                  .[] | select(.number == ($n|tonumber))
                  | ([.labels[].name | select(startswith("task/"))] | first // "task/fix" | ltrimstr("task/"))
                ')"
                units="${units}c4c5-redispatch|${repo}|issue-${ad_n}|${ad_class}\n"
                item_class_push "$repo" "issue-${ad_n}" "phantom" "machine"
                orphans="${orphans}[$repo] ✓ issue #${ad_n} — AGENT_STRIKE + Resumable branch pushed → C4/C5 redispatch with --work-branch (FU-199)\n"
              done
            fi
            # <<<REPLAY:c4c5-derivations<<<
          else
            orphans="${orphans}[$repo] ⚠ PROBE_FAILED (open PRs) — the C4/C5 open-PR predicate was SKIPPED for this repo this tick; no belt write, no c4c5-redispatch (rule #6)\n"
          fi
          # <<<REPLAY:c4c5-bodies-probe<<<
        fi
      else
        echo "  [$repo] PROBE_FAILED reading worker pods — C4/C5 clause skipped this tick (fail-loud, rule #6)" >&2
      fi
    fi
    # ── THE BELT (homelab#1106): RECONCILE the phantom `agent/done` label ──────────────────────
    # A closed issue with a merged PR mentioning it, still labelled `agent/blocked` or
    # `agent/review` past C4C5_PERSIST_S, gets `agent/done`. This is bookkeeping on dead state:
    # the issue is already CLOSED, so a wrong flip costs a mislabeled closed issue, not a
    # duplicate ride. The merged-closeout clause (C6) is the primary path; this belt catches
    # cases where C6 was skipped (e.g. the issue was closed by keyword before C6 ran, or the
    # merged PR's reference was non-closing and the issue was closed by hand).
    #
    # Two holds before it writes, both fail-SAFE — an unreadable probe HOLDS, it never clears
    # (rule #6: never fail INTO a write):
    #   (c) PERSISTENCE. The issue must have been quiet (`updatedAt`) past C4C5_PERSIST_S
    #       to avoid racing with the merged-closeout clause.
    #   (d) A MERGED PR must mention the issue. Without a merged PR, the issue may have been
    #       closed for reasons unrelated to agent work — holding beats guessing.
    # Anything the belt HOLDS keeps today's behaviour exactly — reported, and the merged-closeout
    # unit (C6) still carries it. Anything it CLEARS becomes an ordinary `agent/done` issue.
    # >>>REPLAY:done-phantom-belt>>>
    done_phantom_cleared=""
    done_phantom_cands=""
    # Query CLOSED issues that still carry stale lifecycle labels. `gh issue list --state closed`
    # returns issues closed in the last ~30 days by default; the `--limit` bounds the window.
    # agent/error is excluded (human-first, never auto-relabel).
    done_closed="$(gh issue list --repo "$slug" --state closed --limit "$ISSUE_LIST_LIMIT" --json number,title,labels,updatedAt \
      --jq '[.[]|(.labels|map(.name)) as $L|select(($L|index("agent-fix")) and (($L|index("agent/blocked")) or ($L|index("agent/review"))) and (($L|index("agent/error"))|not))]' 2>/dev/null || echo '[]')"
    jq -e . >/dev/null 2>&1 <<<"${done_closed:-null}" || done_closed='[]'
    [ -n "$dispatchable" ] && done_phantom_cands="$(printf '%s' "$done_closed" \
      | jq -r --arg done "${done_phantom_cleared:-}" \
        '[.[] | (.labels|map(.name)) as $L
               | select((($L|index("agent/error"))|not) and (($L|index("agent/blocked")) or ($L|index("agent/review"))))
               | (.number|tostring) as $n
               | select((($done | split(" ") | map(select(. != ""))) | index($n)) | not)
               | "\($n)|\(.updatedAt // "")"] | .[]')"
    if [ -n "$done_phantom_cands" ]; then
      now_s="$(date -u +%s)"
      done_merged="$(gh pr list --repo "$slug" --state merged --limit 40 --json body --jq '[.[].body // ""]' 2>/dev/null)" || done_merged=""
      if ! jq -e . >/dev/null 2>&1 <<<"${done_merged:-null}"; then
        orphans="${orphans}[$repo] ⚠ PROBE_FAILED (merged PRs) — the agent/done phantom-label belt held every candidate this tick (rule #6)\n"
      else
        for cand in $done_phantom_cands; do
          dcn="${cand%%|*}"; dcupd="${cand#*|}"
          # jq parses the timestamps — same reader the pod janitor uses. An UNPARSEABLE
          # stamp yields -1, which is < the window, so it holds.
          dcage="$(jq -rn --arg t "$dcupd" --argjson now "$now_s" \
            '($t | fromdateiso8601? // null) as $s | if $s == null then -1 else ($now - $s) end' 2>/dev/null || echo -1)"
          case "$dcage" in ''|*[!0-9-]*) dcage=-1;; esac
          if [ "$dcage" -lt "$C4C5_PERSIST_S" ]; then
            orphans="${orphans}[$repo] ⏳ agent/done phantom-label belt HELD — issue #${dcn} was touched $(( dcage < 0 ? 0 : dcage / 60 ))m ago (< the ${C4C5_PERSIST_S}s transition-race guard, or an unreadable timestamp); re-checked next scan\n"
            continue
          fi
          # A merged PR must mention the issue — otherwise the close may be unrelated to agent work.
          if [ "$(jq -r --argjson nn "$dcn" '[.[] | select(test("#\($nn)\\b"))] | length' <<<"$done_merged" 2>/dev/null || echo 0)" -eq 0 ]; then
            orphans="${orphans}[$repo] ⏳ agent/done phantom-label belt HELD — issue #${dcn} is NOT mentioned by any merged PR: the close may be unrelated to agent work. Holding beats guessing.\n"
            continue
          fi
          # ⚠ ORDER IS LOAD-BEARING, and `gh issue edit --add-label X --remove-label Y` is
          # NOT atomic: if the add fails while the remove lands, the issue holds no lifecycle
          # label at all and goes invisible to EVERY clause. Add `agent/done` FIRST,
          # remove the stale label SECOND, then RE-READ and prove the end state.
          # ⚠ `set -euo pipefail` is on: a bare `A && B` whose result is non-zero is NOT in a
          # condition context and would ABORT THE WHOLE SCAN mid-write. The `if` and the
          # `|| true` are what keep a refused write a REPORTED write.
          # The jq filter already selected for agent/blocked or agent/review, so we know
          # one of them is present. Try removing both; the one that doesn't exist fails
          # harmlessly under `|| true`.
          dok=""
          if gh issue edit "$dcn" --repo "$slug" --add-label agent/done >/dev/null 2>&1; then
            gh issue edit "$dcn" --repo "$slug" --remove-label agent/blocked >/dev/null 2>&1 || true
            gh issue edit "$dcn" --repo "$slug" --remove-label agent/review >/dev/null 2>&1 || true
          fi
          dend="$(gh issue view "$dcn" --repo "$slug" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "PROBE_FAILED")"
          case ",${dend}," in
            *",agent/done,"*) case ",${dend}," in *",agent/blocked,"*|*",agent/review,"*) : ;; *) dok=1;; esac;;
          esac
          if [ -n "$dok" ]; then
            gh issue comment "$dcn" --repo "$slug" --body "$(printf '%s\n' \
              "🤖 **Stale label reconciled → \`agent/done\`** (deterministic scan belt, homelab#1106)." \
              "" \
              "Audit, as of \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`:" \
              "" \
              "- **Issue is CLOSED** and a merged PR mentions \`#${dcn}\`." \
              "- **The stale label persisted.** The issue had been untouched for $(( dcage / 60 ))m — past the $(( C4C5_PERSIST_S / 60 ))m guard." \
              "" \
              "The merged-closeout clause (C6) is the primary path for this transition; this belt catches cases where C6 was skipped. The issue is already closed, so this is bookkeeping on dead state — the label now reflects the merged terminal." \
              "" \
              "If the issue is genuinely not done (e.g. the merged PR was a partial fix), reopen it and re-apply the appropriate lifecycle label. Re-applying a stale label by hand on a closed issue will simply be cleared again after the guard window." )" >/dev/null 2>&1 || true
            done_phantom_cleared="${done_phantom_cleared}${dcn} "
            orphans="${orphans}[$repo] ⚠ stale label RECONCILED → \`agent/done\`: issue #${dcn} (closed, merged PR mentions it, state persisted $(( dcage / 60 ))m — audit commented; homelab#1106).\n"
          else
            orphans="${orphans}[$repo] ⛔ agent/done phantom-label reconcile FAILED or landed HALF-APPLIED on issue #${dcn} — labels are now [${dend}]. Check by hand.\n"
          fi
        done
      fi
    fi
    # <<<REPLAY:done-phantom-belt<<<
    # ── FLEET-STRIKE READER (FU-200, Goal #1231 acceptance 4) ─────────────────────────────────
    # A scan-side window count: same `error_class=` on ≥2 distinct issues inside 24h ⇒ apply
    # `agent/error` per affected item + ONE comment listing them + ONE deduped inert platform
    # filing per the brief's filing contract. Match on the structured `error_class=` field only,
    # never log excerpts. Forward-compatible with the G2 key-class split: the reader counts
    # strike-class rows only (AGENT_STRIKE: comments), never key-class rows.
    #
    # The scan already reads AGENT_STRIKE comments per issue for the C4/C5 chain-walk (the
    # ambig-decidable block). This clause extends that read to a CROSS-ISSUE window: same
    # error_class on ≥2 distinct issues inside 24h.
    #
    # DEDUP: before filing, check for an existing OPEN issue in the repo whose title starts
    # with "fleet-strike:" and whose body names the same error_class. If one exists, extend it
    # (add a comment listing the new affected issues) instead of creating a new filing.
    # >>>REPLAY:fleet-strike-reader>>>
    # Read all open issues with agent-fix label (already fetched as $openall). For each, fetch
    # comments and extract AGENT_STRIKE lines with error_class=. Group by error_class and check
    # for ≥2 distinct issues within 24h.
    fleet_strike_issues=""   # space-separated "error_class=issue_nums" pairs
    if [ -n "$dispatchable" ]; then
      # Get all agent-fix issues (not just queued/in-progress — strikes can be on any state)
      all_fix="$(printf '%s' "$openall" | jq -r '[.[]|(.labels|map(.name)) as $L|select($L|index("agent-fix"))|.number] | unique | .[]' 2>/dev/null || true)"
      if [ -n "$all_fix" ]; then
        # Fetch comments for each issue and extract AGENT_STRIKE error_class values.
        # Collect (error_class, issue_number) pairs, then group by error_class using jq.
        pairs=""
        for fn in $all_fix; do
          icmt="$(gh api "repos/${slug}/issues/${fn}/comments?per_page=100" 2>/dev/null)" || icmt=""
          if jq -e 'type == "array"' >/dev/null 2>&1 <<<"${icmt:-null}"; then
            # Extract error_class from AGENT_STRIKE comments. Anchored at start-of-comment,
            # same discipline as AGENT_INFEASIBLE: (homelab#257) and AGENT_STRIKE: (FU-199).
            # Match the structured `error_class=` field only, never log excerpts.
            classes="$(jq -r '[.[] | (.body // "") | select(test("^AGENT_STRIKE:")) | capture("error_class=(?<ec>[^ \\t\\n]+)") | .ec] | unique | .[]' <<<"$icmt" 2>/dev/null || true)"
            if [ -n "$classes" ]; then
              while IFS= read -r ec; do
                [ -n "$ec" ] || continue
                # FU-202 belt: key-class error_class values (budget-exhausted-key, budget-403-key)
                # are MINT defects, not worker strikes. New rides post KEY-RETRY: (not AGENT_STRIKE:)
                # so the ^AGENT_STRIKE: anchor already excludes them going forward. But the 24h
                # window can span the #1233 merge, and historical corpus records key-class as
                # AGENT_STRIKE:. Explicitly exclude them here so the fleet-strike reader never
                # counts a mint defect as a fleet strike.
                case "$ec" in
                  budget-exhausted-key|budget-403-key) continue;;
                esac
                pairs="${pairs}${ec}:${fn}\n"
              done <<< "$classes"
            fi
          fi
        done
        # Group by error_class using awk: collect comma-separated issue numbers per class
        strike_map="$(printf '%b' "$pairs" | awk -F: '
          { ec = $1; fn = $2 }
          { if (ec != "") { seen[ec] = seen[ec] ? seen[ec] "," fn : fn } }
          END { for (ec in seen) print ec "=" seen[ec] }
        ' 2>/dev/null || true)"
        # Check each error_class for ≥2 distinct issues
        if [ -n "$strike_map" ]; then
          while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            ec="${entry%%=*}"
            nums="${entry#*=}"
            # Count distinct issues
            count="$(printf '%s' "$nums" | tr ',' '\n' | sort -u | wc -l | tr -d ' ')"
            if [ "$count" -ge 2 ]; then
              # Check 24h window: fetch the newest AGENT_STRIKE comment's timestamp for each issue
              # and verify all are within 24h of each other
              now_s="$(date -u +%s)"
              timestamps=""
              all_within_24h=1
              for fn in $(printf '%s' "$nums" | tr ',' '\n' | sort -u); do
                [ -n "$fn" ] || continue
                icmt="$(gh api "repos/${slug}/issues/${fn}/comments?per_page=100" 2>/dev/null)" || icmt=""
                if jq -e 'type == "array"' >/dev/null 2>&1 <<<"${icmt:-null}"; then
                  # Find the newest AGENT_STRIKE: comment with this error_class
                  ts="$(jq -r --arg ec "$ec" '
                    [.[] | select((.body // "") | test("^AGENT_STRIKE:") and
                      contains("error_class=\($ec)"))
                     | .created_at] | last // ""
                  ' <<<"$icmt" 2>/dev/null || true)"
                  if [ -n "$ts" ]; then
                    ts_s="$(jq -rn --arg t "$ts" '($t | fromdateiso8601? // null) // -1' 2>/dev/null || echo -1)"
                    timestamps="${timestamps}${fn}=${ts_s}\n"
                  fi
                fi
              done
              # Check that all timestamps are within 86400s (24h) of each other
              if [ -n "$timestamps" ]; then
                min_ts="" max_ts=""
                while IFS= read -r ts_entry; do
                  [ -n "$ts_entry" ] || continue
                  ts_val="${ts_entry#*=}"
                  case "$ts_val" in ''|*[!0-9-]*) continue;; esac
                  if [ -z "$min_ts" ] || [ "$ts_val" -lt "$min_ts" ]; then min_ts="$ts_val"; fi
                  if [ -z "$max_ts" ] || [ "$ts_val" -gt "$max_ts" ]; then max_ts="$ts_val"; fi
                done <<< "$(printf '%b' "$timestamps")"
                if [ -n "$min_ts" ] && [ -n "$max_ts" ]; then
                  span="$(( max_ts - min_ts ))"
                  [ "$span" -le 86400 ] || all_within_24h=0
                  # The window must also be LIVE, not merely historical: the NEWEST strike in the
                  # group has to fall inside 24h of now. Without this, `max_ts - min_ts` is
                  # immutable historical data and a group that once clustered stays "detected"
                  # on every future tick forever.
                  [ "$(( now_s - max_ts ))" -le 86400 ] || all_within_24h=0
                  fi
              fi
              if [ "$all_within_24h" = 1 ]; then
                fleet_strike_issues="${fleet_strike_issues}${ec}=${nums} "
                orphans="${orphans}[$repo] ⚠ FLEET STRIKE: error_class=${ec} on issues $(printf '%s' "$nums" | tr ',' '\n' | sed 's/^/#/' | tr '\n' ' ' | sed 's/ $//') — applying agent/error, commenting, filing\n"
              fi
            fi
          done <<< "$strike_map"
        fi
      fi
    fi
    # Apply actions for each fleet strike
    if [ -n "$fleet_strike_issues" ]; then
      for fs_entry in $fleet_strike_issues; do
        ec="${fs_entry%%=*}"
        nums="${fs_entry#*=}"
        # Dedup: check for an existing OPEN issue titled "fleet-strike: error_class=<ec>"
        existing_filing="$(gh issue list --repo "$slug" --state open --limit 50 --json number,title \
          --jq "[.[] | select(.title | startswith(\"fleet-strike: error_class=${ec}\"))] | first | .number // \"\"" 2>/dev/null || true)"
        case "$existing_filing" in ''|*[!0-9]*) existing_filing="";; esac
        # Apply agent/error to each affected issue
        for fn in $(printf '%s' "$nums" | tr ',' '\n' | sort -u); do
          [ -n "$fn" ] || continue
          # Check if already has agent/error
          has_error="$(printf '%s' "$openall" | jq -r --argjson n "$fn" \
            '[.[] | select(.number == $n) | (.labels|map(.name)) | index("agent/error")] | first // false' 2>/dev/null || false)"
          if [ "$has_error" = "false" ]; then
            gh issue edit "$fn" --repo "$slug" --add-label agent/error >/dev/null 2>&1 || true
          fi
        done
        # ONE comment listing all affected issues
        affected_list=""
        sorted_nums="$(printf '%s' "$nums" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')"
        for fn in $(printf '%s' "$nums" | tr ',' '\n' | sort -u); do
          [ -n "$fn" ] || continue
          affected_list="${affected_list}- #${fn}\n"
        done
        # Marker-based idempotency: the first line of the comment is a machine marker carrying
        # the group identity. A repeat tick against an already-actioned fleet strike finds the
        # identical marker and skips the post (same discipline as state-fp:, homelab#244/IL-T26).
        fleet_strike_marker="fleet-strike-fp: error_class=${ec} issues=${sorted_nums}"
        comment_body="$(printf '%s\n' \
          "${fleet_strike_marker}" \
          "" \
          "🤖 **Fleet strike detected** — \`error_class=${ec}\` on ≥2 distinct issues within 24h (FU-200)." \
          "" \
          "Affected issues:" \
          "$(printf '%b' "$affected_list")" \
          "Each has been labelled \`agent/error\` (human-first, report-only)." \
          "" \
          "**What this means.** The same error class appeared across multiple independent rides. This is a platform-level pattern, not an isolated worker fault — a human should investigate the root cause before any of these issues are re-dispatched." \
          "" \
          "Audit, as of \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`:" \
          "" \
          "- \`error_class=${ec}\` on $(printf '%s' "$nums" | tr ',' '\n' | sort -u | wc -l | tr -d ' ') distinct issues." \
          "- All within a 24h window." \
          "" \
          "To re-enable dispatch on any issue, strip \`agent/error\` by hand after the root cause is resolved." )"
        # Post the comment on the FIRST affected issue only (ONE comment listing them)
        first_fn="$(printf '%s' "$nums" | tr ',' '\n' | sort -u | head -1)"
        if [ -n "$first_fn" ]; then
          # Idempotency check: skip if a comment already starts with the identical marker
          existing_comments="$(gh api "repos/${slug}/issues/${first_fn}/comments?per_page=100" 2>/dev/null || true)"
          already_posted=0
          if jq -e 'type == "array"' >/dev/null 2>&1 <<<"${existing_comments:-null}"; then
            if jq -e --arg m "$fleet_strike_marker" \
              '[.[] | (.body // "") | startswith($m)] | any' \
              <<<"$existing_comments" >/dev/null 2>&1; then
              already_posted=1
            fi
          fi
          if [ "$already_posted" = 0 ]; then
            gh issue comment "$first_fn" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 || true
          fi
        fi
        # ONE deduped inert platform filing
        if [ -n "$existing_filing" ]; then
          # Idempotency check: skip if the filing already has a comment with the identical marker
          filing_comments="$(gh api "repos/${slug}/issues/${existing_filing}/comments?per_page=100" 2>/dev/null || true)"
          filing_already_extended=0
          if jq -e 'type == "array"' >/dev/null 2>&1 <<<"${filing_comments:-null}"; then
            if jq -e --arg m "$fleet_strike_marker" \
              '[.[] | (.body // "") | startswith($m)] | any' \
              <<<"$filing_comments" >/dev/null 2>&1; then
              filing_already_extended=1
            fi
          fi
          if [ "$filing_already_extended" = 0 ]; then
            # Extend the existing filing with a comment
            gh issue comment "$existing_filing" --repo "$slug" --body "$(printf '%s\n' \
              "${fleet_strike_marker}" \
              "" \
              "Additional affected issues detected: $(printf '%s' "$nums" | tr ',' '\n' | sort -u | tr '\n' ' ')" \
              "" \
              "Updated \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`." )" >/dev/null 2>&1 || true
          fi
        else
          # Create a new inert platform filing
          gh issue create --repo "$slug" \
            --title "fleet-strike: error_class=${ec}" \
            --label "agent-fix" \
            --body "$(printf '%s\n' \
              "🤖 **Fleet strike filing** — inert platform issue (FU-200)." \
              "" \
              "**error_class:** \`${ec}\`" \
              "" \
              "**Affected issues:** $(printf '%s' "$nums" | tr ',' '\n' | sort -u | tr '\n' ' ')" \
              "" \
              "**Detected at:** \`$(date -u +%Y-%m-%dT%H:%M:%SZ)\`" \
              "" \
              "This is a DEDUPED filing: one per error_class per 24h window. The affected issues carry \`agent/error\` and are human-first, report-only until the root cause is resolved." \
              "" \
              "**What to do.** Investigate the platform-level pattern behind \`${ec}\`. Each affected issue's ride transcript is in \`s3://agent-transcripts/\`. Once the root cause is fixed, strip \`agent/error\` from each affected issue to re-enable dispatch." )" >/dev/null 2>&1 || true
        fi
      done
    fi
    # <<<REPLAY:fleet-strike-reader<<<
    # arbitrate (FU-086 / MP-G04, built 2026-07-27): the review reflex labels a rounds-exhausted
    # PR `agent/arbitrate` (escalation, NOT anomaly — agent/error stays for impossible states).
    # The coordinator is the designed tie-breaker: one unit per labeled PR; the item session
    # rules per the escalation table (brief §arbitrate).
    # ⚠ The label is STICKY on two of the four rulings (escalate keeps it deliberately; a human is
    # the next mover), so selecting on the label ALONE re-emits the unit every scan forever — the
    # PR#234 churn. The unit is emitted only when the state a ride would read has MOVED since the
    # last arbitrate dispatch (homelab#198, fingerprint helper at the top of this file); unchanged
    # state is a REPORT line, which is what an escalation waiting on a human should look like.
    # >>>REPLAY:arbitrate-gate>>>
    for u in $(printf '%s' "$prsjson" | jq -r '.[]|(.labels|map(.name)) as $L|select((($L|index("agent/error"))|not) and ($L|index("agent/arbitrate")) and ((.autoMergeRequest==null) or (.reviewDecision!="APPROVED")))|.number'); do
      # blocked-on predicate (homelab#1188): if a terminal ruling recorded a blocker and it is
      # still unresolved, report instead of dispatch — the same report-vs-dispatch shape the
      # state-fp debounce already has.
      # Fetch ONCE and share between pr_blocked_on_check and pr_state_fp_pair (homelab#1211).
      pr_json_ab="$(gh pr view "$u" --repo "$slug" \
          --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments,commits 2>/dev/null)" || pr_json_ab=''
      boc="$(pr_blocked_on_check "$slug" "$u" "$pr_json_ab")"
      case "$boc" in
        blocked|blocked\|*)
          orphans="${orphans}[$repo] ⏳ arbitrate BLOCKED-ON — PR #${u}: a terminal ruling recorded \`blocked-on: ${boc#blocked|}\` and the blocker is still unresolved (homelab#1188). No ride is spent to re-derive the same answer.\n"
          continue
          ;;
      esac
      afp="$(pr_state_fp_pair "$slug" "$u" arbitrate "$pr_json_ab")"; afp_prev="${afp#*|}"; afp_cur="${afp%%|*}"
      if [ -n "$afp_cur" ] && [ "$afp_cur" = "$afp_prev" ]; then
        # FU-199: a completed no-op round (stats marker) newer than the newest state-fp marker
        # re-arms the gate — the fingerprint didn't change (STATE_FP_JQ_ARBITRATE drops stats),
        # but a round completed, so the state has effectively changed. The brief's "a second
        # consecutive no-op is a terminal-ride finding → escalate" must be able to fire.
        # Inline stats_ts jq (same shape as STATS_TS_DEF in the round-evidence block) so this
        # check works in extracted replay blocks that do not carry that variable.
        afp_marker_ts="$(printf '%s' "$pr_json_ab" | jq -r '[.comments[]? | select((.body // "") | test("state-fp:(?:[a-z-]+:)?[0-9a-f]{6,64}"))] | sort_by(.createdAt) | last | .createdAt // ""' 2>/dev/null)" || afp_marker_ts=''
        afp_stats_ts="$(printf '%s' "$pr_json_ab" | jq -r '
          def stats_ts: [ .comments[]? | (.body // "") as $b
            | if ($b | startswith("<!-- agent-summary -->"))
              then [ $b | scan("<!-- agent-event kind=stats ts=([^ ]+) -->")[0] ]
              elif ($b | test("Agent run stats")) then [ .createdAt ]
              else [] end | .[] ];
          stats_ts | max // ""' 2>/dev/null)" || afp_stats_ts=''
        if [ -n "$afp_marker_ts" ] && [ -n "$afp_stats_ts" ] && [[ "$afp_stats_ts" > "$afp_marker_ts" ]] 2>/dev/null; then
          # A round completed since the marker — re-arm the gate (don't debounce)
          :
        else
          # No round completed since the marker — debounce holds, but report as who=operator
          # so the board shows it (FU-199)
          orphans="${orphans}[$repo] ⏳ arbitrate DEBOUNCED — PR #${u}: head, checks, reviewDecision and newest verdict are all unchanged since the last arbitrate dispatch (\`state-fp:arbitrate:${afp_cur}\`, homelab#198). The escalation STANDS and the ruling on the thread is still the current one — a human (or new content) is the next mover, so no ride is spent to re-derive it.\n"
          item_class_push "$repo" "pr-${u}" "arbitrate-standing" "operator"
          continue
        fi
      fi
      units="${units}arbitrate|${repo}|pr-${u}\n"
      item_class_push "$repo" "pr-${u}" "arbitrate-standing" "operator"
    done
    # <<<REPLAY:arbitrate-gate<<<

    # ci-red (FU-115 / MP-T12, CONTENT-BASED rewrite of the old ci-red-stale time-gate): an ARMED
    # red PR is invisible to the whole merge path (updater + reviewer both skip red). The OLD trigger
    # was "quiet > RED_STALE_HOURS(4h)" — a coarse LAST-ACTIVITY timer that a no-op fix round's OWN
    # run-stats comment reset, giving a 4h-spaced LIVELOCK with no exhaustion→escalation (the red
    # loop lacked the review loop's ROUNDS_MAX→arbitrate). NOW keyed on CONTENT + a cap, symmetric
    # with the review path (MP-T11), and woken near-instant by the exporter's red edge (github-exporter
    # maybe_dispatch_cired → /coordinate) instead of only the poll. Per red PR we read the fix-round
    # history from the durable run-stats evidence in EITHER channel (`stats_ts`, §ROUND EVIDENCE,
    # TWO CHANNELS) plus `headRefOid` (NOT from `🔴 ci-red round` markers — those were a design
    # that never shipped; stale prose caught by the #198 ride):
    #   attempts==0                    → DISPATCH (first red)
    #   attempts>=RED_ROUNDS_MAX(3)     → ARBITRATE (exhausted — MP-T11 tie-break). The count is
    #                                    keyed on the ISSUE, summed across every PR that references
    #                                    it (homelab#156) — per-PR is only the fast path, because
    #                                    close-and-re-PR would otherwise hand out a fresh budget.
    #   head8 != last dispatched head  → DISPATCH (a round pushed new-but-still-red content; re-attempt)
    #   else (same head, round done)   → ARBITRATE (NO-OP round: the worker produced nothing → escalate,
    #                                    never re-dispatch the same input — this is the anti-livelock)
    # Guarded probe: statusCheckRollup needs checks:read; a 403/bad read SKIPS loudly (rule #6). Held
    # while a worker Runs (the fix round owns it). Dispatch cap 2/repo/scan; arbitrate is uncapped
    # (labeling is cheap + idempotent).
    # `body` rides this list for the FU-146 per-item hold below — without it the hold's issue-link
    # capture is always empty and the hold silently never fires (fail-safe, but useless).
    red_probe="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json number,labels,author,autoMergeRequest,headRefOid,headRefName,statusCheckRollup,body 2>/dev/null)" || red_probe=''
    if [ -n "$red_probe" ] && jq -e . >/dev/null 2>&1 <<<"${red_probe:-null}"; then
      # MANDATE check (homelab#88, sleep-tracking#113 livelock 2026-08-03): red CI on a PR the
      # loop did NOT author is the author's to fix — the scan kept dispatching sessions at a
      # human's armed+red PR every tick until the coordinator breaker-labeled it. Same author
      # predicate as the changes-requested clause; out-of-mandate armed+red stays VISIBLE as a
      # report-only line (a human wants to know their armed PR is stuck red), never a unit.
      red_foreign="$(printf '%s' "$red_probe" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '
          .[]|select(.author.login != $wa)
          | select(.autoMergeRequest != null)
          | select([.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")] | length > 0)
          | "  PR #\(.number) (author \(.author.login))"')"
      [ -n "$red_foreign" ] && orphans="${orphans}[$repo] ⚠ armed+red but NOT loop-authored (mandate: author fixes; no dispatch):\n${red_foreign}\n"
      red_n=0
      for u in $(printf '%s' "$red_probe" | jq -r --arg wa "${WORKER_AUTHOR:-app/homelab-agents-1234}" '
          .[]|(.labels|map(.name)) as $L
          | select(.author.login == $wa)
          | select((($L|index("agent/error"))|not) and (($L|index("agent/arbitrate"))|not)
                   and (($L|index("major"))|not) and (($L|index("major/awaiting-human"))|not))
          | select(.autoMergeRequest != null)
          | select([.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT")] | length > 0)
          | .number'); do
        # FU-146 PER-ITEM hold, ported here 2026-08-07 — the THIRD clause to need it (main scan
        # path `fc606e2`, doorbell fast path `277a73f`, now this one). The comment above claims
        # "Held while a worker Runs (the fix round owns it)", but `wip_busy` is the PROJECT-wide
        # cap: at ADR-097's REPO_MAX_WIP=3 it stays empty while ONE worker rides, so the clause
        # re-emitted the same unit every tick. Live 2026-08-07: tick `q66s7` dispatched pr-50 at
        # wip 2 while `agent-circles-issue-19-r3` had ridden 6 minutes, and each session correctly
        # exited clean — waste, on a subscription the loop needs for real dispatch.
        # Same predicate and fail-safes as the other two: no issue link or no pod probe → falls
        # through unchanged (can only ADD holds), and the hold needs a LIVE pod so it self-releases.
        red_issue="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|(.body // "")
            | (capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i) // ""' 2>/dev/null)" || red_issue=""
        if [ -n "$red_issue" ] && [ -n "$WIPPODS_JSON" ] \
           && printf '%s' "${WIPPODS_JSON:-null}" | jq -e --arg pat "issue-${red_issue}-" \
                '[.items[]? | select((.metadata.name // "") | contains($pat))] | length > 0' >/dev/null 2>&1; then
          orphans="${orphans}[$repo] ⏳ ci-red held — a worker is already riding issue #${red_issue} (FU-146 per-item):\n  PR #${u}\n"
          continue
        fi
        # FU-146 session-currency (the #153 storm, leg (a) for the ci-red lane): same self-releasing shape.
        if sess_holds "issue-${red_issue}"; then
          orphans="${orphans}[$repo] ⏳ ci-red held (item session in flight) — a coordinator session is riding issue #${red_issue} (FU-146):\n  PR #${u}\n"
          continue
        fi
        # BLOCKED-SOURCE hold (2026-08-07) — same as the changes-requested clause's, same
        # fail-safes; this clause is where the churn was actually measured (circles PR#58).
        if [ -n "$red_issue" ] \
           && printf '%s' "${openall:-null}" | jq -e --argjson n "$red_issue" \
                '[.[] | select(.number == $n) | .labels[].name] | index("agent/blocked") != null' >/dev/null 2>&1; then
          orphans="${orphans}[$repo] ⏳ ci-red held — source issue #${red_issue} is agent/blocked (human-gated):\n  PR #${u}\n"
          continue
        fi
        if [ -n "$wip_busy" ]; then
          orphans="${orphans}[$repo] ⏳ ci-red held (project WIP at ${REPO_MAX_WIP} in ${repo}):\n  PR #${u}\n"
          continue
        fi
        head8="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefOid[0:8]')"
        u_head="$(printf '%s' "$red_probe" | jq -r --argjson n "$u" '.[]|select(.number==$n)|.headRefName // ""')"
        # >>>REPLAY:ci-red-goal-head-exclusion>>>
        # FU-143: an ASSEMBLY PR (head goal/**) with ci-red is EXCLUDED — a fix round
        # pushes to the PR head, and the head IS the protected goal/** integration branch
        # (the push would be refused; the mandate is a NEW child on the goal — coordinator
        # README goal-checkpoint play). Report-only line below so it never rots silently.
        if [[ "$u_head" == goal/* ]]; then
          orphans="${orphans}[$repo] ⚠ ASSEMBLY PR #${u} has ci-red (FU-143) — route as a NEW child on the goal; a fix round cannot push to the protected goal/** head\n"
          continue
        fi
        # <<<REPLAY:ci-red-goal-head-exclusion<<<
        # attempts = durable count of completed fix rounds on THIS PR — the fast path under the
        # issue-keyed ceiling below, and still what the no-op detector needs. Restart-safe: it reads
        # GitHub, never launcher memory. Bounds the loop: a no-op round costs at most
        # RED_ROUNDS_MAX attempts before it escalates, never the old infinite 4h-spaced livelock.
        # (Immediate no-op detection — same head across a completed round → arbitrate NOW — is the
        # FU-115(b) refinement below; the cap is the v1 bound.)
        # ⚠ `stats_ts` — NOT a comment count. One round stopped meaning one comment when ADR-103
        # moved the table onto the check-run + the appended summary line; the def at the top of this
        # file reads both channels, and every round-counting site in here goes through it. See the
        # §ROUND EVIDENCE, TWO CHANNELS block.
        # >>>REPLAY:ci-red-rounds>>>
        round_probe="$(gh pr view "$u" --repo "$slug" --json comments,commits 2>/dev/null)" || round_probe=''
        attempts="$(printf '%s' "$round_probe" | jq -r "${STATS_TS_DEF}"'stats_ts | length' 2>/dev/null)" || attempts=0
        case "$attempts" in ''|*[!0-9]*) attempts=0;; esac
        # FU-115(b) immediate no-op detection (built 2026-08-02, marker-free): if the NEWEST
        # stats comment post-dates the newest NON-MERGE commit, the last completed round pushed
        # nothing — same head, still red → arbitrate NOW instead of burning the remaining cap.
        # Merge commits excluded (the updater's BEHIND merges are not round output — the
        # nine-review-loop lesson). ISO-8601 strings compare correctly as strings.
        noop_round=""
        if [ "$attempts" -ge 1 ]; then
          noop_round="$(printf '%s' "$round_probe" | jq -r "$NOOP_ROUND_JQ" 2>/dev/null)" || noop_round=""
        fi
        RED_MAX="${RED_ROUNDS_MAX:-3}"
        # ISSUE-KEYED ROUNDS CEILING (homelab#156, FU-154). `attempts` above is PER-PR, and PR
        # identity is not the unit of the work: close-and-re-PR is a DESIGNED play as of 2026-08-08
        # (#210 re-landed as #221, #214 closed and its issue re-queued, #209 superseded by #218-v2),
        # so every re-creation handed the loop a fresh RED_MAX budget — circles#19 burned five rounds
        # across PR#50 (2) + a fresh #51 (1) plus earlier ones and never hit the cap. The ISSUE is the
        # stable key: sum the SAME run-stats evidence across every PR in this repo whose branch or
        # body references that issue id. Per-PR stays the FAST PATH (no extra API call when it already
        # trips); the issue-keyed sum is the CEILING and can only RAISE the count, never lower it.
        # FAIL-OPEN, matching this clause's guarded-probe posture: an unreadable list warns and leaves
        # the per-PR count standing — the window is the newest 100 PRs, so a miss only UNDER-counts.
        # ⚠ The sibling-match rule (branch `issue-<n>-`, else body closing keyword `#<n>`, both boundary-anchored) is
        # duplicated in review-reflex.sh's issue-keyed verdict ceiling. Change both or neither.
        # The key falls back to the fix/issue-<n>- branch convention when the body carries no closing
        # keyword; `red_issue` above stays body-only on purpose (it gates the per-item holds).
        red_key="$red_issue"
        if [ -z "$red_key" ]; then
          red_key="$(printf '%s' "$u_head" | sed -n 's/.*issue-\([0-9][0-9]*\)\(-.*\)\{0,1\}$/\1/p')"
        fi
        red_rounds="$attempts"; red_rounds_key="PR #${u}"
        if [ "$attempts" -lt "$RED_MAX" ] && [ -n "$red_key" ]; then
          if red_sib="$(gh pr list --repo "$slug" --state all --limit 100 \
                          --json number,headRefName,body,comments 2>/dev/null)"; then
            red_sum="$(printf '%s' "$red_sib" | jq -r --arg n "$red_key" "${STATS_TS_DEF}"'
              def refs($n): ((.headRefName // "") | test("(^|[^0-9])issue-" + $n + "(-|$)"))
                            or ((.body // "") | test("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#" + $n + "([^0-9]|$)"));
              [ .[] | select(refs($n)) ]
              | "\(length) \([ .[] | stats_ts[] ] | length)"
            ' 2>/dev/null)" || red_sum=""
            read -r red_sib_prs red_sib_n <<<"${red_sum:-}"
            case "${red_sib_n:-}" in ''|*[!0-9]*) red_sib_n=""; echo "  [$repo] WARN: issue-keyed round sum unreadable for issue #${red_key} — per-PR count stands for PR #${u}" >&2;; esac
            if [ -n "$red_sib_n" ] && [ "$red_sib_n" -gt "$red_rounds" ]; then
              red_rounds="$red_sib_n"; red_rounds_key="issue #${red_key} (${red_sib_prs} PRs)"
            fi
          else
            echo "  [$repo] WARN: issue-keyed round probe FAILED (gh pr list --state all) — per-PR count stands for PR #${u}" >&2
          fi
        fi
        # <<<REPLAY:ci-red-rounds<<<
        if [ -n "$noop_round" ]; then
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red no-op round, FU-115b): the last completed fix round left the head unchanged at ${head8} and CI is still red — dispatching more identical rounds cannot converge. The coordinator's arbitrate unit rules per the escalation table." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red NO-OP round → agent/arbitrate NOW: PR #${u} (round ${attempts} pushed nothing, still red @ ${head8})\n" \
            || orphans="${orphans}[$repo] ⚠ ci-red no-op arbitrate FAILED to label PR #${u} — human check\n"
        elif [ "$red_rounds" -lt "$RED_MAX" ]; then
          # CURRENCY (homelab#198) — the EXTENSION of this clause's existing content key, not a
          # second mechanism beside it. The markers above answer "did a round complete, and did it
          # push?"; they say nothing when a dispatched round never RAN (pod never started, session
          # died pre-finalize, the /coordinate doorbell re-rang on the same red edge): no stats
          # comment, so `attempts` never moves, no new commit, so `head8` never moves, and the
          # clause re-dispatches the identical input every scan. The fingerprint covers that hole
          # from the other side — the state a fix round would READ. Checked here, inside the
          # dispatch branch only: the no-op→arbitrate leg above must stay level-triggered (it is
          # the anti-livelock), and `continue` before the cap so a debounced PR never spends one of
          # the two dispatch slots a live red PR could use.
          # >>>REPLAY:ci-red-gate>>>
          # blocked-on predicate (homelab#1188): if a terminal ruling recorded a blocker and it is
          # still unresolved, report instead of dispatch.
          # Fetch ONCE and share between pr_blocked_on_check and pr_state_fp_pair (homelab#1211).
          pr_json_cr="$(gh pr view "$u" --repo "$slug" \
              --json headRefOid,reviewDecision,statusCheckRollup,reviews,comments,commits 2>/dev/null)" || pr_json_cr=''
          boc="$(pr_blocked_on_check "$slug" "$u" "$pr_json_cr")"
          case "$boc" in
            blocked|blocked\|*)
              orphans="${orphans}[$repo] ⏳ ci-red BLOCKED-ON — PR #${u}: a terminal ruling recorded \`blocked-on: ${boc#blocked|}\` and the blocker is still unresolved (homelab#1188). No ride is spent to re-derive the same answer.\n"
              continue
              ;;
          esac
          rfp="$(pr_state_fp_pair "$slug" "$u" ci-red "$pr_json_cr")"; rfp_prev="${rfp#*|}"; rfp_cur="${rfp%%|*}"
          if [ -n "$rfp_cur" ] && [ "$rfp_cur" = "$rfp_prev" ]; then
            # FU-199: a launcher pre-flight deferral must not leave the marker armed.
            # If no round completed (no stats comment) since the marker was written,
            # the marker is stale — re-arm the gate so the clause re-evaluates.
            # Inline stats_ts jq (same shape as STATS_TS_DEF in the round-evidence block) so this
            # check works in extracted replay blocks that do not carry that variable.
            rfp_marker_ts="$(printf '%s' "$pr_json_cr" | jq -r '[.comments[]? | select((.body // "") | test("state-fp:(?:[a-z-]+:)?[0-9a-f]{6,64}"))] | sort_by(.createdAt) | last | .createdAt // ""' 2>/dev/null)" || rfp_marker_ts=''
            rfp_stats_ts="$(printf '%s' "$pr_json_cr" | jq -r '
              def stats_ts: [ .comments[]? | (.body // "") as $b
                | if ($b | startswith("<!-- agent-summary -->"))
                  then [ $b | scan("<!-- agent-event kind=stats ts=([^ ]+) -->")[0] ]
                  elif ($b | test("Agent run stats")) then [ .createdAt ]
                  else [] end | .[] ];
              stats_ts | max // ""' 2>/dev/null)" || rfp_stats_ts=''
            if [ -n "$rfp_marker_ts" ] && [ -n "$rfp_stats_ts" ] && [[ "$rfp_stats_ts" > "$rfp_marker_ts" ]] 2>/dev/null; then
              # A round completed since the marker — debounce holds normally
              orphans="${orphans}[$repo] ⏳ ci-red DEBOUNCED — PR #${u}: still red at ${head8} with head, checks, reviewDecision and newest verdict all unchanged since the last ci-red dispatch (\`state-fp:ci-red:${rfp_cur}\`, homelab#198). A round was already dispatched at this exact input; re-dispatching it cannot read anything new. If no round ever completed here, the ride went terminal — that is the finding, not more dispatches.\n"
              continue
            fi
            # No round completed since the marker — re-arm the gate (don't debounce).
            # The marker is stale; fall through to re-evaluate dispatch.
          fi
          # <<<REPLAY:ci-red-gate<<<
          # DISPATCH a fix round (under the attempt cap — the ISSUE-keyed one, see above)
          if [ "$red_n" -lt 2 ]; then
            # FU-106 (c): a RED deploy/* bump PR in an -iac repo is the typed infra-delta — the
            # infra-enrich class (diff values.schema.json, enrich the bump PR), not the generic play.
            case "$repo:$u_head" in
              *-iac:deploy/*) units="${units}infra-enrich|${repo}|pr-${u}\n"; rclause="infra-enrich";;
              *)              units="${units}ci-red|${repo}|pr-${u}\n"; rclause="ci-red";;
            esac
            # units-only clauses were invisible to the `[ -z "$items" ]` gate (the meta-14 stall) —
            # every dispatchable unit MUST also add an items line.
            items="${items}[$repo] PR #${u} — ${rclause} (CI red, armed; attempt $((red_rounds+1))/${RED_MAX} on ${red_rounds_key} @ ${head8})\n"
            item_class_push "$repo" "pr-${u}" "riding" "machine"
            red_n=$((red_n+1))
          fi
        else
          # ARBITRATE: red rounds EXHAUSTED. Reuse the review path's MP-T11 machinery — label
          # agent/arbitrate + comment; the arbitrate scan clause + coordinator tie-break (re-dispatch
          # a stronger model / park / close) take over. This is the Red→arbitrate edge the FSM lacked.
          gh pr edit "$u" --repo "$slug" --add-label agent/arbitrate >/dev/null 2>&1 \
            && gh pr comment "$u" --repo "$slug" --body "ARBITRATE (ci-red, FU-115): ${red_rounds} fix rounds counted on ${red_rounds_key} and CI still red at ${head8} (cap ${RED_MAX}). Rounds are counted against the ISSUE, not the PR (homelab#156), so closing this PR and opening a fresh one does not restore the budget. The CI-red fix-round loop is not converging on its own — review automation now skips it; the coordinator's arbitrate unit rules per the escalation table (re-dispatch with a stronger model / close as not-mergeable / escalate to a human)." >/dev/null 2>&1 \
            && orphans="${orphans}[$repo] ⚠ ci-red → agent/arbitrate: PR #${u} (${red_rounds} rounds on ${red_rounds_key}, still red — exhausted)\n" \
            || orphans="${orphans}[$repo] ⚠ ci-red arbitrate FAILED to label PR #${u} (gh write refused?) — human check\n"
        fi
      done
    else
      echo "  [$repo] PROBE_FAILED reading check rollups — ci-red clause skipped this tick (needs checks:read; fail-loud rule #6)" >&2
    fi

    # >>>REPLAY:merged-closeout>>>
    # C6 merged-closeout (FU-090a / MP-G03, built 2026-07-27): an issue CLOSED by its merged PR
    # but still carrying a non-terminal `agent/*` state is a loop nobody closed — outcome
    # unverified, label stale, and the merged PR's review `Follow-ups:` bullets die in the comment.
    # BOTH pre-merge states qualify: `agent/in-progress` (auto-merge outran the review-flip) AND
    # `agent/review` (the happy-path pre-merge state per merge-path-fsm.md MP-T10 — nothing else
    # flips it to agent/done; #46/PR#63 sat stale here). Emit ONE unit per such issue (the item
    # session verifies, flips agent/done, harvests the bullets as INERT issues — breaker #1).
    # Level-triggered off closed-issue state; capped at 3/repo/scan (a housekeeping trickle — first
    # run meets history) with the overflow reported, 21-day window (older = archaeology).
    closed_ip="$(gh issue list --repo "$slug" --state closed --label agent-fix --limit 30 \
      --json number,title,labels,updatedAt 2>/dev/null)" || closed_ip='[]'
    jq -e . >/dev/null 2>&1 <<<"${closed_ip:-null}" || closed_ip='[]'
    c6_all="$(printf '%s' "$closed_ip" | jq -r --arg cutoff "$(date -u -d '-21 days' +%Y-%m-%dT%H:%M:%SZ)" \
      '[.[] | (.labels|map(.name)) as $L
             | select(($L|index("agent/error"))|not)
             | select(($L|index("agent/done"))|not)
             | select(($L|index("agent/in-progress")) or ($L|index("agent/review")))
             | select(.updatedAt >= $cutoff) | .number] | .[]')"
    c6_n=0
    # FU-143 point 1: the goal children detected above (OPEN, merged into their declared goal/**
    # base, keyword inert) — same unit, same play, same cap; emitted FIRST because C4/C5 was told
    # to stand aside for exactly these, and the closeout moves the burn-down + unblocks
    # blocked-by siblings. The play closes the ISSUE too (README §merged-closeout, goal-child leg).
    for gb in $(printf '%b' "${c6g:-}"); do
      gn="${gb%%|*}"; gbase="${gb#*|}"
      if [ "$c6_n" -lt 3 ]; then
        units="${units}merged-closeout|${repo}|issue-${gn}\n"
        items="${items}[$repo] issue #${gn} — merged-closeout (FU-143: goal child merged into ${gbase}, keyword inert)\n"
        item_class_push "$repo" "issue-${gn}" "riding" "machine"
        c6_n=$((c6_n+1))
      else
        orphans="${orphans}[$repo] ⏳ merged-closeout backlog (cap 3/scan): issue #${gn} (goal child) waits for the next pass\n"
      fi
    done
    # IL-G06 (homelab#1149): OPEN issues on the default branch whose merged PR carries a strong
    # link — same unit, same play, same cap; emitted after goal children because the default-branch
    # keyword SHOULD have closed the issue (GitHub does this for default-branch merges), but the
    # PR used `Implements` instead of `Fixes`, or the issue has no `Base:` line.
    for dn in $(printf '%b' "${c6db:-}"); do
      if [ "$c6_n" -lt 3 ]; then
        units="${units}merged-closeout|${repo}|issue-${dn}\n"
        items="${items}[$repo] issue #${dn} — merged-closeout (IL-G06: default-branch PR merged with strong link, keyword inert)\n"
        item_class_push "$repo" "issue-${dn}" "riding" "machine"
        c6_n=$((c6_n+1))
      else
        orphans="${orphans}[$repo] ⏳ merged-closeout backlog (cap 3/scan): issue #${dn} (default-branch strong link) waits for the next pass\n"
      fi
    done
    for u in $c6_all; do
      if [ "$c6_n" -lt 3 ]; then
        units="${units}merged-closeout|${repo}|issue-${u}\n"
        # trip the actionability gate + surface in the report (see the ci-red note above) —
        # otherwise a merged issue's agent/done flip + Follow-ups harvest silently never dispatches.
        items="${items}[$repo] issue #${u} — merged-closeout (closed, still non-terminal agent/*)\n"
        item_class_push "$repo" "issue-${u}" "riding" "machine"
        c6_n=$((c6_n+1))
      else
        orphans="${orphans}[$repo] ⏳ merged-closeout backlog (cap 3/scan): issue #${u} waits for the next pass\n"
      fi
    done
    # <<<REPLAY:merged-closeout<<<

    # BACKSTOP (C10 leftover class): an agent-pattern branch (fix/*, feat/*, agent/*) with NO open
    # PR is a closed-PR leftover — a same-named future round dies non-fast-forward on it (live
    # 2026-07-09, defused by hand). Report-only; the fix is `gh pr close --delete-branch` hygiene.
    # NB the fallback must live OUTSIDE the $() — `gh api` prints the error BODY to stdout on a 404,
    # so `$(gh … || echo '[]')` concatenates body+[] (live crash 2026-07-12, a nonexistent claim repo).
    # Meta-5 probe rule: a failed probe's stdout is NOT a value — validate or zero it.
    heads="$(gh api "repos/$slug/branches?per_page=100" --jq '[.[].name | select(test("^(fix|feat|agent)/"))]' 2>/dev/null)" || heads='[]'
    prheads="$(gh pr list --repo "$slug" --state open --limit "$ISSUE_LIST_LIMIT" --json headRefName --jq '[.[].headRefName]' 2>/dev/null)" || prheads='[]'
    jq -e . >/dev/null 2>&1 <<<"${heads:-null}" || heads='[]'
    jq -e . >/dev/null 2>&1 <<<"${prheads:-null}" || prheads='[]'
    # A branch owned by a RUNNING ride is not stale — the worker pushes its branch before the PR
    # opens, and the flag fired on active rides' branches twice on 2026-07-26 (issues 129, 138).
    # Probe failure keeps run_iss empty → no exclusion → at worst the old (noisy) behavior.
    run_iss="$("$KUBECTL" $KUBE -n "$repo" get pods -l app=agent-session --no-headers 2>/dev/null | grep -oE 'issue-[0-9]+' | sort -u | paste -sd'|' -)" || run_iss=""
    if [ -n "$run_iss" ]; then
      heads="$(jq --arg re "(^|[^0-9])(${run_iss})([^0-9]|$)" '[.[] | select(test($re) | not)]' <<<"$heads")"
    fi
    stale="$(jq -rn --argjson h "$heads" --argjson p "$prheads" '$h - $p | .[] | "  branch \(.) — no open PR (stale; delete or resume)"')"
    [ -n "$stale" ] && orphans="${orphans}[$repo] ⚠ stale agent branches:\n${stale}\n"
    [ -n "$iss" ]  && items="${items}[$repo]\n${iss}\n"
    [ -n "$v2" ]   && items="${items}[$repo]\n${v2}\n"
    [ -n "$prs" ]  && items="${items}[$repo]\n${prs}\n"
    [ -n "$orph" ] && orphans="${orphans}[$repo] ⚠ un-armed open PRs (invisible to the merge path — arm or park, FU-079):\n${orph}\n"
  done

  [ -n "$orphans" ] && { echo "stack ${name}: ⚠ REPORT-ONLY items (human attention; the tick does not touch these):"; printf '%b' "$orphans"; }

  # FU-086(4): the daily JANITOR tick — the board-level judgment ADR-094 (4) retained, at its
  # own cadence (the janitor-<stack> CronWorkflow sets SCAN_JANITOR=1). Report-only by prompt
  # (coordinator README §The janitor tick): it dispatches nothing and the only writes allowed
  # are INERT spec-gap drafts (issue-authoring leg b). Runs BEFORE the quiet-stack skip on
  # purpose — a clause bug that starves an item class makes the stack LOOK quiet, and catching
  # exactly that is sweep #1.
  if [ -n "$SPAWN" ] && [ "${SCAN_JANITOR:-}" = "1" ]; then
    if [ "$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')" != "true" ]; then
      echo "  janitor: coordinator.enabled=false for ${name} — skipped."
      continue
    fi
    if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
      echo "  janitor: capacity limited (FU-088) — skipped this day (tomorrow's cron retries)."
      continue
    fi
    cmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
    echo "→ spawning janitor tick for ${name} (report-only, model ${cmodel})…"
    dispatch_phase "$mainrepo"   # FU-160
    scan_phase dispatch   # FU-145
    bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
      --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --janitor --detach
    scan_phase deterministic
    continue
  fi

  # ⚠ `units` is NOT derivable from `items`, and gating on `items` alone silently starves a whole
  # clause. Every OTHER unit happens to feed both — its subject is a queued/in-progress issue or an
  # open PR, which also lands in a report list — but `goal-checkpoint`'s subject is a goal parked in
  # `agent/blocked`, deliberately in no report list at all. So the backstop was unreachable in
  # EXACTLY the state it was built for: every child closed and nothing else going on, which is the
  # deadlock the operator asked to be backstopped ("it will deadlock too much when only child
  # traffic causes the goal to move"). It read as working for hours because it only ever ran while
  # OTHER work kept `items` non-empty — 16:30 and 17:00 fired, 18:00 went quiet with the predicate
  # TRUE (2026-08-05, circles#17 with both children closed). Gate on the union, not on the report.
  if [ -z "$items" ] && [ -z "$units" ]; then
    echo "stack ${name}: nothing actionable"
    continue
  fi
  any_work=1
  echo "stack ${name}: ACTIONABLE —"
  if [ -n "$items" ]; then
    printf '%b' "$items"
  else
    # Say it out loud: a dispatchable unit with no report line is the case that hid the bug.
    echo "  (no report items — a units-only clause is dispatchable; see the unit line below)"
  fi

  # FU-080 coordinator knob: default-off, opt in per stack via the claim's spec.coordinator.enabled.
  coord_enabled="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorEnabled // false')"
  if [ -n "$SPAWN" ] && [ "$coord_enabled" != "true" ]; then
    echo "  coordinator.enabled=false for stack ${name} — NOT spawning (report-only; enable in the AgentStack claim)."
    continue
  fi
  if [ -n "$SPAWN" ]; then
    # ADR-094/FU-086 item dispatch: the scan SCHEDULES (one highest-priority unit — WIP=1; the
    # FU-088 gates are the belt), the session JUDGES one item. Priority finishes in-flight work
    # before starting new: c4c5 > changes-requested > merge-conflict > unarmed-major > queued.
    # SCAN_ITEM_MODE=0 = rollback to the whole-stack tick (also the janitor/manual path).
    if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
      echo "  capacity: subscription limited (FU-088) — no dispatch this pass (level-triggered; next scan re-checks)."
      continue
    fi
    if [ "${SCAN_ITEM_MODE:-1}" = "0" ]; then
      echo "→ spawning headless coordinator tick for ${name} (SCAN_ITEM_MODE=0 whole-stack mode)…"
      dispatch_phase "$mainrepo"   # FU-160
      scan_phase dispatch   # FU-145
      bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" --run-tick --detach
      scan_phase deterministic
      continue
    fi
    # ── FU-146 dispatch retry loop: absorb exit-3 racing refusals ────────────────────────────
    # A racing dispatcher can win the (repo, item) key even after the scan's atomic gate passes.
    # Retry from the priority loop until a dispatch succeeds, no units remain, or a real error
    # occurs. Exit code 3 is NORMAL at-least-once delivery; other non-zero codes propagate.
    # >>>REPLAY:fu146-dispatch-loop>>>
    tried_units=""
    dispatch_succeeded=""
    # FU-110: pinned queued-dispatch units go FIRST WITHIN their clause — prepending is safe
    # because the clause loop below greps by clause name, so higher-priority clauses (in-flight
    # recovery etc.) still win regardless of position.
    units="${punits}${units}"
    # ── ADR-125 (3): THE CLAUSE WALK RUNS ONCE PER LANE ───────────────────────────────────────
    # Before this, ONE unit left this block per stack per pass: the first clause with an untried
    # unit won across the whole stack, so a self-regenerating `changes-requested` stream on master
    # could hold every goal-lane unit out indefinitely (#829; #818's decompose lost ~45 min on
    # 2026-08-23). A lane is (repo, base) and lanes cannot invalidate each other's merges, so the
    # walk is per lane and up to ONE unit per lane dispatches per pass.
    #
    # WHAT STAYS PER DISPATCH, deliberately: the subscription latch probe before each spawn (the
    # latch is the FLEET ceiling — per-lane slots were rejected in ADR-125's Considered, because
    # the semaphore protects the subscription pool, not a lane), the FU-146 exit-3 retry, the
    # FU-121 fresh-close probe, `tried_units`, and every WIP/footprint/cap hold (those are
    # computed upstream per unit and are untouched by this change).
    lane_keys="$(unit_lane_keys "$units")"
    if [ -z "$lane_keys" ]; then
      echo "  actionable items but no dispatchable unit (context-only repos / gated) — report-only."
      dispatch_succeeded=1
    fi
    dispatches_done=0
    latch_limited=""
    for lane in $lane_keys; do
      lrepo="${lane%%|*}"; lbase="${lane#*|}"
      lane_units="$(unit_lane_units "$units" "$lrepo" "$lbase")"
      lane_n="$(printf '%s\n' "$lane_units" | grep -c . || true)"
      if [ -n "$latch_limited" ]; then
        echo "  lane ${lrepo}@${lbase}: not walked — the subscription latch ended this pass (fleet ceiling, FU-088)"
        continue
      fi
      # ── WITHIN-LANE AGING (#829, ADR-125 (3)) ───────────────────────────────────────────────
      # Priority is a PREFERENCE, not an absolute: a NEW-WORK unit that has lost N consecutive lane
      # dispatches goes to the FRONT of this lane's walk. STRAIGHT to the front, not one step up —
      # after N honoured preferences the ordering has had its say, and a per-step ladder would need
      # per-step state, which is exactly the in-process state #829 forbids.
      #
      # DERIVED, READ-ONLY, NOTHING NEW WRITTEN (#829's first design question):
      #   queued_at  = the newest `labeled` event for `agent/queued` on the issue — the moment the
      #                unit became eligible, already on the issue's own timeline.
      #   lost       = how many dispatch markers newer than queued_at sit on the lane's OTHER
      #                in-flight items: the `<!-- agent-event kind=… ts=… -->` lines inside each
      #                item's single `<!-- agent-summary -->` comment (grammar owned by
      #                agents/machine-comment.sh). One marker = one ride this lane spent while the
      #                candidate waited.
      # ⚠ Today the only kind mc_event emits is `stats` (agent-session.sh, one per completed fix
      # round); `kind=dispatch` does not exist yet. The count is kind-AGNOSTIC on purpose so it
      # reads what the timeline actually carries and picks up a future dispatch marker for free.
      # The consequence is UNDER-counting, never over: a ride that finishes without posting a
      # marker is invisible here, so aging fires later than the ideal, never earlier. That is the
      # safe direction — the failure mode of over-counting is preempting live recovery work.
      #
      # RULE #6, both probes: unreadable events or unreadable comments ⇒ NO aging, ordinary walk,
      # one report line. A probe that cannot be read is never allowed to become a dispatch.
      #
      # COST BOUND: evaluated once per lane, and only when the lane actually holds a
      # higher-priority unit — with nothing above it the candidate wins the walk anyway and the
      # probes would buy nothing.
      aging_front=""
      if printf '%s\n' "$lane_units" | grep -qE '^(c4c5-redispatch|arbitrate|changes-requested|merge-conflict|unarmed-major|infra-enrich|ci-red|merged-closeout|goal-checkpoint)\|'; then
        while IFS= read -r acand; do
          [ -n "$acand" ] || continue
          case " $tried_units " in *" $acand "*) continue;; esac
          aclause="${acand%%|*}"; arest="${acand#*|}"; arepo="${arest%%|*}"; arest="${arest#*|}"; aitem="${arest%%|*}"
          case "$aitem" in issue-*) :;; *) continue;; esac
          aq="$(gh api "repos/${ORG}/${arepo}/issues/${aitem#issue-}/events" --paginate \
                  --jq '.[] | select(.event == "labeled" and .label.name == "agent/queued") | .created_at' 2>/dev/null | tail -1)" || aq=""
          if [ -z "$aq" ]; then
            echo "  aging: ${aclause}|${aitem} — no readable \`agent/queued\` labeled event; ordinary walk this pass (rule #6, no aging)"
            continue
          fi
          alost=0; aprobe_ok=1
          while IFS= read -r aother; do
            [ -n "$aother" ] || continue
            orest="${aother#*|}"; orepo="${orest%%|*}"; orest="${orest#*|}"; oitem="${orest%%|*}"
            [ "$oitem" = "$aitem" ] && continue
            if ! omarks="$(gh api "repos/${ORG}/${orepo}/issues/${oitem#*-}/comments" --paginate \
                  --jq '.[] | select((.body // "") | startswith("<!-- agent-summary -->")) | .body | scan("<!-- agent-event kind=[^ ]+ ts=([^ ]+) -->") | .[0]' 2>/dev/null)"; then
              aprobe_ok=""; break
            fi
            alost=$(( alost + $(printf '%s\n' "$omarks" | awk -v q="$aq" 'NF && $0 > q' | grep -c . || true) ))
          done <<EOF
$(printf '%s\n' "$lane_units")
EOF
          if [ -z "$aprobe_ok" ]; then
            echo "  aging: ${aclause}|${aitem} — dispatch markers unreadable on a lane sibling; ordinary walk this pass (rule #6, no aging)"
            continue
          fi
          if [ "$alost" -ge "$SCAN_AGING_N" ]; then
            aging_front="$acand"
            echo "  aging: ${aclause}|${aitem} lost ${alost} lane dispatches since ${aq} — escalated to front (N=${SCAN_AGING_N})"
            break
          fi
        done <<EOF
$(printf '%s\n' "$lane_units" | grep -E '^(goal-decompose|queued-dispatch)\|' || true)
EOF
      fi
      lane_done=""
      while [ -z "$lane_done" ]; do
      unit=""
      # An aged unit jumps the whole walk — including the recovery classes — exactly once, while it
      # is still untried this pass.
      if [ -n "$aging_front" ]; then
        case " $tried_units " in
          *" $aging_front "*) : ;;
          *) unit="$aging_front" ;;
        esac
      fi
      # Priority: in-flight recovery first, then merge-path exceptions, then CLOSE loops on merged
      # work (C6 — cheap bookkeeping that keeps state honest), and only then open NEW work.
      # goal-decompose sits just BEFORE queued-dispatch: it opens new work like a queued issue does,
      # but it must win over it when a repo has both, because a goal left undecomposed is what makes
      # its children exist at all (leg (c), 2026-08-05). It stays BELOW every recovery and merge-path
      # clause — an in-flight failure is always more urgent than planning the next thing.
      [ -n "$unit" ] || \
      for clause in c4c5-redispatch arbitrate changes-requested merge-conflict unarmed-major infra-enrich ci-red merged-closeout goal-checkpoint goal-decompose queued-dispatch; do
        # First candidate of THIS clause not yet tried this pass (PR#631 r1: `grep -m1` against
        # the unmodified $units re-found the same skipped line forever, so a clause with two
        # units never drained past its first — the loop fell through to lower-priority clauses
        # while same-clause work sat dispatchable). The subshell only READS tried_units.
        # Scoped to THIS LANE's units (ADR-125): the walk is per lane, so a higher-priority unit
        # in another lane no longer suppresses this one.
        unit="$(printf '%s\n' "$lane_units" | grep "^${clause}|" | while IFS= read -r cand; do
          case " $tried_units " in *" $cand "*) continue;; esac
          printf '%s\n' "$cand"; break
        done || true)"
        [ -n "$unit" ] && break
      done
      if [ -z "$unit" ]; then
        echo "  lane ${lrepo}@${lbase}: nothing dispatchable"
        lane_done=1
        continue
      fi
    uclause="${unit%%|*}"; rest="${unit#*|}"; urepo="${rest%%|*}"; rest2="${rest#*|}"
    # FU-114 L3: 4-field units (queued-dispatch, c4c5-redispatch) carry the task class from the
    # issue's task/* label — the recipe choice is DETERMINISTIC (never the session "figuring it
    # out"; ADR-094). 3-field units (merge-path clauses) have no class — the session derives it
    # from the issue labels per its brief.
    case "$rest2" in
      *"|"*) uitem="${rest2%%|*}"; uclass="${rest2#*|}";;
      *)     uitem="$rest2"; uclass="";;
    esac
    # FU-090 leg (c): a 5th field is the GOAL this item is a child of. Split it back off the class
    # so the coordinator's brief can name it — the whole point of the forest/trees rule is that a
    # child unit never arrives without its goal attached.
    case "$uclass" in
      *"|"*) uparent="${uclass#*|}"; uclass="${uclass%%|*}";;
      *)     uparent="";;
    esac
    # The lane's walk verdict, one line per selection (ADR-125). `n units` is the lane's whole
    # unit count, so a lane that retries after an FU-121 skip or an exit-3 prints the same count
    # beside a different pick — which is exactly the trace needed to read a starved lane.
    echo "  lane ${lrepo}@${lbase}: ${lane_n} units, walk → ${uclause}|${uitem}"
    # FU-121: a c4c5 redispatch can race a closing issue (the #71 r9 spurious round — the scan's
    # list snapshot predated the close). Re-probe the ISSUE fresh immediately before spending a
    # session: closed → skip this unit (the next scan's list won't carry it). Probe failure
    # dispatches anyway (level-triggered permissive — the session's own re-read is the belt).
    if [ "$uclause" = "c4c5-redispatch" ]; then
      fresh_state="$(gh issue view "${uitem#issue-}" --repo "${ORG}/${urepo}" --json state --jq .state 2>/dev/null || echo PROBE-FAILED)"
      if [ "$fresh_state" = "CLOSED" ]; then
        # PR#631 r2: inside the FU-146 retry loop this `continue` targets the NEW `while`, no
        # longer the outer stacks loop — unmarked, it would re-select this same closed unit
        # forever (an unbounded tight loop of live probes). Mark it tried: the skip becomes a
        # bounded drain to the next unit, which is strictly better than master's whole-stack
        # abort — a raced close should not cost the pass its dispatch.
        tried_units="${tried_units} ${unit}"
        echo "  FU-121: ${urepo} ${uitem} closed since the list snapshot — redispatch skipped; trying next unit"
        continue
      fi
    fi
    cmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.coordinatorModel // "sonnet"')"
    # The stack's WORKER model — not this session's model. It is the sizing input the goal-budget
    # estimator needs (a cap is per-ride, and the rides a goal funds are worker rides), read here
    # beside cmodel so the harvest-disposition block below stays free of claim lookups.
    wmodel="$(stacks_json | jq -r --arg n "$name" '.stacks[]|select(.name==$n)|.workerModel // "claude/haiku"')"
    # ── goal-decompose runs a REASONING tier (operator ruling, 2026-08-05) ─────────────────────
    # The axis is AUTHORING vs CHECKING, not goal vs routine. `goal-decompose` CREATES the work —
    # a mis-scoped child burns rides, mis-narrows `Touches:`, and is expensive to undo once its
    # ride opens a PR. Everything else in the lane checks work that is already framed.
    # ⚠ `goal-review` was in this list for ~90 minutes and was REMOVED (operator challenge, same
    # day): it is mostly verification against an acceptance list the goal already carries, and both
    # of its live runs on 2026-08-05 were SONNET and both were right — the 16:32 one ruled "not yet
    # met", correctly told branch-2 (a child covers the gap) from branch-3 (author the missing
    # child), authored no redundant child, and caught stale `Base:` prose the meta session missed;
    # the 18:15 one verified against the goal branch + post-merge CI rather than labels and left
    # the human-reserved PRs alone. It also contradicted standing doctrine — reviewer-session.sh:
    # "Sonnet is sufficient here; opus is available for a genuinely high-stakes PR via --model, but
    # it is not the default." A review is a review. Escalate a SPECIFIC hard goal with GOAL_MODEL,
    # do not raise the floor for the whole clause.
    # G-A 8 (#781): this case map is DEAD — replaced by the goal-decompose class policy in
    # model-classes.json. coordinator-session.sh now calls resolve-model.sh with --role coordinator
    # and the clause-derived class (goal-decompose for goal-decompose/goal-checkpoint, dispatch
    # for everything else via role_defaults). GOAL_MODEL survives as the env escape hatch in
    # coordinator-session.sh. The comment above is left as a historical marker (ADR-094).
    # ADR-097: the launcher-owned AGENT_WIP_LIMIT for this repo (live workers + 1, ceiling-capped;
    # 1 on probe failure). Computed by the scan, carried as pod env — never LLM-assembled.
    uwip="$(printf '%b' "$wipmap" | awk -v r="$urepo" '$1==r{print $2}' | head -1)"
    case "${uwip:-}" in ''|*[!0-9]*) uwip=1;; esac
    # homelab#198: RECORD the fingerprint of the state this ride is about to read, for the three
    # clauses whose emission is gated on it (arbitrate, ci-red, and merge-conflict since homelab#595).
    # Here and not at emission because this is the one place a unit is known to be THE dispatched
    # one; and BEFORE the spawn because the session's own work (a pushed fix round, a dismissal, a
    # rerun) is exactly the state change that must re-open the gate — recording afterwards would
    # fingerprint the outcome and debounce the follow-up ride. A refused write only costs the
    # debounce (the clause re-emits next scan, i.e. today's behaviour), so it WARNs and dispatches;
    # it never blocks the ride it is annotating.
    # >>>REPLAY:dispatch-marker>>>
    case "${uclause}:${uitem}" in
      arbitrate:pr-*|ci-red:pr-*|infra-enrich:pr-*|merge-conflict:pr-*)
        dfp="$(pr_state_fp_pair "${ORG}/${urepo}" "${uitem#pr-}" "${uclause}")"; dfp="${dfp%%|*}"
        if [ -z "$dfp" ]; then
          echo "  WARN: state fingerprint unreadable for ${urepo} ${uitem} — dispatching anyway; the ${uclause} debounce cannot arm this pass (homelab#198)" >&2
        elif ! gh pr comment "${uitem#pr-}" --repo "${ORG}/${urepo}" --body "$(printf '%s\n' \
              "🤖 \`state-fp:${uclause}:${dfp}\` — deterministic scan dispatching a \`${uclause}\` unit at $(date -u +%Y-%m-%dT%H:%M:%SZ)." \
              "" \
              "Machine-readable debounce marker (homelab#198), written by \`agents/coordinator-scan.sh\`, not by the session that follows. It hashes the state that ride reads — head sha, every check's conclusion, \`reviewDecision\`, and the newest verdict's timestamp. For ci-red clauses (homelab#1108) each check's \`startedAt\` is also folded in, so a CI rerun changes the hash and re-arms the gate. For arbitrate clauses (homelab#1011) per-check conclusions are dropped and head narrows to the newest non-merge commit, so CI churn and updater merges do not re-arm arbitration. While the hash is unchanged this clause emits a report line instead of another unit, so an escalation waiting on a human costs no further rides; any real movement on this PR changes it and the clause re-arms by itself." )" >/dev/null 2>&1; then
          echo "  WARN: could not record state-fp on ${urepo} ${uitem} (gh write refused?) — dispatching anyway; the ${uclause} clause will re-emit on unchanged state (homelab#198)" >&2
        fi
        ;;
      goal-checkpoint:issue-*)
        # homelab#1150: an assembly-cr goal-checkpoint unit carries a PR number in the side map
        # (assembly_cr_prs). Look up the dispatched unit's (repo, item) pair; when found, write
        # the state-fp marker on the assembly PR (not the goal issue). No lookup hit ⇒ do nothing
        # (an ordinary threshold-fired goal-checkpoint has no assembly PR and must not get a
        # marker). Match the existing arm's failure semantics: empty fingerprint or refused write
        # WARNS to stderr and dispatches anyway — a refused write only costs the debounce, and
        # it must never block the ride it annotates.
        apr=""
        for entry in $assembly_cr_prs; do
          if [[ "$entry" == "${urepo}:${uitem}:"* ]]; then
            apr="${entry##*:}"
            break
          fi
        done
        if [ -n "$apr" ]; then
          dfp="$(pr_state_fp_pair "${ORG}/${urepo}" "$apr" assembly-cr)"; dfp="${dfp%%|*}"
          if [ -z "$dfp" ]; then
            echo "  WARN: state fingerprint unreadable for ${urepo} PR #${apr} — dispatching anyway; the assembly-cr debounce cannot arm this pass (homelab#198)" >&2
          elif ! gh pr comment "$apr" --repo "${ORG}/${urepo}" --body "$(printf '%s\n' \
                "🤖 \`state-fp:assembly-cr:${dfp}\` — deterministic scan dispatching a \`goal-checkpoint\` unit (trigger=assembly-cr) for goal ${uitem#issue-} at $(date -u +%Y-%m-%dT%H:%M:%SZ)." \
                "" \
                "Machine-readable debounce marker (homelab#198), written by \`agents/coordinator-scan.sh\`, not by the session that follows. It hashes the PR state — head sha, \`reviewDecision\`, and the newest verdict's timestamp. While the hash is unchanged this clause emits a report line instead of another unit, so an assembly PR waiting on a human costs no further rides; any real movement on this PR changes it and the clause re-arms by itself." )" >/dev/null 2>&1; then
            echo "  WARN: could not record state-fp on ${urepo} PR #${apr} (gh write refused?) — dispatching anyway; the assembly-cr clause will re-emit on unchanged state (homelab#198)" >&2
          fi
        fi
        ;;
    esac
    # <<<REPLAY:dispatch-marker<<<
    # ── HARVEST DISPOSITION (ADR-102 goal container, homelab#207) ─────────────────────────────
    # WHAT THIS DECIDES, AND WHY HERE. Until ADR-102 the harvest step of the merged-closeout play
    # judged two things in prose: where a sprout hangs (under the issue that produced it) and
    # whether it may self-apply `agent-fix`+`agent/queued` (unconditionally, whenever the
    # originating issue carried `Base: goal/**`). Both outlive the thing that authorises them —
    # the 2026-08-09 census caught #195/#211-shaped sprouts self-queueing with no budget left and
    # the goal already closed, and oracle-fleet goal-174 grew three generations 34h post-close
    # with nothing owning the tree. Under ADR-102 a sprout belongs to its goal's POST-LAUNCH
    # bucket and the self-queue right dies with the goal, so both answers are now DETERMINISTIC
    # and computed here — the session is told, never asked (ADR-094).
    #
    # AT DISPATCH, not at emission: exactly one unit is known to be THE dispatched one here (the
    # same reason the state-fp marker sits directly above), so the ancestry probe + budget read
    # cost one unit's worth of calls per scan instead of the emission cap's three.
    #
    # BUCKET CREATION IS IDEMPOTENT and fires at the goal-checkpoint/closeout site, which is where
    # ADR-102 puts it. It fires EARLIER than "at assembly merge" on purpose: deliverable 2 files
    # open-goal sprouts into the bucket, so the container must exist while the goal is still
    # pre-launch. One container per goal either way — the search below is what makes a second call
    # a no-op, not a second bucket.
    #
    # FAIL-CLOSED, EVERY EDGE. No goal ancestor → nothing is emitted and the master-lane harvest
    # stays inert exactly as breaker #1 has always required. Goal closed, budget exhausted, no
    # machine-parsed `Budget:` line, unreadable probe, or a bucket that could not be resolved →
    # `selfqueue=no`. The right to queue is a GRANT from an open funded goal; an unreadable grant
    # is not a grant, and the cost asymmetry is stark (a missed queue costs one human triage, a
    # wrong one costs rides against money that is gone).
    # >>>REPLAY:harvest-disposition>>>
    uharvest=""
    case "$uclause" in
      merged-closeout|goal-checkpoint|arbitrate|changes-requested)
        hslug="${ORG}/${urepo}"; hgoal=""; hbucket=""; hsq=""; hwhy=""
        case "$uclause" in
          # A goal-checkpoint unit IS the goal. Nothing to walk.
          goal-checkpoint) hgoal="${uitem#issue-}" ;;
          # A closeout item is the GOAL itself (the assembly PR's own closeout), a goal CHILD
          # (depth 1), or a sprout of one (depth 2+). Test the item, then climb the native
          # sub-issue chain — `goal_resolve_ancestor` (agents/goal-budget.sh). Testing the ITEM
          # first is what puts the bucket under a goal whose own closeout is the unit; a walk that
          # only looks upward would miss exactly the assembly-merge case ADR-102 names, so this
          # caller passes the item and the launcher pre-flight passes the PARENT (stated there).
          #
          # THE WALK MOVED into the helper (homelab#367): same order, same two reads per hop, same
          # bound of 6, all of it argued where it now lives — beside the sum it feeds. One thing
          # widened: the per-hop read is `--json labels,body` and a machine-readable `Budget:` line
          # ALSO stops the walk, so a funded-but-unlabelled ancestor resolves here too (the reason
          # is at the helper). It moved because agent-session.sh was answering the same question
          # with ONE hop, so this block resolved `goal=278 bucket=295` for rides the launcher was
          # gating against #295 — a bucket with no `Budget:` line, i.e. no gate at all.
          merged-closeout)
            command -v goal_resolve_ancestor >/dev/null 2>&1 || . "${HERE}/goal-budget.sh"
            goal_resolve_ancestor "$hslug" "${uitem#issue-}"
            hgoal="$GB_GOAL" ;;
          # arbitrate and changes-requested are PR-shaped items (pr-<N>). Extract the PR's
          # linked issue from the body (Fixes/Closes/Implements #N), then walk the goal
          # ancestor chain from that issue — same goal_resolve_ancestor call the closeout
          # path uses, one walk (homelab#1381).
          arbitrate|changes-requested)
            hpr="${uitem#pr-}"
            hprjson="$(gh pr view "$hpr" --repo "$hslug" --json body 2>/dev/null || echo '{}')"
            hpr_issue="$(printf '%s' "$hprjson" | jq -r '(.body // "") | capture("(?i)(^|[^a-z])(implements|closes|closed|fixes|fixed|resolves|resolved)[ \t]+#(?<i>[0-9]+)") | .i // ""' 2>/dev/null)" || hpr_issue=""
            if [ -n "$hpr_issue" ]; then
              command -v goal_resolve_ancestor >/dev/null 2>&1 || . "${HERE}/goal-budget.sh"
              goal_resolve_ancestor "$hslug" "$hpr_issue"
              hgoal="$GB_GOAL"
            fi
            ;;
        esac
        if [ -n "$hgoal" ]; then
          hgj="$(gh issue view "$hgoal" --repo "$hslug" --json title,state 2>/dev/null || echo '{}')"
          jq -e . >/dev/null 2>&1 <<<"${hgj:-null}" || hgj='{}'
          hgtitle="$(printf '%s' "$hgj" | jq -r '.title // ""')"
          hgstate="$(printf '%s' "$hgj" | jq -r '.state // "PROBE-FAILED"')"
          # ONE bucket, found by title under the goal's own sub-issue list — the container is a
          # SUB-ISSUE and not a label (operator ruling 2026-08-09: one container, one burn-down
          # anchor), so the sub-issue tree is also where you look it up.
          hbucket="$(gh api "repos/${hslug}/issues/${hgoal}/sub_issues" 2>/dev/null \
            | jq -r '[.[] | select(.title | startswith("post-launch:")) | .number] | first // ""' 2>/dev/null || true)"
          case "$hbucket" in ''|*[!0-9]*) hbucket="";; esac
          if [ -z "$hbucket" ] && [ -n "$hgtitle" ]; then
            hburl="$(gh issue create --repo "$hslug" --title "post-launch: ${hgtitle}" --body "$(printf '%s\n' \
              "Post-launch bucket for goal #${hgoal} — created by \`agents/coordinator-scan.sh\`, not by a session (ADR-102, homelab#207)." \
              "" \
              "**What lands here.** Every sprout harvested from a review of a PR descended from this goal. Assembly merge is a MIDPOINT, not the end: the goal keeps shipping to production at its own pace, and this issue is the one container that work hangs off — so the burn-down is a query, not archaeology." \
              "" \
              "**Children base \`master\`.** The goal branch dies at the assembly squash; goal identity is this issue plus its \`Budget:\` line, never the branch. Children here therefore carry NO \`Base:\` line." \
              "" \
              "**They spend the goal's money.** This bucket is a sub-issue of the goal, so its children are goal DESCENDANTS and the launcher pre-flight already counts them against the goal's \`Budget:\` (\`agents/goal-budget.sh\`). A sprout self-queues only while the goal is OPEN and that sum still fits; otherwise it lands here inert for human triage." \
              "" \
              "Closing this issue does not close the goal, and closing the goal kills this tree with it (ADR-102 terminals).")" 2>/dev/null || true)"
            hbucket="${hburl##*/}"
            case "$hbucket" in ''|*[!0-9]*) hbucket="";; esac
            if [ -n "$hbucket" ]; then
              # Native sub-issue edge, the same call the harvest and decompose plays make — the
              # lineage is read by machinery (the budget walk above all), so prose will not do.
              hbid="$(gh api "repos/${hslug}/issues/${hbucket}" 2>/dev/null \
                       | jq -r '.id // ""' 2>/dev/null || true)"
              if [ -z "$hbid" ] || ! gh api -X POST "repos/${hslug}/issues/${hgoal}/sub_issues" \
                   -F sub_issue_id="$hbid" >/dev/null 2>&1; then
                # An UNPARENTED bucket is worse than none: its children would sit outside the
                # goal's descendant walk and spend money the budget gate cannot see.
                echo "  ⚠ harvest: bucket #${hbucket} created but NOT linked under goal #${hgoal} (${hslug}) — its children would escape the budget walk; link it by hand" >&2
                hbucket=""
              else
                # ADR-122 (4): the bucket is a CONTAINER, permanently out of the goal's
                # completion scope — so it is dispositioned `deferred` at birth, by the only
                # non-session writer of the store (`by=bucket`). This is what dissolves #933's
                # `post-launch:` TITLE exception into an ordinary disposition; the title test in
                # the goal lane survives only as the belt for buckets created before this line.
                python3 "${HERE}/epic_dispositions.py" set "$hslug" "$hgoal" "$hbucket" deferred --by bucket >/dev/null 2>&1 \
                  || echo "  ⚠ harvest: bucket #${hbucket} could not be dispositioned on goal #${hgoal} (${hslug}) — the goal lane's post-launch: title belt still excludes it; the next checkpoint can rule it" >&2
              fi
            fi
          fi
          # ── v1.2 (ADR-106 (2)+(3)) — harvest APPENDS, never mints ─────────────────────────
          # The selfqueue GRANT is retired: 52 of 52 goal-#278 inflow edges were worker/ride-
          # authored issues minted per-event, which is the debt the store exists to batch. A
          # closeout's findings now APPEND to the goal's findings store (agents/goal-findings.sh)
          # and the CHECKPOINT is the one minting moment — budget-gated THERE (goal_budget_read
          # moved into that play; children parent to their ORIGINATING issue, the bucket back to
          # post-assembly strays only). A dead goal's findings land inert, as ever.
          # homelab#1381: arbitrate and changes-requested units also carry harvest=store|inert
          # so a follow-up-class finding on a goal child routes through the findings store
          # instead of landing inert with no reader.
          if [ "$uclause" = "merged-closeout" ] || [ "$uclause" = "arbitrate" ] || [ "$uclause" = "changes-requested" ]; then
            if [ "$hgstate" != "OPEN" ]; then
              hsq="inert"; hwhy="goal #${hgoal} is ${hgstate} — findings from a dead goal land inert (ADR-102 terminals)"
            else
              hsq="store"; hwhy="v1.2: findings APPEND to the store; minting is the checkpoint's, budget-gated there (ADR-106 (3))"
            fi
          fi
          uharvest=" goal=${hgoal}${hbucket:+ bucket=${hbucket}}${hsq:+ harvest=${hsq}}"
          echo "  harvest disposition (ADR-106): ${urepo} ${uitem} → goal #${hgoal}, bucket ${hbucket:-UNRESOLVED}${hsq:+, harvest ${hsq}}${hwhy:+ — ${hwhy}}"
        fi
        ;;
    esac
    # <<<REPLAY:harvest-disposition<<<
      # ADR-125 per-dispatch latch probe. The pass-level probe above this block covers the FIRST
      # spawn; every SUBSEQUENT one must re-ask, because the latch is the fleet ceiling and a
      # `limited` verdict between two lanes must stop the pass rather than let the walk keep
      # spending. A limited verdict ends the pass for every remaining lane, and says so.
      # `dispatches_done` counts pods this pass actually CREATED, so an FU-146 exit-3 does not
      # arm it: that refusal means a racing dispatcher's pod already exists and OUR pass spent
      # nothing, so charging it a latch probe would defer real work on someone else's spend.
      if [ "$dispatches_done" -gt 0 ] && ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/subscription-latch.sh"; then
        echo "  capacity: subscription limited (FU-088) — the fleet ceiling ends this pass; remaining lanes are not walked (level-triggered; next scan re-checks)."
        latch_limited=1; lane_done=1
        continue
      fi
      echo "→ dispatching item unit for ${name}: ${urepo} ${uitem} (${uclause}${uclass:+, class ${uclass}}${uparent:+, child of goal #${uparent}}, model ${cmodel}, wip ${uwip})…"
      # FU-080 perStack: under a stack-scoped instance the item session runs in the loop home
      # (<stack>-agents, SA agentstack-loop, broker git creds) instead of agent-coordinator.
      # FU-145/ADR-106 (5): the launcher DETACHES at pod-Ready — the dispatch phase below is pod
      # spin-up, not the streamed ride, and the `coordinator-scan` mutex now spans only the
      # deterministic pass (the pod uploads, pushes its own session row, rings the doorbell itself).
      dispatch_phase "$mainrepo" "$uclause" "${uclass:-}" "$lbase"   # FU-160: the ring→scan and scan rows close on the same boundary; ADR-125: the lane keys the wake series
      scan_phase dispatch
      # ── FU-146 exit-3 dispatch gate (racing dispatcher won): report, retry next unit ─────────
      # When `coordinator-session.sh` exits with 3, the item pod exists and a racing dispatcher
      # won the (repo, item) key. The refusal is CORRECT; its rendering as a red workflow is
      # the problem — 34 red workflows in 16h bury 4 real failures. Retry the next unit (or
      # exit 0 if none); never propagate exit 3 as the scan's exit code.
      # FU-199: if this c4c5-redispatch unit has a resumable branch from an AGENT_STRIKE: +
      # Resumable branch pushed: comment, carry it so the coordinator session resumes with
      # --work-branch <branch> (never a restart).
      # >>>REPLAY:fu146-resumable-match>>>
      uworkbranch=""
      if [ "$uclause" = "c4c5-redispatch" ] && [ -n "${resumable_branches:-}" ]; then
        for rb_entry in $resumable_branches; do
          rb_n="${rb_entry%%=*}"
          rb_branch="${rb_entry#*=}"
          # match on repo#number — the bare-number match was the cross-repo collision
          if [ "${urepo}#${uitem#issue-}" = "$rb_n" ]; then
            uworkbranch=" work-branch=${rb_branch}"
            break
          fi
        done
      fi
      # <<<REPLAY:fu146-resumable-match<<<
      dispatch_rc=0
      bash "${HERE}/coordinator-session.sh" --stack "$name" --repos "${repos% }" --main-repo "$mainrepo" \
        --model "$cmodel" ${LOOP_NS:+--loop-ns "$LOOP_NS"} --wip "$uwip" --detach \
        --item "repo=${urepo} item=${uitem} clause=${uclause}${uclass:+ class=${uclass}}${uparent:+ parent=${uparent}}${uworkbranch}${uharvest}" \
        || dispatch_rc=$?
      if [ $dispatch_rc -eq 3 ]; then
        echo "  FU-146: exit 3 — ${name}/${urepo}/${uitem} taken by racing dispatcher; trying next unit"
        tried_units="${tried_units} ${unit}"
        # Continue the retry loop (stay in THIS LANE's while, re-find a unit). A racing dispatcher
        # took this unit, not the lane's turn — the lane keeps its dispatch if another unit in it
        # is dispatchable, and falls to "nothing dispatchable" if none is.
      elif [ $dispatch_rc -ne 0 ]; then
        # PR#915 review (2026-08-26 07:45Z finding): the batch accumulator dies with the process —
        # flush the tick's classified rows BEFORE the hard exit, or every stack already scanned
        # this pass loses its agent_item_class series whenever one dispatch hard-fails (the
        # pre-batch behavior was push-per-item and never had this window). Idempotent: the flush
        # clears the accumulator, so the ordinary end-of-pass flush becomes a no-op.
        item_class_flush
        exit $dispatch_rc
      else
        # Success — ONE unit per lane per pass (ADR-125). `dispatch_succeeded` now means "this pass
        # dispatched at least once"; the walk moves on to the NEXT LANE rather than ending the pass.
        dispatch_succeeded=1
        dispatches_done=$((dispatches_done + 1))
        lane_done=1
      fi
      scan_phase deterministic
      done
    done
    # <<<REPLAY:fu146-dispatch-loop<<<
  else
    echo "  run it (interactive, supervised):"
    echo "    devbox run coordinator-session -- --stack ${name} --repos \"${repos% }\" --main-repo ${mainrepo} --tick"
  fi
done

# FU-176, one scope level up (PR #915 review): SCAN_PHASE_NS is process-fixed at the top of this
# file, so a per-stack flush would POST every stack to the SAME job=agent_board,namespace=<ns>
# group and pushgateway's replace-by-metric-name semantics would leave only the last stack's rows.
# Accumulate across the whole pass and flush ONCE, here, after the stacks loop.
item_class_flush

[ -n "$any_work" ] || echo "no stack has actionable work — nothing to spawn (no LLM woken)."
