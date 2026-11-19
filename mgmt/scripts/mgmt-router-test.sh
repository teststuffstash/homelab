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
# the in-cluster half's shape (scripts/iac-sentinel.sh MGMT_BOX_SURFACES): the classifier over the
# policy AT a ref, rc kept across the temp copy's cleanup — a router path is found, a doc is not
got="$(printf 'docs/a.md\nansible/opnsense-bgp.yml\n' | mgmt_router_touched_at "$REPO" HEAD)"; rc=$?
[ $rc = 0 ] && [ "$got" = "ansible/opnsense-bgp.yml" ] && ok "path:at-ref" || no "path:at-ref" "rc $rc got '$got'"
printf 'ansible/opnsense-bgp.yml\n' | mgmt_router_touched_at "$REPO" refs/no/such/ref >/dev/null 2>&1; rc=$?
[ $rc = 1 ] && ok "path:at-ref-missing-policy-fails-closed" || no "path:at-ref-missing-policy-fails-closed" "rc $rc"

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

# ── the content key + carry (mgmt_router_key / mgmt_router_carry_from / mgmt_router_record) ──
# A synthetic repo replays the 2026-11-17 box journal: #3525 PASSed at 45f7826c, then the merge bot
# merged master's #3524 (agents/coordinator/deep-dig-argo.yaml — no router path) into it as fe4d665d,
# which re-ran for 20 min. Expected values come from the contract in mgmt-router-verdict.sh's header:
# the key covers router blobs at base/merge-base/head, master's harness files, devbox.lock's harness
# tools and the baseline identity — and nothing else.
KT="$(mktemp -d "${TMPDIR:-/tmp}/mgmt-router-key.XXXXXX")"
G() { git -C "$KT/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
wr() { mkdir -p "$(dirname "$KT/r/$1")"; printf '%s\n' "$2" >"$KT/r/$1"; }
lock() { # <ansible ver> <jq ver> → a devbox.lock with the harness's tools + one it does not use
  printf '{"packages":{"ansible@latest":{"resolved":"github:NixOS/nixpkgs/aaa#ansible","version":"%s"},"jq@latest":{"resolved":"x#jq","version":"1.7"},"k9s@latest":{"resolved":"x#k9s","version":"%s"}}}\n' "$1" "$2"
}
mkdir -p "$KT/r"; G init -q -b master
wr ansible/opnsense-bgp.yml 'bgp: 1'; wr ansible/roles/opnsense-unbound/tasks/main.yml 'u: 1'
wr scripts/opnsense-test-vm.sh 'harness v1'; wr ansible/test-vm/guard.yml 'guard'; wr ansible/inventory.yml 'inv'
wr docs/a.md 'doc'; lock 2.21.5 0.1 >"$KT/r/devbox.lock"
G add -A; G commit -qm B0; B0="$(G rev-parse HEAD)"
G checkout -qb pr; wr ansible/opnsense-bgp.yml 'bgp: 2'; G commit -qam H0; H0="$(G rev-parse HEAD)"   # 45f7826c: the PR's router change
G checkout -q master; wr agents/coordinator/deep-dig-argo.yaml 'dig'; G add -A; G commit -qm B1; B1="$(G rev-parse HEAD)"   # #3524: no router path
G checkout -q pr; G merge -q --no-edit master; H1="$(G rev-parse HEAD)"                      # fe4d665d: the bot's update
G checkout -q master; wr ansible/roles/opnsense-unbound/tasks/main.yml 'u: 2'; G commit -qam B2; B2="$(G rev-parse HEAD)"   # master gains a router change
G checkout -q pr; G merge -q --no-edit master; H2="$(G rev-parse HEAD)"
G checkout -q pr; wr ansible/opnsense-bgp.yml 'bgp: 3'; G commit -qam H3; H3="$(G rev-parse HEAD)"  # the PR changes its router file again
G checkout -q master; wr scripts/opnsense-test-vm.sh 'harness v2'; G commit -qam B3; B3="$(G rev-parse HEAD)"  # master's harness moves
G checkout -q -B pr4 "$H1"; G merge -q --no-edit master; H4="$(G rev-parse HEAD)"
G checkout -q master; lock 2.21.5 0.2 >"$KT/r/devbox.lock"; G commit -qam B4; B4="$(G rev-parse HEAD)"  # a tool the harness does not use
G checkout -q -B pr5 "$H4"; G merge -q --no-edit master; H5="$(G rev-parse HEAD)"
G checkout -q master; lock 2.22.0 0.2 >"$KT/r/devbox.lock"; G commit -qam B5; B5="$(G rev-parse HEAD)"  # ansible moves
G checkout -q -B pr6 "$H5"; G merge -q --no-edit master; H6="$(G rev-parse HEAD)"
BLX=9110/baseline@1793047198; BLY=9110/baseline@1799999999
key() { mgmt_router_key "$KT/r" "$1" "$2" "$POL" "${3-$BLX}"; }   # ${3-…}: an explicit "" stays empty
K0="$(key "$B0" "$H0")"; K1="$(key "$B1" "$H1")"
[[ "$K0" =~ ^[0-9a-f]{64}$ ]] && ok "key:shape" || no "key:shape" "got '$K0'"
key_case() { # <name> <want: same|diff> <key> [reference key, default K0 = the 45f7826c-shaped PASS]
  local ref="${4:-$K0}"
  if { [ "$2" = same ] && [ "$3" = "$ref" ]; } || { [ "$2" = diff ] && [ -n "$3" ] && [ "$3" != "$ref" ]; }; then ok "key:$1 → $2"
  else no "key:$1" "want $2 as the reference key, got '${3}'"; fi
}
key_case a-bot-merged-non-router-master      same "$K1"                 # the fe4d665d case carries
key_case b-base-gained-router-change         diff "$(key "$B2" "$H2")"  # a new head+base combination
key_case c-head-router-file-changed          diff "$(key "$B1" "$H3")"
key_case d-master-harness-changed            diff "$(key "$B3" "$H4")"  # the head's router tree = H1's; only the harness moved
key_case e-baseline-moved                    diff "$(key "$B1" "$H1" "$BLY")"
K4="$(key "$B3" "$H4")"                                                  # the reference from here: harness v2
key_case unused-tool-pin-bumped              same "$(key "$B4" "$H5")" "$K4"  # k9s is not a harness tool
key_case ansible-pin-bumped                  diff "$(key "$B5" "$H6")" "$K4"
key "$B1" "$H1" "" >/dev/null 2>&1 && no "key:no-baseline-no-key" "a key without a baseline identity" || ok "key:no-baseline-no-key"
key "$B1" 0000000000000000000000000000000000000000 >/dev/null 2>&1 && no "key:unknown-head-no-key" "a key for a missing commit" || ok "key:unknown-head-no-key"

# carry: only a recorded PASS with the same key, from a file this uid owns and only it can write
REC="$KT/keys/passes"; mkdir -p "$KT/keys"
carry_case() { # <name> <key> <want sha or "none">
  local got; got="$(mgmt_router_carry_from "$REC" "$2" 2>/dev/null)" || got=none
  [ "$got" = "$3" ] && ok "carry:$1 → ${3:0:8}" || no "carry:$1" "want $3, got $got"
}
carry_case g-record-missing                    "$K1" none
mgmt_router_record "$REC" "$K0" "$H0" failure
carry_case f-earlier-fail-reruns               "$K1" none                # a FAIL is never recorded
mgmt_router_record "$REC" "$K0" "$H0" error
carry_case error-never-carried                 "$K1" none
mgmt_router_record "$REC" "$K0" "$H0" success
carry_case a-pass-carries                      "$K1" "$H0"
carry_case other-key-runs                      "$(key "$B2" "$H2")" none
carry_case empty-key-runs                      "" none
chmod 0666 "$REC"
carry_case g-writable-by-others-refused        "$K1" none
chmod 0600 "$REC"; cp "$REC" "$KT/good"
printf 'garbage\n%s %s %s\n%s %s\n' "$(date +%s)" "$K1" "not-a-sha" "$(date +%s)" "$K1" >"$REC"
carry_case g-corrupt-record-runs               "$K1" none
printf '\0\377\376junk' >"$REC"
carry_case g-binary-record-runs                "$K1" none
# bounded: max lines and max age prune; the newest PASS for a key wins
cp "$KT/good" "$REC"
echo "1 $K0 $H1" >>"$REC"                                               # an ancient PASS line, pruned by age
for i in 1 2 3; do mgmt_router_record "$REC" "$(printf '%064d' "$i")" "$H3" success 3; done
[ "$(wc -l <"$REC")" = 3 ] && ok "record:bounded-by-count" || no "record:bounded-by-count" "$(wc -l <"$REC") lines"
carry_case pruned-out-by-count                 "$K1" none
echo "1 $K0 $H1" >"$REC"; mgmt_router_record "$REC" "$(printf '%064d' 9)" "$H3" success   # epoch 1: 30-day age bound
carry_case pruned-out-by-age                   "$K1" none
mgmt_router_record "$REC" "$K0" "$H0" success; mgmt_router_record "$REC" "$K0" "$H1" success
carry_case newest-wins                         "$K1" "$H1"
mgmt_router_record "$REC" "$K0" not-a-sha success 2>/dev/null && no "record:refuses-bad-sha" "rc 0" || ok "record:refuses-bad-sha"
rm -rf "$KT"

echo "mgmt-router-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
