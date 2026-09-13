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

prs="$(gh_api_paged "pulls?state=open&base=master")" || { log "PROBE-FAIL: PR list failed — evaluating nothing"; exit 1; }
count=$(jq 'length' <<<"$prs"); log "open PRs on ${ORG}/${MGMT_REPO} (base master): $count"

while IFS=$'\t' read -r pr sha; do
  [ -n "$pr" ] || continue
  if verdicted "$sha"; then continue; fi
  log "[#$pr@${sha:0:8}] evaluating"
  git -C "$REPO" fetch --quiet origin "refs/pull/$pr/head:refs/mgmt/pr-$pr" || { log "[#$pr] fetch of the head failed — skipped this run"; continue; }
  base="$(git -C "$REPO" merge-base origin/master "$sha" 2>/dev/null)" || { log "[#$pr] no merge-base with master — skipped"; continue; }
  files_out="$(git -C "$REPO" diff --name-only "$base" "$sha" --)" || { log "[#$pr] diff of the head failed — skipped this run"; continue; }   # an empty list reads as "no surface": never from a failed read
  files=(); [ -n "$files_out" ] && mapfile -t files <<<"$files_out"
  # the classifier's rc decides between "no box-held surface" (a success) and "could not classify"
  # (no verdict, retried next tick) — `$(…) ||`, never mapfile over a process substitution (#1631)
  roots_out="$(printf '%s\n' "${files[@]}" | mgmt_roots_touched "$POL")" || { log "[#$pr] classifier failed (policy unreadable) — skipped this run"; continue; }
  roots=(); [ -n "$roots_out" ] && mapfile -t roots <<<"$roots_out"
  if [ ${#roots[@]} -eq 0 ]; then
    mgmt_post_status "$sha" "$CTX" success "no box-held surface touched" && touch "$SDIR/done/$sha"
    continue
  fi
  # stage 1
  hits="$(mgmt_stage1 "$POL" "$REPO" "$base" "$sha")" || { log "[#$pr] stage 1 could not run (policy unreadable) — skipped this run"; continue; }
  if [ -n "$hits" ]; then
    first="$(head -1 <<<"$hits")"; rule="${first%%$'\t'*}"; rest="${first#*$'\t'}"; file="${rest%%$'\t'*}"
    bodyf="$(mktemp)"
    {
      echo "**management-sentinel: stage 1 refused** (input allowlist, \`policy/mgmt/plan-input.yaml\` on master) — nothing was planned."
      echo; echo "| rule | file | detail |"; echo "|---|---|---|"
      awk -F'\t' '{printf "| %s | `%s` | `%s` |\n", $1, $2, $3}' <<<"$hits"
      echo; echo "A PR that legitimately needs this lands the allowlist widening first (its own change), or gets a human plan in the jail."
    } >"$bodyf"
    mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
    mgmt_post_status "$sha" "$CTX" failure "stage 1: $rule on ${file##*/} — human plan" && touch "$SDIR/done/$sha"
    continue
  fi
  # stage 2
  wt="$SDIR/wt-${sha:0:8}"; rm -rf "$wt"; git -C "$REPO" worktree prune
  git -C "$REPO" worktree add --quiet --detach "$wt" "$sha" || { log "[#$pr] worktree add failed"; continue; }
  bodyf="$(mktemp)"; desc=""; state=success; failed_roots=""
  echo "**management-sentinel** — \`tofu plan\` of ${sha:0:8} on the management box (ADR-131). Addresses and counts only; the plan text stays on the box." >"$bodyf"
  for root in "${roots[@]}"; do
    out="$wt/.mgmt-plan-$root.bin"
    mgmt_plan_root "$wt" "$POL" "$root" "$out" false; rc=$?
    if [ $rc = 1 ]; then
      state=failure; failed_roots="$failed_roots $root"
      tail3="$(tail -3 "$out.log" 2>/dev/null)"
      { echo; echo "### \`$root\` — plan ERRORED"; 
        if printf '%s' "$tail3" | grep -q '='; then echo "see the box journal (output withheld: it may carry values)"; else echo '```'; printf '%s\n' "$tail3"; echo '```'; fi
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
        note="$(mgmt_root_exclude_note "$POL" "$root")"
        echo; echo "⚠ **Not planned on the box** (policy \`plan_exclude_types\`${note:+ — $note}): $excl_types."
      fi
      if [ -n "$changes" ]; then echo; echo "| address | actions |"; echo "|---|---|"; awk -F'\t' '{printf "| `%s` | %s |\n", $1, $2}' <<<"$changes"; else echo; echo "No changes."; fi
      echo
      if [ "$(mgmt_root_apply "$POL" "$root")" != true ]; then echo "apply: plan only — this root is not on the box's apply list."
      elif [ -z "$changes" ]; then echo "apply: nothing to apply."
      else
        outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$POL" "$root")"
        if [ -z "$outside" ]; then echo "apply: all addresses inside the apply allowlist — the box applies after merge."
        else n=$(wc -l <<<"$outside"); echo "apply: $n address(es) OUTSIDE the apply allowlist — human apply: $(tr '\n' ' ' <<<"$outside" | sed 's/ $//' | sed 's/ /, /g')"; fi
      fi
    } >>"$bodyf"
    log "[#$pr] $root: +$a ~$c -$d ${rs}"
  done
  mgmt_upsert_comment "$pr" "$MARKER" "$bodyf"; rm -f "$bodyf"
  if [ "$state" = failure ]; then desc="plan errored:$failed_roots — see the PR comment"; fi
  mgmt_post_status "$sha" "$CTX" "$state" "${desc% }" && touch "$SDIR/done/$sha"
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
done < <(jq -r '.[] | [.number, .head.sha] | @tsv' <<<"$prs")

date +%s >"$SDIR/last-run"
log "done"
