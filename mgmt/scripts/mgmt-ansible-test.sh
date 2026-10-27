#!/usr/bin/env bash
# mgmt-ansible-test — fixture test of the box's ansible bracket (mgmt/scripts/mgmt-ansible.sh, ADR-152
# program step 2): the span → group classifier over the committed policy, the recap reader, and
# ans_bracket's decisions — nothing to do (live = master), SHADOW (would apply, nothing touched), the
# DRIFT refusal, CONFIRM (lease armed then deleted, window opened then closed, confirmed sha recorded)
# vs STOP (lease + window kept, ansible-stopped written, nothing reverted), the standing marker, a stale
# lease. The playbook, kubectl, window, HTTP and unit reads are stubbed; every expected value is derived
# in its comment from the inputs and mgmt-ansible.sh's header. `devbox run mgmt-policy-test` runs it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$(cd "$HERE/../.." && pwd)"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ADIR="$T/apply" MGMT_ANSIBLE_DIR="$T/apply/ansible"; mkdir -p "$ADIR"
# shellcheck source=mgmt-ansible.sh
. "$HERE/mgmt-ansible.sh"
POL="$REAL/policy/mgmt/plan-input.yaml"
CTX=management-apply
pass=0; fail=0
eq() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want [$2]"; echo "                 got  [$3]"; fi
}
has() {  # <name> <ERE> <text>
  if grep -Eq -- "$2" <<<"$3"; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — no /$2/ in:"; printf '%s\n' "$3" | sed 's/^/                 /'; fi
}

# ── 1. the classifier, over the policy as committed here ─────────────────────────────────────────
export REPO="$REAL"
eq groups-role "matchbox" "$(printf 'ansible/roles/matchbox-proxydhcp/tasks/main.yml\n' | ans_groups_touched "$POL")"
eq groups-play "matchbox" "$(printf 'docs/x.md\nansible/matchbox-talos-assets.yml\n' | ans_groups_touched "$POL")"
eq groups-vars "matchbox" "$(printf 'ansible/group_vars/matchbox.yml\n' | ans_groups_touched "$POL")"
eq groups-inventory "matchbox" "$(printf 'ansible/inventory.yml\n' | ans_groups_touched "$POL")"
eq groups-tofu-only "" "$(printf 'tofu/main.tf\nansible/pve-upgrade.yml\n' | ans_groups_touched "$POL")"
eq groups-once "1" "$(printf 'ansible/matchbox.yml\nansible/roles/matchbox/tasks/main.yml\n' | ans_groups_touched "$POL" | grep -c .)"
printf 'roots: [\n' >"$T/bad.yaml"
printf 'ansible/matchbox.yml\n' | ans_groups_touched "$T/bad.yaml" >/dev/null 2>&1; eq groups-unreadable-rc 1 "$?"
_yq 'del(.apply_ansible)' "$POL" >"$T/noans.yaml"
eq groups-no-rows "" "$(printf 'ansible/matchbox.yml\n' | ans_groups_touched "$T/noans.yaml")"
eq row-mode-matchbox-on "on" "$(ans_row "$POL" matchbox | jq -r .mode)"

