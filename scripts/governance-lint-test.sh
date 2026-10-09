#!/usr/bin/env bash
# governance-lint-test — drives the REAL scripts/governance-lint.sh over a synthetic git repo and
# pins its WORKER_PATTERN against every author-login shape the lint meets (FU-296).
# `devbox run governance-lint-test`.
#
# Why this exists: under the ADR-142 trial scripts/ is worker-authorable, and drill D3 (#2092,
# 2026-09-28) anchored WORKER_PATTERN so it missed the REST login `homelab-agents-1234[bot]` —
# every worker PR would have passed the lint, and nothing failed. A login shape the pattern stops
# matching must red HERE.
#
# Each expected verdict is derived from the lint's header, never from running it:
#   - the worker App's PRs go red on any governance-path write (REST `<app>[bot]`, GraphQL
#     `app/<app>`, and the bare slug all name the same App);
#   - seat/operator logins, renovate, and every OTHER App (a sibling of the worker) pass untouched;
#   - a worker diff with NO governance path is ok — the control that proves the red above is the
#     governance rule, not an incidental failure.
# A case must hold for ITS rule: the check greps the lint's output for the rule's own phrase.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/governance-lint.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The lint's PR-context env must not leak in from a CI job running this test: no compare API
# path, no assembly lane, no pattern override.
unset PR_HEAD_SHA GITHUB_REPOSITORY BASE_REF PR_HEAD_REF PR_BODY WORKER_PATTERN

# The lint cd's to "$(dirname "$0")/..", so a copy at <repo>/scripts/ judges <repo>.
mkrepo() {  # mkrepo <dir> <changed-path>: base commit, then one commit writing <changed-path>
  local d="$1" p="$2"
  mkdir -p "$d/scripts" && git -C "$d" init -q -b master
  cp "$LINT" "$d/scripts/governance-lint.sh"
  echo base >"$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -q -m base
  git -C "$d" tag base
  mkdir -p "$d/$(dirname "$p")" && echo change >"$d/$p"
  git -C "$d" add -A && git -C "$d" commit -q -m change
}
mkrepo "$T/gov" ".agents/fix.yaml"
mkrepo "$T/docs" "docs/note.md"

pass=0; fail=0
check() {  # check <repo> <author> <want-exit> <want-phrase> <label>
  local out rc
  out="$(cd "$T" && PR_AUTHOR="$2" CI= bash "$1/scripts/governance-lint.sh" base 2>&1)"; rc=$?
  if [ "$rc" = "$3" ] && grep -qF -- "$4" <<< "$out"; then
    pass=$((pass+1)); echo "ok   $5"
  else
    fail=$((fail+1)); echo "FAIL $5 — author '$2': want exit $3 + '$4', got exit $rc:"; printf '       %s\n' "$out"
  fi
}

WORKER_RED="worker-authored diff touches governance paths"
NOT_WORKER="is not the worker lane"

# The worker App, every surface's spelling of it → red on a governance write.
check "$T/gov" 'homelab-agents-1234[bot]' 1 "$WORKER_RED" "worker, REST login ([bot] suffix — the D3 miss)"
check "$T/gov" 'app/homelab-agents-1234'  1 "$WORKER_RED" "worker, GraphQL login (app/ prefix)"
check "$T/gov" 'homelab-agents-1234'      1 "$WORKER_RED" "worker, bare App slug"
# Everyone else → passes untouched, by the author rule (not by the diff).
check "$T/gov" 'homelab-reviewer[bot]'     0 "$NOT_WORKER" "sibling App (reviewer), REST login"
check "$T/gov" 'app/homelab-reviewer'      0 "$NOT_WORKER" "sibling App (reviewer), GraphQL login"
check "$T/gov" 'renovate[bot]'             0 "$NOT_WORKER" "renovate (public App)"
check "$T/gov" 'app/homelab-renovate-1234' 0 "$NOT_WORKER" "renovate (self-hosted App)"
check "$T/gov" 'RasmusSoot'                0 "$NOT_WORKER" "seat/operator login"
# Control: the worker on a non-governance diff is ok.
check "$T/docs" 'homelab-agents-1234[bot]' 0 "touches no governance path" "worker, docs-only diff (control)"

# homelab#1736: master advances on a governance path AFTER the worker's docs branch forked. The lint
# diffs three-dot (merge base → head; the header's #1441 (b) block), so with base = master's tip
# master's .agents/ write is never the worker's → ok. A two-dot diff would list it and go red.
mkrepo "$T/behind" "docs/note.md"
git -C "$T/behind" checkout -q -b master-ahead base
mkdir -p "$T/behind/.agents" && echo m >"$T/behind/.agents/fix.yaml"
git -C "$T/behind" add -A && git -C "$T/behind" commit -q -m "master: governance write"
git -C "$T/behind" checkout -q master
git -C "$T/behind" tag -f base "$(git -C "$T/behind" rev-parse master-ahead)" >/dev/null
check "$T/behind" 'homelab-agents-1234[bot]' 0 "touches no governance path" "worker, docs branch BEHIND a master governance write (#1736, three-dot)"

echo "governance-lint-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
