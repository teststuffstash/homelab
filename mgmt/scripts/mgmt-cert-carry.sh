#!/usr/bin/env bash
# mgmt-cert-carry — the management box's NIGHTLY router certificate carry (FU-297; docs/management-box.md
# §Router certificate carry). The CARP BACKUP cannot order certificates (no WAN behind the gate), so its
# copies follow the MASTER's renewals only through scripts/opnsense-cert-carry.sh. This wraps that
# script for the box's timer (mgmt-cert-carry.timer, after the routers' 00:00 EET acme.sh cron):
#
#   1 declared windows   any LIVE window not opened with --admit-apply holds the run (mgmt-lib.sh's
#                        mgmt_apply_window_gate — the apply loop's rule; the box's own BACKUP converge
#                        opens one, so the carry never writes into a converge); an unreadable registry
#                        defers too. Held = no router call, outcome `held`.
#   2 who is MASTER      read LIVE, never from a name: mgmt-ansible.sh's ans_carp_map (the CARP status
#                        of the .1 VIP on every inventory node, hasync config sync must be off) +
#                        ans_carp_backup (exactly one MASTER + one BACKUP). After a failover the roles
#                        swap and so do the arguments.
#   3 the carry          scripts/opnsense-cert-carry.sh <master-ip> <backup-ip> as the `automation` API
#                        user — the unit's pre-set OPN_API_KEY/SECRET (/var/lib/mgmt/env). The env
#                        file's OPN_BACKUP_API_* are the backup-PULLER's pair (the drill's), which the
#                        carry would read as "the backup node's own creds": unset here. Idempotent: an
#                        up-to-date pair writes nothing and does not touch HAProxy.
#
# Outcome: ok (carry exit 0) · warn (exit 3: done with warnings — backup-newer / no ACME row) ·
# failed (any other exit, the pair unreadable or not one MASTER + one BACKUP, no creds) · held (a window).
# Only `ok` advances mgmt_cert_carry_last_success_timestamp_seconds — the one alert,
# MgmtCertCarryStale (argocd/resources/mgmt-metrics/cert-carry.yaml), reads that timestamp, so a
# failure, a warning, a hold and a timer that stopped firing all surface the same way after 50 h
# (before the first success ever, mgmt_cert_carry_first_run_timestamp_seconds is the clock).
#
# Usage: mgmt/scripts/mgmt-cert-carry.sh               one run (the unit mgmt-cert-carry)
#        MGMT_CERT_CARRY_DRY=1 …                       --dry-run to the carry: the plan, no POST, no metrics
# Env: OPN_API_KEY/OPN_API_SECRET (required), MGMT_CERT_CARRY_TEXTFILE (unset = no metrics),
# MGMT_CERT_CARRY_STATE (the first-run + last-success stamps' dir; default /var/lib/mgmt/cert-carry),
# MGMT_CERT_CARRY_VIP (default 192.168.2.1), KUBECONFIG (the window registry; /var/lib/mgmt/kubeconfig).
# Exit: 0 ok / held · 1 failed · 3 warn. mgmt-cert-carry-test.sh sources this file and stubs the seams.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-$(cd "$HERE/../.." && pwd)}"; export REPO
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
# shellcheck source=mgmt-ansible.sh
. "$HERE/mgmt-ansible.sh"   # ans_carp_map / ans_carp_backup / _ans_api — the ONE live CARP resolver

CC_TEXTFILE="${MGMT_CERT_CARRY_TEXTFILE:-}"
CC_STATE="${MGMT_CERT_CARRY_STATE:-/var/lib/mgmt/cert-carry}"
CC_VIP="${MGMT_CERT_CARRY_VIP:-192.168.2.1}"
cc_log() { echo "[mgmt-cert-carry] $*" >&2; }

# ── seam (the test overrides it) ──────────────────────────────────────────────────────────────────
_cc_carry() {  # <master-ip> <backup-ip> [--dry-run] → the carry's stdout (plan lines); its exit code
  ( cd "$REPO" && timeout 900 bash "$REPO/scripts/opnsense-cert-carry.sh" "$@" )
}

