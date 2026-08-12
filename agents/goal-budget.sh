# goal-budget.sh — the goal `Budget:` read, ONE implementation, two callers (ADR-102, homelab#207).
#
# Sourced by agent-session.sh (the ENFORCING launcher pre-flight) and by coordinator-scan.sh's
# harvest-disposition block (an ADVISORY read: may this sprout self-queue?). It was inline launcher
# shell until #207 needed the same number at harvest time, and the ⚖ pre-decided line on that issue
# is explicit — "do not duplicate its arithmetic, call the same helper". So the arithmetic moved
# here unchanged and grew exactly one thing it did not have: a verdict a second caller can read
# without exiting the process.
#
# WHO ENFORCES. Only the launcher. This helper never exits, never comments, never labels — it
# computes and returns. The pre-flight keeps the refusal (comment on the goal + exit 1); the
# harvest keeps the demotion (file the sprout inert). Two callers, one number, one enforcer.
#
#   goal_budget_read <slug> <goal-issue> <model> [dispatch-issue]
#     → GB_BUDGET   the parsed `Budget:` number in USD ('' = no machine-readable line on the goal)
#       GB_SUM      Σ(actual spend + live/dispatch reservations) across the goal's DESCENDANTS
#       GB_ROWS     per-child explanation, \n-escaped (printf '%b')
#       GB_VERDICT  within | exhausted | no-budget
#
# `no-budget` is NOT `within`. The launcher has always treated an unparseable `Budget:` as "gate
# off" (it is the pre-ADR-102 world, where goals were optional); the harvest treats it as "no
# self-queue right", because ADR-102 makes the funded goal the thing that GRANTS the right and an
# unreadable grant is not a grant. Same number, different fail direction, each stated at its caller.
#
# TWO I/O SEAMS, on purpose: `gb_ledger` (the spend ledger) and `gb_cap` (the estimator). Both are
# plain functions a caller may redefine — which is how agents/replay/fixtures/harvest-* replay the
# real arithmetic against a recorded world with no network and no estimator drift in the action
# stream. Everything between them is pure shell over one `gh issue list`.

GB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The spend ledger: what the subtree ACTUALLY spent. The pushgateway the finalize leg pushes to is
# the record; one GET, parsed to `<issue> <usd>` lines. Empty output = unreachable, and the caller
# degrades to the conservative cap-sum (see the charge loop).
gb_ledger() {   # gb_ledger <project>
  _gb_pgw="${AGENT_PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
  curl -m 5 -fsS "${_gb_pgw}/metrics" 2>/dev/null | sort -u \
    | awk -v proj="$1" '/^agent_run_cost_usd\{/ && index($0, "project=\"" proj "\"") {
        if (match($0, /issue="[0-9]+"/)) { iss=substr($0, RSTART+7, RLENGTH-8);
          sum[iss] += $NF } }
      END { for (i in sum) printf "%s %.4f\n", i, sum[i] }'
}

# What a minted key for this child would ALLOW (cap_usd) — the reservation unit.
gb_cap() {   # gb_cap <issue-chars> <model> [agent-budget/* label]
  python3 "$GB_HERE/estimate_budget.py" --issue-chars "${1:-0}" --model "$2" \
    ${3:+--label "$3"} 2>/dev/null | jq -r '.cap_usd // 0' 2>/dev/null || echo 0
}

gb_add() { python3 -c "import sys;print(round(float(sys.argv[1])+float(sys.argv[2]),4))" "$1" "$2"; }

# The `Budget:` GRAMMAR, one home (stdin: an issue body → stdout: the USD number, or empty).
# Both readers below need it — the sum parses the goal's line, the walk tests an ancestor for one —
# and a second copy of a parser this load-bearing is how a currency symbol disabled the whole gate
# once already (see goal_budget_read). Currency symbols are stripped and the NUMBER IS READ AS USD:
# the estimator prices in USD (cap_usd) because OpenRouter does, so a `Budget: €5` funds $5, not €5.
# A deliberate, stated approximation — the alternative is an FX rate this platform has no business
# carrying. Write the number you mean in dollars.
gb_budget_line() {
  sed -n 's/^[Bb]udget:[[:space:]]*//p' | head -1 | sed 's/^[^0-9]*//' | tr -d '[:space:]' \
    | grep -E '^[0-9]+(\.[0-9]+)?$' || true
}

