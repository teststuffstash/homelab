#!/bin/sh
# PreToolUse gate on Edit/Write/MultiEdit/Bash: MINTING a new FU id is denied ONCE per id per
# session, with the tracker's own bar as the reason; the same edit retried passes. Extending,
# archiving and pointer edits (ids that already exist) are untouched.
# Operator 2026-10-02: four ids minted in one session for work that could have started that day
# (FU-300 went to a background subagent only after the operator asked) — the rule lived in
# docs/follow-ups.md §THE BAR and in memory, and neither fired at the moment of filing. No clicks
# (an `ask` was rejected), no extra text in the tracker (a `Why later:` field was rejected): one
# denial that makes the bar the next thing read. If it does not work, replace it — it is a trial.
# No jq: runs on the host too. Detection reads the raw hook JSON: an open-item header `[ ] **FU-NNN**`
# whose id heads no item in the tracker or its archive is a mint.
input=$(cat)
case "$input" in *follow-ups.md*) ;; *) exit 0 ;; esac   # not `printf | grep -q` — scripts/sigpipe-lint.py
dir="${CLAUDE_PROJECT_DIR:-.}/docs"
[ -f "$dir/follow-ups.md" ] || exit 0
new=""
# Item HEADERS only, on both sides: the counter line bolds the next free id (`Next free id:
# **FU-NNN**`), so a bare `**FU-NNN**` match would read every mint as an existing id.
for id in $(printf '%s' "$input" | grep -oE '\[ \] \*\*FU-[0-9]{3}\*\*' | grep -oE 'FU-[0-9]{3}' | sort -u); do
  grep -qE "^[[:space:]]*- (\[.\] )?\*\*$id\*\*" "$dir/follow-ups.md" "$dir/follow-ups-archive.md" 2>/dev/null || new="$new $id"
done
[ -n "$new" ] || exit 0
sid=$(printf '%s' "$input" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
state="${TMPDIR:-/tmp}/fu-mint-gate-${sid:-nosession}"
mkdir -p "$state" 2>/dev/null
first=""
for id in $new; do [ -e "$state/$id" ] || { first="$first $id"; : > "$state/$id"; }; done
[ -n "$first" ] || exit 0
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Minting%s is held once (fu-mint-gate, operator trial 2026-10-02). The tracker is for work someone must do LATER (docs/follow-ups.md THE BAR). Before retrying: (1) Can it be done now? Context in hand and safe now = DO IT - and doing it includes dispatching a background subagent (Agent tool, run_in_background) that builds the PR in a clone; a bounded, decided change is never an FU. (2) Is there a next action someone could start today? If not, it is not an FU: a ruling or finding goes to the owning doc, the session story to TICK-LOG, an undecided fork to docs/spikes/. (3) Does an existing item own it? Extend that one (and re-run test 1). Only if it is genuinely blocked (an operator decision, a live window, a dependency) retry the same edit - the retry passes."}}\n' "$first"
