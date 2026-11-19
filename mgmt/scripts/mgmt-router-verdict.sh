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
# CARRY: before a run, the head's content key (mgmt_router_key — the inputs are listed there) is looked
# up in the box's own PASS record; a match posts `success` "PASS carried from <sha8>" at once, no VM, no
# PR comment. FAILs and errors are never carried (they re-run). The bot's up-to-date merges of a
# non-router master commit no longer cost a ~20-min run each.
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

# ── the CONTENT KEY: carry a PASS to a head whose verdict inputs are unchanged ─────────────────
# Master requires up-to-date branches, so every master merge makes the merge bot update every open PR:
# a new head sha with no verdict. When nothing the run depends on moved, the earlier PASS is carried
# instead of a fresh ~20-min run. mgmt_router_key <repo> <base> <head> <policy> <baseline-id> → a
# sha256 over git object ids ONLY (nothing of the head is executed), rc 1 when any input is unreadable
# (no key = no carry = a run — the safe direction). The inputs, each because the harness reads it:
#   - the router-path blobs (mode, blob id, path; the shared classifier over master's policy, which
#     names what deploys) at HEAD (step 3/4/5 converge the head), at BASE (step 2 converges the base)
#     and at merge-base(BASE, HEAD) (the plays under test + step `all` derive from that diff) — plus
#     the glob list itself;
#   - the harness as run from master (= BASE: the loop passes --base origin/master and runs that
#     worktree's copy): scripts/opnsense-test-vm.sh, ansible/test-vm/** (guard, test inventory,
#     overrides), ansible/inventory.yml (the prod host it refuses and hands the plays), and this
#     script (the harness's env and invocation);
#   - the toolchain the harness puts on PATH (`devbox shellenv` at BASE): devbox.lock's entries for
#     ansible, python3, yq-go, jq, curl, openssl — a pin bump of another tool does not invalidate;
#     the collection pin and the controller python are router paths already (requirements.yml,
#     controller-env/**);
#   - the test VM's baseline identity: `vmid/snapshot@snaptime` of the snapshot step 1 rolls back to
#     (`rebaseline` and a VM rebuild replace the snapshot, so its snaptime moves with the firmware —
#     docs/opnsense-test-vm.md §Recipes "Moving the baseline"). Empty = unreadable = no key.
MGMT_ROUTER_KEY_TOOLS='ansible python3 yq-go jq curl openssl'
_mgmt_router_tree() { # <repo> <rev> <policy> → "mode type blob\tpath" for the router paths at rev; rc 1 unreadable
  local lst paths
  lst="$(git -C "$1" ls-tree -r --full-tree "$2")" || return 1
  paths="$(cut -f2 <<<"$lst" | mgmt_router_touched "$3")" || return 1
  [ -n "$paths" ] || return 0
  awk -F'\t' 'NR == FNR { want[$0] = 1; next } ($2 in want)' <(printf '%s\n' "$paths") <(printf '%s\n' "$lst")
}
mgmt_router_key() {
  local repo="$1" base="$2" head="$3" pol="$4" bl="$5" mb globs side rev t p id tools body
  [ -n "$bl" ] || return 1
  base="$(git -C "$repo" rev-parse --verify -q "$base^{commit}")" || return 1
  head="$(git -C "$repo" rev-parse --verify -q "$head^{commit}")" || return 1
  mb="$(git -C "$repo" merge-base "$base" "$head")" || return 1
  globs="$(mgmt_router_globs "$pol")" || return 1
  tools="$(git -C "$repo" show "$base:devbox.lock" 2>/dev/null | jq -c -S --arg t "$MGMT_ROUTER_KEY_TOOLS" '
             ($t | split(" ")) as $want
             | [.packages | to_entries[] | select((.key | split("@")[0]) as $n | $want | index($n))
                | {k: .key, r: .value.resolved, v: .value.version, s: .value.systems["x86_64-linux"].store_path}]')" \
    && [ -n "$tools" ] && [ "$tools" != "[]" ] || return 1
  body="$(
    echo "mgmt-router-key v1"
    echo "baseline $bl"
    echo "globs"; printf '%s\n' "$globs"
    for side in "base $base" "merge-base $mb" "head $head"; do
      rev="${side#* }"; echo "== ${side%% *}"
      t="$(_mgmt_router_tree "$repo" "$rev" "$pol")" || return 1
      printf '%s\n' "$t"
    done
    echo "== harness"
    for p in scripts/opnsense-test-vm.sh ansible/test-vm ansible/inventory.yml mgmt/scripts/mgmt-router-verdict.sh; do
      id="$(git -C "$repo" rev-parse --verify -q "$base:$p")" || id=absent
      echo "$p $id"
    done
    echo "== tools $tools"
  )" || return 1
  printf '%s\n' "$body" | sha256sum | cut -d' ' -f1
}
# The PASS record: box-local, one line per PASS "<epoch> <key> <head sha>", in a 0700 dir only the
# loop's own user writes (the sandbox user that runs PR code can traverse $RDIR, never this dir).
# A FAIL is NOT recorded, so never carried: a step assertion can be a flake or VM state (the
# 2026-10-04 galaxy-cache death; a half-converged VM), and the next run is the arbiter — the per-sha
# memo still keeps a FAIL head from re-running itself. `error` is never recorded either.
# mgmt_router_carry_from <file> <key> → the sha of the newest PASS with that key; rc 1 = none. A file
# that is missing, not owned by this uid, group/world-writable, or a malformed line = no carry.
mgmt_router_carry_from() {
  local f="$1" k="$2"
  [[ "$k" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ -f "$f" ] && [ -O "$f" ] || return 1
  [ -z "$(find "$f" -maxdepth 0 -perm /022 2>/dev/null)" ] || return 1
  awk -v k="$k" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9a-f]+$/ && length($2) == 64 && $3 ~ /^[0-9a-f]+$/ && length($3) == 40 && NF == 3 \
                 && $2 == k { s = $3 } END { if (s == "") exit 1; print s }' "$f"
}
# mgmt_router_record <file> <key> <sha> <state> [max-lines] [max-age-days] — a PASS only (above); the
# file is pruned to the newest max-lines (500) younger than max-age-days (30) and replaced atomically.
mgmt_router_record() {
  local f="$1" k="$2" sha="$3" st="$4" max="${5:-500}" age="${6:-30}" now tmp
  [ "$st" = success ] || return 0
  [[ "$k" =~ ^[0-9a-f]{64}$ ]] && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  now="$(date +%s)"; tmp="$f.tmp.$$"
  { [ -f "$f" ] && awk -v cut=$(( now - age * 86400 )) '$1 ~ /^[0-9]+$/ && $1 >= cut && NF == 3' "$f"
    echo "$now $k $sha"; } | tail -n "$max" >"$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$f"
}