# ── 2. the recap reader ───────────────────────────────────────────────────────────────────────────
recap() {  # <host> <changed> <unreachable> <failed>
  printf 'PLAY [x] ***\n\nPLAY RECAP *********\n%s : ok=5    changed=%s    unreachable=%s    failed=%s    skipped=0    rescued=0    ignored=0\n' "$@"
}
recap matchbox-lxc 0 0 0 >"$T/o-clean"; recap matchbox-lxc 2 0 0 >"$T/o-ch"
{ echo 'fatal: [matchbox-lxc]: FAILED! => {"msg": "Source /tmp/x does not exist"}'; recap matchbox-lxc 1 0 1; } >"$T/o-fail"
{ echo "fatal: [opnsense-pve]: FAILED! => {\"msg\": \"Unable to connect 'GET => https://192.168.2.71/api/x' (No route to host)\"}"; recap opnsense-pve 0 0 1; } >"$T/o-conn"
echo 'ERROR! the playbook could not be found' >"$T/o-none"
eq recap-clean "p.yml	matchbox-lxc	0	0	0	0" "$(ans_recap p.yml 0 "$T/o-clean")"
eq recap-connect-is-unreachable "p.yml	opnsense-pve	0	1	0	2" "$(ans_recap p.yml 2 "$T/o-conn")"
eq recap-none-is-failed "p.yml	-	0	0	1	1" "$(ans_recap p.yml 1 "$T/o-none")"
{ ans_recap a.yml 0 "$T/o-clean"; ans_recap b.yml 0 "$T/o-ch"; } >"$T/r1"; eq judge-changed "changed	b.yml:matchbox-lxc=2" "$(ans_judge "$T/r1")"
{ ans_recap a.yml 0 "$T/o-ch"; ans_recap b.yml 2 "$T/o-conn"; } >"$T/r2"; eq judge-unreachable-over-changed "unreachable	b.yml:opnsense-pve" "$(ans_judge "$T/r2")"
{ ans_recap a.yml 2 "$T/o-conn"; ans_recap b.yml 2 "$T/o-fail"; } >"$T/r3"; eq judge-failed-first "failed	b.yml:matchbox-lxc" "$(ans_judge "$T/r3")"
ans_recap a.yml 0 "$T/o-clean" >"$T/r4"; eq judge-clean "clean" "$(ans_judge "$T/r4")"
# a play killed by the timeout (rc 124) with a clean partial recap is failed, never clean
ans_recap a.yml 124 "$T/o-clean" >"$T/r5"; eq judge-timeout-failed "failed	a.yml:matchbox-lxc" "$(ans_judge "$T/r5")"

# ── 2b. the router row's pure reads + the real *.py play runner ───────────────────────────────────
RROW="$(ans_row "$POL" opnsense)"
eq router-row-backup-only-target "backup-only carp-backup" "$(jq -r '"\(.mode) \(.target)"' <<<"$RROW")"
eq groups-router "opnsense" "$(printf 'opnsense/dnsmasq-dhcp.py\n' | ans_groups_touched "$POL")"
eq groups-router-role "opnsense" "$(printf 'ansible/roles/opnsense-haproxy/tasks/main.yml\n' | ans_groups_touched "$POL")"
# the security boundary: WireGuard / ACME / ddclient / users / CARP / the tuya filter+d_nat → hits; unbound → none
eq deny-hits "ansible/roles/opnsense-acme/tasks/main.yml
ansible/roles/opnsense-wireguard/defaults/main.yml
opnsense/tuya-egress.py" "$(ans_deny_hits "$RROW" ansible/roles/opnsense-acme/tasks/main.yml opnsense/tuya-egress.py ansible/roles/opnsense-wireguard/defaults/main.yml ansible/opnsense-unbound.yml)"
eq deny-none "" "$(ans_deny_hits "$RROW" ansible/opnsense-unbound.yml opnsense/kea-dhcp.py ansible/roles/opnsense-haproxy/x)"
eq deny-carp "ansible/opnsense-carp.yml" "$(ans_deny_hits "$RROW" ansible/opnsense-carp.yml)"
# THE backup: exactly one MASTER + one BACKUP, read from the map — never a name
M2="$(printf 'opnsense-nx02\t192.168.2.70\tMASTER\nopnsense-pve\t192.168.2.71\tBACKUP\n')"
eq carp-backup-pve "opnsense-pve	192.168.2.71" "$(ans_carp_backup "$M2")"
M3="$(printf 'opnsense-nx02\t192.168.2.70\tBACKUP\nopnsense-pve\t192.168.2.71\tMASTER\n')"
eq carp-backup-swapped "opnsense-nx02	192.168.2.70" "$(ans_carp_backup "$M3")"   # after a failover the OTHER node is the canary
ans_carp_backup "$(printf 'a\t1\tMASTER\nb\t2\tMASTER\n')" >/dev/null; eq carp-two-masters-rc 1 "$?"
ans_carp_backup "$(printf 'a\t1\tMASTER\nb\t2\tINIT\n')" >/dev/null; eq carp-init-rc 1 "$?"
# ans_carp_map: the API read per inventory node; hasync config sync ON refuses
_ans_api() { case "$1:$2" in
  192.168.2.70:diagnostics*) echo '{"rows":[{"subnet":"192.168.2.1","mode":"carp","status":"MASTER"},{"subnet":"192.168.3.5","mode":"ipalias","status":"x"}]}' ;;
  192.168.2.71:diagnostics*) echo '{"rows":[{"subnet":"192.168.2.1","mode":"carp","status":"BACKUP"}]}' ;;
  *:core/hasync/get) echo "{\"hasync\":{\"synchronizetoip\":\"${HASYNC:-}\"}}" ;;
