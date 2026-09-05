#!/usr/bin/env bash
# goal-lint — the consumer card's rules as a deterministic check over a Goal and its sub-issue
# tree (docs/agents/issue-authoring.md §Creating a Goal — the consumer card). Operator ruling
# 2026-09-01: Goals are authored from JAILS (not the in-cluster decompose play) and still arrive
# malformed (oracle-fleet#326: no goal branch, children without a task/* class, no ordering
# edges) — so the mistakes are caught at the surface the author touches, before anything is
# queued, instead of one ride later. Pure `gh` REST reads — bash + gh + jq only, all three in
# the jail image, so it needs NO devbox:
#   homelab jail:  devbox run goal-lint -- <owner/repo> <goal-number>
#   stack jail:    bash /workspace/homelab/scripts/goal-lint.sh <owner/repo> <goal-number>
# (never `devbox run` in a stack jail's homelab clone — that materializes homelab's whole
# closure; operator, 2026-09-01). The stack's own token suffices: it reads only that repo.
#
# THIRD READER OF classify_touches() (homelab#1207, #1102 leg 1 sequenced half): the tree walk
# already reads each leaf's `Touches:` line, so it also classifies it here — a leaf whose
# footprint lands in the ❌ operator-author set or on a pin-only GUARDED path (#309) is a FAIL,
# not a WARN: no worker can ever land it as a PR, and the fix belongs at authoring time, not one
# scan-log line later (#1056's cost). `agents/footprint.sh` is sourced (bash-only, no devbox
# needed) rather than re-declared; the GUARDED set is read from `scripts/pin-only-lint.sh`'s
# `GUARDED=` line the same way `coordinator-scan.sh`'s `guarded_paths()` does — one home, a third
# reader, never a second regex.
#
#   exit 0  — no FAIL (WARN lines are advice)
#   exit 1  — at least one FAIL: fix the issue, never the machinery
#   exit 2  — probe failure (unreadable goal/tree) — say so, never report clean
set -uo pipefail

