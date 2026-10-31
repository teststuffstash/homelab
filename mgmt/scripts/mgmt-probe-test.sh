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

# 5b. the router recap + the apply_ansible groups' recaps in ONE output (check_ansible concatenates
#     them, ADR-152 step 2): a Matchbox play with changed=2 is drift on its own host, the router stays clean
reset; ansible_verdict 0 "PLAY RECAP ***
$R_NX_OK
$R_PVE_OK

PLAY [Matchbox proxy-DHCP boot server] ***
PLAY RECAP ***
matchbox-lxc               : ok=5    changed=2    unreachable=0    failed=0    skipped=1" >"$T/mb.out" 2>&1
check "router clean + matchbox changed=2 → fail drift" "fail drift"
n=$((n+1)); if grep -q 'DRIFT — matchbox-lxc=changed:2$' "$T/mb.out"; then echo "ok   the drift names the matchbox host"; else echo "FAIL drift line: $(cat "$T/mb.out")"; fails=$((fails+1)); fi

# 5c. the LOOP itself (check_ansible over the apply_ansible plays), not only the verdict: a stub
#     ansible-playbook on PATH (jail) and as a resolved store path (box, MGMT_BOX=1) must both be RUN —
#     `timeout 900 mgmt_x …` handed `timeout` a shell function and every play exited 127 (2026-10-26)
SB="$T/stub"; mkdir -p "$SB/bin" "$T/home"; : >"$T/key"
printf '%s\n' '#!/bin/sh' 'echo "stub $*" >>"$STUB_CALLS"' 'printf "PLAY RECAP ***\nmatchbox-lxc : ok=4 changed=0 unreachable=0 failed=0 skipped=1\n"' >"$SB/bin/ansible-playbook"
chmod +x "$SB/bin/ansible-playbook"; export STUB_CALLS="$T/stub.calls"
: >"$STUB_CALLS"; reset
( export HOME="$T/home" PVE_SSH_KEY="$T/key" PATH="$SB/bin:$PATH"; unset MGMT_BOX OPN_API_KEY
  check_ansible >/dev/null 2>&1; printf '%s\n' "${RESULTS[@]}" >"$T/loop.res" )
n=$((n+1)); if [ "$(cat "$T/loop.res")" = "ansible pass ok" ] && [ "$(grep -c '^stub ansible/matchbox' "$STUB_CALLS")" -ge 4 ]; then
  echo "ok   check_ansible runs every apply_ansible play through the stub (jail PATH)"; else
  echo "FAIL check_ansible loop (jail): $(cat "$T/loop.res") calls=$(cat "$STUB_CALLS")"; fails=$((fails+1)); fi
: >"$STUB_CALLS"; reset
( export HOME="$T/home" PVE_SSH_KEY="$T/key" MGMT_BOX=1; unset OPN_API_KEY
  mgmt_lock_tool() { echo "$SB"; }
  check_ansible >/dev/null 2>&1; printf '%s\n' "${RESULTS[@]}" >"$T/loop.res" )
n=$((n+1)); if [ "$(cat "$T/loop.res")" = "ansible pass ok" ] && [ "$(grep -c '^stub ansible/matchbox' "$STUB_CALLS")" -ge 4 ]; then
  echo "ok   check_ansible runs every apply_ansible play through the resolved store path (box)"; else
  echo "FAIL check_ansible loop (box): $(cat "$T/loop.res") calls=$(cat "$STUB_CALLS")"; fails=$((fails+1)); fi

# 5d. the ROUTER leg on the box (FU-305): opnsense-playbook.sh gets the lock-resolved ansible-core as
#     OPN_ANSIBLE_BIN and must never run devbox — a POISONED devbox (the python-bump venv prompt, exit 1)
#     first on PATH, a stub `nix` for the controller-env build, the pair pre-set as the unit's env does.
PB="$T/poison"; mkdir -p "$PB/bin" "$T/py/bin"; export DEVBOX_CALLS="$T/devbox.calls"; : >"$DEVBOX_CALLS"
printf '%s\n' '#!/bin/sh' 'echo "devbox $*" >>"$DEVBOX_CALLS"' 'echo "Virtual environment … doesn'"'"'t use Devbox Python. Do you want to overwrite it? (y/n)" >&2' 'exit 1' >"$PB/bin/devbox"
printf '%s\n' '#!/bin/sh' "echo $T/py" >"$PB/bin/nix"
printf '%s\n' '#!/bin/sh' 'echo "galaxy $*" >>"$STUB_CALLS"' >"$SB/bin/ansible-galaxy"
chmod +x "$PB/bin/devbox" "$PB/bin/nix" "$SB/bin/ansible-galaxy"
: >"$STUB_CALLS"; reset
( export HOME="$T/home" PVE_SSH_KEY="$T/no-key" MGMT_BOX=1 OPN_API_KEY=k OPN_API_SECRET=s PATH="$PB/bin:$PATH"
  mgmt_lock_tool() { echo "$SB"; }
  check_ansible >/dev/null 2>&1; printf '%s\n' "${RESULTS[@]}" >"$T/loop.res" )