esac; }
eq carp-map "opnsense-nx02	192.168.2.70	MASTER
opnsense-pve	192.168.2.71	BACKUP" "$(ans_carp_map 192.168.2.1)"
HASYNC=192.168.2.71 ans_carp_map 192.168.2.1 >"$T/hs" ; eq carp-map-hasync-rc 1 "$?"; has carp-map-hasync-why 'hasync config sync to 192.168.2.71 is ON' "$(cat "$T/hs")"
# the REAL _ans_playbook on a *.py play: the node's script env (a `;` in OPN_KEA_HA survives — no
# shell eval), OPN_CHECK=1 under --check, 0 under the apply
printf '%s\n' 'import os' 'print(os.environ["OPN_HOST"], os.environ["OPN_KEA_HA"], os.environ["OPN_CHECK"])' >"$T/fake.py"
printf 'OPN_HOST=192.168.2.71\nOPN_KEA_HA=opnsense-pve;a=http://x:8001/=primary,b=http://y:8001/=standby\n' >"$T/se.env"
eq py-play-check "192.168.2.71 opnsense-pve;a=http://x:8001/=primary,b=http://y:8001/=standby 1" \
  "$(ANS_PY=python3 ANS_SCRIPT_ENV="$T/se.env" _ans_playbook "$T" fake.py --check --diff)"
eq py-play-apply "0" "$(ANS_PY=python3 ANS_SCRIPT_ENV="$T/se.env" _ans_playbook "$T" fake.py | awk '{print $3}')"
# a script WITHOUT OPN_CHECK support never runs in a check phase — it would ignore the flag and write
printf '%s\n' 'open("'"$T"'/WROTE", "w").write("x")' >"$T/old.py"
ANS_PY=python3 _ans_playbook "$T" old.py --check >"$T/old.out" 2>&1; eq py-no-check-support-rc 1 "$?"
eq py-no-check-support-not-run "absent" "$([ -e "$T/WROTE" ] && echo ran || echo absent)"
ans_recap old.py 1 "$T/old.out" >"$T/r6"; eq py-no-check-support-failed "failed	old.py:-" "$(ans_judge "$T/r6")"

# the opnsense runner exports the roles' ssh key from the box's PVE_SSH_KEY (never the jail's $HOME path)
eq runner-ssh-key "/var/lib/mgmt/pve-ssh/id_ed25519" "$( unset OPN_SSH_KEY; export PVE_SSH_KEY=/var/lib/mgmt/pve-ssh/id_ed25519 OPN_API_KEY=k OPN_API_SECRET=s
  nix() { echo /nix/store/x-env; }; ansible-galaxy() { :; }; _ans_runner_opnsense >/dev/null 2>&1; echo "$OPN_SSH_KEY")"

