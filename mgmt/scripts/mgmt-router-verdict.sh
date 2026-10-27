#!/usr/bin/env bash
# mgmt-router-verdict — the management sentinel's ROUTER surface (ADR-152; ROADMAP §Deploy paths, the
# program's step 1; docs/management-box.md §MB3 "The router surface"). Posts the `opnsense-test-vm`
# commit status on EVERY open homelab PR head:
#   base master, a router path touched   scripts/opnsense-test-vm.sh (MASTER's copy) validates the head
#                                        on test VM 9110 — base converge, head on top, mutations reach
#                                        the running daemons, fresh converge + idempotent rerun (+ step
#                                        `all` when a play outside the floor or an opnsense/*.py moved).
#                                        PASS → success, FAIL → failure, could-not-run → error (retried).
#                                        The report (scrubbed of credentials) is the PR comment.
#   base master, no router path          success "n/a: no router path in this head" — the context never
#                                        skips, so it can be REQUIRED (tofu/github/variables.tf: a check
#                                        that can be absent deadlocks the merge). The in-cluster
#                                        iac-sentinel run posts this n/a seconds after a push (the same
#                                        scope split as management-sentinel — scripts/iac-sentinel.sh
#                                        `mgmt_box_surfaces_post`); this loop backstops it and skips a
#                                        head that already carries the context, so a silent box holds
#                                        only router-path heads.
#   base goal/**                         success, judged at the goal → master assembly PR (FU-295's shape)
#   any other base                       not judged (not required there)
# The router paths are `router_test_vm.paths` in policy/mgmt/plan-input.yaml, read from MASTER; the
# classifier (mgmt_router_touched) lives in mgmt-lib.sh — both posters read it.
#
# PR CODE RUNS SANDBOXED: the harness itself, its guard, inventory and overrides are master's and keep
# the hypervisor/VM root key; every command that executes the head's code (galaxy install, the
# controller-env flake, ansible-playbook, opnsense/*.py) runs as the unprivileged `mgmt-opnsense-test`
# user with a clean environment (OPN_TEST_RUN_AS — the harness header), never with the box's env file.
#
# One VM, one run at a time (its own flock — never the sentinel/apply lock: a 15-min run must not
# stall an apply); newest head only: a run whose PR head moves is killed (the watchdog) and the new
# head is judged next tick. Memo per head sha: a success/failure status on the context = judged; a
# `pending` (a run that died with the box) or an `error` (≤ MGMT_ROUTER_MAX_ERRORS times) is re-run.
#
# Usage: mgmt/scripts/mgmt-router-verdict.sh          one pass (the timer's unit, mgmt-router-verdict)
#        MGMT_SHADOW=1 …                              no GitHub writes (verdicts in the journal)
# Env: mgmt-lib.sh's (the homelab-sentinel App), plus OPN_TESTVM_API_KEY/OPN_TESTVM_API_SECRET (the test
# VM's own pair — wallet opnsense-test-api-*, mgmt-provision-secrets.sh), MGMT_ROUTER_DIR
# (/var/lib/mgmt-router — NOT under the 0700 /var/lib/mgmt: the sandbox user must traverse it),
# MGMT_ROUTER_RUN_AS (mgmt-opnsense-test), MGMT_ROUTER_TEXTFILE (unset = no metrics).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"

CTX="opnsense-test-vm"; MARKER="<!-- opnsense-test-vm -->"
NA_DESC="n/a: no router path in this head"

