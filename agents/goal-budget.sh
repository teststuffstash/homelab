# goal-budget.sh — the goal `Budget:` read, ONE implementation, two callers (ADR-102, homelab#207).
#
# ⚠ BASH ONLY, refused loudly otherwise (the 2026-08-12 06:24Z ruling: a probe one shebang from
# live ran this under dash and the budget guards failed OPEN — a mis-summed budget admits rides
# against money that is gone; a refusal only defers one dispatch). Sourcing makes the shebang
# decorative, so the guard is a runtime check, not a header.
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
#       GB_VERDICT  within | exhausted | no-budget | terminal
#
# `no-budget` is NOT `within`. The launcher has always treated an unparseable `Budget:` as "gate
# off" (it is the pre-ADR-102 world, where goals were optional); the harvest treats it as "no
# self-queue right", because ADR-102 makes the funded goal the thing that GRANTS the right and an
# unreadable grant is not a grant. Same number, different fail direction, each stated at its caller.
#
# `terminal` is NOT `within` either — it is the VERDICT exemption (homelab#509): the goal carries a
# terminal label (goal/validated | goal/reverted | goal/abandoned), so the gate declines to enforce
# its `Budget:` at all. After a verdict lands the tree's remaining open work is ordinary master-lane
# work, and the budget line that survived the goal it was scoped to must not keep spending authority
# over it. The launcher logs `terminal` as pass-through; the harvest never sees it — since ADR-106
# the harvest reads the goal's issue STATE (dead goal ⇒ inert), not this verdict, so the two callers
# agree by different routes.
#
# TWO I/O SEAMS, on purpose: `gb_ledger` (the spend ledger) and `gb_cap` (the estimator). Both are
# plain functions a caller may redefine — which is how agents/replay/fixtures/harvest-* replay the
# real arithmetic against a recorded world with no network and no estimator drift in the action
# stream. Everything between them is pure shell over one `gh issue list`.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "goal-budget.sh: bash required — budget guards FAIL OPEN under sh/dash (06:24Z ruling, homelab#377 class); refusing" >&2
  return 1 2>/dev/null || exit 1
fi
GB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# The spend ledger: what the subtree ACTUALLY spent. The pushgateway the finalize leg pushes to is
# the record; one GET, parsed to `<project> <issue> <usd>` lines (all projects, not filtered —
# #917: cross-repo children need their own project's spend). Empty output = unreachable, and the
# caller degrades to the conservative cap-sum (see the charge loop).
gb_ledger() {   # gb_ledger
  _gb_pgw="${AGENT_PUSHGATEWAY_URL:-http://prometheus-pushgateway.monitoring.svc.cluster.local:9091}"
  _gb_raw="$(curl -m 30 -fsS "${_gb_pgw}/metrics" 2>&1)" || {
    _gb_rc=$?
    case $_gb_rc in
      28) echo "→ gb_ledger: TIMED OUT after 30s (payload likely large) — falling back to cap-sum" >&2;;
      *)  echo "→ gb_ledger: UNREACHABLE (curl exit $_gb_rc) — falling back to cap-sum" >&2;;
    esac
    return 1
  }
  printf '%s\n' "$_gb_raw" | sort -u \
    | awk '/^agent_run_cost_usd\{/ {
        if (match($0, /project="([^"]+)"/)) { proj=substr($0, RSTART+9, RLENGTH-10) }
        if (match($0, /issue="([0-9]+)"/)) { iss=substr($0, RSTART+7, RLENGTH-8);
          sum[proj, iss] += $NF } }
      END { for (k in sum) { split(k, a, SUBSEP); printf "%s %s %.4f\n", a[1], a[2], sum[k] } }'
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
# STOP CONDITION: `task/goal` label stops unconditionally — the goal lane routes on it.
# A machine-readable `Budget:` line stops the walk ONLY when the issue has NO native parent
# to climb past (homelab#367's funded-but-unlabelled goal case preserved). An ordinary work
# item with its own per-issue `Budget:` line AND a native parent must NOT be mistaken for a
# goal — the walk climbs past it to the real goal ancestor (homelab#1392).
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
    # `task/goal` label stops unconditionally (homelab#367).
    if [ "$_gr_lbl" = "true" ]; then GB_GOAL="$_gr_cur"; return 0; fi
    # `Budget:` line stops only when the issue has NO native parent to climb past
    # (homelab#367's funded-but-unlabelled goal preserved; homelab#1392: an ordinary
    # work item with its own `Budget:` line must not be mistaken for a goal).
    _gr_par="$(gh api "repos/${_gr_slug}/issues/${_gr_cur}/parent" 2>/dev/null \
                | jq -r '.number // ""' 2>/dev/null || true)"
    if [ -n "$_gr_bud" ] && [ -z "$_gr_par" ]; then GB_GOAL="$_gr_cur"; return 0; fi
    case "$_gr_par" in ''|*[!0-9]*) return 0 ;; esac
    _gr_cur="$_gr_par"; GB_HOPS=$((GB_HOPS + 1))
  done
  return 0
}

