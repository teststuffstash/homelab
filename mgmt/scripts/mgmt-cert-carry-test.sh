#!/usr/bin/env bash
# mgmt-cert-carry-test — fixture test of the box's nightly cert carry (mgmt/scripts/mgmt-cert-carry.sh,
# FU-297): the window hold, the LIVE master/backup resolution (incl. a failover swap), the carry's exit
# → outcome map, the certs-carried count, and the last-success stamp a failure must NOT advance. The
# router API (_ans_api), the window registry (_mgmt_windows_get) and the carry itself (_cc_carry) are
# stubbed; every expected value is derived in its comment from the inputs and mgmt-cert-carry.sh's
# header. `devbox run mgmt-policy-test` discovers and runs it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# shellcheck source=mgmt-cert-carry.sh
. "$HERE/mgmt-cert-carry.sh"
pass=0; fail=0
eq() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want [$2]"; echo "                 got  [$3]"; fi
}
metric() { awk -v m="$1" '$1 == m {print $2}' "$CC_TEXTFILE"; }   # <series as written> → value

export CC_TEXTFILE="$T/cc.prom" CC_STATE="$T/state"
export OPN_API_KEY=k OPN_API_SECRET=s
# the pair: ROLES="<.70 status> <.71 status>", hasync sync off
ROLES="MASTER BACKUP"
_ans_api() {
  local st; case "$1" in 192.168.2.70) st="${ROLES%% *}" ;; 192.168.2.71) st="${ROLES##* }" ;; *) return 1 ;; esac
  case "$2" in
    diagnostics/interface/get_vip_status) echo "{\"rows\":[{\"subnet\":\"192.168.2.1\",\"mode\":\"carp\",\"status\":\"$st\"}]}" ;;
    core/hasync/get) echo '{"hasync":{"synchronizetoip":""}}' ;;
  esac
}
WIN='{}'   # the responder-window ConfigMap's data
_mgmt_windows_get() { jq -n --argjson d "$WIN" '{data: $d}'; }
# the carry: records its args + whether the backup-puller pair leaked in, prints $PLAN, exits $CRC
PLAN=''; CRC=0
_cc_carry() { echo "$* backupkey=${OPN_BACKUP_API_KEY:-unset}" >>"$T/calls"; printf '%s\n' "$PLAN"; return "$CRC"; }
run() { rm -f "$T/calls"; cc_main >/dev/null 2>&1; echo "$?"; }

# 1. nx02 MASTER, pve BACKUP, no window: the carry runs FROM .70 TO .71; two carry/add lines, one
#    up-to-date → carried 2; exit 0 → ok, success 1, last success = this run's timestamp
PLAN="$(printf 'a.example  backup 2026-12-01 -> master 2027-02-15  carry\nb.example  backup none -> master 2027-01-14  add\nc.example  backup 2026-12-18 -> master 2026-12-18  up-to-date')"
export OPN_BACKUP_API_KEY=puller   # the env file's backup-puller pair — must not reach the carry
eq ok-rc 0 "$(run)"
eq ok-args "192.168.2.70 192.168.2.71 backupkey=unset" "$(cat "$T/calls")"
eq ok-carried 2 "$(metric mgmt_cert_carry_certs_carried)"
eq ok-success 1 "$(metric mgmt_cert_carry_success)"
eq ok-outcome 1 "$(metric 'mgmt_cert_carry_outcome{outcome="ok"}')"
eq ok-last-success-is-run "$(metric mgmt_cert_carry_last_run_timestamp_seconds)" "$(metric mgmt_cert_carry_last_success_timestamp_seconds)"
first="$(metric mgmt_cert_carry_first_run_timestamp_seconds)"
eq ok-first-run-is-run "$(metric mgmt_cert_carry_last_run_timestamp_seconds)" "$first"

# 2. after a failover (.70 BACKUP, .71 MASTER) the arguments swap — read live, never a name
ROLES="BACKUP MASTER"
eq swap-rc 0 "$(run)"
eq swap-args "192.168.2.71 192.168.2.70 backupkey=unset" "$(cat "$T/calls")"
ROLES="MASTER BACKUP"

