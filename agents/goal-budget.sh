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

goal_budget_read() {   # <slug> <goal-issue> <model> [dispatch-issue]
  _gb_slug="$1"; _gb_goal="$2"; _gb_model="$3"; _gb_dispatch="${4:-}"
  _gb_proj="${_gb_slug#*/}"
  GB_BUDGET=""; GB_SUM=0; GB_ROWS=""; GB_VERDICT="no-budget"

  # Currency symbols are stripped, and the NUMBER IS READ AS USD — the estimator prices in USD
  # (cap_usd) because OpenRouter does. A `Budget: €5` therefore funds $5, not €5. That is a
  # deliberate, stated approximation rather than a silent one: the alternative is an FX rate
  # this platform has no business carrying. Write the number you mean in dollars.
  # (Before this, a € sign parsed to empty and DISABLED the gate — fail-open, found 2026-08-05.)
  # ⚠ a REAL jq, not `gh --jq` — the standing rule in this lane, and what lets the #207 replay
  # fixtures record the actual API payload rather than a post-jq scalar.
  GB_BUDGET="$(gh issue view "$_gb_goal" --repo "$_gb_slug" --json body 2>/dev/null \
    | jq -r '.body // ""' 2>/dev/null | sed -n 's/^[Bb]udget:[[:space:]]*//p' | head -1 \
    | sed 's/^[^0-9]*//' | tr -d '[:space:]' | grep -E '^[0-9]+(\.[0-9]+)?$' || true)"
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
