#!/usr/bin/env bash
# mgmt-apply — the management box's apply loop: master moved → plan → apply-allowlist check →
# apply (ADR-131 phase B/C, docs/management-box.md §MB1 + §MB3). The residue the box may apply
# unattended is policy/mgmt/plan-input.yaml `apply_addresses` (read from MASTER); every changed
# address must match, or the box REFUSES and says so (status `management-apply` on the commit).
#
#   first run   stamps the current master as the baseline — nothing is ever applied on a first run
#   each run    fetch; new master sha? → roots with apply:true touched since the last applied sha →
#               stage 1 over the master diff too (an admin push bypasses the PR gate) → plan -out →
#               show -json → allowlist → `tofu apply plan.bin` (never re-planned in between) → stamp
#   refusal     status failure + refused-rev (no re-plan every tick; a NEW master sha re-evaluates)
#   MGMT_SHADOW=1  plan + check, log the would-be apply, no apply, no status, no stamp
# Usage: scripts/mgmt-apply.sh   (the timer's unit). Env: scripts/mgmt-lib.sh + MGMT_APPLY_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"

ORG="${ORG:-teststuffstash}"; MGMT_REPO="${MGMT_REPO:-homelab}"
REPO_URL="${MGMT_REPO_URL:-https://github.com/${ORG}/${MGMT_REPO}.git}"
ADIR="${MGMT_APPLY_DIR:-/var/lib/mgmt/apply}"
REPO="$ADIR/homelab"; export REPO
CTX="management-apply"
LOCK="${MGMT_SENTINEL_DIR:-/var/lib/mgmt/sentinel}/.lock"
mkdir -p "$ADIR" "$(dirname "$LOCK")"

if [ "${MGMT_SHADOW:-0}" != 1 ] && ! mgmt_gh_token >/dev/null; then
  log "no App token — running SHADOW (no apply, no status)"; export MGMT_SHADOW=1
fi
exec 9>"$LOCK"; flock -w 600 9 || { log "PROBE-FAIL: lock busy for 10 min"; exit 1; }

mgmt_clone "$REPO" "$REPO_URL" || { log "PROBE-FAIL: clone/fetch failed"; exit 1; }
sha="$(git -C "$REPO" rev-parse origin/master)" || exit 1
last=""; [ -f "$ADIR/applied-rev" ] && last="$(cat "$ADIR/applied-rev")"
refused=""; [ -f "$ADIR/refused-rev" ] && refused="$(cat "$ADIR/refused-rev")"

