#!/usr/bin/env bash
# mgmt-sentinel — the management sentinel: plan-on-PR on the management box (ADR-131,
# docs/management-box.md §MB3; the tofu lane's L1, iac-lane.md §Assurance layers).
#
# For every open homelab PR head that touches a box-held root (policy/mgmt/plan-input.yaml, read
# from MASTER — never the PR's copy):
#   stage 1  the PR tree as DATA: deny_paths / symlinks / deny_patterns over the added lines.
#            A hit ⇒ `management-sentinel` = failure, rule named, NOTHING executed.
#   stage 2  `tofu plan` in an EPHEMERAL worktree of the head (never this box's system checkout),
#            providers from the committed lockfile (-lockfile=readonly) out of the local cache,
#            main's state via -state=. Then `tofu show -json` → addresses + counts.
# VERDICT-ONLY leaves the box: the commit status + one PR comment (addresses, action counts, and
# whether the apply allowlist covers them). Plan text stays in the journal + local files.
# A head touching no box-held surface gets success "no box-held surface touched" (v1: the box
# posts every verdict; the in-cluster no-root poster arrives with the required flip — §MB3).
#
# Usage:  scripts/mgmt-sentinel.sh            # one pass over the open PRs (the timer's unit)
#         MGMT_SHADOW=1 scripts/mgmt-sentinel.sh   # no GitHub writes; verdict ledger under done/
#         scripts/mgmt-sentinel.sh --human-plan <pr> [--yes]
#            THE ESCAPE HATCH (FU-237 (e), §MB3 "When the box refuses"): ONE PR head, ordered by a
#            human who has read the diff (the jail's `devbox run mgmt-human-plan -- <pr>` ssh-es
#            here). Stage 1 still runs and is REPORTED — in the terminal and in the verdict
#            comment as "overridden" — but does not refuse; stage 2 plans as usual; the plan text
#            is shown in the terminal (the human READS it, as with mgmt-tf plan) and the verdict
#            is posted only after a y/N confirmation (`--yes` skips it; no tty + no --yes = no
#            post). The timer never takes this path: a refused head stays red until a human acts.
# Env: see scripts/mgmt-lib.sh. Plus MGMT_SENTINEL_DIR (default /var/lib/mgmt/sentinel) — its clone,
# worktrees, done/ ledger, last-run stamp, and .lock (shared with mgmt-apply: one state file).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"

ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
SDIR="${MGMT_SENTINEL_DIR:-/var/lib/mgmt/sentinel}"
REPO="$SDIR/homelab"; export REPO
CTX="management-sentinel"; MARKER="<!-- management-sentinel -->"
mkdir -p "$SDIR/done"

HUMAN=0; HPR=""; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --human-plan) HPR="${2:-}"; shift; case "$HPR" in ''|*[!0-9]*) echo "usage: $0 [--human-plan <pr> [--yes]]" >&2; exit 2 ;; esac; HUMAN=1 ;;
    --yes) YES=1 ;;
    *) echo "usage: $0 [--human-plan <pr> [--yes]]" >&2; exit 2 ;;
  esac
  shift
done

if [ "${MGMT_SHADOW:-0}" != 1 ] && ! mgmt_gh_token >/dev/null; then
  log "no App token (MGMT_GH_APP_* unset or key unreadable) — running SHADOW"; export MGMT_SHADOW=1
fi
exec 9>"$SDIR/.lock"; flock -w 600 9 || { log "PROBE-FAIL: lock busy for 10 min"; exit 1; }

mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch of $REPO_URL failed"; exit 1; }
POL="$(mgmt_policy_load "$REPO" "${MGMT_POLICY_REF:-origin/master}")" || exit 1  # MGMT_POLICY_REF: a TEST knob only (a branch's policy before it lands) — production reads master
trap 'rm -f "$POL"' EXIT

verdicted() {   # <sha> → 0 if already judged
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then [ -f "$SDIR/done/$1" ]; return; fi
  local n
  n="$(gh_api GET "commits/$1/status" | jq --arg c "$CTX" '[.statuses[]|select(.context==$c)]|length')" || { echo probe-fail; return 1; }
  [ "${n:-0}" -gt 0 ]
}