n=$((n+1)); if [ "$(cat "$T/loop.res")" = "ansible pass ok" ] \
   && grep -qx "stub ansible/opnsense-unbound.yml --check -e ansible_python_interpreter=$T/py/bin/python3" "$STUB_CALLS" \
   && grep -q '^galaxy collection install' "$STUB_CALLS" && [ ! -s "$DEVBOX_CALLS" ]; then
  echo "ok   check_ansible's router leg on the box runs the lock-resolved ansible-playbook, devbox never"; else
  echo "FAIL router leg (box): $(cat "$T/loop.res") calls=$(cat "$STUB_CALLS") devbox=$(cat "$DEVBOX_CALLS")"; fails=$((fails+1)); fi
# …and the jail keeps its devbox path (OPN_ANSIBLE_BIN unset → `devbox run -- ansible-playbook`)
: >"$DEVBOX_CALLS"; reset
( export HOME="$T/home" PVE_SSH_KEY="$T/no-key" OPN_API_KEY=k OPN_API_SECRET=s PATH="$PB/bin:$PATH"; unset MGMT_BOX
  check_ansible >/dev/null 2>&1 )
n=$((n+1)); if grep -q '^devbox run -- ansible-playbook ansible/opnsense-unbound.yml --check' "$DEVBOX_CALLS"; then
  echo "ok   the jail's router leg still runs through devbox"; else
  echo "FAIL router leg (jail): devbox=$(cat "$DEVBOX_CALLS")"; fails=$((fails+1)); fi

# 5e. rc≠0 under a clean recap names the play that exited non-zero
reset; ansible_verdict 2 "PLAY RECAP ***
$R_NX_OK" "ansible/opnsense-unbound.yml=2" >"$T/rc.out" 2>&1
check "rc 2 with a clean recap → fail failed" "fail failed"
n=$((n+1)); if grep -q 'clean recap (rc≠0: ansible/opnsense-unbound.yml=2)' "$T/rc.out"; then echo "ok   the clean-recap failure names the play"; else
  echo "FAIL clean-recap line: $(cat "$T/rc.out")"; fails=$((fails+1)); fi

# 7. the CRD-owner belt (ADR-151, G16): kps_crds_verdict over captured `get crd` JSON + the image.
CRDS='{"items":[{"metadata":{"name":"prometheuses.monitoring.coreos.com","annotations":{"operator.prometheus.io/version":"0.91.0"}},"spec":{"group":"monitoring.coreos.com"}},{"metadata":{"name":"servicemonitors.monitoring.coreos.com","annotations":{"operator.prometheus.io/version":"0.91.0"}},"spec":{"group":"monitoring.coreos.com"}},{"metadata":{"name":"workflows.argoproj.io"},"spec":{"group":"argoproj.io"}}]}'
reset; kps_crds_verdict "$CRDS" "quay.io/prometheus-operator/prometheus-operator:v0.91.0" >/dev/null 2>&1
check "CRDs equal the operator image → pass ok" "pass ok"
reset; kps_crds_verdict "$CRDS" "quay.io/prometheus-operator/prometheus-operator:v0.94.1" >/dev/null 2>&1
check "operator a minor ahead of the CRDs → fail skew" "fail skew"
reset; kps_crds_verdict "$(printf '%s' "$CRDS" | jq -c '.items[0].metadata.annotations = {}')" "quay.io/prometheus-operator/prometheus-operator:v0.91.0" >/dev/null 2>&1
check "one CRD without the version annotation → fail skew" "fail skew"
reset; kps_crds_verdict "$CRDS" "quay.io/prometheus-operator/prometheus-operator@sha256:abc" >/dev/null 2>&1
check "digest-only image ref → fail unparseable" "fail unparseable"
reset; kps_crds_verdict '{"items":[]}' "quay.io/prometheus-operator/prometheus-operator:v0.91.0" >/dev/null 2>&1
check "no monitoring.coreos.com CRD → fail missing" "fail missing"

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
