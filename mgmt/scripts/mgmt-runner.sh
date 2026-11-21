#!/usr/bin/env bash
# mgmt-runner — the management box's unattended ci-runner VM recreate (docs/management-box.md §"Non-Talos
# VMs: the runner verb"). Two faces in one file:
#
#   SOURCED by mgmt/scripts/mgmt-apply.sh (after mgmt-lib.sh): runner_bracket — one VM per tick.
#   RUN by scripts/runner-maintenance.sh as its MGMT_TF (the box-local stand-in for mgmt-tf.sh, which
#   ssh-es to the box and cannot run ON it):
#     mgmt-runner.sh summary <plan-id>   the `MGMT_SUMMARY {json}` line of a plan the bracket saved
#     mgmt-runner.sh apply   <plan-id>   `tofu apply` of exactly that saved plan, under the loops' lock
#
# THE TRIGGER (the FU-306 wrinkle). Both runner VMs ignore `initialization[0].user_data_file_id`
# (tofu/ci-runner.tf), so a cloud-init template edit plans ONLY the snippet file's re-create — no VM
# diff, so "the plan replaces a VM" never fires. The loop's unscoped plan of master names the trigger
# instead: mgmt_runner_candidates (mgmt-lib.sh) reads the plan JSON's `configuration` — a VM whose
# `initialization` block REFERENCES a file the plan creates/replaces/updates is a `seed` candidate (a
# VM the plan replaces outright is a `replace` one). Only an `apply_vm_recreate.<root>` row's address
# glob admits a VM; its name comes from the plan, never from a list here.
#
# runner_bracket <policy> <root> <sha> <rel-dir> <candidate lines> → rc
#   0  one VM recreated and verified (status success; NO stamp — the next tick re-plans master: the
#      next candidate, or the final unscoped apply that stamps `applied-rev` as any other)
#   3  REFUSED (refuse() called: status failure + refused-rev — a new master commit re-evaluates)
#   1  PROBE-FAIL (nothing changed; no stamp, the next tick retries)
#   4  not taken (no `mode: on` candidate, or the loop is SHADOW): the would-be recreate is in the
#      journal; the caller continues down the ordinary path, which refuses the seed file to a human
# Steps for the first `on` candidate (sorted by address):
#   1 guard     the same VM already recreated at this same master sha and STILL a candidate = a
#               perpetual diff, never a second recreate ($ADIR/runner-done)
#   2 plan      `-target=<vm> -replace=<vm>` — scoped to the VM + its dependencies (its own seed file,
#               the seed image); the OTHER runner's snippet stays pending, so its trigger survives for
#               the next tick. `-replace` beside `-target` is the documented pair (mgmt-tf.sh's usage);
#               beside `-exclude` it is silently ignored, and mgmt_plan_root refuses that pair
#   3 scope     mgmt_runner_scope over the scoped plan: the VM replaced, no other VM, no Talos/helm
#               change, everything else its seed files or inside the allowlist
#   4 verb      `scripts/runner-maintenance.sh run <plan-id> <vm>` — the verb is the gate (it re-reads
#               the plan's VM changes, opens its own window, drains, applies, verifies, closes on a clean
#               compare) — off the loops' lock (the drain alone may wait an hour); our `apply` re-takes it
#   5 verdict   rc 0 → status success; 1 (failed after acting: its window + silences stay open, which
#               holds this loop by itself) / 2 (drain refused, labels restored) / 3 (refused before a
#               window) → refuse() naming it. Never a revert, never a retry inside the tick.
# Record: $MGMT_RUNNER_DIR (default $ADIR/runner): <plan-id>.bin(.json/.log), the verb's log, its evidence.
_RUNNER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── the MGMT_TF face (executed, not sourced) ───────────────────────────────────────────────────────
# Env from runner_bracket (exported before it calls the verb): MGMT_RUNNER_DIR, MGMT_RUNNER_ROOT_DIR
# (the root's dir in $REPO), MGMT_RUNNER_STATE (-state= path, empty for a backend root), MGMT_RUNNER_LOCK,
# REPO. tofu is on PATH (the loop's mgmt_tree_path). No ssh, no prompt: passing the plan id IS the
# confirmation (the verb sets MGMT_YES=1, as for mgmt-tf.sh).
runner_tf_main() {
  local verb="${1:-}" id="${2:-}" d="${MGMT_RUNNER_DIR:-}" rc
  case "$id" in ''|-*|*[!A-Za-z0-9._-]*) echo "mgmt-runner: '$id' is not a plan id" >&2; return 2 ;; esac
  [ -n "$d" ] && [ -f "$d/$id.bin" ] || { echo "mgmt-runner: no such plan id: $id (${d:-MGMT_RUNNER_DIR unset})" >&2; return 2; }
  case "$verb" in
    summary)
      # shellcheck source=mgmt-lib.sh
      . "$_RUNNER_HERE/mgmt-lib.sh"
      local j; j="$(mgmt_plan_summary "$d/$id.bin" "$id" true)" && [ -n "$j" ] || { echo "mgmt-runner: could not read plan $id" >&2; return 1; }
      echo "MGMT_SUMMARY $j" ;;
    apply)
      [ -n "${REPO:-}" ] && [ -n "${MGMT_RUNNER_ROOT_DIR:-}" ] && [ -n "${MGMT_RUNNER_LOCK:-}" ] \
        || { echo "mgmt-runner: REPO / MGMT_RUNNER_ROOT_DIR / MGMT_RUNNER_LOCK unset — only runner_bracket calls this" >&2; return 2; }
      exec 8>"$MGMT_RUNNER_LOCK"; flock -w 600 8 || { echo "mgmt-runner: lock busy for 10 min" >&2; return 1; }
      echo "mgmt-runner: applying saved plan $id (scoped)" >&2
      local -a st=(); [ -n "${MGMT_RUNNER_STATE:-}" ] && st=(-state="$MGMT_RUNNER_STATE")
      rc=0; ( cd "$REPO" && tofu -chdir="$MGMT_RUNNER_ROOT_DIR" apply -no-color -input=false "${st[@]}" "$d/$id.bin" ) || rc=$?
      # the loop's own post-apply snapshot (docs/tofu-state.md §Snapshots), inside this lock span
      local snap="${MGMT_SNAPSHOT:-/var/lib/homelab/mgmt/scripts/mgmt-state-snapshot.sh}"
      if [ "$rc" = 0 ] && [ -x "$snap" ]; then "$snap" --lock-held main >&2 || echo "mgmt-runner: WARN snapshot failed — the apply itself succeeded" >&2; fi
      return "$rc" ;;
    *) echo "usage: mgmt-runner.sh summary|apply <plan-id>" >&2; return 64 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -uo pipefail; runner_tf_main "$@"; exit $?; fi

