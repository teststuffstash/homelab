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
#   windows    a span that would PLAN waits while any live declared window holds it (FU-300,
#               mgmt_apply_window_gate): no plan, no apply, no stamp, no status — one DEFERRED line,
#               exit 0, mgmt_apply_deferred_window 1. A window opened with --admit-apply does not hold
#               it. An unreadable registry defers too, as a PROBE-FAIL (exit 1). A span touching no
#               apply root still stamps: it changes nothing a window could be watching.
#   providers  a successful apply that CHANGED addresses records, per root, the locked version of each
#               provider owning one ($ADIR/exercised-<root>.tsv); an apply that ERRORS while such a
#               provider's locked version is not the exercised one publishes
#               mgmt_apply_errored_unexercised{root,provider,exercised,locked} (S9 #1988) — a provider
#               bump plans empty, so this is the first moment its apply path runs
#   MGMT_SHADOW=1  plan + check, log the would-be apply, no apply, no status, no stamp
# Usage: mgmt/scripts/mgmt-apply.sh   (the timer's unit). Env: mgmt/scripts/mgmt-lib.sh + MGMT_APPLY_DIR.
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
deferred=0; deferred_n=0; deferred_unreadable=0   # FU-300: set by the window gate, read by emit_metrics
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
# HELP mgmt_apply_deferred_window 1 while the last tick DEFERRED a plan because a declared window held it (or the window registry was unreadable).
# TYPE mgmt_apply_deferred_window gauge
mgmt_apply_deferred_window $deferred
# HELP mgmt_apply_deferred_windows Live declared windows holding the apply loop at the last tick (0 when unreadable — see the next series).
# TYPE mgmt_apply_deferred_windows gauge
mgmt_apply_deferred_windows $deferred_n
# HELP mgmt_apply_deferred_window_unreadable 1 while the last tick deferred because the declared-window registry could not be read.
# TYPE mgmt_apply_deferred_window_unreadable gauge
mgmt_apply_deferred_window_unreadable $deferred_unreadable
# HELP mgmt_apply_errored_unexercised 1 per provider while master's standing refusal is an apply ERROR in <root> and that provider owns a changed address at a version no successful changing apply has run yet (exercised = the last one that did, or unknown).
# TYPE mgmt_apply_errored_unexercised gauge
PROM
  [ -s "$ADIR/apply-unexercised" ] && [ -n "$r" ] && awk -F'\t' '{printf "mgmt_apply_errored_unexercised{root=\"%s\",provider=\"%s\",exercised=\"%s\",locked=\"%s\"} 1\n", $1, $2, $3, $4}' "$ADIR/apply-unexercised" >>"$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_apply.prom"
}

if [ -z "$last" ]; then
  log "first run — baseline set at ${sha:0:8}, nothing applied"; stamp "$sha"; exit 0
fi
[ "$sha" = "$last" ] && { log "master at ${sha:0:8} = applied — nothing to do"; exit 0; }
[ "$sha" = "$refused" ] && { log "master at ${sha:0:8} was REFUSED — waiting for a new commit or a human apply"; exit 0; }

[ "${MGMT_SHADOW:-0}" = 1 ] || rm -f "$ADIR/apply-unexercised"   # a new master sha re-judges; the old verdict's attribution goes with it
POL="$(mgmt_policy_load "$REPO" "${MGMT_POLICY_REF:-origin/master}")" || exit 1  # MGMT_POLICY_REF: a TEST knob only (a branch's policy before it lands) — production reads master
trap 'rc=$?; rm -f "$POL"; emit_metrics $rc' EXIT
# FAIL CLOSED, no stamp (the #1631 third round): a failed diff or classifier read must never look
# like "touches no apply root" — that path STAMPS the sha as applied and the loop would advance its
# baseline past a master push it never classified. `$(…) ||`, never `mapfile < <(…)` (rc discarded).
# The span's surface is EVERY file any commit in it touched (`git log --name-only`), never the
# endpoint diff (2026-09-28, the tofu-image-revert drill #2085/#2086): a bad image tag and its
# revert net to ZERO files between the baseline and master, so the endpoint diff read "touches no
# apply:true root" and this loop STAMPED past a span whose first half had already reached the
# cluster (the apply of the bad tag errored on the rollout wait — "half-applied? human" — and
# the object was updated regardless). The plan is the only honest read of what the cluster holds;
# a span that contained a tofu change plans, whatever its endpoints say.
# Both reads FAIL CLOSED on their own (review round 3 on PR#2087): a failed span read must never
# downgrade to the endpoint diff this comment says cannot be trusted alone — `$(…) ||`, never
# `|| true`, and "empty" is only ever a successful read's answer. The union is what plans.
log_files="$(git -C "$REPO" log --name-only --format= "${last}..${sha}" --)" || { log "PROBE-FAIL: log ${last:0:8}..${sha:0:8} failed — not stamping, next run retries"; exit 1; }
diff_files="$(git -C "$REPO" diff --name-only "$last" "$sha" --)" || { log "PROBE-FAIL: diff ${last:0:8}..${sha:0:8} failed — not stamping, next run retries"; exit 1; }
files_out="$(printf '%s\n%s\n' "$log_files" "$diff_files" | grep . | sort -u || true)"
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

