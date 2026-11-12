#!/usr/bin/env bash
# mgmt-runner-test — fixture test of the box's unattended ci-runner VM recreate (mgmt/scripts/mgmt-runner.sh,
# docs/management-box.md §"Non-Talos VMs: the runner verb"): the trigger read over SYNTHETIC `tofu show
# -json` plans fed through the loop's own mgmt_plan_digest (mgmt_runner_candidates — the FU-306 seed
# shape and the plain replace), the rest/scope reads, the MGMT_TF face driven through the REAL
# scripts/runner-maintenance.sh scope check, and runner_bracket's decisions with the plan, the verb and
# the status stubbed. Every expected value is derived in its comment from the inputs and the contract in
# mgmt-runner.sh's header / mgmt-lib.sh. `devbox run mgmt-policy-test` runs it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL="$(cd "$HERE/../.." && pwd)"
export REPO="$REAL"
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export ADIR="$T/apply"; mkdir -p "$ADIR"
# shellcheck source=mgmt-runner.sh
. "$HERE/mgmt-runner.sh"
POL="$REAL/policy/mgmt/plan-input.yaml"
export CTX=management-apply
pass=0; fail=0
eq() {  # <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — want [$2]"; echo "                 got  [$3]"; fi
}
has() {  # <name> <ERE> <text>
  if grep -Eq -- "$2" <<<"$3"; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); echo "FAIL $1 — no /$2/ in:"; printf '%s\n' "$3" | sed 's/^/                 /'; fi
}

# ── fixtures: the two runner VMs as tofu/ci-runner.tf declares them ─────────────────────────────────
V1='proxmox_virtual_environment_vm.ci_runner[0]';    F1='proxmox_virtual_environment_file.ci_runner_cloud_init[0]'
V2='proxmox_virtual_environment_vm.ci_runner_02[0]'; F2='proxmox_virtual_environment_file.ci_runner_02_cloud_init[0]'
# the `configuration` half: each VM's initialization block references its own snippet — the shape
# `tofu show -json` gives `user_data_file_id = proxmox_virtual_environment_file.<x>[0].id`
CFG='[
 {"address":"proxmox_virtual_environment_vm.ci_runner","type":"proxmox_virtual_environment_vm","name":"ci_runner",
  "expressions":{"initialization":[{"user_data_file_id":{"references":["proxmox_virtual_environment_file.ci_runner_cloud_init[0].id","proxmox_virtual_environment_file.ci_runner_cloud_init[0]","proxmox_virtual_environment_file.ci_runner_cloud_init"]},
    "ip_config":[{"ipv4":[{"address":{"references":["var.ci_runner_ip_cidr"]}}]}]}]}},
 {"address":"proxmox_virtual_environment_vm.ci_runner_02","type":"proxmox_virtual_environment_vm","name":"ci_runner_02",
  "expressions":{"initialization":[{"user_data_file_id":{"references":["proxmox_virtual_environment_file.ci_runner_02_cloud_init[0].id","proxmox_virtual_environment_file.ci_runner_02_cloud_init[0]","proxmox_virtual_environment_file.ci_runner_02_cloud_init"]}}]}},
 {"address":"proxmox_virtual_environment_vm.node","type":"proxmox_virtual_environment_vm","name":"node",
  "expressions":{"initialization":[{"user_data_file_id":{"references":["proxmox_virtual_environment_file.node_seed[0]"]}}]}}]'
