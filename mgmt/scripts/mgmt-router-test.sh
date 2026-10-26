#!/usr/bin/env bash
# mgmt-router-test — fixture test of the router verdict's JUDGEMENT (mgmt/scripts/mgmt-router-verdict.sh,
# docs/management-box.md §MB3 "The router surface") against policy/mgmt/plan-input.yaml as committed
# HERE: which paths are router paths, what each (base, touched, current status) gets, and how the
# harness exit maps to a status. No network, no VM. Part of `devbox run mgmt-policy-test`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export REPO="$HERE/../.."
export MGMT_ROUTER_LIB_ONLY=1
# shellcheck source=mgmt-router-verdict.sh
. "$HERE/mgmt-router-verdict.sh"
POL="$REPO/policy/mgmt/plan-input.yaml"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 — $2"; }

# ── path classification: every router input is in, its neighbours are out ──
path_case() { # <path> <want: router|no>
  local got
  got="$(printf '%s\n' "$1" | mgmt_router_touched "$POL")"; rc=$?
  [ $rc = 0 ] || { no "path:$1" "classifier rc $rc"; return; }
  if { [ "$2" = router ] && [ "$got" = "$1" ]; } || { [ "$2" = no ] && [ -z "$got" ]; }; then ok "path:$1 → $2"
  else no "path:$1" "want $2, got '${got}'"; fi
}
path_case ansible/opnsense-haproxy.yml                       router
path_case ansible/opnsense-users.yml                         router
path_case ansible/roles/opnsense-bgp/tasks/main.yml          router
path_case ansible/roles/opnsense-haproxy/defaults/main.yml   router
path_case ansible/group_vars/opnsense.yml                    router
path_case ansible/router-nodes/inventory.yml                 router
path_case ansible/router-nodes/group_vars/opnsense.yml       router
path_case ansible/collections/requirements.yml               router
path_case ansible/controller-env/flake.lock                  router
path_case ansible/ansible.cfg                                router
path_case opnsense/dnsmasq-dhcp.py                           router
path_case opnsense/kea-dhcp.py                               router
path_case ansible/matchbox.yml                               no
path_case ansible/roles/matchbox/tasks/main.yml              no
path_case ansible/group_vars/matchbox.yml                    no
path_case ansible/host_vars/nx-02-host.yml                   no
path_case ansible/test-vm/overrides.yml                      no    # the harness's own input — master's copy runs
path_case scripts/opnsense-test-vm.sh                        no    # likewise
path_case opnsense/drill/config-compare.py                   no    # `*` stays inside one segment
path_case opnsense/test-vm/seed-shape.py                     no
path_case docs/opnsense-test-vm.md                           no
path_case ansible/opnsense-haproxy.yml.bak                   no

# a list with no router path at all → empty, rc 0 (the n/a verdict) — never a classifier failure
got="$(printf 'docs/a.md\ntofu/x.tf\n' | mgmt_router_touched "$POL")"; rc=$?
[ $rc = 0 ] && [ -z "$got" ] && ok "path:none-is-empty-rc0" || no "path:none-is-empty-rc0" "rc $rc got '$got'"
# an unreadable policy → rc 1 (judge nothing), never "n/a"
printf 'roots: {}\n' >"${TMPDIR:-/tmp}/mgmt-router-test-pol.$$.yaml"
printf 'ansible/opnsense-bgp.yml\n' | mgmt_router_touched "${TMPDIR:-/tmp}/mgmt-router-test-pol.$$.yaml" >/dev/null 2>&1; rc=$?
rm -f "${TMPDIR:-/tmp}/mgmt-router-test-pol.$$.yaml"
[ $rc = 1 ] && ok "path:policy-without-list-fails-closed" || no "path:policy-without-list-fails-closed" "rc $rc"

# ── the action per head ──
act_case() { # <name> <base> <touched> <state> <errors> <want>
  local got; got="$(mgmt_router_action "$2" "$3" "$4" "$5" 3)"
  [ "$got" = "$6" ] && ok "action:$1 → $6" || no "action:$1" "want $6, got $got"
}
act_case master-router-new        master    2 ""        0 run
act_case master-router-pending    master    2 pending   0 run     # a run that died with the box
act_case master-router-success    master    2 success   0 skip    # judged (per-sha memo)
act_case master-router-failure    master    2 failure   0 skip
act_case master-router-error-1    master    2 error     1 run     # could-not-run is retried …
act_case master-router-error-max  master    2 error     3 skip    # … a bounded number of times
act_case master-none-new          master    0 ""        0 na      # the context never skips
act_case master-none-judged       master    0 success   0 skip
act_case goal-child               goal/x    2 ""        0 assembly
act_case goal-child-judged        goal/x    0 success   0 skip
act_case other-base               feature/y 2 ""        0 skip    # not required there, not judged

# ── harness exit → status ──
for c in 0:success 1:failure 2:error 143:error; do
  got="$(mgmt_router_state "${c%%:*}")"; [ "$got" = "${c#*:}" ] && ok "state:rc${c%%:*} → ${c#*:}" || no "state:rc${c%%:*}" "got $got"
done

echo "mgmt-router-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