if [ $HUMAN = 1 ]; then
  # one head, named by the human; must be OPEN and master-bound (the same population the timer judges)
  one="$(gh_api GET "pulls/$HPR")" || { log "PROBE-FAIL: PR #$HPR unreadable"; exit 1; }
  [ "$(jq -r '.state' <<<"$one")" = open ] && [ "$(jq -r '.base.ref' <<<"$one")" = master ] \
    || { log "#$HPR is not an open master-bound PR (state $(jq -r .state <<<"$one"), base $(jq -r .base.ref <<<"$one")) — nothing to plan"; exit 1; }
  prs="$(jq -c '[.]' <<<"$one")"
  log "HUMAN PLAN of #$HPR@$(jq -r '.head.sha[0:8]' <<<"$one") — stage 1 reported, not enforced; the verdict posts only on confirmation"
else
  prs="$(gh_api_paged "pulls?state=open&base=master")" || { log "PROBE-FAIL: PR list failed — evaluating nothing"; exit 1; }
  count=$(jq 'length' <<<"$prs"); log "open PRs on ${ORG}/${MGMT_REPO} (base master): $count"
fi

# human_confirm <pr> <sha> <state> → 0 to post. --yes skips; no tty and no --yes = no post (rc 1).
human_confirm() {
  [ $YES = 1 ] && return 0
  [ -r /dev/tty ] && [ -w /dev/tty ] || { log "no tty and no --yes — NOT posting the verdict for #$1@${2:0:8}"; return 1; }
  local ans
  printf 'post management-sentinel=%s on #%s@%s under homelab-sentinel? [y/N] (the loops wait on the lock — answer within 10 min) ' "$3" "$1" "${2:0:8}" >/dev/tty
  # -t 600: the prompt holds SDIR/.lock, which the timer and mgmt-apply wait on for at most 600 s
  # (review finding on PR#1721) — an unanswered prompt times out to "no" before they PROBE-FAIL
  read -r -t 600 ans </dev/tty || ans=""
  case "$ans" in y|Y|yes) return 0 ;; *) log "declined — nothing posted for #$1@${2:0:8}"; return 1 ;; esac
}
# head_still <pr> <sha> → 0 while the PR's head is still <sha> (a push during the plan = the verdict is stale)
head_still() {
  local now; now="$(gh_api GET "pulls/$1" | jq -r '.head.sha // empty')" || return 1
  [ "$now" = "$2" ] || { log "#$1 head moved to ${now:0:8} during the plan — NOT posting on ${2:0:8}"; return 1; }
}
human_stamp=""