# ── WHICH issue is the goal — the question the sum is asked ABOUT (homelab#367) ──────────────────
#
#   goal_resolve_ancestor <slug> <issue> [max-hops]
#     → GB_GOAL  the goal issue this one belongs to ('' = none within the bound)
#       GB_HOPS  parent hops walked to reach it (0 = <issue> IS the goal)
#
# `goal_budget_read` answers "what has this goal spent". It cannot answer "which of my ancestors IS
# the goal", and until #367 the two callers answered that differently: coordinator-scan.sh climbed
# the native `parent` chain, agent-session.sh read `/issues/<n>/parent` ONCE. One hop is right for a
# direct child and wrong for everything ADR-102 files post-launch — a sprout's parent is the
# post-launch BUCKET, which carries no `Budget:` line, so the launcher pre-flight read `no-budget`
# (gate off by design) and the goal card came from the bucket (no Goal/Acceptance headings ⇒ a
# goal-blind ride, the exact forgetting FU-090 leg (c) built the card to end). Measured live on
# homelab #367 → #295 → #278: the gate was reading the bucket while goal #278 sat at $76 of $60
# `exhausted`, and #351 dispatched straight through it. Worse than "one lane is ungated": the
# DOWNWARD sum is transitive, so bucket children were adding to the sum while exempt from the gate
# that sum feeds.
#
# So the walk lives HERE, beside the sum, and both callers use it. The ⚖ line on #207 that moved
# the arithmetic into this file ("do not duplicate it, call the same helper") applies with more
# force to the question it is asked about: two components disagreeing on WHICH issue is the goal is
# the same defect class as two components summing it differently, reached one indirection earlier.
#
# STOP CONDITION: a `task/goal` label OR a machine-readable `Budget:` line — the two discriminators
# docs/agents/issue-authoring.md names ("labels route, body lines parameterise"), read in ONE
# `gh issue view --json labels,body` per hop. EITHER alone stops the walk, on purpose: the label is
# what the goal lane routes on, the `Budget:` line is what the gate spends against, and an ancestor
# carrying one without the other is a mis-authored goal that must still be FOUND — walking past a
# funded issue is precisely how money goes unwatched.
#
# THE BOUND IS 6, measured rather than guessed, and it travels with the walk instead of being
# re-argued at each caller: the reviewer's depth-≥2 bar suggested 4, until #207's dry-run walked the
# real circles#29 tree and found #75 → #47 → #18 → #29 — four hops on a tree that exists today
# (agents/replay/fixtures/harvest-deep-sprout pins it). ADR-102's other case, oracle-fleet goal-174,
# grew THREE generations post-close. Cost is two reads per hop, only until the goal answers.
#
# SILENT-SAFE, like every read on this path: an API that does not answer ends the walk with GB_GOAL
# empty, and each caller states its own degrade (the launcher keeps the direct parent for the card;
# the scan files the sprout inert). ⚠ PIPE TO A REAL jq, never `gh --jq` — the standing rule in this
# lane, and what lets a replay fixture record the actual API payload rather than a post-jq scalar.
goal_resolve_ancestor() {   # <slug> <issue> [max-hops]
  _gr_slug="$1"; _gr_cur="$2"; _gr_max="${3:-6}"
  GB_GOAL=""; GB_HOPS=0
  case "$_gr_cur" in ''|*[!0-9]*) return 0 ;; esac
  while [ -n "$_gr_cur" ] && [ "$GB_HOPS" -lt "$_gr_max" ]; do
    _gr_view="$(gh issue view "$_gr_cur" --repo "$_gr_slug" --json labels,body 2>/dev/null || true)"
    _gr_lbl="$(printf '%s' "$_gr_view" | jq -r '[.labels[].name]|index("task/goal")!=null' 2>/dev/null || echo false)"
    _gr_bud="$(printf '%s' "$_gr_view" | jq -r '.body // ""' 2>/dev/null | gb_budget_line)"
    if [ "$_gr_lbl" = "true" ] || [ -n "$_gr_bud" ]; then GB_GOAL="$_gr_cur"; return 0; fi
    _gr_par="$(gh api "repos/${_gr_slug}/issues/${_gr_cur}/parent" 2>/dev/null \
                | jq -r '.number // ""' 2>/dev/null || true)"
    case "$_gr_par" in ''|*[!0-9]*) return 0 ;; esac
    _gr_cur="$_gr_par"; GB_HOPS=$((GB_HOPS + 1))
  done
  return 0
}