# ── 3. the bracket, against a fixture clone ───────────────────────────────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
R="$T/clone"; git init -q -b master "$R"; mkdir -p "$R/ansible"
echo a >"$R/ansible/matchbox.yml"; git -C "$R" add -A; git -C "$R" commit -qm prev; LAST="$(git -C "$R" rev-parse HEAD)"
echo b >"$R/ansible/matchbox.yml"; git -C "$R" commit -qam span; SHA="$(git -C "$R" rev-parse HEAD)"
export REPO="$R"
# seams: the playbook answers per PHASE — base (a tree other than the clone), target (the first --check
# on the clone), apply (no --check), confirm (a --check after the apply) — from P_<phase> =
# clean|changed|failed|unreach; every call is recorded
_ans_playbook() {
  local tree="$1" play="$2" ph; shift 2
  if [ "$tree" != "$REPO" ]; then ph=base
  elif ! grep -qx -- --check <<<"$(printf "%s\n" "$@")"; then ph=apply; : >"$T/applied"
  elif [ -e "$T/applied" ]; then ph=confirm
  else ph=target; fi
  echo "$ph $(basename "$play") $(cd "$tree" && cat ansible/matchbox.yml)" >>"$T/calls"
  local v="P_$ph" r
  r="${!v}"
  # P_TARGET_ONLY=<play basename>: the target --check measures a change in that play alone
  [ "$ph" = target ] && [ -n "${P_TARGET_ONLY:-}" ] && [ "$(basename "$play")" != "$P_TARGET_ONLY" ] && r=clean
  case "$r" in
    clean)   recap matchbox-lxc 0 0 0 ;;
    changed) recap matchbox-lxc 2 0 0 ;;
    failed)  echo 'fatal: [matchbox-lxc]: FAILED! => {"msg": "x"}'; recap matchbox-lxc 0 0 1; return 2 ;;
    unreach) recap matchbox-lxc 0 1 0; return 4 ;;
  esac
}
_ak() { echo "kubectl $*" >>"$T/calls"
  case "$*" in *" get cm "*) [ -n "${LEASE_JSON:-}" ] && { printf '%s' "$LEASE_JSON"; return 0; }; echo 'Error from server (NotFound)' >&2; return 1 ;; esac; }
_awin() { echo "window $1" >>"$T/calls"; [ "$1" = open ] && echo "✓ window w-1 open until x"; return 0; }
_ans_http() { [ "${HTTP_OK:-1}" = 1 ]; }
_ans_units() { [ "${UNITS_OK:-1}" = 1 ]; }
_ans_date() { case "$1" in now) echo 2026-10-26T12:00:00Z ;; *) echo 2026-10-26T12:30:00Z ;; esac; }
ans_tools() { return 0; }
refuse() { echo "REFUSE $2" >>"$T/calls"; printf '%s' "$1" >"$ADIR/refused-rev"; }
mgmt_post_status() { echo "status $3 $4" >>"$T/calls"; }
mkpol() { _yq ".apply_ansible.matchbox.mode = \"$1\"" "$POL" >"$T/pol.yaml"; }
run() {  # <name> <mode> <target> <base> <apply> <confirm> → rc in $RC, calls in $C
  rm -f "$T/calls" "$T/applied" "$ADIR/refused-rev"; mkpol "$2"
  P_target="$3" P_base="$4" P_apply="$5" P_confirm="$6"
  ans_bracket "$T/pol.yaml" matchbox "$SHA" "$LAST" >"$T/out.$1" 2>&1; RC=$?
  C="$(cat "$T/calls" 2>/dev/null)"; OUT="$(cat "$T/out.$1")"
}
plays=4   # the matchbox row's four plays → four lines per phase

# a. live already IS master: one target --check per play, nothing else; on → success + confirmed sha
rm -f "$ADIR/ansible-confirmed-matchbox"
run converged on clean - - -
eq converged-rc 0 "$RC"
eq converged-only-target "$plays" "$(grep -c '^target ' <<<"$C")"
eq converged-no-lease "0" "$(grep -c kubectl <<<"$C")"
has converged-status '^status success ansible matchbox: live matches master' "$C"
eq converged-confirmed-sha "$SHA" "$(cat "$ADIR/ansible-confirmed-matchbox")"
has converged-metric-mark '	on	converged	0$' "$(cat "$ADIR/ansible-last-matchbox")"
rm -f "$ADIR/ansible-confirmed-matchbox"
run converged-shadow shadow clean - - -
eq converged-shadow-observed "$SHA" "$(cat "$ADIR/ansible-confirmed-matchbox")"   # an observation, in shadow too
eq converged-shadow-no-status "0" "$(grep -c '^status' <<<"$C")"

