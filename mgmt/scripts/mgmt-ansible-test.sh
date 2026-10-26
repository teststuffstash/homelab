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
eq groups-tofu-only "" "$(printf 'tofu/main.tf\nansible/opnsense-unbound.yml\n' | ans_groups_touched "$POL")"
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
  local v="P_$ph"
  case "${!v}" in
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

echo "mgmt-ansible-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
