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

# ── The revert-lock arm (class 7, #2369; the 2026-10-10 drill's #2480 went red here). Expected
# verdicts from the arm's header in governance-lint.sh: the worker App may write a lock ONLY as
# `revert-lock-<sha8>` + a `reverted-locks:` body line + lock files only + <sha8> on master + every
# file byte-for-byte <sha8>^'s with master still at <sha8>'s version; anything else is the plain
# worker red (or the arm's own refusal phrase). History is read through GOVLINT_REMOTE=. (the seam).
# mklock <dir>: master = base (lock v1) → PLANT (lock v2, the bad lock) ; tag base = PLANT. Sets P8.
mklock() {
  local d="$1"
  mkdir -p "$d/scripts" && git -C "$d" init -q -b master
  cp "$LINT" "$d/scripts/governance-lint.sh"
  printf '{"packages":{"qrencode@latest":{"version":"4.1.1"}}}\n' >"$d/devbox.lock"
  git -C "$d" add -A && git -C "$d" commit -q -m base
  printf '{"packages":{"qrencode@latest":{"version":"4.1.99"}}}\n' >"$d/devbox.lock"
  git -C "$d" commit -q -am plant
  git -C "$d" tag base
  P8="$(git -C "$d" rev-parse --short=8 HEAD)"
}
checkrl() {  # checkrl <repo> <head-ref> <body> <want-exit> <want-phrase> <label>  (HEAD = <head-ref>)
  local out rc
  git -C "$1" checkout -q "$2"
  out="$(cd "$T" && PR_AUTHOR='homelab-agents-1234[bot]' PR_HEAD_REF="$2" PR_BODY="$3" GOVLINT_REMOTE=. CI= \
         bash "$1/scripts/governance-lint.sh" base 2>&1)"; rc=$?
  if [ "$rc" = "$4" ] && grep -qF -- "$5" <<< "$out"; then
    pass=$((pass+1)); echo "ok   $6"
  else
    fail=$((fail+1)); echo "FAIL $6 — head '$2': want exit $4 + '$5', got exit $rc:"; printf '       %s\n' "$out"
  fi
}
BODY='Lock revert chain (class 7 …)

**Reverted PR:** #2478

reverted-locks: qrencode@4.1.99'
RL_OK="revert-lock lane"