# b. SHADOW: master would change, live = the previous master → would apply; no lease, no window, no status
rm -f "$ADIR/ansible-confirmed-matchbox"
run shadow shadow changed clean - -
eq shadow-rc 0 "$RC"
has shadow-would-apply '\[shadow\] ansible matchbox: would apply' "$OUT"
# the drift read ran the PREVIOUS master's plays (the base tree's file says `a`), master's said `b`
has shadow-base-is-prev '^base matchbox.yml a$' "$C"
has shadow-target-is-master '^target matchbox.yml b$' "$C"
eq shadow-no-apply "0" "$(grep -c '^apply ' <<<"$C")"
eq shadow-no-kubectl-window-status "0" "$(grep -cE '^(kubectl|window|status)' <<<"$C")"
has shadow-metric-mark '	shadow	shadow	8$' "$(cat "$ADIR/ansible-last-matchbox")"   # 4 plays × changed=2
# the clean drift read is RECORDED (an observation): the next span's read starts from the previous master,
# so the change this tick only shadowed reads as pending, never as drift, once the row flips on
eq shadow-records-observed "$LAST" "$(cat "$ADIR/ansible-confirmed-matchbox")"
run shadow-then-on on changed clean changed clean
has shadow-then-on-base "^base matchbox.yml a$" "$C"; eq shadow-then-on-rc 0 "$RC"
rm -f "$ADIR/ansible-confirmed-matchbox"
# …and a DRIFT in shadow is only a log line
run shadow-drift shadow changed changed - -
eq shadow-drift-rc 0 "$RC"; has shadow-drift-line 'would REFUSE — ansible-live-drift' "$OUT"; eq shadow-drift-no-refuse "" "$(grep REFUSE <<<"$C")"
# …and MGMT_SHADOW=1 (no App token) shadows an `on` row
MGMT_SHADOW=1 run loop-shadow on changed clean - -
eq loop-shadow-rc 0 "$RC"; eq loop-shadow-no-apply "0" "$(grep -c '^apply ' <<<"$C")"; has loop-shadow-line '\[shadow\]' "$OUT"

# c. DRIFT: live already differs from the previous master → REFUSED, nothing begun
run drift on changed changed - -
eq drift-rc 3 "$RC"
has drift-refused '^REFUSE ansible matchbox: ansible-live-drift — live differs from' "$C"
eq drift-no-lease-window "0" "$(grep -cE '^(kubectl|window)' <<<"$C")"
# …a base that cannot be read refuses too ("could not look" is never clean)
run base-unreach on changed unreach - -
eq base-unreach-rc 3 "$RC"; has base-unreach-rule '^REFUSE ansible matchbox: ansible-unreachable' "$C"
# …and a target that fails
run target-failed on failed - - -
eq target-failed-rc 3 "$RC"; has target-failed-rule '^REFUSE ansible matchbox: ansible-check-failed' "$C"

# d. CONFIRM: window + lease → apply → confirm clean + health → lease deleted, window closed, success
rm -f "$ADIR/ansible-confirmed-matchbox"
run confirm on changed clean changed clean
eq confirm-rc 0 "$RC"
# the order: the stale-lease read (none), window open, lease create, apply ×4, confirm ×4, lease delete, window close
eq confirm-order "get|window open|create|apply|confirm|delete|window close" \
  "$(sed -n 's/^kubectl.* \(get\|create\|delete\) .*/\1/p; s/^\(window [a-z]*\)$/\1/p; s/^\(apply\|confirm\) .*/\1/p' <<<"$C" | uniq | paste -sd'|')"