# 3. a carry failure (exit 1) does NOT advance the stamp: seeded 1000 → still 1000; nothing carried
echo 1000 >"$CC_STATE/last-success"; CRC=1
eq fail-rc 1 "$(run)"
eq fail-success 0 "$(metric mgmt_cert_carry_success)"
eq fail-outcome 1 "$(metric 'mgmt_cert_carry_outcome{outcome="failed"}')"
eq fail-carried 0 "$(metric mgmt_cert_carry_certs_carried)"
eq fail-last-success-kept 1000 "$(metric mgmt_cert_carry_last_success_timestamp_seconds)"
eq fail-first-run-kept "$first" "$(metric mgmt_cert_carry_first_run_timestamp_seconds)"   # written once, at the first run

# 4. exit 3 (done with warnings): warn, rc 3; the `add,no-row` line WAS written → carried 1; no stamp
CRC=3; PLAN='d.example  backup none -> master 2027-01-14  add,no-row'
eq warn-rc 3 "$(run)"
eq warn-outcome 1 "$(metric 'mgmt_cert_carry_outcome{outcome="warn"}')"
eq warn-carried 1 "$(metric mgmt_cert_carry_certs_carried)"
eq warn-last-success-kept 1000 "$(metric mgmt_cert_carry_last_success_timestamp_seconds)"
CRC=0

# 5. a LIVE declared window without admit_apply holds: no carry call, outcome held, rc 0, stamp kept
WIN="{\"w1\": $(jq -n --arg u "2099-01-01T00:00:00Z" '{id:"seat-1",by:"seat",reason:"router work",until:$u} | tojson')}"
eq held-rc 0 "$(run)"
eq held-no-call "no" "$([ -e "$T/calls" ] && echo yes || echo no)"
eq held-outcome 1 "$(metric 'mgmt_cert_carry_outcome{outcome="held"}')"
eq held-last-success-kept 1000 "$(metric mgmt_cert_carry_last_success_timestamp_seconds)"
# … an --admit-apply window admits it (mgmt_apply_window_gate's rule); an EXPIRED window holds nothing
WIN="{\"w1\": $(jq -n '{id:"seat-1",until:"2099-01-01T00:00:00Z",admit_apply:true} | tojson')}"
eq admit-rc 0 "$(run)"; eq admit-called "yes" "$([ -e "$T/calls" ] && echo yes || echo no)"
WIN="{\"w1\": $(jq -n '{id:"old",until:"2001-01-01T00:00:00Z"} | tojson')}"
eq expired-rc 0 "$(run)"; eq expired-called "yes" "$([ -e "$T/calls" ] && echo yes || echo no)"
WIN='{}'

# 6. not one MASTER + one BACKUP (split brain): failed before any carry call
ROLES="MASTER MASTER"
eq split-rc 1 "$(run)"; eq split-no-call "no" "$([ -e "$T/calls" ] && echo yes || echo no)"
ROLES="MASTER BACKUP"

# 7. no API pair in the env: failed, no carry call
( unset OPN_API_KEY; rm -f "$T/calls"; cc_main >/dev/null 2>&1; echo "$?" ) >"$T/rc7"
eq nocreds-rc 1 "$(cat "$T/rc7")"; eq nocreds-no-call "no" "$([ -e "$T/calls" ] && echo yes || echo no)"

# 7b. a box that never succeeded: no last-success series at all, first-run present (the alert's clock)
rm -f "$CC_STATE/last-success"; CRC=1
eq never-rc 1 "$(run)"
eq never-no-last-success "" "$(metric mgmt_cert_carry_last_success_timestamp_seconds)"
eq never-first-run "$first" "$(metric mgmt_cert_carry_first_run_timestamp_seconds)"
CRC=0; echo 1000 >"$CC_STATE/last-success"

# 8. a hand dry run: the carry gets --dry-run; the textfile and the stamp are untouched (not a run)
before="$(cat "$CC_TEXTFILE" "$CC_STATE/last-success")"
eq dry-rc 0 "$(MGMT_CERT_CARRY_DRY=1 run)"
eq dry-args "192.168.2.70 192.168.2.71 --dry-run backupkey=unset" "$(cat "$T/calls")"
eq dry-no-metrics "$before" "$(cat "$CC_TEXTFILE" "$CC_STATE/last-success")"

echo "mgmt-cert-carry-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