# cc_metrics <outcome> <carried> — the textfile, written whole (tmp + mv); the last success is the
# state stamp, so a failed run keeps reporting the previous success's time
cc_metrics() {
  local outcome="$1" carried="$2" now o last="" first
  [ -z "${MGMT_CERT_CARRY_DRY:-}" ] || return 0   # a hand dry run is not a run: no stamp, no metrics
  now="$(date +%s)"
  mkdir -p "$CC_STATE"
  [ -s "$CC_STATE/first-run" ] || echo "$now" >"$CC_STATE/first-run"   # the stale clock before any success
  first="$(cat "$CC_STATE/first-run")"
  if [ "$outcome" = ok ]; then echo "$now" >"$CC_STATE/last-success"; fi
  [ -s "$CC_STATE/last-success" ] && last="$(cat "$CC_STATE/last-success")"
  [ -n "$CC_TEXTFILE" ] || return 0
  {
    echo "# HELP mgmt_cert_carry_last_run_timestamp_seconds End of the last router cert-carry run (docs/management-box.md §Router certificate carry)."
    echo "# TYPE mgmt_cert_carry_last_run_timestamp_seconds gauge"
    echo "mgmt_cert_carry_last_run_timestamp_seconds $now"
    echo "# HELP mgmt_cert_carry_success 1 when the last run carried (or found nothing to carry) with no warning."
    echo "# TYPE mgmt_cert_carry_success gauge"
    echo "mgmt_cert_carry_success $( [ "$outcome" = ok ] && echo 1 || echo 0)"
    echo "# HELP mgmt_cert_carry_outcome The last run's outcome, one-hot: ok, warn, failed, held (a declared window)."
    echo "# TYPE mgmt_cert_carry_outcome gauge"
    for o in ok warn failed held; do echo "mgmt_cert_carry_outcome{outcome=\"$o\"} $( [ "$o" = "$outcome" ] && echo 1 || echo 0)"; done
    echo "# HELP mgmt_cert_carry_certs_carried Certificates the last run wrote to the CARP BACKUP (carry + add)."
    echo "# TYPE mgmt_cert_carry_certs_carried gauge"
    echo "mgmt_cert_carry_certs_carried $carried"
    echo "# HELP mgmt_cert_carry_first_run_timestamp_seconds When this box first ran the carry — MgmtCertCarryStale's clock until a first success."
    echo "# TYPE mgmt_cert_carry_first_run_timestamp_seconds gauge"
    echo "mgmt_cert_carry_first_run_timestamp_seconds $first"
    if [ -n "$last" ]; then
      echo "# HELP mgmt_cert_carry_last_success_timestamp_seconds When a run last ended ok — MgmtCertCarryStale reads it."
      echo "# TYPE mgmt_cert_carry_last_success_timestamp_seconds gauge"
      echo "mgmt_cert_carry_last_success_timestamp_seconds $last"
    fi
  } >"$CC_TEXTFILE.$$" && mv -f "$CC_TEXTFILE.$$" "$CC_TEXTFILE"
}

cc_main() {
  local held map node mline mip bip out rc carried=0 outcome
  unset OPN_BACKUP_API_KEY OPN_BACKUP_API_SECRET OPN_BACKUP_KEY_ENTRY OPN_BACKUP_SECRET_ENTRY OPN_AS_ROOT
  if [ -z "${OPN_API_KEY:-}" ] || [ -z "${OPN_API_SECRET:-}" ]; then
    cc_log "FAIL: no OPN_API_KEY/OPN_API_SECRET in the unit's env (/var/lib/mgmt/env — the automation pair)"
    cc_metrics failed 0; return 1
  fi
  held="$(mgmt_apply_window_gate)"; rc=$?
  case "$rc" in
    0) ;;
    2) cc_log "held by a declared window: $held"; cc_metrics held 0; return 0 ;;
    *) cc_log "the window registry is unreadable — deferring (\"could not look\" is not \"nothing is open\")"; cc_metrics held 0; return 0 ;;
  esac
  if ! map="$(ans_carp_map "$CC_VIP")"; then cc_log "FAIL: $map"; cc_metrics failed 0; return 1; fi
  if ! node="$(ans_carp_backup "$map")"; then cc_log "FAIL: $node"; cc_metrics failed 0; return 1; fi
  bip="$(cut -f2 <<<"$node")"
  mline="$(awk -F'\t' '$3 == "MASTER"' <<<"$map")"; mip="$(cut -f2 <<<"$mline")"
  cc_log "MASTER $(cut -f1 <<<"$mline") ($mip) → BACKUP $(cut -f1 <<<"$node") ($bip)"
  out="$(_cc_carry "$mip" "$bip" ${MGMT_CERT_CARRY_DRY:+--dry-run})"; rc=$?
  printf '%s\n' "$out"
  # plan lines end in the action (opnsense-cert-carry.sh header): carry/add were WRITTEN unless dry
  if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then
    carried="$(grep -cE '  (carry|add)(,no-row)?$' <<<"$out")"
  fi
  case "$rc" in 0) outcome=ok ;; 3) outcome=warn ;; *) outcome=failed ;; esac
  cc_log "outcome $outcome (carry exit $rc), $carried cert(s) $( [ -n "${MGMT_CERT_CARRY_DRY:-}" ] && echo 'WOULD be carried (dry run)' || echo carried)"
  cc_metrics "$outcome" "$carried"
  case "$outcome" in ok) return 0 ;; warn) return 3 ;; *) return 1 ;; esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then cc_main; exit $?; fi