slug="${1:-}"; goal="${2:-}"
[ -n "$slug" ] && [ -n "$goal" ] || { echo "usage: goal-lint.sh <owner/repo> <goal-number>" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=agents/footprint.sh
. "$HERE/../agents/footprint.sh"
export CLASSIFY_CODEOWNERS="$HERE/../CODEOWNERS"

fails=0; warns=0; incomplete=0
fail() { echo "FAIL: $*"; fails=$((fails+1)); }
warn() { echo "WARN: $*"; warns=$((warns+1)); }
ok()   { echo "ok:   $*"; }

api() { gh api "$@" 2>/dev/null; }
line() { printf '%s\n' "$1" | grep -m1 -E "^[[:space:]]*$2:[[:space:]]*" | sed -E "s/^[[:space:]]*$2:[[:space:]]*//; s/[[:space:]]+$//"; }
count_lines() { printf '%s\n' "$1" | grep -cE "^[[:space:]]*$2:" || true; }
branch_exists() { api "repos/$slug/branches/$(printf '%s' "$1" | sed 's|/|%2F|g')" --jq .name >/dev/null; }

# ── pin-only GUARDED paths (homelab#309) — ONE home: scripts/pin-only-lint.sh's `GUARDED=` line.
# Same read shape as `coordinator-scan.sh`'s `guarded_paths()`: grep the line, eval it, split the
# `|`-alternation into plain paths. Empty output = could not read (never "none guarded").
guarded_paths() {
  local gline="" GUARDED=""
  [ -r "$HERE/pin-only-lint.sh" ] && gline="$(grep -m1 '^GUARDED=' "$HERE/pin-only-lint.sh" || true)"
  [ -n "$gline" ] || return 1
  eval "$gline" || return 1
  [ -n "$GUARDED" ] || return 1
  printf '%s\n' "$GUARDED" | tr '|' '\n' | sed 's/\\\(.\)/\1/g' | grep -v '^[[:space:]]*$'
}
GUARDED_PATHS="$(guarded_paths || true)"
[ -n "$GUARDED_PATHS" ] || warn "pin-only GUARDED set unreadable at $HERE/pin-only-lint.sh — cannot check Touches against it (homelab#309)"

# ── the Goal ────────────────────────────────────────────────────────────────────────────────
gj="$(api "repos/$slug/issues/$goal")" || { echo "PROBE-FAIL: cannot read $slug#$goal" >&2; exit 2; }
jq -e . >/dev/null 2>&1 <<<"$gj" || { echo "PROBE-FAIL: unparseable issue payload" >&2; exit 2; }
title="$(jq -r .title <<<"$gj")"; body="$(jq -r '.body // ""' <<<"$gj")"
labels="$(jq -r '[.labels[].name] | join(" ")' <<<"$gj")"; utype="$(jq -r .user.type <<<"$gj")"
has_label() { printf ' %s ' "$labels" | grep -q " $1 "; }
echo "goal-lint — $slug#$goal: $title"

has_label task/goal && ok "task/goal label" || fail "missing \`task/goal\` — nothing in the goal lane sees it (burn-down, checkpoint, terminals all key on the label)"
printf '%s' "$title" | grep -qE '^Goal:' || warn "title should read \`Goal: <intent>\` (the type is capitalised; lowercase 'goal' is retired vocabulary — docs/glossary.md)"

nb="$(count_lines "$body" Budget)"
if [ "$nb" -eq 1 ]; then
  bv="$(line "$body" Budget)"; printf '%s' "$bv" | grep -qE '^[0-9]+(\.[0-9]+)?$' && ok "Budget: $bv" || fail "Budget: '$bv' is not a bare number (the launcher parses it as USD)"
elif [ "$nb" -eq 0 ]; then fail "no \`Budget:\` line — the launcher pre-flight and the registry both read it (unfunded-unknown, not funded-zero)"
else fail "$nb \`Budget:\` lines — exactly one is the machine truth (#29's trap: €12 in prose, \$16 in the footer)"; fi

va="$(line "$body" Verdict-authority)"
case "$va" in
  human) ok "Verdict-authority: human";;
  kpi)   warn "Verdict-authority: kpi is refused with a report line until the KPI unit exists — the terminal will not fire";;
  "")    fail "no \`Verdict-authority:\` line (human | kpi) — the goal can never reach a terminal";;
  *)     fail "Verdict-authority: '$va' — must be \`human\` or \`kpi\`";;
esac

pl="$(line "$body" Production-leg)"
[ -n "$pl" ] && ok "Production-leg: present" || fail "no \`Production-leg:\` line — a goal with no production leg can only be assembly-complete, never validated"

gbase="$(line "$body" Base)"
if [ -z "$gbase" ]; then
  fail "no \`Base:\` line — children inherit nothing and dispatch against master silently (oracle-fleet#281); the decompose clause refuses it (#1053)"
elif [ "$gbase" = master ]; then
  warn "Base: master — legitimate only with a stated reason; a direct-master Goal is more likely a stint (or a v1.3 themed Goal whose level-2 themes carry goal/<n>-<theme> branches)"
elif printf '%s' "$gbase" | grep -qE "^goal/${goal}-[a-z0-9][a-z0-9.-]*$"; then
  if branch_exists "$gbase"; then ok "Base: $gbase (branch exists)"; else
    fail "Base: $gbase — the branch does NOT exist. IL-G02: the AUTHOR cuts it from master before queueing anything; nothing in the machinery creates it (the first child ride fails at clone otherwise)"; fi
else
  fail "Base: '$gbase' — must be \`master\` or \`goal/${goal}-<slug>\` (this goal's own number)"
fi

printf '%s\n' "$body" | grep -qE '^##+[[:space:]]*Goal\b' && ok "## Goal section" || fail "no \`## Goal\` section (intent + the acid test)"
if printf '%s\n' "$body" | grep -qiE '^##+[[:space:]]*Acceptance'; then
  printf '%s\n' "$body" | grep -qE '^[[:space:]]*[0-9]+\.' && ok "## Acceptance (numbered)" || warn "## Acceptance has no numbered items — each criterion must be checkable"
