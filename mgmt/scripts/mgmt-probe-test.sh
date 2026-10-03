#!/usr/bin/env bash
# mgmt-probe-test — the drift belt's REASON label (mgmt/scripts/mgmt-probe.sh, responder audit
# 2026-10-03): the ansible check's per-host verdict against captured --check output, and the
# published `mgmt_probe_check{…,reason}` series staying inside the fixed vocabulary. Sources the
# real probe (it defines and returns when sourced) — no router, no box.
#   devbox run mgmt-policy-test   (or: bash mgmt/scripts/mgmt-probe-test.sh)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/text"
export MGMT_TEXTFILE_DIR="$T/text" DRY_RUN=0 MODE=belt
# shellcheck source=mgmt-probe.sh
. "$HERE/mgmt-probe.sh" 2>/dev/null || { echo "FATAL: could not source mgmt-probe.sh"; exit 1; }

fails=0 n=0
reset() { RESULTS=(); PASS=0 FAIL=0 SKIPPED=0; }
check() {  # check <name> <expected "status reason"> — against the single RESULTS row
  n=$((n+1))
  local got="${RESULTS[0]#* }"
  if [ "${#RESULTS[@]}" -eq 1 ] && [ "$got" = "$2" ]; then echo "ok   $1"; else
    echo "FAIL $1: want '$2', got '${RESULTS[*]:-<none>}'"; fails=$((fails+1)); fi
}