# (1) the #2480 shape: `git revert <plant>` on revert-lock-<plant8> → lock back to v1 byte-for-byte → ok.
mklock "$T/rl"
git -C "$T/rl" checkout -q -b "revert-lock-$P8" && git -C "$T/rl" revert --no-edit HEAD >/dev/null
checkrl "$T/rl" "revert-lock-$P8" "$BODY" 0 "$RL_OK" "revert-lock: the #2480 shape (git revert of a lock-only merge) passes"
# (2) the SAME byte-exact restore without the `reverted-locks:` memory line → not the chain's PR → worker red.
checkrl "$T/rl" "revert-lock-$P8" "a revert" 1 "$WORKER_RED" "revert-lock: no reverted-locks: body line → worker red"
# (3) a worker lock edit NOT on a revert branch (same body, same restored bytes) → worker red.
git -C "$T/rl" checkout -q -b fix/lock-edit "revert-lock-$P8"
checkrl "$T/rl" fix/lock-edit "$BODY" 1 "$WORKER_RED" "revert-lock: a worker lock edit on fix/* → worker red"
# (4) a revert-lock branch whose lock is NOT the byte-exact parent (an invented version) → refused.
mklock "$T/rl-inv"
git -C "$T/rl-inv" checkout -q -b "revert-lock-$P8"
printf '{"packages":{"qrencode@latest":{"version":"4.1.0"}}}\n' >"$T/rl-inv/devbox.lock"
git -C "$T/rl-inv" commit -q -am "revert, but invents 4.1.0"
checkrl "$T/rl-inv" "revert-lock-$P8" "$BODY" 1 "is not byte-for-byte" "revert-lock: head lock not <sha8>^'s bytes → refused"
# (4b) byte-exact is BYTES: the same JSON re-serialised (key order, whitespace) is still refused.
mklock "$T/rl-ws"
git -C "$T/rl-ws" checkout -q -b "revert-lock-$P8"
printf '{ "packages": { "qrencode@latest": { "version": "4.1.1" } } }\n' >"$T/rl-ws/devbox.lock"
git -C "$T/rl-ws" commit -q -am "revert, reformatted"
checkrl "$T/rl-ws" "revert-lock-$P8" "$BODY" 1 "is not byte-for-byte" "revert-lock: same JSON, different bytes → refused"
# (5) the revert branch also writes a governance path beside the lock → the arm declines → worker red.
mklock "$T/rl-gov"
git -C "$T/rl-gov" checkout -q -b "revert-lock-$P8" && git -C "$T/rl-gov" revert --no-edit HEAD >/dev/null
mkdir -p "$T/rl-gov/.agents" && echo x >"$T/rl-gov/.agents/fix.yaml"
git -C "$T/rl-gov" add -A && git -C "$T/rl-gov" commit -q -m smuggle
checkrl "$T/rl-gov" "revert-lock-$P8" "$BODY" 1 "$WORKER_RED" "revert-lock: lock + .agents/ smuggled → worker red"
# (6) <sha8> is a commit the BRANCH carries, not master's: X writes an invented lock, Y overwrites it,
# the head restores Y^ (= X's invented lock) byte-for-byte — refused, <sha8> is not on master.
mklock "$T/rl-side"
git -C "$T/rl-side" checkout -q -b side
printf '{"packages":{"qrencode@latest":{"version":"6.6.6"}}}\n' >"$T/rl-side/devbox.lock"; git -C "$T/rl-side" commit -q -am X
printf '{"packages":{"qrencode@latest":{"version":"4.1.99"}}}\n' >"$T/rl-side/devbox.lock"; git -C "$T/rl-side" commit -q -am Y
Y8="$(git -C "$T/rl-side" rev-parse --short=8 HEAD)"
git -C "$T/rl-side" checkout -q -b "revert-lock-$Y8" && git -C "$T/rl-side" revert --no-edit HEAD >/dev/null
checkrl "$T/rl-side" "revert-lock-$Y8" "$BODY" 1 "is not on master" "revert-lock: <sha8> off master (branch-carried) → refused"
# (7) master changed the lock AGAIN after <sha8>: restoring <sha8>^ would undo more than that commit → refused.
mklock "$T/rl-moved"
PLANT="$(git -C "$T/rl-moved" rev-parse HEAD)"
printf '{"packages":{"qrencode@latest":{"version":"4.2.0"}}}\n' >"$T/rl-moved/devbox.lock"; git -C "$T/rl-moved" commit -q -am later
git -C "$T/rl-moved" tag -f base >/dev/null
git -C "$T/rl-moved" checkout -q -b "revert-lock-$P8"
git -C "$T/rl-moved" show "$PLANT^:devbox.lock" >"$T/rl-moved/devbox.lock"   # <sha8>^'s exact bytes
git -C "$T/rl-moved" commit -q -am "restore the plant's parent over the later move"
checkrl "$T/rl-moved" "revert-lock-$P8" "$BODY" 1 "moved on the base since" "revert-lock: master moved the lock after <sha8> → refused"

# ── The revert-wf arm (FU-1990 part 2, homelab#2561; the #2177 / #2358 shape). The SAME predicate
# as the lock arm with the chain's wf triple: `revert-wf-<sha8>` + a `reverted-pins:` body line +
# `.github/workflows/**` only + <sha8> on master + every file byte-for-byte <sha8>^'s with master
# still at <sha8>'s version. The chain opens these PRs as the worker App, so without the arm a
# legitimate revert is red on `^\.github/` and can never merge (#2177, #2358: armed, reflex-
# APPROVED, structurally red). Expected verdicts from the arm's header in governance-lint.sh.
# mkwf <dir>: master = base (ci.yaml pin v1) → PLANT (ci.yaml pin v2, the bad pin); tag base = PLANT. Sets P8.
mkwf() {
  local d="$1"
  mkdir -p "$d/scripts" "$d/.github/workflows" && git -C "$d" init -q -b master
  cp "$LINT" "$d/scripts/governance-lint.sh"
  printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@1111111111111111111111111111111111111111 # v4\n' >"$d/.github/workflows/ci.yaml"
  git -C "$d" add -A && git -C "$d" commit -q -m base
  printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@2222222222222222222222222222222222222222 # v5\n' >"$d/.github/workflows/ci.yaml"
  git -C "$d" commit -q -am plant
  git -C "$d" tag base
  P8="$(git -C "$d" rev-parse --short=8 HEAD)"
}
WF_BODY='FU-1990 deterministic rollback: workflow **CI** failed on `master` …