else fail "no \`## Acceptance\` section"; fi
printf '%s\n' "$body" | grep -qiE '^##+[[:space:]]*Out of scope' && ok "## Out of scope" || warn "no \`## Out of scope\` — name it, or sprouts drift in"
printf '%s\n' "$body" | grep -qE '^[[:space:]]*Assembly-for:' && fail "\`Assembly-for:\` belongs on the ASSEMBLY PR body, never the goal (IL-T18 keys on the PR)"
has_label agent/error && fail "agent/error on the goal — human-first breaker; clear it before anything runs"
[ "$utype" = Bot ] && warn "authored by a Bot — breaker #1: the scan refuses a Bot-queued goal (a jail session writes as the operator and is fine)"

# ── the tree ────────────────────────────────────────────────────────────────────────────────
leaves=0; containers=0; edges=0; closed=0
declare -a LEAF_NUMS=()
walk() {  # walk <issue-number> <depth>
  local n="$1" d="$2" kids ij t b l par
  # An unreadable read here is a PROBE FAILURE, not a lint verdict: the walk continues (report
  # everything else it CAN see) but the run may never report clean — the exit-code contract
  # (line 16) says exit 2, and `incomplete` is what carries that to the exit block. walk() runs
  # in the main shell (no pipe/subshell), so the flag survives the recursion.
  kids="$(api "repos/$slug/issues/$n/sub_issues?per_page=100" --jq '.[].number')" || { warn "#$n: sub-issues unreadable"; incomplete=1; return; }
  for k in $kids; do
    ij="$(api "repos/$slug/issues/$k")" || { warn "#$k: unreadable"; incomplete=1; continue; }
    # Closed descendants are finished work (or absorbed sprouts): the burn-down counts them,
    # this lint does not judge them.
    [ "$(jq -r .state <<<"$ij")" = "open" ] || { closed=$((closed+1)); continue; }
    t="$(jq -r .title <<<"$ij")"; b="$(jq -r '.body // ""' <<<"$ij")"; l="$(jq -r '[.labels[].name] | join(" ")' <<<"$ij")"
    [ "$(count_lines "$b" Budget)" -eq 0 ] || fail "#$k carries a \`Budget:\` line — the ancestor walk stops at it and would read this child as its own goal"
    # Same probe-failure contract as kids/ij above (round-3 finding): an unreadable sub-issue
    # COUNT would otherwise default par=0, misclassify a container as a leaf AND skip the
    # recursion into its subtree — a whole unwalked branch reported clean.
    par="$(api "repos/$slug/issues/$k/sub_issues?per_page=1" --jq 'length')" || { warn "#$k: sub-issue count unreadable"; incomplete=1; par=0; }; par="${par:-0}"
    cb="$(line "$b" Base)"
    if [ -n "$cb" ]; then
      if [ "$cb" = "$gbase" ]; then :; elif printf '%s' "$cb" | grep -qE "^goal/${goal}-" && branch_exists "$cb"; then :;
      else fail "#$k Base: '$cb' — must equal the goal's Base ($gbase) or name an EXISTING goal/${goal}-<theme> branch"; fi
    fi
    # A CONTAINER (theme / post-launch bucket) is label-inert by design; a WORK ITEM may also
    # have sub-issues — its sprouts bind under their origin (lineage rule 8) — so "has children"
    # alone says nothing. Work item = carries agent-fix; container = has children and does not.
    if printf ' %s ' "$l" | grep -q ' agent-fix '; then is_work=1; else is_work=0; fi
    # Machine/seat containers are recognisable by title even before they have children: the
    # IL-T17 post-launch bucket, v1.3 themes, stints, retro batches.
    if printf '%s' "$t" | grep -qiE '^(post-launch|theme|stint|retro-batch):'; then is_named_container=1; else is_named_container=0; fi
    if { [ "$par" -gt 0 ] || [ "$is_named_container" -eq 1 ]; } && [ "$is_work" -eq 0 ]; then
      containers=$((containers+1))
      # a post-launch bucket's children base master by design (ADR-102) — no Base: expected
      if [ -z "$cb" ] && ! printf '%s' "$t" | grep -qiE '^post-launch:'; then warn "#$k (container, depth $d) has no \`Base:\` — its children inherit nothing"; fi
      printf ' %s ' "$l" | grep -qE ' agent/(queued|in-progress) ' && fail "#$k is a container (sub-issues, no agent-fix) but carries a dispatch label — containers stay label-inert"
      [ "$d" -lt 3 ] && walk "$k" $((d+1))
    else
      leaves=$((leaves+1)); LEAF_NUMS+=("$k")
      [ -n "$cb" ] || fail "#$k (work item) has no \`Base:\` — it will fork from master and its diff will swallow the goal branch"
      printf '%s\n' "$b" | grep -qE '^[[:space:]]*Touches:' || warn "#$k has no \`Touches:\` — footprint is EXCLUSIVE (serial with every sibling)"
      ctouches="$(line "$b" Touches)"
      if [ -n "$ctouches" ]; then
        if [ "$(classify_touches "$ctouches")" = "codeowner-author" ]; then
          fail "#$k Touches lands in the operator-author set ($ctouches) — no worker can deliver it; split that half out or hand it to the seat (iac-lane.md §The platform lane)"
        fi
        if [ -n "$GUARDED_PATHS" ]; then
          cghit=""
          while IFS= read -r gpath; do
            [ -n "$gpath" ] || continue
            fp_conflict_strict "$ctouches" "$gpath" && cghit="${cghit} ${gpath}"
          done <<EOF_CGUARD
$GUARDED_PATHS
EOF_CGUARD
          [ -n "$cghit" ] && fail "#$k Touches lands on pin-only GUARDED${cghit} — a PR may carry only a pin line there; operator push to master (homelab#309)"
        fi
      fi
      [ "$is_work" -eq 1 ] || warn "#$k lacks \`agent-fix\` — invisible to every dispatch clause until labelled"
      if ! printf ' %s ' "$l" | grep -qE ' task/[a-z]+ '; then
        if printf '%s' "$t" | grep -qiE '\b(build|harness|e2e|as-code|implement|scaffold|wire|add)\b'; then
          warn "#$k has no \`task/*\` class and reads build-shaped — it would ride \`fix.yaml\` (a bug-hunter's brief); label \`task/build\` (the sleep#48 trap)"
        else
          echo "info: #$k has no \`task/*\` class — defaults to \`task/fix\` (fine for a defect)"
        fi
      fi
      printf '%s\n' "$b" | grep -qiE 'acceptance|deliverable|done when|expected' || warn "#$k states no acceptance/deliverable anywhere in its body — one deliverable with its own acceptance"
      e="$(api "repos/$slug/issues/$k/dependencies/blocked_by?per_page=50" --jq 'length')"; edges=$((edges + ${e:-0}))
      [ "$par" -gt 0 ] && [ "$d" -lt 3 ] && walk "$k" $((d+1))
    fi
  done
}
walk "$goal" 1

if [ "$leaves" -eq 0 ] && [ "$containers" -eq 0 ]; then
  ok "no children yet — the decompose clause authors them when the goal is queued (agent-fix + agent/queued on the GOAL)"
else
  ok "tree: $leaves open work item(s), $containers container(s), $closed closed descendant(s) skipped"
  has_label agent/queued && fail "agent/queued on a PRE-DECOMPOSED goal — this summons the decomposer against children you already authored; queue the children, leave the goal at task/goal"
  [ "$leaves" -ge 2 ] && [ "$edges" -eq 0 ] && warn "$leaves leaves and ZERO blockedBy edges among them — ordering is not encoded (body lines gate nothing); overlapping footprints serialize in ARBITRARY order"
fi

echo "goal-lint: $fails FAIL, $warns WARN"
# Probe failure trumps a clean count: a partial tree walk (rate-limit/5xx mid-recursion) must
# never report the tree as verified — say so and exit 2, per the header's exit-code contract.
if [ "$incomplete" -ne 0 ]; then
  echo "PROBE-FAIL: the tree walk was INCOMPLETE (unreadable sub-issue listing or child above) — a partial read is not a clean tree" >&2
  exit 2
fi
[ "$fails" -eq 0 ] && exit 0 || exit 1