# The live capture (2026-10-03, the jail running the belt's own command): opnsense-pve stopped by its
# kill switch, opnsense-nx02 answering. Trimmed to the lines the verdict reads; the two failure
# messages are verbatim (one timeout, one ENETUNREACH — the same host, two loop items).
LIVE_HEAD='PLAY [OPNsense Unbound static host overrides] **********************************
TASK [opnsense-unbound : Unbound host override per entry] **********************
ok: [opnsense-nx02] => (item=opnsense.teststuff.net -> 192.168.2.1)
[ERROR]: Task failed: Module failed: Got timeout calling '"'"'GET => https://192.168.2.71/api/unbound/settings/get'"'"' (timed out)
failed: [opnsense-pve] (item=opnsense.teststuff.net -> 192.168.2.1) => {"ansible_loop_var": "item", "changed": false, "msg": "Got timeout calling '"'"'GET => https://192.168.2.71/api/unbound/settings/get'"'"' (timed out)"}
failed: [opnsense-pve] (item=npm-cache.teststuff.net -> 192.168.40.35) => {"ansible_loop_var": "item", "changed": false, "msg": "Unable to connect '"'"'GET => https://192.168.2.71/api/unbound/settings/get'"'"' ([Errno 113] No route to host)"}
PLAY RECAP *********************************************************************'
R_NX_OK='opnsense-nx02              : ok=5    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0'
R_NX_CH='opnsense-nx02              : ok=5    changed=2    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0'
R_PVE_F='opnsense-pve               : ok=0    changed=0    unreachable=0    failed=1    skipped=0    rescued=0    ignored=0'
R_PVE_OK='opnsense-pve               : ok=5    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0'

# 1. the 2026-10-02 condition: one node down (connect errors only), the other clean → unreachable,
#    not the old opaque "--check run failed" (the contract: a dead node is not a plumbing failure).
reset; ansible_verdict 2 "$LIVE_HEAD
$R_NX_OK
$R_PVE_F
Error: error running script \"ansible-playbook\" in Devbox: exit status 2" >/dev/null 2>&1
check "one node down by connect errors → fail unreachable" "fail unreachable"

# 2. drift on the answering node while the other is down → drift wins (precedence failed > drift > unreachable)
reset; ansible_verdict 2 "$LIVE_HEAD
$R_NX_CH
$R_PVE_F" >/dev/null 2>&1
check "drift beside a down node → fail drift" "fail drift"

# 3. a node that answered with a NON-connect error (an API 401) → failed, even beside a down one
reset; ansible_verdict 2 "PLAY RECAP ***
fatal: [opnsense-nx02]: FAILED! => {\"changed\": false, \"msg\": \"Got HTTP 401 calling GET => https://192.168.2.70/api/unbound/settings/get\"}
failed: [opnsense-pve] (item=x) => {\"msg\": \"Unable to connect 'GET => https://192.168.2.71/' ([Errno 113] No route to host)\"}
PLAY RECAP ***
opnsense-nx02              : ok=0    changed=0    unreachable=0    failed=1    skipped=0
$R_PVE_F" >/dev/null 2>&1
check "a non-connect task error → fail failed" "fail failed"

# 4. ansible's own unreachable= counter (an ssh-connected host) → unreachable
reset; ansible_verdict 4 "PLAY RECAP ***
opnsense-nx02              : ok=0    changed=0    unreachable=1    failed=0    skipped=0
$R_PVE_OK" >/dev/null 2>&1
check "recap unreachable=1 → fail unreachable" "fail unreachable"

# 5. clean recap, rc 0 → pass (reason ok); rc 0 + changed → drift (the --check exit-0 trap)
reset; ansible_verdict 0 "PLAY RECAP ***
$R_NX_OK
$R_PVE_OK" >/dev/null 2>&1
check "both nodes clean → pass ok" "pass ok"
reset; ansible_verdict 0 "PLAY RECAP ***
$R_NX_CH
$R_PVE_OK" >/dev/null 2>&1
check "rc 0 with changed=2 → fail drift" "fail drift"

# 6. no recap: the play never ran (rc≠0) → failed; rc 0 without a recap → unparseable
reset; ansible_verdict 1 "ERROR! couldn't resolve module/action 'oxlorg.opnsense.unbound_host'" >/dev/null 2>&1
check "no recap, rc 1 → fail failed" "fail failed"
reset; ansible_verdict 0 "nothing here" >/dev/null 2>&1
check "no recap, rc 0 → fail unparseable" "fail unparseable"

# 7. the label is bounded: a word outside the vocabulary publishes as `other`, never as itself
reset; failed ansible "some free text reason" "x" >/dev/null 2>&1
check "an out-of-vocabulary reason → other" "fail other"

# 8. publish() writes the reason as a label on every series, and only vocabulary words
reset
passed talos "fine" >/dev/null 2>&1
failed ansible unreachable "x" >/dev/null 2>&1
skipped creds no-input "x" >/dev/null 2>&1
publish >/dev/null 2>&1
prom="$T/text/mgmt_probe_belt.prom"
n=$((n+1))
want='mgmt_probe_check{mode="belt",check="talos",status="pass",reason="ok"} 1
mgmt_probe_check{mode="belt",check="ansible",status="fail",reason="unreachable"} 1
mgmt_probe_check{mode="belt",check="creds",status="skip",reason="no-input"} 1'
got="$(grep '^mgmt_probe_check{' "$prom" 2>/dev/null)"
if [ "$got" = "$want" ]; then echo "ok   publish() carries reason on every mgmt_probe_check series"; else
  echo "FAIL publish(): want
$want
got
$got"; fails=$((fails+1)); fi

# 9. every reason word the probe's call sites pass is IN the vocabulary (a typo would publish
#    `other` forever). Reads the call sites from the source — the vocabulary itself is $REASONS.
n=$((n+1))
bad=""
while read -r w; do
  case "$REASONS" in *" $w "*) ;; *) bad="$bad $w" ;; esac
done < <(grep -oE '\b(failed|skipped) "?[a-z0-9:$_{}]+"? [a-z-]+ "' "$HERE/mgmt-probe.sh" | awk '{print $(NF-1)}' | sort -u)
used="$(grep -cE '\b(failed|skipped) "?[a-z0-9:$_{}]+"? [a-z-]+ "' "$HERE/mgmt-probe.sh")"
if [ -z "$bad" ] && [ "$used" -ge 30 ]; then echo "ok   all $used call sites use vocabulary words"; else
  echo "FAIL call sites outside the vocabulary:${bad:- none} (matched $used call sites, expected ≥30)"; fails=$((fails+1)); fi

echo "mgmt-probe-test: $((n-fails))/$n passed"
[ "$fails" -eq 0 ]
