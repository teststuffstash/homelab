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
# shellcheck disable=SC2034  # read by the sourced probe (passed/failed/skipped, publish)
reset() { RESULTS=(); PASS=0 FAIL=0 SKIPPED=0; SEEDS=(); FIRMWARE=(); }
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

# 10. check_seeds — the runner seed the main STATE declares (the lost-trigger detector's declared half).
#     A state in tofu's v4 shape: two runner VMs, each referencing its own snippet by id; a non-runner
#     VM with a snippet (out of the `ci_runner*` glob → no series); a runner VM whose file id matches
#     no file (→ no series). Expected shas are sha256 of the content's exact bytes — the same bytes
#     Proxmox hands the VM as user-data.txt — computed here from the inputs, not by the probe.
S1=$'#cloud-config\nhostname: ci-runner-01\n'
S2=$'#cloud-config\nhostname: ci-runner-02\nruncmd:\n  - echo "tab\there" \\\n'
jq -n --arg s1 "$S1" --arg s2 "$S2" '{version: 4, resources: [
  {mode: "managed", type: "proxmox_virtual_environment_file", name: "ci_runner_cloud_init",
   instances: [{index_key: 0, attributes: {id: "local:snippets/ci-runner-cloud-init.yaml", source_raw: [{file_name: "ci-runner-cloud-init.yaml", data: $s1}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_file", name: "ci_runner_02_cloud_init",
   instances: [{index_key: 0, attributes: {id: "local:snippets/ci-runner-02-cloud-init.yaml", source_raw: [{file_name: "ci-runner-02-cloud-init.yaml", data: $s2}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_file", name: "other_cloud_init",
   instances: [{attributes: {id: "local:snippets/other.yaml", source_raw: [{data: "x"}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_vm", name: "ci_runner",
   instances: [{index_key: 0, attributes: {name: "ci-runner-01", initialization: [{user_data_file_id: "local:snippets/ci-runner-cloud-init.yaml"}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_vm", name: "ci_runner_02",
   instances: [{index_key: 0, attributes: {name: "ci-runner-02", initialization: [{user_data_file_id: "local:snippets/ci-runner-02-cloud-init.yaml"}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_vm", name: "ci_runner_03",
   instances: [{index_key: 0, attributes: {name: "ci-runner-03", initialization: [{user_data_file_id: "local:snippets/gone.yaml"}]}}]},
  {mode: "managed", type: "proxmox_virtual_environment_vm", name: "other_vm",
   instances: [{attributes: {name: "other", initialization: [{user_data_file_id: "local:snippets/other.yaml"}]}}]}
]}' >"$T/main.tfstate"
H1="$(printf '%s' "$S1" | sha256sum | cut -d' ' -f1)"
H2="$(printf '%s' "$S2" | sha256sum | cut -d' ' -f1)"
seeds_published() { grep '^mgmt_runner_seed_declared_info{' "$prom" 2>/dev/null | sort; }

reset; MAIN_STATE="$T/main.tfstate" check_seeds >/dev/null 2>&1
check "two runner seeds in state → pass ok" "pass ok"
publish >/dev/null 2>&1
n=$((n+1))
want="$(printf 'mgmt_runner_seed_declared_info{vm="ci-runner-01",sha256="%s"} 1\nmgmt_runner_seed_declared_info{vm="ci-runner-02",sha256="%s"} 1' "$H1" "$H2" | sort)"
got="$(seeds_published)"
if [ "$got" = "$want" ]; then echo "ok   two runner VMs → two declared series, names + shas from the state"; else
  echo "FAIL declared series: want
$want
got
$got"; fails=$((fails+1)); fi

# unreadable state → fail unparseable, and the rewritten file carries NO declared series
printf 'not json{' >"$T/bad.tfstate"
reset; MAIN_STATE="$T/bad.tfstate" check_seeds >/dev/null 2>&1
check "unreadable main state → fail unparseable" "fail unparseable"
publish >/dev/null 2>&1
n=$((n+1)); if [ -z "$(seeds_published)" ]; then echo "ok   an unreadable state publishes no declared series"; else
  echo "FAIL unreadable state published: $(seeds_published)"; fails=$((fails+1)); fi

# no state file (the jail) → skip no-input, no series
reset; MAIN_STATE="$T/absent.tfstate" check_seeds >/dev/null 2>&1
check "no main state → skip no-input" "skip no-input"
publish >/dev/null 2>&1
n=$((n+1)); if [ -z "$(seeds_published)" ]; then echo "ok   an absent state publishes no declared series"; else
  echo "FAIL absent state published: $(seeds_published)"; fails=$((fails+1)); fi

# the VM side's metric line, rendered from the real template: the runcmd hashes user-data.txt and
# names the VM by the template's ${name}. Rendering through tofu is the sentinel's job; here the
# guard is that the line exists and survives tftpl escaping (a `${` would be a template var).
n=$((n+1))
TPL="$HERE/../../tofu/templates/ci-runner-cloud-init.yaml.tftpl"
if grep -qF 'ci_runner_seed_info{vm="${name}",sha256="%s"} 1' "$TPL" \
   && grep -qF 'sha256sum /var/lib/cloud/instance/user-data.txt' "$TPL"; then
  echo "ok   the runner template publishes ci_runner_seed_info{vm,sha256}"; else
  echo "FAIL the runner template no longer writes ci_runner_seed_info — MgmtRunnerSeedDrift's live side"; fails=$((fails+1)); fi

# 11. check_firmware — the router firmware currency belt (class 14, ADR-152 program step 1).
#     Captured readings (2026-11-17, root's GET core/firmware/status; trimmed to the fields read):
#     FW_NX = opnsense-nx02, its cached check from 2026-10-11 offering 26.7.5 → 26.7.6_3 (the event
#     this belt exists for); FW_PVE = opnsense-pve, never checked (status none + "requires to check").
FW_NX='{"status":"update","status_msg":"There are 40 updates available, total download size is 196.2MiB. This update requires a reboot.","last_check":"Sun Oct 11 20:41:27 EEST 2026","needs_reboot":"1","upgrade_needs_reboot":"0","upgrade_major_version":"","product_version":"26.7.5","connection":"ok","repository":"ok","upgrade_packages":[{"name":"opnsense","repository":"OPNsense","current_version":"26.7.5","new_version":"26.7.6_3"},{"name":"kernel","size":"33526828","repository":"OPNsense","current_version":"26.7.4","new_version":"26.7.6"}],"product":{"product_version":"26.7.5","product_latest":"26.7.8"}}'
FW_PVE='{"status":"none","status_msg":"Firmware status requires to check for update first to provide more information.","product":{"product_version":"26.7.5","product_latest":"26.7.5","product_check":null}}'
# a checked-and-current reading (a following check after an update: status none, a last_check, no packages)
FW_CUR='{"status":"none","status_msg":"There are no updates available on the selected mirror.","last_check":"Tue Nov 17 20:00:00 EET 2026","needs_reboot":"0","product_version":"26.7.8","upgrade_packages":[],"product":{"product_version":"26.7.8"}}'
# EEST = UTC+3 (Europe/Tallinn summer time): 20:41:27 EEST = 17:41:27Z; EET = UTC+2
LC_NX="$(date -u -d '2026-10-11T17:41:27Z' +%s)"
LC_CUR="$(date -u -d '2026-11-17T18:00:00Z' +%s)"
FWC="$T/fwcache"; mkdir -p "$FWC"
fwrow() {  # fwrow <name> <expected row> — against the single FIRMWARE row
  n=$((n+1))
  if [ "${#FIRMWARE[@]}" -eq 1 ] && [ "${FIRMWARE[0]}" = "$2" ]; then echo "ok   $1"; else
    echo "FAIL $1: want '$2', got '${FIRMWARE[*]:-<none>}'"; fails=$((fails+1)); fi
}
reset; rm -f "$FWC"/*
fw_row opnsense-nx02 node "$FW_NX" "$(fw_last_check "$FW_NX")" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "today's MASTER: update offered since its 10-11 check, reboot, 26.7.5 → 26.7.6_3" \
  "opnsense-nx02 node 1 1 1 $LC_NX $LC_NX 26.7.5 26.7.6_3"
# the box keeps the EARLIER first-seen across later checks (a fresh check moves last_check, not the offer)
reset
fw_row opnsense-nx02 node "$FW_NX" "$LC_CUR" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "a later check keeps the first-seen offer time" "opnsense-nx02 node 1 1 1 $LC_CUR $LC_NX 26.7.5 26.7.6_3"
# checked and current: available 0, nothing offered, and the box forgets the offer
reset
fw_row opnsense-nx02 node "$FW_CUR" "$(fw_last_check "$FW_CUR")" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "checked and current → available 0" "opnsense-nx02 node 1 0 0 $LC_CUR - 26.7.8 -"
n=$((n+1)); if [ ! -e "$FWC/firmware-offered.opnsense-nx02" ]; then echo "ok   a current reading clears the box-side offer"; else
  echo "FAIL the offer file survived a current reading"; fails=$((fails+1)); fi
# never checked / 403 / no answer / a check that ended in error → read_ok 0, no currency fields
reset; fw_row opnsense-pve node "$FW_PVE" "$(fw_last_check "$FW_PVE")" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "a node never checked (status none, no last_check) → unread" "opnsense-pve node 0 - - - - - -"
reset; fw_row opnsense-pve node '{"status":403,"message":"Forbidden"}' "" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "a 403 body → unread" "opnsense-pve node 0 - - - - - -"
reset; fw_row opnsense-pve node "" "" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "no answer → unread" "opnsense-pve node 0 - - - - - -"
reset; fw_row opnsense-pve node '{"status":"error","last_check":"Tue Nov 17 20:00:00 EET 2026","connection":"error"}' "$LC_CUR" "$FWC" "$LC_CUR" >/dev/null 2>&1
fwrow "a check that ended in error → unread" "opnsense-pve node 0 - - - - - -"

# fw_node: WHEN the belt runs the check. A stub router: per-host status bodies in files, every call logged.
FWS="$T/fwstub"; mkdir -p "$FWS"; export FWS
_fw_curl() {
  local host="${3#https://}"; host="${host%%/*}"; local ep="${3##*/}"
  echo "$2 $host $ep" >>"$FWS/calls"
  case "$2 $ep" in
    "GET status")        cat "$FWS/$host.status" 2>/dev/null || return 22 ;;
    "GET running")       cat "$FWS/$host.running" 2>/dev/null || echo '{"status":"ready"}' ;;
    "POST check")        cp "$FWS/$host.after" "$FWS/$host.status" 2>/dev/null; echo '{"status":"ok"}' ;;
    "GET upgradestatus") if [ -e "$FWS/$host.stuck" ]; then echo '{"status":"running"}'; else echo '{"status":"done","log":"***DONE***"}'; fi ;;
    *) return 22 ;;
  esac
}
export FW_CHECK_POLL_SLEEP=0
fwcalls() { grep -c "^POST $1 check$" "$FWS/calls" 2>/dev/null; }
# stale (10-11, a month before LC_CUR) → POST check, re-read: the row carries the NEW check's answer
reset; rm -f "$FWC"/* "$FWS"/*; printf '%s' "$FW_NX" >"$FWS/h1.status"; printf '%s' "$FW_CUR" >"$FWS/h1.after"
FW_NOW="$LC_CUR" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
fwrow "a stale reading → POST check, the re-read wins" "opnsense-nx02 node 1 0 0 $LC_CUR - 26.7.8 -"
n=$((n+1)); [ "$(fwcalls h1)" = 1 ] && echo "ok   exactly one check POST" || { echo "FAIL check POSTs: $(cat "$FWS/calls")"; fails=$((fails+1)); }
# …and the next tick within FW_CHECK_RETRY does not POST again even though the reading is still stale
reset; : >"$FWS/calls"; printf '%s' "$FW_NX" >"$FWS/h1.status"; printf '%s' "$FW_NX" >"$FWS/h1.after"
FW_NOW="$((LC_CUR + 900))" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
n=$((n+1)); [ "$(fwcalls h1)" = 0 ] && echo "ok   no second check inside FW_CHECK_RETRY" || { echo "FAIL retried within the hour: $(cat "$FWS/calls")"; fails=$((fails+1)); }
# a fresh reading (last_check 1 h old) → GET only
reset; rm -f "$FWC"/*; : >"$FWS/calls"; printf '%s' "$FW_CUR" >"$FWS/h1.status"
FW_NOW="$((LC_CUR + 3600))" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
n=$((n+1)); [ "$(fwcalls h1)" = 0 ] && echo "ok   a fresh reading → no check" || { echo "FAIL checked a fresh reading: $(cat "$FWS/calls")"; fails=$((fails+1)); }
# a firmware job running (an update in flight) → no check, the cached reading stands
reset; rm -f "$FWC"/*; : >"$FWS/calls"; printf '%s' "$FW_NX" >"$FWS/h1.status"; echo '{"status":"busy"}' >"$FWS/h1.running"
FW_NOW="$LC_CUR" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
n=$((n+1)); [ "$(fwcalls h1)" = 0 ] && echo "ok   busy firmware job → no check" || { echo "FAIL checked while busy: $(cat "$FWS/calls")"; fails=$((fails+1)); }
rm -f "$FWS/h1.running"
# FW_CHECK=0 → read-only, whatever the age
reset; rm -f "$FWC"/*; : >"$FWS/calls"
FW_CHECK=0 FW_NOW="$LC_CUR" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
n=$((n+1)); [ "$(fwcalls h1)" = 0 ] && echo "ok   FW_CHECK=0 → GETs only" || { echo "FAIL FW_CHECK=0 posted: $(cat "$FWS/calls")"; fails=$((fails+1)); }

# the poll is BOUNDED (mgmt-belt's TimeoutStartSec=30m): a check that never finishes stops polling
# after FW_CHECK_NODE_SECS (2 s at 1 s sleeps → ≤ 3 polls, never the 30 the count alone allows) …
reset; rm -f "$FWC"/*; : >"$FWS/calls"; printf '%s' "$FW_NX" >"$FWS/h1.status"; printf '%s' "$FW_NX" >"$FWS/h1.after"; : >"$FWS/h1.stuck"
FW_CHECK_POLL_SLEEP=1 FW_CHECK_NODE_SECS=2 FW_NOW="$LC_CUR" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
polls="$(grep -c '^GET h1 upgradestatus$' "$FWS/calls")"
n=$((n+1)); [ "$polls" -ge 1 ] && [ "$polls" -le 3 ] && echo "ok   a stuck check stops polling at FW_CHECK_NODE_SECS ($polls polls)" || { echo "FAIL per-node poll bound: $polls polls"; fails=$((fails+1)); }
rm -f "$FWS/h1.stuck"
# … and a spent per-tick budget (FW_CHECK_TOTAL_SECS) starts no further check at all
reset; rm -f "$FWC"/*; : >"$FWS/calls"
FW_CHECK_T0="$SECONDS" FW_CHECK_TOTAL_SECS=0 FW_NOW="$LC_CUR" fw_node opnsense-nx02 node h1 cfg "$FWC" >/dev/null 2>&1
n=$((n+1)); [ "$(fwcalls h1)" = 0 ] && echo "ok   a spent tick budget → no check POST" || { echo "FAIL posted past the tick budget: $(cat "$FWS/calls")"; fails=$((fails+1)); }

# check_firmware end to end: the REAL inventory's nodes (yq over ansible/router-nodes/inventory.yml)
# + the test VM, the env pair → one row per router, and publish() writes no currency series for the
# unread node (the never-checked BACKUP, with its check POST refused).
reset; rm -f "$FWC"/* "$FWS"/*
# the post-check body a real router returns: the SAME offer, a FRESH last_check (LC_CUR) — the offer
# must still date from the pre-check reading's 10-11 check (reviewer finding on #3525)
FW_NX_FRESH="$(printf '%s' "$FW_NX" | jq -c '.last_check = "Tue Nov 17 20:00:00 EET 2026"')"
printf '%s' "$FW_NX"  >"$FWS/192.168.2.70.status"; printf '%s' "$FW_NX_FRESH" >"$FWS/192.168.2.70.after"
printf '%s' "$FW_PVE" >"$FWS/192.168.2.71.status"
printf '%s' "$FW_CUR" >"$FWS/192.168.2.67.status"
( export MGMT_CACHE_DIR="$FWC" OPN_FIRMWARE_API_KEY=k OPN_FIRMWARE_API_SECRET=s OPN_TESTVM_API_KEY=k OPN_TESTVM_API_SECRET=s FW_NOW="$((LC_CUR + 60))" HOME="$T/home"
  unset OPN_API_KEY OPN_API_SECRET
  check_firmware >/dev/null 2>&1; publish >/dev/null 2>&1; printf '%s\n' "${RESULTS[@]}" >"$T/fw.res" )
n=$((n+1)); if [ "$(cat "$T/fw.res")" = "firmware pass ok" ]; then echo "ok   check_firmware reports (pass) with a node behind and one unread"; else
  echo "FAIL check_firmware verdict: $(cat "$T/fw.res")"; fails=$((fails+1)); fi
n=$((n+1))
want="mgmt_router_firmware_read_ok{node=\"opnsense-nx02\",role=\"node\"} 1
mgmt_router_firmware_read_ok{node=\"opnsense-pve\",role=\"node\"} 0
mgmt_router_firmware_read_ok{node=\"opnsense-test\",role=\"test\"} 1
mgmt_router_firmware_update_available{node=\"opnsense-nx02\",role=\"node\"} 1
mgmt_router_firmware_update_available{node=\"opnsense-test\",role=\"test\"} 0
mgmt_router_firmware_update_offered_since_timestamp_seconds{node=\"opnsense-nx02\",role=\"node\"} $LC_NX"
got="$(grep -E '^mgmt_router_firmware_(read_ok|update_available|update_offered_since_timestamp_seconds)\{' "$prom" 2>/dev/null)"
if [ "$got" = "$want" ]; then echo "ok   publish(): read_ok for all three, currency only for the read ones"; else
  echo "FAIL firmware series: want
$want
got
$got"; fails=$((fails+1)); fi
# the prod pair is the dedicated `firmware` user's ONLY (operator ruling on #3525): with just the
# `automation` pair present (the box before provision-secrets carries OPN_FIRMWARE_API_*) the check
# skips no-input, reads nothing, and publishes no firmware series — MgmtRouterFirmwareUnread's
# "no series at all" arm (router-firmware.promtool-test) is what sees that box.
reset; rm -f "$FWC"/*; : >"$FWS/calls"
( export MGMT_CACHE_DIR="$FWC" OPN_API_KEY=k OPN_API_SECRET=s HOME="$T/home"
  unset OPN_FIRMWARE_API_KEY OPN_FIRMWARE_API_SECRET OPN_TESTVM_API_KEY OPN_TESTVM_API_SECRET
  check_firmware >/dev/null 2>&1; publish >/dev/null 2>&1; printf '%s\n' "${RESULTS[@]}" >"$T/fw.res" )
n=$((n+1)); if [ "$(cat "$T/fw.res")" = "firmware skip no-input" ] && [ ! -s "$FWS/calls" ] \
   && ! grep -q '^mgmt_router_firmware_' "$prom"; then echo "ok   automation pair only → skip no-input, no router call, no firmware series"; else
  echo "FAIL automation-only: $(cat "$T/fw.res") calls=$(cat "$FWS/calls") series=$(grep -c '^mgmt_router_firmware_' "$prom")"; fails=$((fails+1)); fi
unset -f _fw_curl

echo "mgmt-probe-test: $((n-fails))/$n passed"
[ "$fails" -eq 0 ]