# FU-300 — WIP 1 across windows this loop did not open (it opens none), BEFORE anything plans or
# posts: a deferral is not a verdict, so no refusal, no status, no stamp — the next tick re-reads.
# Here, not earlier: a span that touches no apply root stamped above and changes nothing a window
# could be watching. docs/management-box.md §MB3 "Declared windows hold the apply loop".
held="$(mgmt_apply_window_gate)"; wrc=$?
if [ "$wrc" = 2 ]; then
  deferred=1; deferred_n="$(grep -c . <<<"$held")"
  log "DEFERRED ${sha:0:8}: $deferred_n declared window(s) open — $(tr '\n' ';' <<<"$held" | sed 's/;$//; s/;/; /g') — no plan, no apply, no stamp; next tick re-reads"
  exit 0
elif [ "$wrc" != 0 ]; then
  deferred=1; deferred_unreadable=1
  log "PROBE-FAIL: declared-window registry (agent-coordinator/responder-window) unreadable — DEFERRING ${sha:0:8} (an unreadable gate is a no): no plan, no stamp; next run retries"
  exit 1
fi

hits="$(mgmt_stage1 "$POL" "$REPO" "$last" "$sha")" || { log "PROBE-FAIL: stage 1 could not run (policy unreadable) — not applying, not stamping; next run retries"; exit 1; }
# The provider-pin shape (ADR-131 amended 2026-09-27) is ADMITTED on a master span exactly as on a
# PR head: stage 1 prints an `admitted` line for a lockfile / versions.tf diff that is only version,
# constraint and hash lines (mgmt_provider_pin_shape), and the sentinel separates those from the
# hits (mgmt-sentinel.sh). This loop did not — an admitted line read as a hit, so EVERY master after
# an auto-merged provider bump was refused ("stage 1: admitted on master diff — human apply";
# 2026-09-28: #2075's merge parked #2077/#2079/#2080 and everything after, until a human apply).
# The PR-time sentinel already required the pin head to plan EMPTY merged onto master; here the
# plan below and the apply allowlist are the gate — a provider whose schema moves an address
# outside the allowlist refuses like any other change, and `init` (every run, #2045) verifies the
# new provider against the lockfile's hashes and the registry's signature before anything plans.
admitted="$(grep $'^admitted\t' <<<"$hits" || true)"; hits="$(grep -v $'^admitted\t' <<<"$hits" || true)"
[ -n "$admitted" ] && log "provider-pin master diff — stage 1 admitted: $(awk -F'\t' '{printf "%s ", $2}' <<<"$admitted")"
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
    # the providers this apply EXERCISED (their create/update/delete code ran) — see mgmt_unexercised
    if [ -n "$changes" ] && locks="$(mgmt_lock_versions "$REPO/$rel/.terraform.lock.hcl")"; then
      printf '%s\n' "$locks" >"$ADIR/locks.tmp"; printf '%s\n' "$changes" >"$ADIR/changes.tmp"
      mgmt_record_exercised "$ADIR/locks.tmp" "$ADIR/exercised-$root.tsv" "$ADIR/changes.tmp" || log "$root: WARN could not record the exercised provider versions"
    fi
    # A dated, verified snapshot of the state this apply just wrote (docs/tofu-state.md
    # §Snapshots). Still inside this loop's lock (fd 9), hence --lock-held. A failed snapshot is
    # logged, never allowed to turn a successful apply into a refusal.
    snap="${MGMT_SNAPSHOT:-/var/lib/homelab/mgmt/scripts/mgmt-state-snapshot.sh}"
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
    # Was a provider in this apply NEW to applies? (S9 #1988) — the attribution the revert chain
    # keys on. Unreadable lock, or no record yet (a box that has not completed a changing apply
    # since this landed — seed it by hand, §MB3), = no attribution: never a guessed one.
    unex=""
    if [ -n "$changes" ] && [ -f "$ADIR/exercised-$root.tsv" ] && locks="$(mgmt_lock_versions "$REPO/$rel/.terraform.lock.hcl")"; then
      printf '%s\n' "$locks" >"$ADIR/locks.tmp"; printf '%s\n' "$changes" >"$ADIR/changes.tmp"
      unex="$(mgmt_unexercised "$ADIR/locks.tmp" "$ADIR/exercised-$root.tsv" "$ADIR/changes.tmp")" || unex=""
    fi
    if [ -n "$unex" ]; then
      awk -F'\t' -v r="$root" '{printf "%s\t%s\t%s\t%s\n", r, $1, $2, $3}' <<<"$unex" >"$ADIR/apply-unexercised"
      refuse "$sha" "$root: apply errored on a provider no apply had run yet: $(awk -F'\t' '{printf "%s%s %s→%s", (NR>1?", ":""), $1, $2, $3}' <<<"$unex") — see the box journal (half-applied? human)"; exit 0
    fi
    refuse "$sha" "$root: apply errored — see the box journal (half-applied? human)"; exit 0
  fi
done
[ "${MGMT_SHADOW:-0}" = 1 ] || { stamp "$sha"; date +%s >"$ADIR/last-run"; }
log "done"