goal_budget_read() {   # <slug> <goal-issue> <model> [dispatch-issue]
  _gb_slug="$1"; _gb_goal="$2"; _gb_model="$3"; _gb_dispatch="${4:-}"
  GB_BUDGET=""; GB_SUM=0; GB_ROWS=""; GB_VERDICT="no-budget"

  # ONE view answers two questions now: the `Budget:` line (the grammar is `gb_budget_line` above —
  # ONE home, shared with the ancestor walk; currency stripping, USD, and why a € sign once disabled
  # the whole gate are all stated there) AND the goal's verdict labels.
  # ⚠ a REAL jq, not `gh --jq` — the standing rule in this lane, and what lets the #207 replay
  # fixtures record the actual API payload rather than a post-jq scalar. `|| true` keeps the
  # pre-existing fail-soft: the ORIGINAL read piped straight into `gb_budget_line` (exit 0 via
  # `|| true`), so a transient probe failure degraded to `no-budget` instead of aborting the ride
  # under `set -e`; the bare assignment would now propagate gh's non-zero and abort the launcher.
  _gb_view="$(gh issue view "$_gb_goal" --repo "$_gb_slug" --json body,labels 2>/dev/null || true)"

  # TERMINAL VERDICT FIRST (homelab#509) — a goal a human has already ruled terminal gates NOTHING.
  # `goal/validated` / `goal/reverted` / `goal/abandoned` are ADR-102 terminals: after one lands,
  # the tree's remaining open work is ordinary master-lane work, and the `Budget:` line that
  # survived the goal it was scoped to must not keep spending authority over it. Checked HERE, ahead
  # of the descendant walk, on purpose: it is the same one-probe short-circuit the harvest's dead-
  # goal read gets (harvest-goal-closed pins it), so a dead goal costs nothing to discover. NOT in
  # `goal_resolve_ancestor`: that walk is shared with the goal-card injection and the scan's harvest
  # disposition, and making it skip terminal goals would silently change what those two see. The
  # walk should still FIND the goal; the gate declines to enforce it.
  _gb_term="$(printf '%s' "$_gb_view" | jq -r '([.labels[]? | select(.name == "goal/validated" or .name == "goal/reverted" or .name == "goal/abandoned")] | length)' 2>/dev/null || echo 0)"
  if [ "${_gb_term:-0}" != "0" ]; then
    GB_VERDICT="terminal"
    return 0
  fi

  GB_BUDGET="$(printf '%s' "$_gb_view" | jq -r '.body // ""' 2>/dev/null | gb_budget_line)"
  [ -n "$GB_BUDGET" ] || return 0

  # DESCENDANTS, not direct children (2026-08-05). A goal that overruns does it by sprouting
  # DEEP: the harvest links each review follow-up under the issue that produced it, so a
  # sprout of a child sits at depth 2 and a direct-children sum misses it entirely. Measured
  # live on openrouter-operator#10 the moment this was written: direct children [14,15],
  # actual descendants [14,15,17,18,21] — a gate counting 2 of 5 is not a cap.
  # The walk is a BFS over the sub-issues API (gh api repos/<r>/issues/<n>/sub_issues), which
  # returns repo-qualified children — the fix for #917: cross-repo descendants now appear in
  # GB_ROWS and their spend sums into GB_SUM. Each child is identified by its qualified
  # <owner>/<repo>#<number> identity, so a foreign parent number can never alias a local one.
  # Cycle-safe by construction (a seen-set over qualified IDs), bounded at depth 6 (same bound
  # as the ancestor walk). If any sub_issues API call fails (root or non-root), the walk
  # flags it as degraded and the caller falls back to cap-sum — under-counting descendant
  # spend *lowers* GB_SUM, which admits *more* rides, not fewer, so a degraded walk must not
  # remain silent.
  _gb_kids="$(python3 -c '
import json, sys, subprocess

def gh_sub_issues(repo, number):
    """Call gh api repos/<repo>/issues/<n>/sub_issues, return list or None on failure."""
    try:
        res = subprocess.run(
            ["gh", "api", "repos/{}/issues/{}/sub_issues".format(repo, number)],
            capture_output=True, text=True, timeout=30
        )
        if res.returncode != 0:
            return None
        return json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return None

def repo_of(issue):
    return issue["repository_url"].split("/repos/", 1)[1]

def names(issue):
    return [l["name"] for l in (issue.get("labels") or [])]

root_repo = sys.argv[1]
root_num = int(sys.argv[2])
max_depth = int(sys.argv[3]) if len(sys.argv) > 3 else 6

seen = set()
frontier = [(root_repo, root_num, 0)]
nodes = {}
degraded = []

while frontier:
    repo, num, depth = frontier.pop(0)
    nid = "{}#{}".format(repo, num)
    if nid in seen:
        continue
    seen.add(nid)
    children = gh_sub_issues(repo, num)
    if children is None:
        degraded.append(nid)
        continue
    for child in children:
        cr = repo_of(child)
        cn = child["number"]
        cnid = "{}#{}".format(cr, cn)
        if cnid not in seen:
            nodes[cnid] = child
            if depth < max_depth:
                frontier.append((cr, cn, depth + 1))

out = []
for nid, issue in sorted(nodes.items(), key=lambda x: (x[0].split("#")[0], int(x[0].split("#")[1]))):
    n = int(nid.split("#")[1])
    out.append({
        "n": n,
        "repo": nid.split("#")[0],
        "chars": len(issue.get("body") or ""),
        "label": next((l for l in names(issue) if l.startswith("agent-budget/")), ""),
        "live": ("agent/in-progress" in names(issue)),
        "ridden": (issue.get("state") == "CLOSED"
                   or any(l in ("agent/in-progress","agent/review","agent/done","agent/error","agent/blocked")
                          for l in names(issue)))
    })

result = {
    "degraded": len(degraded) > 0,
    "children": out
}
print(json.dumps(result))
' "$_gb_slug" "$_gb_goal" 6 2>/dev/null || echo '{\"degraded\":false,\"children\":[]}')"
  # Check for degraded walk (any sub_issues fetch failed — root or non-root).
  _gb_walk_degraded="$(printf '%s' "$_gb_kids" | jq -r '.degraded // false' 2>/dev/null || echo false)"
  GB_WALK_DEGRADED="$_gb_walk_degraded"

  # A parent that HAS descendants must not silently resolve to none — that is the gate failing open.
  if [ "$(printf '%s' "$_gb_kids" | jq -r '.children | length' 2>/dev/null || echo 0)" = "0" ]; then
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
  # #917: ledger now returns <project> <issue> <usd> lines (all projects), and each child carries
  # its repo. Spend is looked up by project+issue, so cross-repo children find their own spend.
  _gb_led="$(gb_ledger)" || _gb_led=""
  GB_LEDGER_DEGRADED="false"
  [ -z "$_gb_led" ] && GB_LEDGER_DEGRADED="true" && echo "→ Goal budget: spend ledger unreachable — falling back to CAP-sum (conservative)" >&2

  # If the descendant walk is degraded (any sub_issues fetch failed), fall back to conservative cap-sum.
  # Under-counting descendant spend *lowers* GB_SUM, which admits *more* rides; degraded must not be silent.
  if [ "$_gb_walk_degraded" = "true" ]; then
    echo "→ Goal budget: descendant walk degraded (fetch failure in tree) — falling back to CAP-sum (conservative)" >&2
    GB_SUM=0; GB_ROWS=""
    for _gb_row in $(printf '%s' "$_gb_kids" | jq -r '.children[] | "\(.n):\(.repo):\(.chars):\(.label):\(.live):\(.ridden)"' 2>/dev/null); do
      _gb_n="${_gb_row%%:*}"; _gb_rest="${_gb_row#*:}"
      _gb_repo="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
      _gb_c="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
      _gb_l="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
      _gb_live="${_gb_rest%%:*}"; _gb_ridden="${_gb_rest#*:}"
      _gb_c_cap="$(gb_cap "${_gb_c:-0}" "$_gb_model" "$_gb_l")"
      _gb_charge="$_gb_c_cap"; _gb_why="cap (walk degraded)"
      GB_SUM="$(gb_add "$GB_SUM" "${_gb_charge:-0}")"
      GB_ROWS="${GB_ROWS}    ${_gb_repo}#${_gb_n} → \$${_gb_charge} (${_gb_why})\n"
    done
    GB_VERDICT="exhausted"
    [ "$(python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$GB_SUM" "$GB_BUDGET")" = "1" ] || GB_VERDICT="within"
    return 0
  fi

  GB_SUM=0; GB_ROWS=""
  for _gb_row in $(printf '%s' "$_gb_kids" | jq -r '.children[] | "\(.n):\(.repo):\(.chars):\(.label):\(.live):\(.ridden)"' 2>/dev/null); do
    _gb_n="${_gb_row%%:*}"; _gb_rest="${_gb_row#*:}"
    _gb_repo="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
    _gb_c="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
    _gb_l="${_gb_rest%%:*}"; _gb_rest="${_gb_rest#*:}"
    _gb_live="${_gb_rest%%:*}"; _gb_ridden="${_gb_rest#*:}"
    _gb_c_cap="$(gb_cap "${_gb_c:-0}" "$_gb_model" "$_gb_l")"
    _gb_proj="${_gb_repo#*/}"
    _gb_spent="$(printf '%s\n' "$_gb_led" | awk -v p="$_gb_proj" -v n="$_gb_n" '$1==p && $2==n{print $3; exit}')"
    if [ -z "$_gb_led" ]; then
      _gb_charge="$_gb_c_cap"; _gb_why="cap (no ledger)"
    elif [ "$_gb_live" = "true" ] || { [ -n "$_gb_dispatch" ] && [ "$_gb_n" = "$_gb_dispatch" ] && [ "$_gb_repo" = "$_gb_slug" ]; }; then
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
    GB_ROWS="${GB_ROWS}    ${_gb_repo}#${_gb_n} → \$${_gb_charge} (${_gb_why})\n"
  done

  if [ "$(python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$GB_SUM" "$GB_BUDGET")" = "1" ]; then
    GB_VERDICT="exhausted"
  else
    GB_VERDICT="within"
  fi
  return 0
}