[ "${MGMT_ROUTER_LIB_ONLY:-0}" = 1 ] && return 0 2>/dev/null

# ── the pass ────────────────────────────────────────────────────────────────────────────────────
ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
RDIR="${MGMT_ROUTER_DIR:-/var/lib/mgmt-router}"
RUN_AS="${MGMT_ROUTER_RUN_AS:-mgmt-opnsense-test}"
MAXERR="${MGMT_ROUTER_MAX_ERRORS:-3}"
RUN_TIMEOUT="${MGMT_ROUTER_RUN_TIMEOUT:-3600}"   # s — a healthy run is ~10–16 min (+7 with step all)
TEXTFILE="${MGMT_ROUTER_TEXTFILE:-}"
TVM_HOST=192.168.2.67; TVM_VMID=9110; TVM_PVE=192.168.2.59; TVM_SNAP=baseline   # the harness's defaults for the last two
REPO="$RDIR/homelab"; export REPO
PASSES="$RDIR/keys/passes"   # the content-key PASS record (mgmt_router_record) — 0700, the sandbox user never writes it
mkdir -p "$RDIR/done" "$RDIR/runs" "$RDIR/keys"; chmod 0711 "$RDIR"; chmod 0700 "$RDIR/keys"

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
    # a carry posts a verdict without a run: it never touches last-verdict (the last REAL run — so
    # -Errored keeps reading the VM's health), and -Stale reads the pass, which a carry-only pass ends
    local lct=0 cn=0
    [ -s "$RDIR/carried" ] && read -r lct cn <"$RDIR/carried"
    echo "# HELP mgmt_router_verdict_carried_total PASS verdicts carried to a head whose router content key matched an earlier PASS (no test-VM run)."
    echo "# TYPE mgmt_router_verdict_carried_total counter"
    echo "mgmt_router_verdict_carried_total ${cn:-0}"
    echo "# HELP mgmt_router_verdict_last_carry_timestamp_seconds When the box last carried a PASS (0 = never)."
    echo "# TYPE mgmt_router_verdict_last_carry_timestamp_seconds gauge"
    echo "mgmt_router_verdict_last_carry_timestamp_seconds ${lct:-0}"
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
BSHA="$(git -C "$REPO" rev-parse origin/master)"   # the base every run (and every key) of this pass uses
# the test VM's baseline identity for the content key — the same hypervisor ssh as the harness's step 1;
# unreadable = empty = no key = every head runs (the harness then says why the hypervisor is unreachable)
PVE_KEY="${OPN_TEST_PVE_KEY:-/var/lib/mgmt/pve-ssh/id_ed25519}"
BL="$(ssh -i "$PVE_KEY" -o BatchMode=yes -o ConnectTimeout=10 "root@$TVM_PVE" "qm config $TVM_VMID --snapshot $TVM_SNAP" 2>/dev/null \
       | sed -n "s/^snaptime: \([0-9][0-9]*\)\$/$TVM_VMID\/$TVM_SNAP@\1/p")"
