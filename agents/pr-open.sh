#!/usr/bin/env bash
# pr-open — the ONLY way a worker opens a PR, on every stack (docs/agents/workflow.md §Gate A).
#
# The launcher (agent-session.sh) writes this file into every recipe ride as /work/bin/pr-open and
# puts /work/bin on PATH; this file in homelab is its one home. Recipes and the card name NO gate
# command of their own: a worker that runs the gate by hand and then pr-open pays for it twice, and
# a recipe that names a different gate than the repo runs is how a ride ends up running nothing.
#
#   pr-open --title "<title>" --body-file <file> [--base <ref>] [--check-only] [-- <gh pr create args>]
#   pr-open --check-only --body-file <file>      # every check + the gate, no PR (stamps a green gate)
#   pr-open --self-test
#
# In order, cheapest first; the first refusal prints what to fix and exits 1:
#   1. the body references its issue with a closing keyword or Refs (`Fixes|Closes|Resolves|Refs #N`)
#   2. no uncommitted change to a tracked file (the PR is HEAD — an edit not committed is not in it)
#   3. HEAD is pushed: origin/<branch> == HEAD (`git push -u origin HEAD` first)
#   4. THE GATE: `devbox run pr-gate` — each repo's one declared pre-PR gate (its devbox.json maps it
#      to `ci`, `diff-ci`, …), run with PR_OPEN_BASE=<base> in its env so a diff-scoped gate compares
#      against the PR's real base. No `pr-gate` script = refusal. A GREEN run stamps HEAD + the tree under
#      the git dir; a second call at the same HEAD + tree is served from the stamp (paid for once).
#   5. the repo's own body checks, when it has them: `scripts/pr-open-check --base B --body-file F`
#      (optional hook; non-zero = refusal)
#   6. `gh pr create --base B --head <branch>` (head explicit: a worker clone's master-only refspec
#      leaves `@{u}` unresolved and gh's own branch detection fails even after a push)
# The base defaults to $PR_OPEN_BASE (the launcher exports the ride's base), else master.
# Exit: 0 = done / all green, 1 = refused (the message says why), 2 = usage.
set -euo pipefail