while IFS=$'\t' read -r pr sha; do
  [ -n "$pr" ] || continue
  if [ $HUMAN = 0 ] && verdicted "$sha"; then continue; fi
  log "[#$pr@${sha:0:8}] evaluating"
  mgmt_git -C "$REPO" fetch --quiet origin "refs/pull/$pr/head:refs/mgmt/pr-$pr" || { log "[#$pr] fetch of the head failed — skipped this run"; continue; }
  base="$(git -C "$REPO" merge-base origin/master "$sha" 2>/dev/null)" || { log "[#$pr] no merge-base with master — skipped"; continue; }
  files_out="$(git -C "$REPO" diff --name-only "$base" "$sha" --)" || { log "[#$pr] diff of the head failed — skipped this run"; continue; }   # an empty list reads as "no surface": never from a failed read
  files=(); [ -n "$files_out" ] && mapfile -t files <<<"$files_out"
  # the classifier's rc decides between "no box-held surface" (a success) and "could not classify"
  # (no verdict, retried next tick) — `$(…) ||`, never mapfile over a process substitution (#1631)
  roots_out="$(printf '%s\n' "${files[@]}" | mgmt_roots_touched "$POL")" || { log "[#$pr] classifier failed (policy unreadable) — skipped this run"; continue; }
  roots=(); [ -n "$roots_out" ] && mapfile -t roots <<<"$roots_out"
  if [ ${#roots[@]} -eq 0 ]; then
    if [ $HUMAN = 1 ]; then log "[#$pr] touches no box-held surface — nothing to override; the in-cluster half posts this head's success"; continue; fi
    mgmt_post_status "$sha" "$CTX" success "no box-held surface touched" && touch "$SDIR/done/$sha"
    continue
  fi
  # stage 1
  hits="$(mgmt_stage1 "$POL" "$REPO" "$base" "$sha")" || { log "[#$pr] stage 1 could not run (policy unreadable) — skipped this run"; continue; }
  overridden=""
  if [ -n "$hits" ] && [ $HUMAN = 1 ]; then
    overridden="$hits"
    log "[#$pr] stage 1 would REFUSE — overridden by the human plan:"; awk -F'\t' '{printf "    %s  %s  (%s)\n", $1, $2, $3}' <<<"$hits"
    hits=""
  fi
  if [ -n "$hits" ]; then
    first="$(head -1 <<<"$hits")"; rule="${first%%$'\t'*}"; rest="${first#*$'\t'}"; file="${rest%%$'\t'*}"
    bodyf="$(mktemp)"
    {
      echo "**management-sentinel: stage 1 refused** (input allowlist, \`policy/mgmt/plan-input.yaml\` on master) — nothing was planned."
      echo; echo "| rule | file | detail |"; echo "|---|---|---|"
      awk -F'\t' -v bt='`' '{printf "| %s | %s%s%s | %s%s%s |\n", $1, bt, $2, bt, bt, $3, bt}' <<<"$hits"
      echo; echo "A PR that legitimately needs this lands the allowlist widening first (its own change), or a human who has read the diff orders the plan from the jail: \`devbox run mgmt-human-plan -- $pr\` (docs/management-box.md §MB3 \"When the box refuses\")."
    } >"$bodyf"
    mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
    mgmt_post_status "$sha" "$CTX" failure "stage 1: $rule on ${file##*/} — human plan" && touch "$SDIR/done/$sha"
    continue
  fi
  # stage 2
  wt="$SDIR/wt-${sha:0:8}"; rm -rf "$wt"; git -C "$REPO" worktree prune
  git -C "$REPO" worktree add --quiet --detach "$wt" "$sha" || { log "[#$pr] worktree add failed"; continue; }
  bodyf="$(mktemp)"; desc=""; state=success; failed_roots=""
  if [ $HUMAN = 1 ]; then
    { echo "**management-sentinel: HUMAN PLAN** — \`tofu plan\` of ${sha:0:8} on the management box, ordered from the jail by a human who read the diff (ADR-131's escape hatch, §MB3 \"When the box refuses\"). Addresses and counts only; the plan text stays on the box."
      if [ -n "$overridden" ]; then
        echo; echo "Stage 1 would have refused this head — **overridden** by the human order:"
        echo; echo "| rule | file | detail |"; echo "|---|---|---|"
        awk -F'\t' -v bt='`' '{printf "| %s | %s%s%s | %s%s%s |\n", $1, bt, $2, bt, bt, $3, bt}' <<<"$overridden"
      fi
    } >"$bodyf"
    desc="human plan: "
  else
    echo "**management-sentinel** — \`tofu plan\` of ${sha:0:8} on the management box (ADR-131). Addresses and counts only; the plan text stays on the box." >"$bodyf"
  fi
  for root in "${roots[@]}"; do
    out="$wt/.mgmt-plan-$root.bin"
    mgmt_plan_root "$wt" "$POL" "$root" "$out" false; rc=$?
    if [ $HUMAN = 1 ]; then   # the human READS the plan — terminal only (stderr), never the comment
      { echo; echo "──── plan of root $root (${sha:0:8}) — rc $rc ────"; cat "$out.log" 2>/dev/null; echo "──── end of plan ────"; } >&2
    fi
    if [ $rc = 1 ]; then
      state=failure; failed_roots="$failed_roots $root"
      tail3="$(tail -3 "$out.log" 2>/dev/null)"
      # what leaves the box on an error: the tofu error HEADLINES only (`Error: …` lines, ≤3), never
      # the detail body — a provider's message can name live objects and values, and this comment
      # is public (the #1635 review: an error quoted verbatim is an existence oracle)
      heads="$(grep -E '^(│ )?Error: ' "$out.log" 2>/dev/null | sed -E 's/^│ //' | grep -v 'error running script' | head -3)"
      { echo; echo "### \`$root\` — plan ERRORED"
        if [ -n "$heads" ] && ! printf '%s' "$heads" | grep -q '='; then echo '```'; printf '%s\n' "$heads"; echo '```'; echo "(headlines only — the full log stays in the box journal)"; else echo "see the box journal (output withheld: it may carry values)"; fi
      } >>"$bodyf"
      log "[#$pr] $root plan errored: $(tr '\n' ' ' <<<"$tail3" | head -c 200)"
      continue
    fi
    if ! changes="$(mgmt_plan_changes "$wt" "$POL" "$root" "$out")"; then
      state=failure; failed_roots="$failed_roots $root"
      { echo; echo "### \`$root\` — plan SUMMARY failed (the plan ran; its summary did not — see the box journal)"; } >>"$bodyf"
      log "[#$pr] $root plan summary failed"; continue
    fi
    if [ $rc = 2 ] && [ -z "$changes" ]; then   # the plan says "changes", the summary says none — never trust the zero
      state=failure; failed_roots="$failed_roots $root"
      { echo; echo "### \`$root\` — INCONSISTENT: plan exit 2 (changes) but an empty summary — see the box journal"; } >>"$bodyf"
      log "[#$pr] $root inconsistent: plan rc=2, summary empty"; continue
    fi
    read -r a c d r <<<"$(printf '%s\n' "$changes" | mgmt_plan_counts)"; rs=""; [ "${r:-0}" -gt 0 ] && rs="×$r"
    excl_n=0; excl_types=""
    notplanned="$(mgmt_plan_not_planned "$out")"
    if [ -n "$notplanned" ]; then
      excl_n=$(wc -l <<<"$notplanned")
      # type = the address minus its name (a data source keeps its `data.` prefix)
      excl_types="$(sed -E 's/^((data\.)?[^.]+)\..*/\1/' <<<"$notplanned" | sort | uniq -c | awk '{printf "%s%s `%s`", (NR>1?", ":""), $1, $2}')"
    fi
    excl_note=""; [ "$excl_n" -gt 0 ] && excl_note=" ($excl_n not planned)"
    desc="$desc$root: +$a ~$c -$d ${rs}${excl_note} "
    { echo; echo "### \`$root\` — +$a to add, ~$c to change, -$d to destroy${rs:+, $r to replace}"
      if [ "$excl_n" -gt 0 ]; then
        note="$(mgmt_root_exclude_note "$POL" "$root")" || note="(reason unreadable this run)"
        echo; echo "⚠ **Not planned on the box** (policy \`plan_exclude_types\`${note:+ — $note}): $excl_types."
      fi
      if [ -n "$changes" ]; then echo; echo "| address | actions |"; echo "|---|---|"; awk -F'\t' '{printf "| `%s` | %s |\n", $1, $2}' <<<"$changes"; else echo; echo "No changes."; fi
      echo
      ap="$(mgmt_root_apply "$POL" "$root")" || ap=unknown   # a failed read must not print "plan only" for an apply:true root
      if [ "$ap" = unknown ]; then echo "apply: UNKNOWN — the apply flag could not be read from the policy this run; the apply loop reads it again after merge."
      elif [ "$ap" != true ]; then echo "apply: plan only — this root is not on the box's apply list."
      elif [ -z "$changes" ]; then echo "apply: nothing to apply."
      else
        outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$POL" "$root")" || outside="(allowlist unreadable — the apply loop refuses until it reads)"
        if [ -z "$outside" ]; then echo "apply: all addresses inside the apply allowlist — the box applies after merge."
        else n=$(wc -l <<<"$outside"); echo "apply: $n address(es) OUTSIDE the apply allowlist — human apply: $(tr '\n' ' ' <<<"$outside" | sed 's/ $//' | sed 's/ /, /g')"; fi
      fi
    } >>"$bodyf"
    log "[#$pr] $root: +$a ~$c -$d ${rs}"
  done
  if [ "$state" = failure ]; then desc="plan errored:$failed_roots — see the PR comment"; [ $HUMAN = 1 ] && desc="human plan: $desc"; fi
  if [ -n "$overridden" ] && [ "$state" = success ]; then
    desc="${desc% } — stage 1 overridden: $(awk -F'\t' 'NR==1{f=$2; sub(".*/","",f); printf "%s %s", $1, f}' <<<"$overridden")"
  fi
  if [ $HUMAN = 1 ]; then
    if ! human_confirm "$pr" "$sha" "$state" || ! head_still "$pr" "$sha"; then
      rm -f "$bodyf"; git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"; human_stamp=declined; continue
    fi
  fi
  mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
  mgmt_post_status "$sha" "$CTX" "$state" "${desc% }" && touch "$SDIR/done/$sha"
  [ $HUMAN = 1 ] && human_stamp="$state"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
done < <(jq -r '.[] | [.number, .head.sha] | @tsv' <<<"$prs")

if [ $HUMAN = 1 ]; then
  case "$human_stamp" in
    success) log "HUMAN PLAN posted: #$HPR management-sentinel=success" ;;
    failure) log "HUMAN PLAN posted: #$HPR management-sentinel=FAILURE (the plan itself errored — fix the head)"; exit 1 ;;
    declined) exit 3 ;;
    *) log "HUMAN PLAN: nothing posted for #$HPR (no box-held surface, or the head could not be evaluated — see above)"; exit 1 ;;
  esac
fi

date +%s >"$SDIR/last-run"
log "done"
