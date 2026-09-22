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
#   Talos       a talos_machine_configuration_apply change must ALSO pass mgmt_talos_gate (no_reboot,
#               in-place, worker unless apply_controlplane_config) and is bracketed by the health
#               gate: baseline before, bounded post-check after — a regression = status failure +
#               mgmt_apply_post_check_failed, never a revert. Clear by hand: rm $ADIR/post-check-failed
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
trap 'emit_metrics $?' EXIT
last=""; [ -f "$ADIR/applied-rev" ] && last="$(cat "$ADIR/applied-rev")"
refused=""; [ -f "$ADIR/refused-rev" ] && refused="$(cat "$ADIR/refused-rev")"

stamp() { [ "${MGMT_SHADOW:-0}" = 1 ] && { log "[shadow] would stamp ${1:0:8}"; return; }; printf '%s' "$1" >"$ADIR/applied-rev"; rm -f "$ADIR/refused-rev" "$ADIR/refused-addresses"; }
refuse() {  # <sha> <desc> <comment-lines>
  log "REFUSED ${1:0:8}: $2"; [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/    /'
  mgmt_post_status "$1" "$CTX" failure "$2"
  [ "${MGMT_SHADOW:-0}" = 1 ] && return
  printf '%s' "$1" >"$ADIR/refused-rev"
  # the address count, when the refusal has one ("N address(es) outside the apply allowlist")
  grep -o '^[^:]*: [0-9]* address' <<<"$2" | grep -o '[0-9]*' >"$ADIR/refused-addresses" || echo 0 >"$ADIR/refused-addresses"
}

# FU-252 — the metric a STANDING refusal needs (docs/management-box.md §"A standing refusal is a
# THIRD verdict shape"): the AGE of the oldest master commit this loop has not accounted for, not
# liveness. A commit touching no apply root is stamped on the next tick, so only a refusal (or a
# loop that keeps failing) lets that age grow — and it ratchets exactly as the 09-14..09-18
# refusal did. Written on EVERY exit through node_exporter's textfile collector (the box's
# node_exporter, scraped as job mgmt-node — argocd/resources/mgmt-metrics/). A PROBE-FAIL exit
# (rc≠0) leaves last-ok-tick alone, so a loop that cannot fetch reads as stale, not as fresh.
TEXTDIR="${MGMT_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
emit_metrics() {
  local rc=$1 a r n=0 oldest=0 isref=0 addrs=0 okt=0 pcf=0 tmp
  [ -d "$TEXTDIR" ] || return 0
  [ "$rc" = 0 ] && date +%s >"$ADIR/last-ok-tick"
  a="$(cat "$ADIR/applied-rev" 2>/dev/null)"; r="$(cat "$ADIR/refused-rev" 2>/dev/null)"
  [ -n "$r" ] && { isref=1; addrs="$(cat "$ADIR/refused-addresses" 2>/dev/null)"; addrs="${addrs:-0}"; }
  okt="$(cat "$ADIR/last-ok-tick" 2>/dev/null)"; okt="${okt:-0}"
  [ -s "$ADIR/post-check-failed" ] && pcf=1
  if [ -n "$a" ] && [ -n "${sha:-}" ] && [ "$a" != "$sha" ]; then
    n="$(git -C "$REPO" rev-list --count "$a..$sha" 2>/dev/null)" || n=0
    oldest="$(git -C "$REPO" log --reverse --format=%ct "$a..$sha" 2>/dev/null | sed -n 1p)"
  fi
  tmp="$(mktemp "$TEXTDIR/.mgmt_apply.XXXXXX")" || return 0
  cat >"$tmp" <<PROM
# HELP mgmt_apply_last_ok_tick_timestamp_seconds Last tick of the apply loop that completed its evaluation (any verdict).
# TYPE mgmt_apply_last_ok_tick_timestamp_seconds gauge
mgmt_apply_last_ok_tick_timestamp_seconds ${okt:-0}
# HELP mgmt_apply_refused 1 while master's head is REFUSED and waits for a human apply.
# TYPE mgmt_apply_refused gauge
mgmt_apply_refused $isref
# HELP mgmt_apply_refused_addresses Addresses outside the apply allowlist in the standing refusal (0 = not an allowlist refusal).
# TYPE mgmt_apply_refused_addresses gauge
mgmt_apply_refused_addresses ${addrs:-0}
# HELP mgmt_apply_unapplied_commits Master commits past the last applied baseline.
# TYPE mgmt_apply_unapplied_commits gauge
mgmt_apply_unapplied_commits ${n:-0}
# HELP mgmt_apply_unapplied_oldest_timestamp_seconds Commit time of the oldest master commit past the baseline (0 = none).
# TYPE mgmt_apply_unapplied_oldest_timestamp_seconds gauge
mgmt_apply_unapplied_oldest_timestamp_seconds ${oldest:-0}
# HELP mgmt_apply_post_check_failed 1 while the last Talos config apply's post-apply health check regressed (cleared by the next clean one, or by hand).
# TYPE mgmt_apply_post_check_failed gauge
mgmt_apply_post_check_failed $pcf
PROM
  chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_apply.prom"
}

if [ -z "$last" ]; then
  log "first run — baseline set at ${sha:0:8}, nothing applied"; stamp "$sha"; exit 0
fi
[ "$sha" = "$last" ] && { log "master at ${sha:0:8} = applied — nothing to do"; exit 0; }
[ "$sha" = "$refused" ] && { log "master at ${sha:0:8} was REFUSED — waiting for a new commit or a human apply"; exit 0; }

POL="$(mgmt_policy_load "$REPO" "${MGMT_POLICY_REF:-origin/master}")" || exit 1  # MGMT_POLICY_REF: a TEST knob only (a branch's policy before it lands) — production reads master
trap 'rc=$?; rm -f "$POL"; emit_metrics $rc' EXIT
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
  out="$ADIR/plan-$root.bin"; rm -f "$out" "$out.log" "$out.planned" "$out.outputs"
  mgmt_plan_root "$REPO" "$POL" "$root" "$out" true; rc=$?
  if [ $rc = 1 ]; then refuse "$sha" "$root: plan errored — see the box journal" "$(tail -5 "$out.log")"; exit 0; fi
  if ! changes="$(mgmt_plan_changes "$REPO" "$POL" "$root" "$out")"; then refuse "$sha" "$root: plan summary failed — see the box journal"; exit 0; fi
  # An OUTPUT-ONLY plan is rc=2 with zero resource changes — legitimate, not the silent zero
  # #1629 ruled on (#1774, the `node_install_targets` output). It must still be APPLIED: outputs
  # live in the state, so an unapplied one leaves the drift belt (mgmt-probe's plan → rc 2)
  # alarming on main forever. No address is touched, so the apply allowlist has nothing to judge
  # and the apply changes no infrastructure ("save these new output values … without changing any
  # real infrastructure").
  outs="$(mgmt_plan_outputs "$out")"; o=0; [ -n "$outs" ] && o=$(grep -c . <<<"$outs")
  osuf=""; [ "$o" -gt 0 ] && osuf=" ⇢$o output"   # ${o:+…} would print "⇢0 output": "0" is SET
  if [ $rc = 2 ] && [ -z "$changes" ] && [ -z "$outs" ]; then refuse "$sha" "$root: plan exit 2 but an empty summary — inconsistent, human"; exit 0; fi
  read -r a c d r <<<"$(printf '%s\n' "$changes" | mgmt_plan_counts)"; rs=""; [ "${r:-0}" -gt 0 ] && rs="×$r"
  if [ -z "$changes" ] && [ -z "$outs" ]; then log "$root: no changes"; continue; fi
  if [ -n "$changes" ]; then
    outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$POL" "$root")" || { refuse "$sha" "$root: apply allowlist unreadable — human apply"; exit 0; }
    if [ -n "$outside" ]; then
      n=$(wc -l <<<"$outside")
      refuse "$sha" "$root: $n address(es) outside the apply allowlist — human apply" "$outside"; exit 0
    fi
    # Inside the allowlist is not enough for a Talos config apply: the PRECONDITION (no_reboot,
    # in-place, a worker unless apply_controlplane_config) — mgmt_talos_gate, §MB3.
    thits="$(mgmt_talos_gate "$POL" "$root" "$out")" || { refuse "$sha" "$root: Talos precondition unreadable — human apply"; exit 0; }
    if [ -n "$thits" ]; then
      trule="$(head -1 <<<"$thits" | cut -f1)"; n=$(wc -l <<<"$thits")
      refuse "$sha" "$root: $trule — $n Talos config change(s) fail the auto-apply precondition — human apply" "$thits"; exit 0
    fi
  fi
  # Talos config applies ride the post-apply health gate; nothing else in the residue does.
  talos_n=0; [ -s "$out.talos" ] && talos_n=$(grep -c . "$out.talos")
  log "$root: +$a ~$c -$d ${rs}${osuf} — all inside the apply allowlist"
  [ -n "$changes" ] && printf '%s\n' "$changes" | sed 's/^/    /'
  [ -n "$outs" ] && printf '%s\n' "$outs" | sed 's/^/    output /'
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then
    tsuf=""; [ "$talos_n" -gt 0 ] && tsuf=" ($talos_n Talos config apply(s) — health baseline + post-check)"
    log "[shadow] would apply $root now$tsuf"; continue
  fi
  # The health BASELINE, before any Talos config apply (the /maintenance-window `open`, unattended).
  # An unreadable one is not a refusal — it is a probe failure: no apply, no stamp, the next tick
  # retries (a check that measured nothing must never be the "before" of a comparison).
  hbase="$ADIR/health-baseline.json"; rm -f "$hbase"
  if [ "$talos_n" -gt 0 ]; then
    if ! mgmt_health snapshot >"$hbase" 2>"$hbase.err"; then
      log "PROBE-FAIL: health baseline unreadable before $talos_n Talos config apply(s) — not applying, not stamping; next run retries"
      sed 's/^/    /' "$hbase.err"; exit 1
    fi
    log "$root: health baseline taken ($(jq -r '"alerts=\(.alerts|length) up=\(.up) pods_bad=\(.pods_bad) cilium_have=\(.cilium_have) nodes=\(.nodes)"' "$hbase"))"
  fi
  # ⚠ a saved plan does NOT carry the -state= override (found on the box, 2026-09-13: apply read
  # the default path, an empty state, "Saved plan does not match the given state") — repeat it.
  stateargs=""; [ -f "$REPO/$rel/backend.tf" ] || stateargs="-state=$MGMT_STATE_DIR/$root/terraform.tfstate"
  # shellcheck disable=SC2086
  if ( cd "$REPO" && devbox run --quiet -- tofu -chdir="$rel" apply -no-color -input=false $stateargs "$out" ) >"$out.apply.log" 2>&1; then
    log "$root: APPLIED (+$a ~$c -$d${osuf})"
    # A dated, verified snapshot of the state this apply just wrote (docs/tofu-state.md
    # §Snapshots). Still inside this loop's lock (fd 9), hence --lock-held. A failed snapshot is
    # logged, never allowed to turn a successful apply into a refusal.
    snap="${MGMT_SNAPSHOT:-/var/lib/homelab/scripts/mgmt-state-snapshot.sh}"
    if [ -x "$snap" ]; then "$snap" --lock-held "$root" || log "$root: WARN snapshot failed — the apply itself succeeded"; fi
    if [ "$talos_n" -gt 0 ]; then
      # The post-apply health gate. A regression reports — status failure naming it, the
      # post-check-failed marker (→ mgmt_apply_post_check_failed → MgmtApplyPostCheckFailed) — and
      # does NOT revert (FU-273: default forward; a revert is a human commit). The apply HAPPENED,
      # so the sha is still stamped below.
      if regress="$(mgmt_post_check "$hbase")"; then
        rm -f "$ADIR/post-check-failed"
        mgmt_post_status "$sha" "$CTX" success "$root: +$a ~$c -$d${osuf} applied by the management box · post-check clean"
      else
        log "$root: POST-CHECK REGRESSED after $talos_n Talos config apply(s):"; printf '%s\n' "$regress" | sed 's/^/    /'
        printf '%s\t%s\n' "$sha" "$(printf '%s' "$regress" | tr '\n' ';')" >"$ADIR/post-check-failed"
        mgmt_post_status "$sha" "$CTX" failure "$root: applied, POST-CHECK regressed: $(printf '%s' "$regress" | tr '\n' ';' | sed 's/;/; /g')"
      fi
    else
      mgmt_post_status "$sha" "$CTX" success "$root: +$a ~$c -$d${osuf} applied by the management box"
    fi
  else
    tail -5 "$out.apply.log" | sed 's/^/    /'
    refuse "$sha" "$root: apply errored — see the box journal (half-applied? human)"; exit 0
  fi
done
[ "${MGMT_SHADOW:-0}" = 1 ] || { stamp "$sha"; date +%s >"$ADIR/last-run"; }
log "done"