**Reverted PR:** #2175 — renovatebot/github-action v46.3.3 -> v46.3.4

reverted-pins: renovatebot/github-action@3333333333333333333333333333333333333333'
WF_OK="revert-wf lane"

# (1) the #2177 shape: `git revert <plant>` on revert-wf-<plant8> → the workflow back to v1 → ok.
mkwf "$T/wf"
git -C "$T/wf" checkout -q -b "revert-wf-$P8" && git -C "$T/wf" revert --no-edit HEAD >/dev/null
checkrl "$T/wf" "revert-wf-$P8" "$WF_BODY" 0 "$WF_OK" "revert-wf: the #2177 shape (git revert of a pin-only workflow merge) passes"
# (2) the SAME byte-exact restore without the `reverted-pins:` memory line → not the chain's PR → worker red.
checkrl "$T/wf" "revert-wf-$P8" "a revert" 1 "$WORKER_RED" "revert-wf: no reverted-pins: body line → worker red"
# (3) a worker workflow edit NOT on a revert branch (same body, same restored bytes) → worker red.
git -C "$T/wf" checkout -q -b fix/wf-edit "revert-wf-$P8"
checkrl "$T/wf" fix/wf-edit "$WF_BODY" 1 "$WORKER_RED" "revert-wf: a worker workflow edit on fix/* → worker red"
# (4) the revert PLUS a smuggled non-pin line in the workflow (the head is no longer <sha8>^'s bytes) → refused.
mkwf "$T/wf-smug"
git -C "$T/wf-smug" checkout -q -b "revert-wf-$P8" && git -C "$T/wf-smug" revert --no-edit HEAD >/dev/null
printf '      - run: echo smuggled\n' >>"$T/wf-smug/.github/workflows/ci.yaml"
git -C "$T/wf-smug" commit -q -am "revert, plus a line the chain never wrote"
checkrl "$T/wf-smug" "revert-wf-$P8" "$WF_BODY" 1 "is not byte-for-byte" "revert-wf: a smuggled non-pin line in the workflow → refused"
# (5) the revert branch also writes a governance path beside the workflow → the arm declines → worker red.
mkwf "$T/wf-gov"
git -C "$T/wf-gov" checkout -q -b "revert-wf-$P8" && git -C "$T/wf-gov" revert --no-edit HEAD >/dev/null
mkdir -p "$T/wf-gov/.agents" && echo x >"$T/wf-gov/.agents/fix.yaml"
git -C "$T/wf-gov" add -A && git -C "$T/wf-gov" commit -q -m smuggle
checkrl "$T/wf-gov" "revert-wf-$P8" "$WF_BODY" 1 "$WORKER_RED" "revert-wf: workflow + .agents/ smuggled → worker red"
# (6) <sha8> is a commit the BRANCH carries, not master's: X writes an invented pin, Y overwrites it,
# the head restores Y^ (= X's invented pin) byte-for-byte — refused, <sha8> is not on master.
mkwf "$T/wf-side"
git -C "$T/wf-side" checkout -q -b side
printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@6666666666666666666666666666666666666666 # v9\n' >"$T/wf-side/.github/workflows/ci.yaml"; git -C "$T/wf-side" commit -q -am X
printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@2222222222222222222222222222222222222222 # v5\n' >"$T/wf-side/.github/workflows/ci.yaml"; git -C "$T/wf-side" commit -q -am Y
Y8="$(git -C "$T/wf-side" rev-parse --short=8 HEAD)"
git -C "$T/wf-side" checkout -q -b "revert-wf-$Y8" && git -C "$T/wf-side" revert --no-edit HEAD >/dev/null
checkrl "$T/wf-side" "revert-wf-$Y8" "$WF_BODY" 1 "is not on master" "revert-wf: <sha8> off master (branch-carried) → refused"
# (7) master changed the workflow AGAIN after <sha8>: restoring <sha8>^ would undo more than that commit → refused.
mkwf "$T/wf-moved"
PLANT="$(git -C "$T/wf-moved" rev-parse HEAD)"
printf 'jobs:\n  ci:\n    steps:\n      - uses: actions/checkout@4444444444444444444444444444444444444444 # v6\n' >"$T/wf-moved/.github/workflows/ci.yaml"; git -C "$T/wf-moved" commit -q -am later
git -C "$T/wf-moved" tag -f base >/dev/null
git -C "$T/wf-moved" checkout -q -b "revert-wf-$P8"
git -C "$T/wf-moved" show "$PLANT^:.github/workflows/ci.yaml" >"$T/wf-moved/.github/workflows/ci.yaml"   # <sha8>^'s exact bytes
git -C "$T/wf-moved" commit -q -am "restore the plant's parent over the later move"
checkrl "$T/wf-moved" "revert-wf-$P8" "$WF_BODY" 1 "moved on the base since" "revert-wf: master moved the workflow after <sha8> → refused"