rc_() {  # <address> <actions json> [vm-name] → one resource_changes entry
  local a="$1" type="${1%%.*}" rest="${1#*.}" name idx
  name="${rest%%\[*}"; idx="${rest#"$name"}"
  if [ -n "${3:-}" ]; then
    printf '{"address":"%s","mode":"managed","type":"%s","name":"%s","index":0,"change":{"actions":%s,"before":{"name":"%s"},"after":{"name":"%s"},"after_unknown":{}}}' "$a" "$type" "$name" "$2" "$3" "$3"
  else
    printf '{"address":"%s","mode":"managed","type":"%s","name":"%s","change":{"actions":%s,"before":{},"after":{},"after_unknown":{}}}' "$a" "$type" "$name" "$2"
  fi
  : "$idx"
}
digest() {  # <out> <resource_changes json array> [configuration resources json] → changes lines on stdout
  jq -n --argjson rc "$2" --argjson cfg "${3:-$CFG}" '{resource_changes:$rc, configuration:{root_module:{resources:$cfg}}}' | mgmt_plan_digest "$1"
}
NOOP='["no-op"]'; REPL='["delete","create"]'; UPD='["update"]'
VM1_NOOP="$(rc_ "$V1" "$NOOP" ci-runner-01)"; VM2_NOOP="$(rc_ "$V2" "$NOOP" ci-runner-02)"
F1_REPL="$(rc_ "$F1" "$REPL")"; F2_REPL="$(rc_ "$F2" "$REPL")"
CM="$(rc_ kubernetes_config_map.x "$UPD")"
# the policy as committed, and the same row flipped (the operator's two later states)
POL_ON="$T/pol-on.yaml";     _yq '.apply_vm_recreate.main[0].mode = "on"' "$POL" >"$POL_ON"
POL_SHADOW="$T/pol-sh.yaml"; _yq '.apply_vm_recreate.main[0].mode = "shadow"' "$POL" >"$POL_SHADOW"
POL_NONE="$T/pol-none.yaml"; _yq 'del(.apply_vm_recreate)' "$POL" >"$POL_NONE"

# ── 1. the committed row: one glob, the one verb, shipped OFF ──────────────────────────────────────
eq row-committed-off "proxmox_virtual_environment_vm.ci_runner*|runner-maintenance|off" \
  "$(mgmt_policy_get "$POL" '.apply_vm_recreate.main[0] | .address + "|" + .verb + "|" + .mode')"

# the loop's off-switch: the committed policy has no live row (the recreate path is not read at all);
# shadow and on are live; no rows at all is 0
eq live-committed 0 "$(mgmt_runner_live "$POL" main)"
eq live-on 1 "$(mgmt_runner_live "$POL_ON" main)"
eq live-shadow 1 "$(mgmt_runner_live "$POL_SHADOW" main)"
eq live-no-rows 0 "$(mgmt_runner_live "$POL_NONE" main)"

# ── 2. the trigger (mgmt_runner_candidates) ─────────────────────────────────────────────────────────
# a template edit since FU-306: both snippets re-created, both VMs no-op → two `seed` candidates, sorted
# by address (`ci_runner[0]` < `ci_runner_02[0]`: `[` 0x5B < `_` 0x5F), names from the plan's `name`,
# each covering its VM + its OWN snippet (the configuration's references), mode = the row's
digest "$T/p-both" "[$VM1_NOOP, $F1_REPL, $VM2_NOOP, $F2_REPL, $CM]" >/dev/null
eq cand-template-edit-both "$V1	ci-runner-01	seed	on	runner-maintenance	$V1 $F1
$V2	ci-runner-02	seed	on	runner-maintenance	$V2 $F2" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-both")"
# the committed policy reports the same candidates with mode off (the caller then does nothing new)
eq cand-mode-off "off off" "$(mgmt_runner_candidates "$POL" main "$T/p-both" | cut -f4 | tr '\n' ' ' | sed 's/ $//')"
# one snippet only (the second runner's, left pending by the first tick's -target) → one candidate
digest "$T/p-one" "[$VM1_NOOP, $VM2_NOOP, $F2_REPL]" >/dev/null
eq cand-second-left "$V2" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-one" | cut -f1)"
# the plan replaces the VM itself (a forcing attribute) → trigger `replace`, covering the VM alone
digest "$T/p-repl" "[$(rc_ "$V1" "$REPL" ci-runner-01)]" >/dev/null
eq cand-replace "$V1	ci-runner-01	replace	on	runner-maintenance	$V1" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-repl")"
# create-before-destroy order is a replace too
digest "$T/p-cbd" "[$(rc_ "$V1" '["create","delete"]' ci-runner-01)]" >/dev/null
eq cand-replace-cbd "replace" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-cbd" | cut -f3)"
# a VM with an in-place update beside its snippet → NOT a candidate (a recreate would apply it unread)
digest "$T/p-upd" "[$(rc_ "$V1" "$UPD" ci-runner-01), $F1_REPL]" >/dev/null
eq cand-vm-update-not "" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-upd")"
# nothing pending on the snippets → none
digest "$T/p-quiet" "[$VM1_NOOP, $VM2_NOOP, $CM]" >/dev/null
eq cand-quiet "" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-quiet")"
# a Talos VM replace: the glob does not match `node` → none (never a runner recreate)
digest "$T/p-talos" "[$(rc_ 'proxmox_virtual_environment_vm.node[0]' "$REPL" wk-03)]" >/dev/null
eq cand-talos-vm-unmatched "" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-talos")"
# no apply_vm_recreate rows (master before this change) → none, rc 0: the code alone widens nothing
mgmt_runner_candidates "$POL_NONE" main "$T/p-both" >"$T/o" ; eq cand-no-rows "0|" "$?|$(cat "$T/o")"
# a reference the plan JSON does not resolve to an instance address (bare resource name only) → no
# trigger: fail closed, the ordinary path refuses the file
CFG_BARE="$(jq -c '.[0].expressions.initialization[0].user_data_file_id.references = ["proxmox_virtual_environment_file.ci_runner_cloud_init"]' <<<"$CFG")"
digest "$T/p-bare" "[$VM1_NOOP, $F1_REPL]" "$CFG_BARE" >/dev/null
eq cand-unresolved-ref "" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-bare")"
# no name in the plan → `-` (the bracket refuses it), never an empty field shifting the columns
digest "$T/p-noname" "[$(rc_ "$V1" "$REPL")]" >/dev/null
eq cand-no-name "-	replace" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-noname" | cut -f2,3)"
# unreadable plan JSON → rc 1, never "no candidate"
mgmt_runner_candidates "$POL_ON" main "$T/never-digested.bin" >/dev/null 2>&1; eq cand-no-json-rc 1 "$?"