has confirm-lease-name 'delete cm upgrade-lease-ansible-matchbox' "$C"
has confirm-status '^status success ansible matchbox: applied by the management box \(8 change' "$C"
eq confirm-confirmed-sha "$SHA" "$(cat "$ADIR/ansible-confirmed-matchbox")"
eq confirm-no-marker "" "$(cat "$ADIR/ansible-stopped" 2>/dev/null)"
# the lease record: subject ansible/matchbox, from = the previous master (nothing confirmed yet), to = master
L="$(ls -d "$MGMT_ANSIBLE_DIR"/*-matchbox-"${SHA:0:8}" | tail -1)/lease.json"
eq confirm-lease-fields "ansible/matchbox $LAST $SHA 2026-10-26T12:30:00Z" "$(jq -r '.data | "\(.subject) \(.from) \(.to) \(.["expected-end"])"' "$L")"
# d2. the apply runs ONLY the plays the target --check measured as changed (a 0-diff DHCP script would
#     still wipe + re-add; the confirm still reads every play)
rm -f "$ADIR/ansible-confirmed-matchbox"
P_TARGET_ONLY=matchbox-ipxe-tftp.yml run apply-only-changed on changed clean changed clean
eq apply-only-changed-rc 0 "$RC"
eq apply-only-changed-plays "apply matchbox-ipxe-tftp.yml" "$(grep '^apply ' <<<"$C" | cut -d' ' -f1,2 | paste -sd'|')"
eq apply-only-changed-confirm-all "$plays" "$(grep -c '^confirm ' <<<"$C")"
# e. the NEXT span's drift read uses the CONFIRMED sha, not the span's previous master
run after-confirm shadow changed clean - -
has drift-reads-confirmed "^base matchbox.yml b$" "$C"

# f. STOP on a confirm --check that still changes: lease + window KEPT, marker written, failure status
rm -f "$ADIR/ansible-confirmed-matchbox" "$ADIR/ansible-stopped"
run stop-confirm on changed clean changed changed
eq stop-confirm-rc 2 "$RC"
eq stop-confirm-lease-kept "0" "$(grep -c 'delete cm' <<<"$C")"
eq stop-confirm-window-kept "0" "$(grep -c '^window close' <<<"$C")"
has stop-confirm-marker '^'"$SHA"'	ansible/matchbox	.*	apply changed; confirm --check changed$' "$(cat "$ADIR/ansible-stopped")"
has stop-confirm-status '^status failure ansible matchbox: applied, STOPPED on the confirm' "$C"
eq stop-confirm-confirmed-stays-observed "$LAST" "$(cat "$ADIR/ansible-confirmed-matchbox" 2>/dev/null)"   # never master after a STOP
# g. the marker refuses every later `on` apply — before any play runs; a shadow row still evaluates
run stopped on changed clean changed clean
eq stopped-rc 3 "$RC"; has stopped-refused '^REFUSE ansible matchbox: ansible applies STOPPED since' "$C"; eq stopped-no-play "0" "$(grep -cE '^(target|base|apply) ' <<<"$C")"
run stopped-shadow shadow changed clean - -
eq stopped-shadow-rc 0 "$RC"; has stopped-shadow-evaluates '\[shadow\] ansible matchbox: would apply' "$OUT"
rm -f "$ADIR/ansible-stopped"
# h. STOP on a health read (the confirm --check is clean) and on a failed apply
HTTP_OK=0 run stop-health on changed clean changed clean
eq stop-health-rc 2 "$RC"; has stop-health-why 'http: http://192.168.2.30:8080/ did not answer 2xx' "$(cat "$ADIR/ansible-stopped")"
rm -f "$ADIR/ansible-stopped"
UNITS_OK=0 run stop-units on changed clean changed clean
eq stop-units-rc 2 "$RC"; has stop-units-why 'units: not all active on matchbox: matchbox dnsmasq' "$(cat "$ADIR/ansible-stopped")"
rm -f "$ADIR/ansible-stopped"
run stop-apply on changed clean failed clean
eq stop-apply-rc 2 "$RC"; has stop-apply-why 'apply failed' "$(cat "$ADIR/ansible-stopped")"
rm -f "$ADIR/ansible-stopped"
# i. a STALE lease of this group (expected-end in the past): the actor died → STOP marker + refusal, nothing begun
LEASE_JSON='{"data":{"sha":"abc","expected-end":"2026-10-26T11:00:00Z","max-end":"2026-10-26T11:00:00Z","by":"mgmt-apply"}}' \
  run stale on changed clean changed clean
eq stale-rc 3 "$RC"; has stale-marker 'stale lease upgrade-lease-ansible-matchbox' "$(cat "$ADIR/ansible-stopped")"; eq stale-no-apply "0" "$(grep -c '^apply ' <<<"$C")"
rm -f "$ADIR/ansible-stopped"
# …and a LIVE one is in flight: a PROBE-FAIL (rc 1), no window, no marker
LEASE_JSON='{"data":{"sha":"abc","expected-end":"2026-10-26T13:00:00Z","max-end":"2026-10-26T13:00:00Z"}}' \
  run live-lease on changed clean changed clean