# ── seams (mgmt-runner-test.sh overrides these) ────────────────────────────────────────────────────
_runner_plan()    { mgmt_plan_root "$REPO" "$@"; }            # <policy> <root> <out> <lock> <flags…>
_runner_changes() { mgmt_plan_changes "$REPO" "$@"; }         # <policy> <root> <out>
_runner_verb() {  # <plan-id> <vm-name> — the attended verb, unchanged, with this file as its MGMT_TF
  MGMT_TF="$_RUNNER_HERE/mgmt-runner.sh" RUNNER_EVIDENCE_DIR="$RUNNER_DIR/evidence" SEAT_WINDOW_BY=mgmt-apply \
    bash "$REPO/scripts/runner-maintenance.sh" run "$1" "$2"
}
_runner_unlock() { flock -u 9 2>/dev/null || true; }
_runner_relock() { flock -w 600 9 2>/dev/null || log "WARN: lock busy re-taking it after the runner recreate"; }

runner_bracket() {
  local pol="$1" root="$2" sha="$3" rel="$4" cands="$5" line vm name trig mode verb cov excl id out prc rch hits vrc st
  RUNNER_DIR="${MGMT_RUNNER_DIR:-$ADIR/runner}"; mkdir -p "$RUNNER_DIR"
  local pick="" shadow_only=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r vm name trig mode verb cov <<<"$line"
    if [ "$mode" = on ] && [ "${MGMT_SHADOW:-0}" != 1 ]; then pick="$line"; shadow_only=0; break; fi
    [ -z "$pick" ] && pick="$line"   # the first shadow candidate is still evaluated, for the journal
  done <<<"$cands"
  [ -n "$pick" ] || return 4
  IFS=$'\t' read -r vm name trig mode verb cov <<<"$pick"
  log "$root: VM recreate candidate $vm ($name, trigger $trig, mode $mode$([ "${MGMT_SHADOW:-0}" = 1 ] && echo ", loop SHADOW")) — covers: $cov"
  if [ "$verb" != runner-maintenance ]; then refuse "$sha" "$root: apply_vm_recreate row for $vm names verb '$verb' — only runner-maintenance exists — human"; return 3; fi
  if [ "$name" = - ]; then refuse "$sha" "$root: VM recreate: $vm has no readable name in the plan — human"; return 3; fi
  if grep -qxF "$sha"$'\t'"$vm" "$ADIR/runner-done" 2>/dev/null; then
    refuse "$sha" "$root: $name still needs a recreate after the box recreated it at this sha — a perpetual diff? human" "$cov"; return 3
  fi
  excl="$(mgmt_policy_get "$pol" ".roots.\"$root\".plan_exclude_types // [] | length")" || { refuse "$sha" "$root: policy unreadable for the VM recreate — human"; return 3; }
  if [ "$excl" != 0 ]; then refuse "$sha" "$root: VM recreate needs -target/-replace, and $root carries plan_exclude_types — human"; return 3; fi

  id="$(date -u +%Y%m%dT%H%M%SZ)-box-${sha:0:8}-$name"; out="$RUNNER_DIR/$id.bin"
  _runner_plan "$pol" "$root" "$out" true "-target=$vm" "-replace=$vm"; prc=$?
  case "$prc" in
    2) ;;
    1) refuse "$sha" "$root: the scoped recreate plan of $name errored — see the box journal" "$(tail -5 "$out.log" 2>/dev/null)"; return 3 ;;
    *) refuse "$sha" "$root: the scoped recreate plan of $name planned no change (rc $prc) — inconsistent, human"; return 3 ;;
  esac
  rch="$(_runner_changes "$pol" "$root" "$out")" || { refuse "$sha" "$root: the scoped recreate plan of $name is unreadable — human"; return 3; }
  hits="$(printf '%s\n' "$rch" | mgmt_runner_scope "$pol" "$root" "$vm" "$cov")" || { refuse "$sha" "$root: the recreate scope check is unreadable — human"; return 3; }
  if [ -n "$hits" ]; then
    refuse "$sha" "$root: $(head -1 <<<"$hits" | cut -f1) — the scoped recreate plan of $name is not the VM alone — human" "$hits"; return 3
  fi
  log "$root: scoped plan $id: $(printf '%s\n' "$rch" | grep -c .) change(s), $vm replaced — in scope"
  printf '%s\n' "$rch" | sed 's/^/    /'
  if [ "$shadow_only" = 1 ]; then
    log "[shadow] would run: runner-maintenance run $id $name (drain → apply → verify), no stamp; the ordinary path decides this tick"
    return 4
  fi

  mgmt_post_status "$sha" "$CTX" pending "$root: recreating $name through runner-maintenance (plan $id) — drain, apply, verify" || true
  export MGMT_RUNNER_DIR="$RUNNER_DIR" MGMT_RUNNER_ROOT_DIR="$rel" MGMT_RUNNER_LOCK="${LOCK:-/var/lib/mgmt/sentinel/.lock}"
  st=""; [ -f "$REPO/$rel/backend.tf" ] || st="${MGMT_STATE_DIR:-/var/lib/mgmt/state}/$root/terraform.tfstate"
  export MGMT_RUNNER_STATE="$st"
  _runner_unlock
  vrc=0; _runner_verb "$id" "$name" >"$RUNNER_DIR/$id.verb.log" 2>&1 || vrc=$?
  _runner_relock
  sed 's/^/    verb: /' "$RUNNER_DIR/$id.verb.log"
  case "$vrc" in 0|1) printf '%s\t%s\n' "$sha" "$vm" >>"$ADIR/runner-done" ;; esac
  case "$vrc" in
    0)
      log "$root: $name RECREATED (plan $id)"
      mgmt_post_status "$sha" "$CTX" success "$root: $name recreated by the management box (runner-maintenance, plan $id)"
      return 0 ;;
    1) refuse "$sha" "$root: $name recreate FAILED after acting — its window + silences stay open; read $RUNNER_DIR/$id.verb.log — human" "$(tail -5 "$RUNNER_DIR/$id.verb.log")" ;;
    2) refuse "$sha" "$root: $name drain refused, nothing applied (labels restored) — re-tried on the next master commit, or a human" "$(tail -3 "$RUNNER_DIR/$id.verb.log")" ;;
    *) refuse "$sha" "$root: runner-maintenance refused $name before a window (rc $vrc) — human" "$(tail -3 "$RUNNER_DIR/$id.verb.log")" ;;
  esac
  return 3
}