goal_budget_read() {   # <slug> <goal-issue> <model> [dispatch-issue]
  _gb_slug="$1"; _gb_goal="$2"; _gb_model="$3"; _gb_dispatch="${4:-}"
  _gb_proj="${_gb_slug#*/}"
  GB_BUDGET=""; GB_SUM=0; GB_ROWS=""; GB_VERDICT="no-budget"

  # The grammar is `gb_budget_line` above — ONE home, shared with the ancestor walk (currency
  # stripping, USD, and why a € sign once disabled the whole gate are all stated there).
  # ⚠ a REAL jq, not `gh --jq` — the standing rule in this lane, and what lets the #207 replay
  # fixtures record the actual API payload rather than a post-jq scalar.
  GB_BUDGET="$(gh issue view "$_gb_goal" --repo "$_gb_slug" --json body 2>/dev/null \
    | jq -r '.body // ""' 2>/dev/null | gb_budget_line)"
  [ -n "$GB_BUDGET" ] || return 0

  # DESCENDANTS, not direct children (2026-08-05). A goal that overruns does it by sprouting
  # DEEP: the harvest links each review follow-up under the issue that produced it, so a
  # sprout of a child sits at depth 2 and a direct-children sum misses it entirely. Measured
  # live on openrouter-operator#10 the moment this was written: direct children [14,15],
  # actual descendants [14,15,17,18,21] — a gate counting 2 of 5 is not a cap.
  # The walk is a fixpoint over ONE fetch, cycle-safe by construction (a seen-set), and it
  # is what makes "an unrealistic goal keeps sprouting" a BOUNDED failure instead of a
  # silent one: every sprout in the tree spends the goal's money. Post-launch sprouts (ADR-102)
  # hang off the post-launch bucket, which is itself a sub-issue of the goal — so they are
  # descendants and this walk already counts them, which is what makes the bucket affordable.
  # NB `gh --jq` takes only an expression — it has NO --argjson (that is a jq flag); the
  # first cut used it, errored, and behind `|| echo []` made this gate pass everything.
  _gb_kids="$(gh issue list --repo "$_gb_slug" --state all --limit 300 \
    --json number,body,labels,parent 2>/dev/null \
    | python3 -c '
import json,sys
try: items = json.load(sys.stdin)
except Exception: print("[]"); sys.exit(0)
root = int(sys.argv[1])
par = {i["number"]: ((i.get("parent") or {}).get("number")) for i in items}
seen, frontier = set(), [root]
while frontier:
    cur = frontier.pop()
    for n, pn in par.items():
        if pn == cur and n not in seen:
            seen.add(n); frontier.append(n)
by = {i["number"]: i for i in items}
def names(i): return [l["name"] for l in (i.get("labels") or [])]
out = [{"n": n,
        "chars": len(by[n].get("body") or ""),
        "label": next((l for l in names(by[n]) if l.startswith("agent-budget/")), ""),
        # actual-spend accounting (operator ruling 2026-08-08): a LIVE child holds a minted key
        # that can still spend up to its cap; a RIDDEN child exposes only its harvested actual.
        "live": ("agent/in-progress" in names(by[n])),
        "ridden": (by[n].get("state") == "CLOSED"
                   or any(l in ("agent/in-progress","agent/review","agent/done","agent/error","agent/blocked")
                          for l in names(by[n])))}
       for n in sorted(seen) if n in by]
print(json.dumps(out))
' "$_gb_goal" 2>/dev/null || echo '[]')"
  # A parent that HAS descendants must not silently resolve to none — that is the gate failing open.
  if [ "$(printf '%s' "$_gb_kids" | jq -r 'length' 2>/dev/null || echo 0)" = "0" ]; then
    echo "→ Goal budget: no descendants resolved for #${_gb_goal} — nothing to sum (if that is wrong, the query is broken, not the goal)" >&2
  fi

  # ACTUAL-SPEND accounting (operator ruling 2026-08-08 — supersedes the cap-sum): the budget
  # is measured against what the subtree actually SPENT, plus real reservations. Charging a
  # settled child its full cap billed ~$1.90 of nothing per child on circles#29 (Σ caps $26
  # vs ~$2 measured spend) and refused a goal that was ~$2 into its $12. Per child:
  #   spent      = Σ agent_run_cost_usd across its rounds (the pushgateway the finalize leg
  #                pushes to is the ledger; one GET, parsed here)
  #   + its cap  IF the child is LIVE (a minted key can still spend to cap) or IS this
  #              dispatch (the key about to be minted)
  #   = its cap  IF it has ridden but the ledger has nothing (FU-131 harvest gap, killed
  #              pods — fail-CONSERVATIVE per child, never fail-open)
  #   = spent($0) for a never-ridden sibling: it gets its own gate when it dispatches.
  # If the ledger is unreachable (jail dispatch, docker mode) the WHOLE sum falls back to
  # caps — the pre-ruling behavior, loudly. Worst-case overshoot under this accounting is
  # one cap per concurrently-live ride, which is the operator's stated model (graduated
  # per-job tokens; the breaker watches actuals).
  # ⚠ The HARVEST caller passes no dispatch issue: it is asking "does this goal still have room",
  # not "may this specific ride mint a key". Same sum, one fewer reservation — advisory, as the
  # ⚖ line on #207 requires. The launcher pre-flight remains the enforcing arithmetic.
  _gb_led="$(gb_ledger "$_gb_proj")" || _gb_led=""
  [ -z "$_gb_led" ] && echo "→ Goal budget: spend ledger unreachable — falling back to CAP-sum (conservative)" >&2
  GB_SUM=0; GB_ROWS=""
  for _gb_row in $(printf '%s' "$_gb_kids" | jq -r '.[] | "\(.n):\(.chars):\(.label):\(.live):\(.ridden)"' 2>/dev/null); do
    _gb_n="${_gb_row%%:*}"; _gb_rest="${_gb_row#*:}"; _gb_c="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
    _gb_l="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"; _gb_live="${_gb_rest%%:*}"; _gb_ridden="${_gb_rest#*:}"
    _gb_c_cap="$(gb_cap "${_gb_c:-0}" "$_gb_model" "$_gb_l")"
    _gb_spent="$(printf '%s\n' "$_gb_led" | awk -v n="$_gb_n" '$1==n{print $2; exit}')"
    if [ -z "$_gb_led" ]; then
      _gb_charge="$_gb_c_cap"; _gb_why="cap (no ledger)"
    elif [ "$_gb_n" = "$_gb_dispatch" ] || [ "$_gb_live" = "true" ]; then
      _gb_charge="$(gb_add "${_gb_spent:-0}" "$_gb_c_cap")"
      _gb_why="\$${_gb_spent:-0} spent + \$${_gb_c_cap} live/dispatch reservation"
    elif [ -n "$_gb_spent" ]; then
      _gb_charge="$_gb_spent"; _gb_why="settled, actual spend"
    elif [ "$_gb_ridden" = "true" ]; then
      _gb_charge="$_gb_c_cap"; _gb_why="cap (ridden, no ledger entry — FU-131 gap, conservative)"
    else
      _gb_charge="0"; _gb_why="never ridden — gated at its own dispatch"
    fi
    GB_SUM="$(gb_add "$GB_SUM" "${_gb_charge:-0}")"
    GB_ROWS="${GB_ROWS}    #${_gb_n} → \$${_gb_charge} (${_gb_why})\n"
  done

  if [ "$(python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$GB_SUM" "$GB_BUDGET")" = "1" ]; then
    GB_VERDICT="exhausted"
  else
    GB_VERDICT="within"
  fi
  return 0
}