# ── judgement (pure; fixture-tested by mgmt/scripts/mgmt-router-test.sh) ────────────────────────
# The path classifier (mgmt_router_globs / mgmt_router_touched) is mgmt-lib.sh's — shared with the
# in-cluster n/a poster, so the two can never disagree on what a router path is.
# mgmt_router_action <base-ref> <router-files-touched (count)> <latest state of the context on the head, or "">
# <errors so far> <max errors> → one word:
#   skip      not judged (another base) or already judged (success/failure) or out of error retries
#   assembly  goal/** base → the assembly-PR success
#   na        no router path → the n/a success
#   run       validate on the test VM
mgmt_router_action() {
  local bref="$1" n="$2" st="$3" errs="${4:-0}" max="${5:-3}"
  case "$bref" in master) ;; goal/*) [ "$st" = success ] && echo skip || echo assembly; return ;; *) echo skip; return ;; esac
  case "$st" in success|failure) echo skip; return ;; esac
  if [ "$n" -eq 0 ]; then echo na; return; fi
  if [ "$st" = error ] && [ "$errs" -ge "$max" ]; then echo skip; return; fi
  echo run
}
# mgmt_router_state <harness rc> → the commit status state (0 PASS, 1 FAIL, anything else = could not run)
mgmt_router_state() { case "$1" in 0) echo success ;; 1) echo failure ;; *) echo error ;; esac; }

[ "${MGMT_ROUTER_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── the pass ────────────────────────────────────────────────────────────────────────────────────
ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
RDIR="${MGMT_ROUTER_DIR:-/var/lib/mgmt-router}"
RUN_AS="${MGMT_ROUTER_RUN_AS:-mgmt-opnsense-test}"
MAXERR="${MGMT_ROUTER_MAX_ERRORS:-3}"
RUN_TIMEOUT="${MGMT_ROUTER_RUN_TIMEOUT:-3600}"   # s — a healthy run is ~10–16 min (+7 with step all)
TEXTFILE="${MGMT_ROUTER_TEXTFILE:-}"
REPO="$RDIR/homelab"; export REPO
mkdir -p "$RDIR/done" "$RDIR/runs"; chmod 0711 "$RDIR"

if [ "${MGMT_SHADOW:-0}" != 1 ] && ! mgmt_gh_token >/dev/null; then
  log "no App token (MGMT_GH_APP_* unset or key unreadable) — running SHADOW"; export MGMT_SHADOW=1
fi
exec 8>"$RDIR/.lock"; flock -n 8 || { log "another router-verdict pass holds the VM — this tick does nothing"; exit 0; }

T0=$(date +%s); queue=0; last_state=""; last_dur=0; last_at=0
metrics() {
  [ -n "$TEXTFILE" ] || return 0
  local tmp="$TEXTFILE.$$" st
  {
    echo "# HELP mgmt_router_verdict_last_run_timestamp_seconds End of the last router-verdict pass (docs/management-box.md §MB3 The router surface)."
    echo "# TYPE mgmt_router_verdict_last_run_timestamp_seconds gauge"
    echo "mgmt_router_verdict_last_run_timestamp_seconds $(date +%s)"
    echo "# HELP mgmt_router_verdict_queue Open master-bound heads touching a router path with no verdict yet, at the pass's start."
    echo "# TYPE mgmt_router_verdict_queue gauge"
    echo "mgmt_router_verdict_queue $queue"
    if [ -s "$RDIR/last-verdict" ]; then
      read -r last_at st last_dur <"$RDIR/last-verdict"
      echo "# HELP mgmt_router_verdict_last_verdict_timestamp_seconds When the box last posted a test-VM verdict (a real run, not n/a)."
      echo "# TYPE mgmt_router_verdict_last_verdict_timestamp_seconds gauge"
      echo "mgmt_router_verdict_last_verdict_timestamp_seconds $last_at"
      echo "# HELP mgmt_router_verdict_last_duration_seconds Wall time of that run."
      echo "# TYPE mgmt_router_verdict_last_duration_seconds gauge"
      echo "mgmt_router_verdict_last_duration_seconds $last_dur"
      echo "# HELP mgmt_router_verdict_last_result 1 for the state of that run's verdict (success|failure|error)."
      echo "# TYPE mgmt_router_verdict_last_result gauge"
      for s in success failure error; do echo "mgmt_router_verdict_last_result{state=\"$s\"} $([ "$s" = "$st" ] && echo 1 || echo 0)"; done
    fi
  } >"$tmp" && mv -f "$tmp" "$TEXTFILE"
}
trap metrics EXIT

mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch of $REPO_URL failed"; exit 1; }
mgmt_tree_path "$REPO" || log "WARN a tree-locked tool is unresolvable from $REPO/devbox.lock"
POL="$(mgmt_policy_load "$REPO" origin/master)" || exit 1
trap 'rm -f "$POL"; metrics' EXIT
mgmt_router_globs "$POL" >/dev/null || { log "PROBE-FAIL: router_test_vm.paths unreadable in master's policy — judging nothing"; exit 1; }

prs="$(gh_api_paged "pulls?state=open")" || { log "PROBE-FAIL: PR list failed"; exit 1; }
rows="$(jq -r '.[] | [.number, .head.sha, .base.ref] | @tsv' <<<"$prs")" || { log "PROBE-FAIL: PR list unreadable"; exit 1; }
log "open PRs on ${ORG}/${MGMT_REPO}: $(jq length <<<"$prs")"

latest_state() { # <sha> → the context's current state on the head ("" = none); rc 1 = unreadable
  gh_api GET "commits/$1/status" | jq -r --arg c "$CTX" '[.statuses[] | select(.context == $c)][0].state // ""'
}
head_now() { gh_api GET "pulls/$1" | jq -r '.head.sha // empty'; }
post() { # <sha> <state> <desc>
  mgmt_post_status "$1" "$CTX" "$2" "$3"
}

declare -a todo=()
while IFS=$'\t' read -r pr sha bref; do
  [ -n "$pr" ] || continue
  st="$(latest_state "$sha")" || { log "[#$pr] status unreadable — skipped this tick"; continue; }
  if [ "$bref" = master ]; then
    mgmt_git -C "$REPO" fetch --quiet origin "+refs/pull/$pr/head:refs/mgmt/pr-$pr" || { log "[#$pr] head fetch failed — skipped this tick"; continue; }
    base="$(git -C "$REPO" merge-base origin/master "$sha" 2>/dev/null)" || { log "[#$pr] no merge-base — skipped"; continue; }
    # --no-renames: a router file renamed AWAY still lists its old path
    files="$(git -C "$REPO" diff --name-only --no-renames "$base" "$sha" --)" || { log "[#$pr] diff failed — skipped this tick"; continue; }
    touched="$(printf '%s\n' "$files" | mgmt_router_touched "$POL")" || { log "[#$pr] classifier failed — skipped"; continue; }
    n=0; [ -n "$touched" ] && n=$(grep -c . <<<"$touched")
  else
    n=0
  fi
  errs=0; [ -f "$RDIR/done/$sha.errors" ] && errs="$(cat "$RDIR/done/$sha.errors")"
  act="$(mgmt_router_action "$bref" "$n" "$st" "$errs" "$MAXERR")"
  case "$act" in
    skip) ;;
    assembly) post "$sha" success "base $bref — router surface judged at the assembly PR to master" ;;
    na) post "$sha" success "$NA_DESC" ;;
    run) todo+=("$pr"$'\t'"$sha"$'\t'"$(tr '\n' ' ' <<<"$touched")"); log "[#$pr@${sha:0:8}] router paths: $(tr '\n' ' ' <<<"$touched")" ;;
  esac
done <<<"$rows"
queue=${#todo[@]}
[ "$queue" -gt 0 ] || { date +%s >"$RDIR/last-run"; log "no router head to validate"; exit 0; }

# the harness, from MASTER (a worktree of the clone's origin/master — never the head's copy)
HWT="$RDIR/harness"
git -C "$REPO" worktree remove --force "$HWT" >/dev/null 2>&1 || rm -rf "$HWT"
git -C "$REPO" worktree prune
git -C "$REPO" worktree add --quiet --detach "$HWT" origin/master || { log "PROBE-FAIL: harness worktree"; exit 1; }
M8="$(git -C "$REPO" rev-parse --short=8 origin/master)"

for row in "${todo[@]}"; do
  IFS=$'\t' read -r pr sha touched <<<"$row"
  now="$(head_now "$pr")" || { log "[#$pr] head unreadable — skipped"; continue; }
  [ "$now" = "$sha" ] || { log "[#$pr] head moved to ${now:0:8} — ${sha:0:8} is superseded (next tick)"; continue; }
  post "$sha" pending "running on the OPNsense test VM (master@$M8 harness, ~15 min)"
  work="$RDIR/runs/${sha:0:12}"; rm -rf "$work"; mkdir -p "$work"
  t0=$(date +%s)
  # the harness's environment, named: never the unit's env file (the test VM's own pair only)
  setsid env -i PATH="$PATH" HOME="${HOME:-/root}" LANG=C.UTF-8 MGMT_BOX=1 \
    OPN_TEST_HOST=192.168.2.67 OPN_TEST_VMID=9110 OPN_TEST_PVE_KEY="${OPN_TEST_PVE_KEY:-/var/lib/mgmt/pve-ssh/id_ed25519}" \
    OPN_TEST_API_KEY="${OPN_TESTVM_API_KEY:-}" OPN_TEST_API_SECRET="${OPN_TESTVM_API_SECRET:-}" \
    OPN_TEST_RUN_AS="$RUN_AS" OPN_TEST_WORKDIR="$work" \
    bash "$HWT/scripts/opnsense-test-vm.sh" --base "$(git -C "$REPO" rev-parse origin/master)" --head "$sha" --no-fetch \
    >"$work.log" 2>&1 &
  hp=$!; killed=""
  while kill -0 "$hp" 2>/dev/null; do
    sleep 60
    kill -0 "$hp" 2>/dev/null || break
    if [ $(( $(date +%s) - t0 )) -gt "$RUN_TIMEOUT" ]; then killed=timeout
    else now="$(head_now "$pr" 2>/dev/null)" && [ -n "$now" ] && [ "$now" != "$sha" ] && killed="superseded by ${now:0:8}"; fi
    if [ -n "$killed" ]; then log "[#$pr@${sha:0:8}] $killed — stopping the run"; kill -TERM -- "-$hp" 2>/dev/null; sleep 20; kill -KILL -- "-$hp" 2>/dev/null; break; fi
  done
  wait "$hp"; rc=$?
  dur=$(( $(date +%s) - t0 ))
  sed 's/^/    /' "$work.log"   # the harness's own lines → the journal
  [ -f "$work/report.md" ] && { log "[#$pr@${sha:0:8}] report:"; sed 's/^/    | /' "$work/report.md"; }
  case "$killed" in
    superseded*) continue ;;   # the new head gets its own run; the old one keeps `pending`
    timeout) rc=2 ;;
  esac
  state="$(mgmt_router_state "$rc")"
  plays="$(sed -n 's/^plays under test (steps prep\/2\/3\/5): //p' "$work.log" | head -1 | tr -d '`')"
  case "$state" in
    success) desc="PASS at ${sha:0:8} in $((dur/60)) min — ${plays:-?}" ;;
    failure) desc="FAIL at ${sha:0:8}: $(grep -m1 '^FAIL: ' "$work.log" | cut -c7-80) — see the PR comment" ;;
    *)       why="$(grep -m1 '^opnsense-test-vm: ' "$work.log" | cut -c19-90)"
             [ -n "$why" ] || why="$(grep -v '^Info:' "$work.log" | tail -1 | sed 's|^.*/scripts/||' | cut -c1-80)"   # a shell error, not the harness's own die
             desc="could not run (${killed:-rc $rc}): $why — retried"
             e=0; [ -f "$RDIR/done/$sha.errors" ] && e="$(cat "$RDIR/done/$sha.errors")"
             echo $(( e + 1 )) >"$RDIR/done/$sha.errors" ;;
  esac
  if [ -f "$work/report.md" ]; then
    bodyf="$(mktemp)"
    { echo "**opnsense-test-vm** — the management box validated \`${sha:0:8}\` on test VM 9110 with master@$M8's harness (ADR-152 step 1; PR code ran as the sandbox user). Router paths: $touched"
      echo; head -c 60000 "$work/report.md"; } >"$bodyf"
    head_now "$pr" | grep -qx "$sha" && mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"
    rm -f "$bodyf"
  fi
  if [ "$(head_now "$pr")" = "$sha" ]; then post "$sha" "$state" "$desc"
  else log "[#$pr] head moved during the run — no verdict on ${sha:0:8}"; fi
  echo "$(date +%s) $state $dur" >"$RDIR/last-verdict"
  [ "$state" = error ] || rm -f "$RDIR/done/$sha.errors"
  find "$RDIR/runs" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null
done
git -C "$REPO" worktree remove --force "$HWT" >/dev/null 2>&1 || true
date +%s >"$RDIR/last-run"
log "done"