[ -n "$BL" ] || log "WARN baseline snapshot identity unreadable — no PASS is carried this pass"

for row in "${todo[@]}"; do
  IFS=$'\t' read -r pr sha touched <<<"$row"
  now="$(head_now "$pr")" || { log "[#$pr] head unreadable — skipped"; continue; }
  [ "$now" = "$sha" ] || { log "[#$pr] head moved to ${now:0:8} — ${sha:0:8} is superseded (next tick)"; continue; }
  # checked here, not at selection: a PASS earlier in THIS pass carries to a later head with the same key
  key="$(mgmt_router_key "$REPO" "$BSHA" "$sha" "$POL" "$BL")" || key=""
  if [ -n "$key" ] && from="$(mgmt_router_carry_from "$PASSES" "$key")"; then
    # no PR comment: the status description is the record; the earlier run's comment stays on the thread
    post "$sha" success "PASS carried from ${from:0:8} — router content unchanged (key ${key:0:12})"
    log "[#$pr@${sha:0:8}] PASS carried from ${from:0:8} — key ${key:0:12} unchanged, no run"
    cn=0; [ -s "$RDIR/carried" ] && read -r _ cn <"$RDIR/carried"
    echo "$(date +%s) $(( ${cn:-0} + 1 ))" >"$RDIR/carried"
    continue
  fi
  [ -n "$key" ] || log "[#$pr@${sha:0:8}] no content key (an input unreadable) — running"
  post "$sha" pending "running on the OPNsense test VM (master@$M8 harness, ~15 min)"
  work="$RDIR/runs/${sha:0:12}"; rm -rf "$work"; mkdir -p "$work"
  t0=$(date +%s)
  # the harness's environment, named: never the unit's env file (the test VM's own pair only)
  setsid env -i PATH="$PATH" HOME="${HOME:-/root}" LANG=C.UTF-8 MGMT_BOX=1 \
    OPN_TEST_HOST="$TVM_HOST" OPN_TEST_VMID="$TVM_VMID" OPN_TEST_PVE="$TVM_PVE" OPN_TEST_SNAPSHOT="$TVM_SNAP" OPN_TEST_PVE_KEY="$PVE_KEY" \
    OPN_TEST_API_KEY="${OPN_TESTVM_API_KEY:-}" OPN_TEST_API_SECRET="${OPN_TESTVM_API_SECRET:-}" \
    OPN_TEST_RUN_AS="$RUN_AS" OPN_TEST_WORKDIR="$work" \
    bash "$HWT/scripts/opnsense-test-vm.sh" --base "$BSHA" --head "$sha" --no-fetch \
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
  # a finished PASS validated this content even if the head moved meanwhile — record it (PASS only)
  [ -z "$key" ] || mgmt_router_record "$PASSES" "$key" "$sha" "$state" || log "WARN could not record the PASS key for ${sha:0:8}"
  [ "$state" = error ] || rm -f "$RDIR/done/$sha.errors"
  find "$RDIR/runs" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null
done
git -C "$REPO" worktree remove --force "$HWT" >/dev/null 2>&1 || true
date +%s >"$RDIR/last-run"
log "done"