# ── 3. the rest + the scope check ───────────────────────────────────────────────────────────────────
CH="$(printf '%s\tno-op\n%s\tdelete+create\n%s\tdelete+create\nkubernetes_config_map.x\tupdate\n' "$V1" "$F1" "$F2")"
CANDS="$(mgmt_runner_candidates "$POL_ON" main "$T/p-both")"
# both candidates cover V1 F1 V2 F2 → only the config map is left for the ordinary allowlist
eq rest-both "kubernetes_config_map.x	update" "$(printf '%s\n' "$CH" | mgmt_runner_rest "$CANDS")"
# with only the first candidate, F2 stays in the rest (and is outside the allowlist → ordinary refusal)
eq rest-first-only "$F2	delete+create
kubernetes_config_map.x	update" "$(printf '%s\n' "$CH" | mgmt_runner_rest "$(head -1 <<<"$CANDS")")"
scope() { printf '%b' "$2" | mgmt_runner_scope "$POL_ON" main "$V1" "$V1 $F1" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//'; : "$1"; }
# the -target plan: V1 replaced, its snippet re-created, the seed image (allowlisted) → in scope
eq scope-ok "" "$(scope ok "$V1\tdelete+create\n$F1\tdelete+create\nproxmox_download_file.debian_cloud[0]\tupdate\n")"
eq scope-other-vm "runner-other-vm" "$(scope x "$V1\tdelete+create\n$V2\tdelete+create\n")"
eq scope-other-snippet "runner-outside" "$(scope x "$V1\tdelete+create\n$F2\tdelete+create\n")"
eq scope-talos "runner-gated-class" "$(scope x "$V1\tdelete+create\ntalos_machine_configuration_apply.node[\"wk-03\"]\tupdate\n")"
eq scope-helm "runner-gated-class" "$(scope x "$V1\tdelete+create\nhelm_release.argocd\tupdate\n")"
eq scope-not-replaced "runner-not-replaced" "$(scope x "$V1\tupdate\n$F1\tdelete+create\n")"
eq scope-vm-absent "runner-not-replaced" "$(scope x "$F1\tdelete+create\n")"

# ── 4. the MGMT_TF face, read by the REAL verb ──────────────────────────────────────────────────────
# runner-maintenance.sh `run` reads `summary <id>` and refuses unless the plan's only VM change is a
# replace of <vm>; with that read passing it goes on to open its window — stubbed to FAIL here, so a
# passing scope ends at exit 3 "window did not open", a failing one at exit 3 "not scoped".
RD="$T/runner"; mkdir -p "$RD"
digest "$RD/good.bin" "[$(rc_ "$V1" "$REPL" ci-runner-01), $F1_REPL]" >/dev/null; : >"$RD/good.bin"
digest "$RD/two.bin" "[$(rc_ "$V1" "$REPL" ci-runner-01), $(rc_ "$V2" "$REPL" ci-runner-02)]" >/dev/null; : >"$RD/two.bin"
printf '#!/bin/sh\necho "no live seat window"\n' >"$T/seatwin"; printf '#!/bin/sh\necho "stub: no window" >&2; exit 1\n' >"$T/maint"
: >"$T/kubeconfig"
verb() { MGMT_RUNNER_DIR="$RD" MGMT_TF="$HERE/mgmt-runner.sh" SEAT_WINDOW="$T/seatwin" MAINT_WINDOW="$T/maint" KUBECONFIG="$T/kubeconfig" \
           bash "$REAL/scripts/runner-maintenance.sh" run "$@" 2>&1; }
out="$(verb good ci-runner-01)"; rc=$?
eq verb-scope-pass-rc 3 "$rc"
has verb-scope-pass "run: ok proxmox_virtual_environment_vm\.ci_runner\[0\] replace; 2 change\(s\) in plan, scoped=true" "$out"
has verb-scope-pass-stopped-at-window "window did not open" "$out"
out="$(verb two ci-runner-01)"; rc=$?
eq verb-two-vms-rc 3 "$rc"
has verb-two-vms-refused "not scoped to ci-runner-01 — refusing: plan changes 2 VMs" "$out"
out="$(verb good ci-runner-02)"; has verb-wrong-vm "plan changes VM ci-runner-01" "$out"
MGMT_RUNNER_DIR="$RD" bash "$HERE/mgmt-runner.sh" apply ../good >/dev/null 2>&1; eq tf-bad-id-rc 2 "$?"
MGMT_RUNNER_DIR="$RD" bash "$HERE/mgmt-runner.sh" apply nope >/dev/null 2>&1; eq tf-unknown-id-rc 2 "$?"
MGMT_RUNNER_DIR="$RD" bash "$HERE/mgmt-runner.sh" apply good >/dev/null 2>&1; eq tf-apply-needs-bracket-env-rc 2 "$?"

# ── 5. runner_bracket's decisions (plan, verb, status, refuse stubbed) ─────────────────────────────
SCOPED=""; VERB_RC=0; VERB_CALLS=0; STATUS=""; REFUSED=""; LOCKLOG=""
_runner_plan() {  # <policy> <root> <out> <lock> <flags…> — records the flags, writes the scoped plan SCOPED
  printf '%s\n' "${@:5}" >"$T/flags"
  [ "$SCOPED" = error ] && { echo boom >"$3.log"; return 1; }
  digest "$3" "$SCOPED" >/dev/null; return 2
}
_runner_changes() { jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | [.address, (.change.actions | join("+"))] | @tsv' "$3.json"; }
_runner_verb()   { VERB_CALLS=$((VERB_CALLS+1)); echo "verb $1 $2" >"$T/verbargs"; LOCKLOG="${LOCKLOG}verb "; return "$VERB_RC"; }
_runner_unlock() { LOCKLOG="${LOCKLOG}unlock "; }
_runner_relock() { LOCKLOG="${LOCKLOG}relock "; }
mgmt_post_status() { STATUS="${STATUS}$3:$4"$'\n'; }
refuse() { REFUSED="$2"; }
bracket() {  # <policy> <candidates> → rc; fresh stubs state each time
  STATUS=""; REFUSED=""; VERB_CALLS=0; LOCKLOG=""; rm -f "$T/flags" "$T/verbargs"
  runner_bracket "$1" main SHA1 tofu "$2"
}
GOOD_SCOPED="[$(rc_ "$V1" "$REPL" ci-runner-01), $F1_REPL]"
C_ON="$(mgmt_runner_candidates "$POL_ON" main "$T/p-both")"
# on + verb 0 → rc 0; the FIRST candidate (V1) planned `-target=V1 -replace=V1`; the verb got
# (<plan-id>, ci-runner-01); lock released around it; status pending then success; no refusal
SCOPED="$GOOD_SCOPED"; VERB_RC=0; bracket "$POL_ON" "$C_ON"; rc=$?
eq br-on-ok-rc 0 "$rc"
eq br-on-ok-flags "-target=$V1
-replace=$V1" "$(cat "$T/flags")"
has br-on-ok-verb-args '^verb [0-9TZ]+-box-SHA1-ci-runner-01 ci-runner-01$' "$(cat "$T/verbargs")"
eq br-on-ok-lock "unlock verb relock" "$(sed 's/ $//' <<<"$LOCKLOG")"
has br-on-ok-status "^pending:.*recreating ci-runner-01.*success:main: ci-runner-01 recreated by the management box" "$(tr '\n' ' ' <<<"$STATUS")"
eq br-on-ok-no-refusal "" "$REFUSED"
eq br-on-ok-done-record "SHA1	$V1" "$(cat "$ADIR/runner-done")"
# the same VM still a candidate at the same sha → refused as a perpetual diff, the verb NOT called again
bracket "$POL_ON" "$C_ON"; rc=$?
eq br-perpetual-rc 3 "$rc"; eq br-perpetual-no-verb 0 "$VERB_CALLS"; has br-perpetual-why "perpetual diff" "$REFUSED"
rm -f "$ADIR/runner-done"
# verb 1 (failed after acting) → refused naming it; recorded (no second recreate at this sha)
VERB_RC=1; bracket "$POL_ON" "$C_ON"; rc=$?
eq br-verb-failed-rc 3 "$rc"; has br-verb-failed-why "recreate FAILED after acting" "$REFUSED"
eq br-verb-failed-recorded "SHA1	$V1" "$(cat "$ADIR/runner-done")"; rm -f "$ADIR/runner-done"
# verb 2 (drain refused, nothing applied) → refused; NOT recorded (nothing was recreated)
VERB_RC=2; bracket "$POL_ON" "$C_ON"; rc=$?
eq br-drain-refused-rc 3 "$rc"; has br-drain-refused-why "drain refused, nothing applied" "$REFUSED"
eq br-drain-not-recorded "absent" "$([ -e "$ADIR/runner-done" ] && echo present || echo absent)"
# verb 3 (refused before a window) → refused with its rc
VERB_RC=3; bracket "$POL_ON" "$C_ON"; has br-verb-refused-why "refused ci-runner-01 before a window \(rc 3\)" "$REFUSED"
VERB_RC=0
# the scoped plan carries the other VM → runner-other-vm, the verb never runs
SCOPED="[$(rc_ "$V1" "$REPL" ci-runner-01), $(rc_ "$V2" "$REPL" ci-runner-02)]"; bracket "$POL_ON" "$C_ON"; rc=$?
eq br-scope-rc 3 "$rc"; eq br-scope-no-verb 0 "$VERB_CALLS"; has br-scope-why "^main: runner-other-vm" "$REFUSED"
# the scoped plan errored → refused, the verb never runs
SCOPED=error; bracket "$POL_ON" "$C_ON"; rc=$?
eq br-plan-error-rc 3 "$rc"; eq br-plan-error-no-verb 0 "$VERB_CALLS"
SCOPED="$GOOD_SCOPED"
# row mode shadow → rc 4 (the ordinary path decides), the scoped plan still made + checked, no verb, no status
C_SH="$(mgmt_runner_candidates "$POL_SHADOW" main "$T/p-both")"
bracket "$POL_SHADOW" "$C_SH"; rc=$?
eq br-shadow-rc 4 "$rc"; eq br-shadow-no-verb 0 "$VERB_CALLS"; eq br-shadow-no-status "" "$STATUS"
eq br-shadow-planned "-target=$V1" "$(head -1 "$T/flags")"
# the loop itself SHADOW (no App token) with the row on → the same: never a recreate
MGMT_SHADOW=1 bracket "$POL_ON" "$C_ON"; rc=$?
eq br-loop-shadow-rc 4 "$rc"; eq br-loop-shadow-no-verb 0 "$VERB_CALLS"
# a row naming any other verb → refused
C_BADVERB="$(sed 's/runner-maintenance/node-maintenance/' <<<"$C_ON")"
bracket "$POL_ON" "$C_BADVERB"; rc=$?; eq br-bad-verb-rc 3 "$rc"; has br-bad-verb-why "only runner-maintenance exists" "$REFUSED"
# no name in the plan → refused before any plan
bracket "$POL_ON" "$(mgmt_runner_candidates "$POL_ON" main "$T/p-noname")"; rc=$?
eq br-no-name-rc 3 "$rc"; eq br-no-name-no-plan absent "$([ -e "$T/flags" ] && echo present || echo absent)"
# no candidates at all → 4, nothing done
bracket "$POL_ON" ""; eq br-empty-rc 4 "$?"

echo "mgmt-runner-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