eq live-lease-rc 1 "$RC"; eq live-lease-no-window "0" "$(grep -c '^window' <<<"$C")"; eq live-lease-no-marker "" "$(cat "$ADIR/ansible-stopped" 2>/dev/null)"

# ── 4. the ROUTER row: BACKUP-only, the node-local restore armed before the apply ─────────────────
# the span above touches ansible/matchbox.yml only; the router bracket is driven directly. Stubs: the
# pair map (MAP_MODE), the script env, the runner, the node check (NODE_OK), the revert arm/cancel.
_ans_runner_opnsense() { ANS_PY=python3; }
_ans_script_env() { echo "script-env $1" >>"$T/calls"; printf 'OPN_HOST=192.168.2.71\n'; }
_ans_node_check() { echo "node-check $1" >>"$T/calls"; [ "${NODE_OK:-1}" = 1 ] || { echo '  FAIL  CARP 192.168.2.1 lan/INIT'; return 1; }; }
ans_carp_map() {
  case "${MAP_MODE:-ok}:$(cat "$T/applied" 2>/dev/null && echo after)" in
    two-masters:*) printf 'opnsense-nx02\t192.168.2.70\tMASTER\nopnsense-pve\t192.168.2.71\tMASTER\n' ;;
    moved:after)   printf 'opnsense-nx02\t192.168.2.70\tBACKUP\nopnsense-pve\t192.168.2.71\tMASTER\n' ;;
    *)             printf 'opnsense-nx02\t192.168.2.70\tMASTER\nopnsense-pve\t192.168.2.71\tBACKUP\n' ;;
  esac; }
ans_revert_arm() { echo "revert-arm $1 $2" >>"$T/calls"; [ "${ARM_OK:-1}" = 1 ] && echo "armed; history head config-1.xml" || { echo "sleeper did not start"; return 1; }; }
ans_revert_cancel() { echo "revert-cancel $1" >>"$T/calls"; echo cancelled; }
_ans_sleep() { :; }
rmode() { _yq ".apply_ansible.opnsense.mode = \"$1\"" "$POL" >"$T/pol.yaml"; }
rrun() {  # <name> <mode> <target> <base> <apply> <confirm>
  rm -f "$T/calls" "$T/applied" "$ADIR/refused-rev" "$ADIR/ansible-stopped" "$ADIR/ansible-confirmed-opnsense"; rmode "$2"
  P_target="$3" P_base="$4" P_apply="$5" P_confirm="$6"
  ans_bracket "$T/pol.yaml" opnsense "$SHA" "$LAST" >"$T/out.$1" 2>&1; RC=$?
  C="$(cat "$T/calls" 2>/dev/null)"; OUT="$(cat "$T/out.$1")"
}
rplays=6
# r1 shadow: the BACKUP resolved live, the plays limited to it, would apply; nothing armed, no lease
rrun r-shadow shadow changed clean - -
eq r-shadow-rc 0 "$RC"
has r-shadow-target 'target = the CARP BACKUP opnsense-pve \(192.168.2.71\); MASTER opnsense-nx02 untouched' "$OUT"
has r-shadow-would '\[shadow\] ansible opnsense: would apply' "$OUT"
eq r-shadow-no-arm-lease "0" "$(grep -cE '^(revert-arm|kubectl|window)' <<<"$C")"
eq r-shadow-limit "opnsense-pve" "$ANS_LIMIT"
# r2 backup-only, confirm good: arm BEFORE the apply, node check, CARP unchanged → cancel, lease deleted
rrun r-good backup-only changed clean changed clean
eq r-good-rc 0 "$RC"
eq r-good-order "get|window open|create|revert-arm|apply|confirm|node-check|revert-cancel|delete|window close" \
  "$(sed -n 's/^kubectl.* \(get\|create\|delete\) .*/\1/p; s/^\(window [a-z]*\)$/\1/p; s/^\(apply\|confirm\) .*/\1/p; s/^\(revert-arm\|revert-cancel\|node-check\) .*/\1/p' <<<"$C" | uniq | paste -sd'|')"