stamp() { [ "${MGMT_SHADOW:-0}" = 1 ] && { log "[shadow] would stamp ${1:0:8}"; return; }; printf '%s' "$1" >"$ADIR/applied-rev"; rm -f "$ADIR/refused-rev"; }
refuse() {  # <sha> <desc> <comment-lines>
  log "REFUSED ${1:0:8}: $2"; [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/    /'
  mgmt_post_status "$1" "$CTX" failure "$2"
  [ "${MGMT_SHADOW:-0}" = 1 ] || printf '%s' "$1" >"$ADIR/refused-rev"
}

if [ -z "$last" ]; then
  log "first run — baseline set at ${sha:0:8}, nothing applied"; stamp "$sha"; exit 0
fi
[ "$sha" = "$last" ] && { log "master at ${sha:0:8} = applied — nothing to do"; exit 0; }
[ "$sha" = "$refused" ] && { log "master at ${sha:0:8} was REFUSED — waiting for a new commit or a human apply"; exit 0; }

POL="$(mgmt_policy_load "$REPO" "${MGMT_POLICY_REF:-origin/master}")" || exit 1  # MGMT_POLICY_REF: a TEST knob only (a branch's policy before it lands) — production reads master
trap 'rm -f "$POL"' EXIT
# FAIL CLOSED, no stamp (the #1631 third round): a failed diff or classifier read must never look
# like "touches no apply root" — that path STAMPS the sha as applied and the loop would advance its
# baseline past a master push it never classified. `$(…) ||`, never `mapfile < <(…)` (rc discarded).
files_out="$(git -C "$REPO" diff --name-only "$last" "$sha" --)" || { log "PROBE-FAIL: diff ${last:0:8}..${sha:0:8} failed — not stamping, next run retries"; exit 1; }
files=(); [ -n "$files_out" ] && mapfile -t files <<<"$files_out"
roots_out="$(printf '%s\n' "${files[@]}" | mgmt_roots_touched "$POL")" || { log "PROBE-FAIL: classifier failed (policy unreadable) — not stamping, next run retries"; exit 1; }
roots=(); [ -n "$roots_out" ] && mapfile -t roots <<<"$roots_out"
apply_roots=()
for r in "${roots[@]}"; do
  ap="$(mgmt_root_apply "$POL" "$r")" || { log "PROBE-FAIL: apply flag of $r unreadable — not stamping, next run retries"; exit 1; }
  [ "$ap" = true ] && apply_roots+=("$r")
done
if [ ${#apply_roots[@]} -eq 0 ]; then
  log "${last:0:8}..${sha:0:8} touches no apply:true root (${#files[@]} files) — stamping"; stamp "$sha"; exit 0
fi
log "${last:0:8}..${sha:0:8} touches: ${apply_roots[*]}"

hits="$(mgmt_stage1 "$POL" "$REPO" "$last" "$sha")" || { log "PROBE-FAIL: stage 1 could not run (policy unreadable) — not applying, not stamping; next run retries"; exit 1; }
if [ -n "$hits" ]; then
  first="$(head -1 <<<"$hits")"; rule="${first%%$'\t'*}"
  refuse "$sha" "stage 1: $rule on master diff — human apply" "$hits"; exit 0
fi

git -C "$REPO" reset --hard --quiet "$sha" || { log "PROBE-FAIL: reset to $sha failed"; exit 1; }
for root in "${apply_roots[@]}"; do
  rel="$(mgmt_root_dir "$POL" "$root")" && [ -n "$rel" ] && [ "$rel" != null ] || { refuse "$sha" "$root: dir unreadable from the policy — human"; exit 0; }
  out="$ADIR/plan-$root.bin"; rm -f "$out" "$out.log"
  mgmt_plan_root "$REPO" "$POL" "$root" "$out" true; rc=$?
  if [ $rc = 1 ]; then refuse "$sha" "$root: plan errored — see the box journal" "$(tail -5 "$out.log")"; exit 0; fi
  if ! changes="$(mgmt_plan_changes "$REPO" "$POL" "$root" "$out")"; then refuse "$sha" "$root: plan summary failed — see the box journal"; exit 0; fi
  if [ $rc = 2 ] && [ -z "$changes" ]; then refuse "$sha" "$root: plan exit 2 but an empty summary — inconsistent, human"; exit 0; fi
  read -r a c d r <<<"$(printf '%s\n' "$changes" | mgmt_plan_counts)"; rs=""; [ "${r:-0}" -gt 0 ] && rs="×$r"
  if [ -z "$changes" ]; then log "$root: no changes"; continue; fi
  outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$POL" "$root")" || { refuse "$sha" "$root: apply allowlist unreadable — human apply"; exit 0; }
  if [ -n "$outside" ]; then
    n=$(wc -l <<<"$outside")
    refuse "$sha" "$root: $n address(es) outside the apply allowlist — human apply" "$outside"; exit 0
  fi
  log "$root: +$a ~$c -$d ${rs} — all inside the apply allowlist"
  printf '%s\n' "$changes" | sed 's/^/    /'
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then log "[shadow] would apply $root now"; continue; fi
  # ⚠ a saved plan does NOT carry the -state= override (found on the box, 2026-09-13: apply read
  # the default path, an empty state, "Saved plan does not match the given state") — repeat it.
  stateargs=""; [ -f "$REPO/$rel/backend.tf" ] || stateargs="-state=$MGMT_STATE_DIR/$root/terraform.tfstate"
  # shellcheck disable=SC2086
  if ( cd "$REPO" && devbox run --quiet -- tofu -chdir="$rel" apply -input=false $stateargs "$out" ) >"$out.apply.log" 2>&1; then
    log "$root: APPLIED (+$a ~$c -$d)"
    mgmt_post_status "$sha" "$CTX" success "$root: +$a ~$c -$d applied by the management box"
  else
    tail -5 "$out.apply.log" | sed 's/^/    /'
    refuse "$sha" "$root: apply errored — see the box journal (half-applied? human)"; exit 0
  fi
done
[ "${MGMT_SHADOW:-0}" = 1 ] || { stamp "$sha"; date +%s >"$ADIR/last-run"; }
log "done"
