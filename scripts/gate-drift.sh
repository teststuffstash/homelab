#!/usr/bin/env bash
# gate-drift — did this PR WEAKEN a gate? A REPORT for the reviewer's gate-change lens, never a
# gate itself (ADR-142, the scripts/ un-gating trial, 2026-09-28). CI executes scripts/** from the
# PR branch, so a PR that edits a check is judged by its own edited check. This step re-runs the
# judgement with MASTER's side of the edit, two ways:
#
#   (A) old gate × new content — every changed/deleted non-test script under scripts/ is put back
#       to its BASE version in a scratch worktree of the PR, and every CI command that exercises
#       it runs there. A FAIL here while the PR's own run is green = the PR's content relies on
#       the edit to pass: a weakening, or a deliberate rule change the PR body must justify.
#   (B) old tests × new script — every changed/deleted TEST (…-test.sh, …self-test…, fixtures/)
#       is put back to its BASE version, and the commands exercising those tests run against the
#       PR's scripts. A FAIL = a case master's tests pinned no longer holds — the signature of a
#       gate loosened together with the test that would have caught it.
#
#   bash gate-drift.sh <base-sha>        (CI runs MASTER's copy of this file — see ci.yaml)
#
# SELF-GATING: the CI step extracts this script from the BASE commit (`git show $BASE:…`), so a PR
# cannot neuter the detector by editing it; an edit takes effect only once merged. For the same
# reason every command list (ci.yaml, diff-ci.sh's MAP, devbox.json task bodies) is read from
# BASE. Only commands CI already runs are ever executed (never a seat task like node-maintenance).
#
# Output: one block between GATE-DRIFT-BEGIN / GATE-DRIFT-END on stdout (the reviewer greps the
# job log for it) and the same text in $GITHUB_STEP_SUMMARY. Always exits 0 — a report whose
# failure reds the PR would be a gate, and this trial's gate is the reviewer.
set -uo pipefail
BASE="${1:?usage: gate-drift.sh <base-sha>}"
REPO="$(git rev-parse --show-toplevel)"
cd "$REPO" || exit 0
PER_CMD_TIMEOUT="${GATE_DRIFT_TIMEOUT:-900}"
MAX_CMDS="${GATE_DRIFT_MAX_CMDS:-8}"
T="$(mktemp -d)"; trap 'git -C "$REPO" worktree remove --force "$T/a" >/dev/null 2>&1; git -C "$REPO" worktree remove --force "$T/b" >/dev/null 2>&1; rm -rf "$T"' EXIT
OUT="$T/report.md"