has r-good-arm-deadline '^revert-arm 192.168.2.71 1800$' "$C"   # revert_min 30 → 1800 s, on the BACKUP's address
has r-good-node-check '^node-check pve$' "$C"
has r-good-status '^status success ansible opnsense: applied by the management box' "$C"
L="$(ls -d "$MGMT_ANSIBLE_DIR"/*-opnsense-"${SHA:0:8}" | tail -1)/lease.json"
has r-good-lease-reason 'target opnsense-pve \(its node-local restore is the revert\)' "$(jq -r .data.reason "$L")"
# r3 the node check fails → STOP: the restore stays ARMED (the revert, by construction), lease + window kept
NODE_OK=0 rrun r-node-bad backup-only changed clean changed clean
eq r-node-bad-rc 2 "$RC"; eq r-node-bad-no-cancel "0" "$(grep -c '^revert-cancel' <<<"$C")"
eq r-node-bad-lease-kept "0" "$(grep -c 'delete cm' <<<"$C")"
has r-node-bad-why 'router node check: 1 FAIL line\(s\).*stays ARMED' "$(cat "$ADIR/ansible-stopped")"
# r4 the pair MOVED during the apply (the BACKUP took .1) → STOP, armed
MAP_MODE=moved rrun r-moved backup-only changed clean changed clean
eq r-moved-rc 2 "$RC"; has r-moved-why 'carp: the pair moved' "$(cat "$ADIR/ansible-stopped")"; eq r-moved-no-cancel "0" "$(grep -c '^revert-cancel' <<<"$C")"
# r5 two MASTERs → refused before anything runs (and in shadow, only said)
MAP_MODE=two-masters rrun r-pair backup-only changed clean changed clean
eq r-pair-rc 3 "$RC"; has r-pair-refused '^REFUSE ansible opnsense: ansible-pair-unhealthy — the pair is not one MASTER \+ one BACKUP' "$C"; eq r-pair-no-play "0" "$(grep -cE '^(target|apply) ' <<<"$C")"
MAP_MODE=two-masters rrun r-pair-shadow shadow changed clean - -
eq r-pair-shadow-rc 0 "$RC"; has r-pair-shadow-line 'would REFUSE — ansible-pair-unhealthy' "$OUT"
# r6 the restore does not arm → PROBE-FAIL: lease deleted, window closed, NOTHING applied
ARM_OK=0 rrun r-noarm backup-only changed clean changed clean
eq r-noarm-rc 1 "$RC"; eq r-noarm-no-apply "0" "$(grep -c '^apply ' <<<"$C")"; has r-noarm-lease-deleted 'delete cm upgrade-lease-ansible-opnsense' "$C"
# r7 a span touching the security boundary → REFUSED whatever else it holds (shadow: said only)
mkdir -p "$R/opnsense"; echo x >"$R/opnsense/tuya-egress.py"; echo c >"$R/ansible/matchbox.yml"
git -C "$R" add -A; git -C "$R" commit -qm tuya; SHA2="$(git -C "$R" rev-parse HEAD)"
rm -f "$T/calls"; rmode backup-only; P_target=changed P_base=clean P_apply=changed P_confirm=clean
ans_bracket "$T/pol.yaml" opnsense "$SHA2" "$SHA" >"$T/out.r7" 2>&1; RC=$?; C="$(cat "$T/calls" 2>/dev/null)"
eq r-deny-rc 3 "$RC"; has r-deny-refused '^REFUSE ansible opnsense: security-boundary — the span touches 1 denied path' "$C"; eq r-deny-no-play "0" "$(grep -cE '^(target|apply) ' <<<"$C")"
# r8 a mode that would reach the MASTER does not exist: `on` without a target is refused for this row
# (target carp-backup + mode on is not a combination the bracket admits)
rm -f "$T/calls"; _yq '.apply_ansible.opnsense.mode = "on"' "$POL" >"$T/pol.yaml"
ans_bracket "$T/pol.yaml" opnsense "$SHA" "$LAST" >/dev/null 2>&1; eq r-on-refused-rc 3 "$?"

echo "mgmt-ansible-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