# homelab#2412 — the THIRD shape (#1736's comment): a master-sync PR into a goal/** base. The PR
# forks from the GOAL tip and merges master, so merge-base(base, head) == goal tip and three-dot ≡
# two-dot: master's own governance write IS the PR's diff. The predicate is "content NOT reachable
# from origin/master", so master's file drops out — while the PR's OWN governance write stays red.
# mksync <dir> <goal-own-path-or-empty> <post-sync edit shell>: master = base + a governance write;
# goal/2412 = base + <own-path> (if any) + the sync merge + <edit> (if any). Sets GTIP (the PR's
# base) and leaves HEAD on goal/2412. GOVLINT_MASTER is the seam (the synthetic repo has no origin).
mksync() {
  local d="$1" p="$2" edit="$3"
  mkdir -p "$d/scripts" && git -C "$d" init -q -b master
  cp "$LINT" "$d/scripts/governance-lint.sh"
  echo base >"$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -q -m base
  git -C "$d" checkout -q -b goal/2412
  if [ -n "$p" ]; then mkdir -p "$d/$(dirname "$p")"; echo own >"$d/$p"; git -C "$d" add -A && git -C "$d" commit -q -m "goal: own write"; fi
  GTIP="$(git -C "$d" rev-parse HEAD)"
  git -C "$d" checkout -q master
  mkdir -p "$d/.agents" && echo m >"$d/.agents/fix.yaml"
  git -C "$d" add -A && git -C "$d" commit -q -m "master: governance write"
  git -C "$d" checkout -q goal/2412
  git -C "$d" merge -q --no-ff --no-edit master >/dev/null
  if [ -n "$edit" ]; then ( cd "$d" && eval "$edit" ) >/dev/null 2>&1; git -C "$d" add -A && git -C "$d" commit -q -m "pr: own write"; fi
}
checksync() {  # checksync <repo> <want-exit> <want-phrase> <label>
  local out rc
  out="$(cd "$T" && PR_AUTHOR='homelab-agents-1234[bot]' GOVLINT_MASTER=master CI= \
         bash "$1/scripts/governance-lint.sh" "$GTIP" 2>&1)"; rc=$?
  if [ "$rc" = "$2" ] && grep -qF -- "$3" <<< "$out"; then
    pass=$((pass+1)); echo "ok   $4"
  else
    fail=$((fail+1)); echo "FAIL $4 — want exit $2 + '$3', got exit $rc:"; printf '       %s\n' "$out"
  fi
}
# master's own governance write rides the sync → never the worker's (the goal wrote only docs/).
mksync "$T/sync" "docs/note.md" ""
checksync "$T/sync" 0 "touches no governance path" "master-sync into goal/**: master's governance write is not the worker's (#2412)"
# The PR's OWN governance write on top of the sync is still red.
mksync "$T/sync-own" "" "mkdir -p policy/mgmt && echo p > policy/mgmt/plan-input.yaml"
checksync "$T/sync-own" 1 "$WORKER_RED" "master-sync into goal/**: the PR's own governance write is still red (#2412)"

echo "governance-lint-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