say() { printf '%s\n' "$*" >>"$OUT"; }
finish() {
  { echo "GATE-DRIFT-BEGIN base=${BASE:0:12} head=$(git rev-parse --short=12 HEAD)"; cat "$OUT"; echo "GATE-DRIFT-END"; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
}

# Changed paths under scripts/ (the merge ref's first parent is BASE — the diff is the PR's own).
# A-D-M only matters: added files have no master version to replay.
mapfile -t changed < <(git diff --name-status --no-renames "$BASE" HEAD -- scripts/ | awk '$1 ~ /^[MD]$/ {print $2}')
mapfile -t added < <(git diff --name-status --no-renames "$BASE" HEAD -- scripts/ | awk '$1=="A" {print $2}')
if [ "${#changed[@]}" -eq 0 ]; then
  say "No existing script under scripts/ changed (added: ${#added[@]}) — nothing to replay."
  finish
fi

is_test() { case "$1" in *-test.sh|*-test.py|*self-test*|*/fixtures/*|*_test.py|*test_*.py) return 0 ;; esac; return 1; }
gates=(); tests=()
for f in "${changed[@]}"; do if is_test "$f"; then tests+=("$f"); else gates+=("$f"); fi; done

# CI's command list, from BASE: ci.yaml `devbox run <task> …` lines + diff-ci.sh MAP rows.
base_file() { git show "$BASE:$1" 2>/dev/null; }
base_file .github/workflows/ci.yaml \
  | sed -nE 's/^[[:space:]]*(- run:[[:space:]]*|run:[[:space:]]*)?devbox run ([a-z0-9][a-z0-9-]*)(.*)$/\2\3/p' \
  | sed -E 's/[[:space:]]*[)|;&].*$//; s/[[:space:]]+$//' >"$T/cmds"
base_file scripts/diff-ci.sh | sed -nE 's/^[[:space:]]+"([a-z0-9][a-z0-9-]*( [^:"]*)?):.*"$/\1/p' >>"$T/cmds"
grep -vxE "diff-ci" "$T/cmds" | sort -u >"$T/cmds.u"; mv "$T/cmds.u" "$T/cmds"   # bare diff-ci = the MAP dispatcher (every row), never a single gate
base_file devbox.json >"$T/devbox.json"

# closure <task> — the scripts a task's BASE body names, plus one hop through those scripts.
closure() {
  local body; body="$(jq -r --arg t "$1" '.shell.scripts[$t] // empty | if type=="array" then join("\n") else . end' "$T/devbox.json")"
  local direct; direct="$(printf '%s\n' "$body" | grep -oE '(^|[^A-Za-z0-9_./-])(scripts|agents|mgmt/scripts)/[A-Za-z0-9_./-]+' | sed -E 's#^[^a-z]##' | sort -u)"
  printf '%s\n' "$direct"
  for d in $direct; do base_file "$d" | grep -oE '(^|[^A-Za-z0-9_./-])scripts/[A-Za-z0-9_./-]+' | sed -E 's#^[^a-z]##'; done | sort -u
}
: >"$T/closures"
while IFS= read -r cmd; do
  task="${cmd%% *}"
  closure "$task" | sed "s|^|$task\t|" >>"$T/closures"
done <"$T/cmds"

# cmds_for <file…> — the CI commands whose task closure names any of the files.
cmds_for() {
  local f task; : >"$T/sel"
  for f in "$@"; do awk -F'\t' -v f="$f" '$2==f {print $1}' "$T/closures"; done | sort -u >"$T/tasks"
  while IFS= read -r task; do grep -E "^${task}( |$)" "$T/cmds"; done <"$T/tasks" | sort -u | head -n "$MAX_CMDS"
}

# run_leg <label> <worktree> <overlay-files…> — overlay BASE versions, run the selected commands.
run_leg() {
  local label="$1" wt="$2"; shift 2
  git worktree add --detach --quiet "$wt" HEAD 2>/dev/null || { say "- $label: could not create a worktree — NOT RUN (no signal)"; return; }
  local f
  for f in "$@"; do mkdir -p "$wt/$(dirname "$f")"; base_file "$f" >"$wt/$f"; chmod --reference="$REPO/$f" "$wt/$f" 2>/dev/null || chmod +x "$wt/$f"; done
  mapfile -t sel < <(cmds_for "$@")
  if [ "${#sel[@]}" -eq 0 ]; then
    say "- $label: no CI command exercises $(printf '`%s` ' "$@")— these are not CI gates (seat/cluster scripts); nothing to replay."
    return
  fi
  local c rc hrc
  for c in "${sel[@]}"; do
    ( cd "$wt" && BASE="$BASE" timeout "$PER_CMD_TIMEOUT" bash -c "devbox run --quiet $c" ) >"$T/log" 2>&1; rc=$?
    # The same command on the PR's own tree — the comparison is the finding, not either verdict.
    ( cd "$REPO" && BASE="$BASE" timeout "$PER_CMD_TIMEOUT" bash -c "devbox run --quiet $c" ) >"$T/hlog" 2>&1; hrc=$?
    local tag="same"; [ "$rc" -ne "$hrc" ] && tag="**DIFFERS**"
    say "- $label: \`devbox run $c\` → master's side **$(verdict "$rc")**, this PR's side $(verdict "$hrc") — $tag"
    if [ "$rc" -ne 0 ] || [ "$rc" -ne "$hrc" ]; then
      # Lines only master's side printed, plus master's failure-shaped lines: a weakened gate often
      # still PRINTS the finding and only stops exiting non-zero, so the unique-lines diff alone
      # would show nothing. The tail when neither yields anything.
      { grep -Fvxf "$T/hlog" "$T/log"; grep -iE 'fail|dangl|missing|violat|refus|not allowed|invalid|✗|❌' "$T/log"; } \
        | grep -vE '^(Info: Running script|Error: error running script)' | awk '!seen[$0]++' | head -n 20 >"$T/only"
      say '```'; if [ -s "$T/only" ]; then cat "$T/only" >>"$OUT"; else tail -n 15 "$T/log" >>"$OUT"; fi; say '```'
    fi
  done
}
verdict() { case "$1" in 0) echo PASS ;; 124) echo TIMEOUT ;; *) echo "FAIL($1)" ;; esac; }

say "Changed existing scripts: gates=${#gates[@]} tests=${#tests[@]} (added, no master version: ${#added[@]})."
say "The PR's OWN versions ran as this job's gates; the lines below re-run with MASTER's side."
if [ "${#gates[@]}" -gt 0 ]; then
  say ""; say "**(A) master's gate × this PR's content** — overlay: $(printf '`%s` ' "${gates[@]}")"
  run_leg "A" "$T/a" "${gates[@]}"
fi
if [ "${#tests[@]}" -gt 0 ]; then
  say ""; say "**(B) master's tests × this PR's scripts** — overlay: $(printf '`%s` ' "${tests[@]}")"
  run_leg "B" "$T/b" "${tests[@]}"
else
  say ""; say "**(B)** no test file changed — master's tests are the PR's tests, and this job already ran them."
fi
finish