usage() { sed -n '8,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
say() { printf 'pr-open: %s\n' "$*"; }
refuse() { printf 'pr-open: REFUSED — %s\n' "$*" >&2; exit 1; }

# stamp_key → HEAD sha + a hash of the working tree's status (untracked files included, the body
# file excluded): any change after a green gate voids its stamp.
stamp_key() {
  local head st
  head="$(git rev-parse HEAD)"
  st="$(git status --porcelain=v1 -uall | grep -vF -- " ${BODY_REL:-/dev/null}" || true)"
  printf '%s-%s' "$head" "$(printf '%s' "$st" | sha256sum | cut -c1-16)"
}

main() {
  local base="${PR_OPEN_BASE:-master}" title="" body="" check_only="" ; local -a extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift 2;;
      --title) title="${2:-}"; shift 2;;
      --body-file) body="${2:-}"; shift 2;;
      --check-only) check_only=1; shift;;
      --self-test) self_test; return $?;;
      --) shift; extra=("$@"); break;;
      -h|--help) usage;;
      *) echo "pr-open: unknown argument '$1'" >&2; usage;;
    esac
  done
  [ -n "$body" ] && [ -f "$body" ] || { echo "pr-open: --body-file <file> is required" >&2; usage; }
  [ -n "$check_only" ] || [ -n "$title" ] || { echo "pr-open: --title is required" >&2; usage; }
  [ -n "$base" ] || { echo "pr-open: --base is empty" >&2; usage; }
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a git checkout — run pr-open from your repo"
  body="$(cd "$(dirname "$body")" && pwd)/$(basename "$body")"
  cd "$root"
  BODY_REL=""; case "$body" in "$root"/*) BODY_REL="${body#"$root"/}";; esac

  # 1. the issue reference
  grep -qiE '\b(fixes|closes|resolves|refs) #[0-9]+' "$body" \
    || refuse "the body names no issue — write 'Fixes #<n>' (a PR to master) or 'Refs #<n>' (a PR to any other base, or an issue this PR does not finish)"
  # 2. the tree
  if [ -n "$(git status --porcelain=v1 --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    refuse "uncommitted changes to tracked files (above) — commit them (they belong in the PR) or revert them"
  fi
  # 3. pushed
  local branch head remote
  branch="$(git rev-parse --abbrev-ref HEAD)"; head="$(git rev-parse HEAD)"
  [ "$branch" != HEAD ] || refuse "detached HEAD — work on your branch"
  [ "$branch" != "$base" ] || refuse "you are on the base branch '$base' — commit to your own branch"
  remote="$(git ls-remote origin "refs/heads/${branch}" 2>/dev/null | cut -f1)"
  [ "$remote" = "$head" ] || refuse "origin/${branch} is ${remote:-absent}, HEAD is ${head:0:12} — push first: git push -u origin HEAD"
  # 4. the gate
  [ -f devbox.json ] && jq -e '.shell.scripts["pr-gate"] // empty' devbox.json >/dev/null 2>&1 \
    || refuse "this repo declares no 'pr-gate' devbox script, so there is no gate to run — do not open the PR; report the missing gate as a blocker"
  local sdir key; sdir="$(git rev-parse --absolute-git-dir)/pr-open"; mkdir -p "$sdir"; key="$(stamp_key)"
  if [ -f "$sdir/green-$key" ]; then
    say "gate: PR-GATE GREEN at ${head:0:12} (served from this HEAD + tree's stamp — not re-run)"
  else
    say "gate: devbox run pr-gate at ${head:0:12} (log: $sdir/gate.log)"
    local rc=0
    PR_OPEN_BASE="$base" devbox run pr-gate > "$sdir/gate.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      tail -n 40 "$sdir/gate.log" >&2
      refuse "the gate is RED (devbox run pr-gate exit ${rc}; the last 40 lines above, the whole log at $sdir/gate.log) — fix it, commit, push, and call pr-open again"
    fi
    [ "$(stamp_key)" = "$key" ] || refuse "the gate changed the working tree (a formatter or a generated file?) — commit what it wrote, push, and call pr-open again"
    : > "$sdir/green-$key"
    say "gate: PR-GATE GREEN at ${head:0:12}"
  fi
  # 5. the repo's body checks
  if [ -f scripts/pr-open-check ]; then
    say "repo check: scripts/pr-open-check"
    bash scripts/pr-open-check --base "$base" --body-file "$body" || refuse "scripts/pr-open-check refused the PR (its message above) — fix the body or the branch, then call pr-open again"
  fi
  if [ -n "$check_only" ]; then say "check-only: every check passed — no PR opened"; return 0; fi
  # 6. open it
  gh pr create --base "$base" --head "$branch" --title "$title" --body-file "$body" "${extra[@]}"
}

# ── self-test: a throwaway repo + a bare origin, devbox and gh stubbed on PATH ─────────────────────
self_test() {
  local t fails=0 me; me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  t="$(mktemp -d)"
  mkdir -p "$t/bin"
  # devbox stub: counts gate runs; red when $t/red exists
  printf '#!/bin/sh\necho "run base=$PR_OPEN_BASE" >> "%s/gate.count"\n[ -f "%s/red" ] && { echo "1 test FAILED"; exit 1; }\necho "all green"\n' "$t" "$t" > "$t/bin/devbox"
  printf '#!/bin/sh\necho "$@" >> "%s/gh.calls"\n' "$t" > "$t/bin/gh"
  chmod +x "$t/bin/devbox" "$t/bin/gh"
  git init -q --bare "$t/origin.git"
  git init -q -b master "$t/repo"
  (cd "$t/repo" && git config user.email t@t && git config user.name t \
    && printf '{"shell":{"scripts":{"pr-gate":["echo"]}}}\n' > devbox.json && git add . && git commit -qm init \
    && git remote add origin "$t/origin.git" && git push -q origin master \
    && git checkout -qb fix/x && echo a > a && git add a && git commit -qm a)
  printf 'Fixes #7\n' > "$t/body.md"; printf 'no ref\n' > "$t/noref.md"
  run() { (cd "$t/repo" && PATH="$t/bin:$PATH" PR_OPEN_BASE="" bash "$me" "$@") >"$t/out" 2>&1; echo $?; }
  gates() { cat "$t/gate.count" 2>/dev/null | wc -l | tr -d ' '; }
  check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$2' got '$3'"; sed 's/^/       | /' "$t/out"; fails=$((fails+1)); fi; }

  check "no issue reference → refused"            1 "$(run --title x --body-file "$t/noref.md")"
  check "not pushed → refused"                    1 "$(run --title x --body-file "$t/body.md")"
  (cd "$t/repo" && git push -q -u origin fix/x)
  echo b >> "$t/repo/a"
  check "uncommitted tracked change → refused"    1 "$(run --title x --body-file "$t/body.md")"
  (cd "$t/repo" && git checkout -q -- a)
  touch "$t/red"
  check "red gate → refused"                      1 "$(run --title x --body-file "$t/body.md")"
  check "red gate: no PR"                         0 "$(cat "$t/gh.calls" 2>/dev/null | wc -l | tr -d ' ')"
  rm -f "$t/red"
  check "check-only: green, no PR"                0 "$(run --check-only --body-file "$t/body.md")"
  check "check-only ran the gate once"            2 "$(gates)"
  check "green → PR opened"                       0 "$(run --title x --body-file "$t/body.md")"
  check "…from the stamp: the gate did not re-run" 2 "$(gates)"
  check "…with explicit base + head"              1 "$(grep -c -- '--base master --head fix/x --title x' "$t/gh.calls")"
  echo c > "$t/repo/untracked"
  check "a new untracked file voids the stamp"    0 "$(run --check-only --body-file "$t/body.md")"
  check "…so the gate re-ran"                     3 "$(gates)"
  rm -f "$t/repo/untracked"
  cp "$t/body.md" "$t/repo/body.md"
  check "a body file inside the repo keeps the stamp" 0 "$(run --check-only --body-file "$t/repo/body.md")"
  check "…gate not re-run"                        3 "$(gates)"
  rm -f "$t/repo/body.md"
  mkdir -p "$t/repo/scripts"; printf 'echo "acceptance row 2 unverified"; exit 1\n' > "$t/repo/scripts/pr-open-check"
  (cd "$t/repo" && git add scripts && git commit -qm hook && git push -q)
  check "repo hook refusal → refused"             1 "$(run --title x --body-file "$t/body.md")"
  check "…and says why"                           1 "$(grep -c 'acceptance row 2 unverified' "$t/out")"
  (cd "$t/repo" && git rm -q scripts/pr-open-check && printf '{}\n' > devbox.json && git commit -qam nogate && git push -q)
  check "no pr-gate script → refused"             1 "$(run --title x --body-file "$t/body.md")"
  check "base from PR_OPEN_BASE"                  1 "$( (cd "$t/repo" && printf '{"shell":{"scripts":{"pr-gate":["echo"]}}}\n' > devbox.json && git commit -qam gate && git push -q); (cd "$t/repo" && PATH="$t/bin:$PATH" PR_OPEN_BASE=goal/1-x bash "$me" --title y --body-file "$t/body.md") >/dev/null 2>&1; grep -c -- '--base goal/1-x --head fix/x --title y' "$t/gh.calls")"
  check "the gate saw the PR's base"               1 "$(grep -c 'base=goal/1-x' "$t/gate.count")"
  check "usage: no body → 2"                      2 "$(run --title x)"
  rm -rf "$t"
  [ "$fails" -eq 0 ] && { echo "pr-open self-test: ok"; return 0; }
  echo "pr-open self-test: $fails FAILED"; return 1
}

main "$@"
