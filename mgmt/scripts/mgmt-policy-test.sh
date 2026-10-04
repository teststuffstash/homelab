#!/usr/bin/env bash
# mgmt-policy-test — fixture test of the management sentinel's STAGE-1 checker (mgmt_stage1 in
# mgmt/scripts/mgmt-lib.sh) against policy/mgmt/plan-input.yaml as committed HERE: a synthetic repo, a
# clean dashboard edit must pass, every deny rule must fire exactly on its own change, a symlink
# is caught, a foreign-root-only change selects no root. `devbox run mgmt-policy-test`.
# Since 2026-09-22 also the APPLY side: the allowlist, the Talos config precondition, the post-check polling.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export REPO="$HERE/../.."
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
POL="$REPO/policy/mgmt/plan-input.yaml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$T" init -q -b master
mkdir -p "$T/tofu/dashboards" "$T/tofu/provisioning" "$T/tofu/github" "$T/tofu/cloudflare" "$T/tofu/cloudflare-token"
echo '{"title":"x"}' >"$T/tofu/dashboards/x.json"
printf 'resource "kubernetes_config_map" "x" {\n  data = { "x.json" = file("${path.module}/dashboards/x.json") }\n}\n' >"$T/tofu/monitoring.tf"
printf 'terraform {\n  required_providers {\n    random = {\n      source  = "hashicorp/random"\n      version = "~> 3.6"\n    }\n  }\n}\n' >"$T/tofu/versions.tf"
printf 'provider "registry.opentofu.org/hashicorp/random" {\n  version     = "3.9.0"\n  constraints = "~> 3.6"\n  hashes = [\n    "h1:8EQU5KSxezcjo/phRSe69rDOI0lk4pSaggj7FsskYp8=",\n    "zh:03f1114cc20b8913523735ab76e0f0a2b16ce13c92923a53304bf85f07fc0dbc",\n  ]\n}\n' >"$T/tofu/.terraform.lock.hcl"
echo 'x' >"$T/tofu/provisioning/main.tf"; echo 'x' >"$T/tofu/github/main.tf"; echo 'x' >"$T/tofu/cloudflare/main.tf"; echo 'x' >"$T/tofu/cloudflare-token/main.tf"
git -C "$T" add -A && git -C "$T" commit -q -m base
BASE="$(git -C "$T" rev-parse HEAD)"

pass=0; fail=0
case_() {  # <name> <expected-rule|none|noroot> <shell to make the change>
  local name="$1" want="$2" shell="$3" head hits got roots
  git -C "$T" checkout -q -b "c-$name" "$BASE"
  ( cd "$T" && eval "$shell" ) >/dev/null 2>&1
  git -C "$T" add -A && git -C "$T" commit -q -m "$name" && head="$(git -C "$T" rev-parse HEAD)"
  roots="$(git -C "$T" diff --name-only "$BASE" "$head" | mgmt_roots_touched "$POL")"; rrc=$?
  [ $rrc = 0 ] || { fail=$((fail+1)); echo "FAIL $name — mgmt_roots_touched rc=$rrc (must be 0 whenever the policy is readable)"; git -C "$T" checkout -q "$BASE"; return; }
  roots="$(printf '%s' "$roots" | tr '\n' ' ')"
  hits="$(mgmt_stage1 "$POL" "$T" "$BASE" "$head")"
  got="$(printf '%s' "$hits" | awk -F'\t' '{print $1}' | sort -u | tr '\n' ' ')"
  case "$want" in
    noroot) [ -z "$roots" ] && [ -z "$hits" ] ;;
    none)   [ -n "$roots" ] && [ -z "$hits" ] ;;
    *)      [ "$got" = "$want " ] ;;
  esac
  if [ $? = 0 ]; then pass=$((pass+1)); echo "PASS $name (roots: ${roots:-none}; hits: ${got:-none})"
  else fail=$((fail+1)); echo "FAIL $name — want '$want', roots '${roots}', hits: ${got:-none}"; printf '%s\n' "$hits" | sed 's/^/     /'; fi
  git -C "$T" checkout -q "$BASE"
}
case_ clean-dashboard   none          'echo "{\"title\":\"y\"}" > tofu/dashboards/x.json'
case_ clean-resource    none          'printf "resource \"kubernetes_config_map\" \"y\" {}\n" >> tofu/monitoring.tf'
case_ versions-tf       deny_paths    'echo "# bump" >> tofu/versions.tf'
case_ lockfile          deny_paths    'echo "provider" > tofu/.terraform.lock.hcl'
# the provider-pin shape (ADR-131 amended 2026-09-27): a Renovate bump is ADMITTED, anything wider is not —
# a changed `provider "…"` header trips deny_patterns too (the existing provider-block rule), by design
case_ lockfile-pin      admitted      'sed -i -e "s/3.9.0/3.9.1/" -e "s|h1:8EQU.*|h1:Lw9im2VBBJQ3RyAbHPQ0rcvcmmcZWm3x+kIOpN+Tv9s=\",|" -e "s|zh:03f1.*|zh:105b678ee72322a3067f105d7e05e940f6143238f377f6e87ff4ec909246ac2a\",|" tofu/.terraform.lock.hcl'
case_ lockfile-constraint admitted    'sed -i "s/~> 3.6/~> 3.9/" tofu/.terraform.lock.hcl'
case_ lockfile-source   'deny_paths deny_patterns'    'sed -i "s|hashicorp/random|evil/random|" tofu/.terraform.lock.hcl'
case_ lockfile-new-provider 'deny_paths deny_patterns' 'printf "provider \"registry.opentofu.org/evil/x\" {\n  version = \"1.0.0\"\n}\n" >> tofu/.terraform.lock.hcl'
case_ lockfile-new-file 'deny_paths deny_patterns'    'printf "provider \"registry.opentofu.org/hashicorp/random\" {\n  version = \"3.9.1\"\n}\n" > tofu/provisioning/.terraform.lock.hcl'
case_ lockfile-extra-line deny_paths  'sed -i "s/3.9.0/3.9.1/" tofu/.terraform.lock.hcl; echo "# note" >> tofu/.terraform.lock.hcl'
case_ versions-pin      admitted      'sed -i "s/~> 3.6/~> 3.9/" tofu/versions.tf'
case_ versions-source   deny_paths    'sed -i "s|hashicorp/random|evil/random|" tofu/versions.tf'
case_ pin-plus-tf-edit  admitted      'sed -i "s/3.9.0/3.9.1/" tofu/.terraform.lock.hcl; printf "resource \"kubernetes_config_map\" \"y\" {}\n" >> tofu/monitoring.tf'
# the shape function called DIRECTLY, with no variable named `f` in scope (drill #2030's finding: the
# basename was taken from the caller's `f` and every other caller was silently refused)
git -C "$T" checkout -q -b c-shape-direct "$BASE"; sed -i "s/3.9.0/3.9.1/" "$T/tofu/.terraform.lock.hcl"
git -C "$T" add -A && git -C "$T" commit -q -m shape-direct && shape_head="$(git -C "$T" rev-parse HEAD)"
unset f; lockfile_path="tofu/.terraform.lock.hcl"
if mgmt_provider_pin_shape "$T" "$BASE" "$shape_head" "$lockfile_path"; then pass=$((pass+1)); echo "PASS shape-direct-call (no caller variable named f)"
else fail=$((fail+1)); echo "FAIL shape-direct-call — mgmt_provider_pin_shape refused a pin-shaped lockfile when called outside mgmt_stage1"; fi
git -C "$T" checkout -q "$BASE"
case_ tfvars            deny_paths    'echo "a=1" > tofu/x.auto.tfvars'
case_ shell-script      deny_paths    'echo "#!/bin/sh" > tofu/apply.sh'
case_ tfvars-json       deny_paths    'echo "{}" > tofu/x.auto.tfvars.json'
case_ tf-json           deny_paths    'echo "{}" > tofu/evil.tf.json'
case_ remote-module     deny_patterns 'printf "module \"m\" { source = \"git::https://x/y.git\" }\n" >> tofu/monitoring.tf'
# A denied PATTERN added in one commit and reverted in the next nets to nothing at the span's
# endpoints; the span-wide scan (2026-09-28, review on PR#2087) still sees the added line.
case_ remote-module-added-then-reverted deny_patterns 'printf "module \"m\" { source = \"git::https://x/y.git\" }\n" > tofu/evil.tf; git add -A; git commit -q -m add-evil; rm tofu/evil.tf'
case_ data-external     deny_patterns 'printf "data \"external\" \"x\" {}\n" >> tofu/monitoring.tf'
case_ data-http         deny_patterns 'printf "data \"http\" \"x\" {}\n" >> tofu/monitoring.tf'
case_ provisioner       deny_patterns 'printf "  provisioner \"local-exec\" {}\n" >> tofu/monitoring.tf'
# a StorageClass's storage_provisioner attribute is not a provisioner block (#1843 false positive)
case_ storage-provisioner none        'printf "resource \"kubernetes_storage_class\" \"y\" {\n  storage_provisioner    = \"driver.longhorn.io\"\n}\n" >> tofu/monitoring.tf'
case_ required-providers deny_patterns 'printf "terraform { required_providers { x = {} } }\n" >> tofu/monitoring.tf'
case_ backend           deny_patterns 'printf "terraform { backend \"s3\" {} }\n" >> tofu/monitoring.tf'
# a provider block outside providers.tf (probed 2026-09-16: passed) — endpoint + credential surface
case_ provider-block    deny_patterns 'printf "provider \"proxmox\" {\n  alias    = \"nx02\"\n  endpoint = \"https://evil.example:8006/\"\n}\n" >> tofu/monitoring.tf'
case_ provider-meta-arg none          'printf "resource \"kubernetes_config_map\" \"z\" {\n  provider = kubernetes.other\n}\n" >> tofu/monitoring.tf'
case_ encryption        deny_patterns 'printf "terraform { encryption { } }\n" >> tofu/monitoring.tf'
case_ file-absolute     deny_patterns 'printf "output \"x\" { value = file(\"/var/lib/mgmt/env\") }\n" >> tofu/monitoring.tf'
case_ file-parent       deny_patterns 'printf "output \"x\" { value = filebase64(\"../../etc/x\") }\n" >> tofu/monitoring.tf'
case_ path-cwd          deny_patterns 'printf "output \"x\" { value = path.cwd }\n" >> tofu/monitoring.tf'
case_ symlink           symlink       'ln -s /etc/passwd tofu/dashboards/evil.json'
# a plan READS what these name, with the root's credentials (the #1635 existence-oracle finding)
case_ k8s-data-source   deny_patterns 'printf "data \"kubernetes_secret\" \"x\" { metadata { name = \"cnpg\" namespace = \"kube-system\" } }\n" >> tofu/monitoring.tf'
case_ import-block      deny_patterns 'printf "import {\n  to = kubernetes_secret.x\n  id = \"kube-system/cnpg\"\n}\n" >> tofu/monitoring.tf'
case_ k8s-resource-ok   none          'printf "resource \"kubernetes_secret\" \"y\" { metadata { name = \"y\" } }\n" >> tofu/monitoring.tf'
case_ foreign-only      noroot        'echo "y" > tofu/cloudflare-token/main.tf'
case_ cloudflare-only   none          'echo "y" > tofu/cloudflare/main.tf'
case_ github-only       none          'echo "y" > tofu/github/main.tf'
case_ non-tofu          noroot        'echo "y" > README.md'
# the last diff file (git sorts names) outside every root, an earlier one inside — the loop's
# last-command status must not become the classifier's rc (the 2026-09-13 apply-loop wedge)
case_ last-file-outside none          'echo "y" > tofu/monitoring.tf; mkdir -p zzz; echo "y" > zzz/README.md'
case_ provisioning-only none          'echo "y" > tofu/provisioning/main.tf'
# a deny hit in a FOREIGN root must not fire (not this box's business)
case_ foreign-deny      noroot        'printf "data \"external\" \"x\" {}\n" >> tofu/cloudflare-token/main.tf'
# a root's out-of-dir INPUT selects it (main reads machines/machines.yaml — #1716 onboarded nx-01
# through that file alone and was never planned); a sibling of the input does not
case_ inventory-only    none          'mkdir -p machines; echo "machines: []" > machines/machines.yaml'
case_ inventory-sibling noroot        'mkdir -p machines; echo "x" > machines/README.md'

# ── the classifier FAILS CLOSED (review finding on homelab#1631): an empty root list is a SUCCESS
# status ("no box-held surface touched"), so every way the policy read can fail must surface as a
# non-zero rc with NO output — never as an empty, success-shaped list.
fail_() {  # <name> <shell> — the shell must exit non-zero AND print nothing on stdout
  local name="$1" shell="$2" out rc
  out="$(eval "$shell" 2>/dev/null)"; rc=$?
  if [ $rc -ne 0 ] && [ -z "$out" ]; then pass=$((pass+1)); echo "PASS $name (rc=$rc, no output)"
  else fail=$((fail+1)); echo "FAIL $name — want rc≠0 + empty, got rc=$rc output '$out'"; fi
}
fail_ yq-hiccup        '( _yq() { return 7; }; printf "tofu/github/x.tf\n" | mgmt_roots_touched "$POL" )'
fail_ policy-missing   'printf "tofu/github/x.tf\n" | mgmt_roots_touched "$T/absent.yaml"'
fail_ policy-no-roots  'echo "deny_paths: []" > "$T/empty.yaml"; printf "tofu/github/x.tf\n" | mgmt_roots_touched "$T/empty.yaml"'
fail_ root-without-dir 'printf "roots:\n  main: { apply: true }\n" > "$T/nodir.yaml"; printf "tofu/x.tf\n" | mgmt_roots_touched "$T/nodir.yaml"'
fail_ stage1-rc        '( _yq() { return 7; }; mgmt_stage1 "$POL" "$T" "$BASE" "$(git -C "$T" rev-parse c-versions-tf)" )'
fail_ stage1-bad-head  'mgmt_stage1 "$POL" "$T" "$BASE" 0000000000000000000000000000000000000000'
# the SIBLING reads inside stage 1 (dirs / deny_paths / deny_patterns — the second-round #1631
# finding): _yq fails only from the K-th call onward, so mgmt_roots_touched itself succeeds
# (1 keys + N dirs + N inputs + 1 foreign = its call count); with only the first k calls succeeding, the
# failure lands on the dirs read, then deny_paths, then deny_patterns.
eval "_yq_real() $(declare -f _yq | sed 1d)"
nroots="$(_yq_real -r '.roots | keys | length' "$POL")"
for k in $((2*nroots+2)) $((2*nroots+3)) $((2*nroots+4)); do   # the (k+1)-th call fails: dirs, deny_paths, deny_patterns
  fail_ "stage1-sibling-read-$k" '( C="$T/yqcount"; echo 0 >"$C"; _yq() { n=$(cat "$C"); echo $((n+1)) >"$C"; [ "$n" -lt '"$k"' ] || return 7; _yq_real "$@"; }; mgmt_stage1 "$POL" "$T" "$BASE" "$(git -C "$T" rev-parse c-versions-tf)" )'
done
# the in-cluster half's shape: policy at a ref, temp copy cleaned up, rc preserved across the cleanup
fail_ at-ref-no-policy 'printf "tofu/github/x.tf\n" | mgmt_roots_touched_at "$T" HEAD'
fail_ at-ref-yq-hiccup '( cp "$POL" "$T/policy.yaml"; mkdir -p "$T/policy/mgmt" && cp "$POL" "$T/policy/mgmt/plan-input.yaml" && git -C "$T" add -A && git -C "$T" commit -q -m pol; _yq() { return 7; }; printf "tofu/github/x.tf\n" | mgmt_roots_touched_at "$T" HEAD )'
got="$(printf 'tofu/github/x.tf\ntofu/cloudflare-token/y.tf\n' | mgmt_roots_touched_at "$T" HEAD)"; rc=$?
if [ $rc = 0 ] && [ "$got" = github ]; then pass=$((pass+1)); echo "PASS at-ref-positive (roots: github)"
else fail=$((fail+1)); echo "FAIL at-ref-positive — rc=$rc roots '$got'"; fi

# ── the APPLY side: the allowlist + the Talos config precondition (mgmt_talos_gate) + the post-apply
# health gate (mgmt_post_check), over SYNTHETIC `tofu show -json` plans fed through mgmt_plan_digest —
# the same digest the loop runs on a real plan (docs/management-box.md §MB3 "Talos config applies").
# NIT: node_install_targets roles as the plan's output carries them (before = applied, after = head).
NIT='{"actions":["no-op"],"before":{"wk-03":{"role":"worker"},"cp-01":{"role":"controlplane"},"wk-metal-02":{"role":"controlplane"},"nx-01":{"role":"worker"}},"after":{"wk-03":{"role":"worker"},"cp-01":{"role":"controlplane"},"wk-metal-02":{"role":"controlplane"},"nx-01":{"role":"worker"}},"after_unknown":false}'
talos_rc() {  # <type.name> <key> <actions json> <apply_mode json|absent|unknown>
  local after='{}' unk='{}'
  case "$4" in absent) ;; unknown) unk='{"apply_mode":true}' ;; *) after="{\"apply_mode\":$4}" ;; esac
  [ "$3" = '["delete"]' ] && after=null
  printf '{"address":"%s[\\"%s\\"]","type":"%s","index":"%s","change":{"actions":%s,"after":%s,"after_unknown":%s}}' \
    "$1" "$2" "${1%%.*}" "$2" "$3" "$after" "$unk"
}
apply_case() {  # <name> <expected: allowed | outside | rule-name> <policy> <resource_changes json array> [nit json]
  local name="$1" want="$2" pol="$3" rcs="$4" nit="${5:-$NIT}" out changes outside hits got
  out="$T/plan-$name.bin"
  changes="$(jq -n --argjson rc "$rcs" --argjson nit "$nit" '{resource_changes:$rc, output_changes:(if $nit == null then {} else {node_install_targets:$nit} end)}' | mgmt_plan_digest "$out")" \
    || { fail=$((fail+1)); echo "FAIL apply:$name — mgmt_plan_digest rc≠0"; return; }
  outside="$(printf '%s\n' "$changes" | mgmt_apply_allowed "$pol" main)" || { fail=$((fail+1)); echo "FAIL apply:$name — allowlist unreadable"; return; }
  hits="$(mgmt_talos_gate "$pol" main "$out")" || { fail=$((fail+1)); echo "FAIL apply:$name — talos gate rc≠0"; return; }
  if [ -n "$outside" ]; then got=outside
  elif [ -n "$hits" ]; then got="$(cut -f1 <<<"$hits" | sort -u | tr '\n' ' ' | sed 's/ $//')"
  else got=allowed; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "PASS apply:$name ($got)"
  else fail=$((fail+1)); echo "FAIL apply:$name — want '$want', got '$got'"; printf '%s\n' "$outside" "$hits" | grep . | sed 's/^/     /'; fi
}
POL_CP="$T/policy-cp-true.yaml"
_yq '.roots.main.apply_controlplane_config = true' "$POL" >"$POL_CP"
POL_NOCP="$T/policy-cp-false.yaml"   # the toggle OFF, explicitly — the committed value no longer is
_yq '.roots.main.apply_controlplane_config = false' "$POL" >"$POL_NOCP"
# the committed value: the operator flipped the toggle ON 2026-09-22 (CP config applies are the box's)
got="$(mgmt_policy_get "$POL" '.roots.main.apply_controlplane_config')"
if [ "$got" = true ]; then pass=$((pass+1)); echo "PASS apply:toggle-committed (apply_controlplane_config=true)"
else fail=$((fail+1)); echo "FAIL apply:toggle-committed — committed apply_controlplane_config is '$got', want true (operator 2026-09-22)"; fi
W_NR="$(talos_rc talos_machine_configuration_apply.node wk-03 '["update"]' '"no_reboot"')"
apply_case worker-no-reboot     allowed            "$POL"    "[$W_NR]"
apply_case metal-worker-no-reboot allowed          "$POL"    "[$(talos_rc talos_machine_configuration_apply.metal nx-01 '["update"]' '"no_reboot"')]"
# the ordering point: before package A declares apply_mode the plan carries the provider default
# (or nothing) — the loop keeps refusing
apply_case worker-auto          talos-apply-mode   "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-03 '["update"]' '"auto"')]"
apply_case worker-reboot        talos-apply-mode   "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-03 '["update"]' '"reboot"')]"
apply_case worker-mode-absent   talos-apply-mode   "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-03 '["update"]' absent)]"
apply_case worker-mode-unknown  talos-apply-mode   "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-03 '["update"]' unknown)]"
apply_case cp-toggle-false      talos-controlplane "$POL_NOCP"    "[$(talos_rc talos_machine_configuration_apply.node cp-01 '["update"]' '"no_reboot"')]"
apply_case metal-cp-toggle-false talos-controlplane "$POL_NOCP"   "[$(talos_rc talos_machine_configuration_apply.metal wk-metal-02 '["update"]' '"no_reboot"')]"
apply_case cp-toggle-true       allowed            "$POL_CP" "[$(talos_rc talos_machine_configuration_apply.node cp-01 '["update"]' '"no_reboot"')]"
# the toggle never waives the rest of the precondition
apply_case cp-toggle-true-auto  talos-apply-mode   "$POL_CP" "[$(talos_rc talos_machine_configuration_apply.node cp-01 '["update"]' '"auto"')]"
# one bad apple refuses the whole root (a worker passes, the CP beside it does not)
apply_case worker-plus-cp       talos-controlplane "$POL_NOCP"    "[$W_NR, $(talos_rc talos_machine_configuration_apply.node cp-01 '["update"]' '"no_reboot"')]"
apply_case metal-create         talos-action       "$POL"    "[$(talos_rc talos_machine_configuration_apply.metal nx-01 '["create"]' '"no_reboot"')]"
apply_case metal-delete         talos-action       "$POL"    "[$(talos_rc talos_machine_configuration_apply.metal nx-01 '["delete"]' absent)]"
apply_case node-replace         talos-action       "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-03 '["delete","create"]' '"no_reboot"')]"
# role from node_install_targets only — a node the output does not know is refused, and so is a
# plan whose output is absent (never a name list)
apply_case role-unknown         talos-role-unknown "$POL"    "[$(talos_rc talos_machine_configuration_apply.node wk-99 '["update"]' '"no_reboot"')]"
apply_case no-nit-output        talos-role-unknown "$POL"    "[$W_NR]" null
# the rest of the widening, and what stays outside it
apply_case seed-image-replace   allowed            "$POL"    '[{"address":"proxmox_download_file.talos[\"worker\"]","type":"proxmox_download_file","index":"worker","change":{"actions":["delete","create"],"after":{},"after_unknown":{}}}]'
apply_case vm-change            outside            "$POL"    "[$W_NR, "'{"address":"proxmox_virtual_environment_vm.node[\"wk-03\"]","type":"proxmox_virtual_environment_vm","index":"wk-03","change":{"actions":["update"],"after":{},"after_unknown":{}}}]'
apply_case bootstrap-outside    outside            "$POL"    '[{"address":"talos_machine_bootstrap.this","type":"talos_machine_bootstrap","change":{"actions":["update"],"after":{},"after_unknown":{}}}]'
apply_case residue-only         allowed            "$POL"    '[{"address":"kubernetes_config_map.x","type":"kubernetes_config_map","change":{"actions":["update"],"after":{},"after_unknown":{}}}]'
# the side channel is REQUIRED: a missing one is rc 1 (the loop refuses), never "no Talos change"
fail_ talos-gate-no-channel 'mgmt_talos_gate "$POL" main "$T/never-digested.bin"'

# the post-apply health gate's polling, over a stubbed `compare` (maintenance-window.sh's own verbs
# are pinned by `devbox run maint-self-test`). HSEQ = one verdict per call: ok | reg (a regression).
post_case() {  # <name> <want-rc> <verdict sequence> [grep for the output]
  local name="$1" want="$2" seq="$3" pat="${4:-}" out rc
  printf '%s\n' $seq >"$T/hseq"
  out="$( mgmt_health() { local v; v="$(head -1 "$T/hseq")"; sed -i 1d "$T/hseq"; [ -n "$v" ] || v=reg
            case "$v" in ok) echo "  ok  all"; return 0 ;; *) echo "  ⚠ NEW firing alerts: KubeAPIDown"; echo "  ok  nodes"; return 2 ;; esac; }
          echo 0 >"$T/hclock"; _mgmt_now() { cat "$T/hclock"; }
          _mgmt_sleep() { echo $(( $(cat "$T/hclock") + $1 )) >"$T/hclock"; }
          MGMT_POSTCHECK_SETTLE=0 MGMT_POSTCHECK_INTERVAL=30 MGMT_POSTCHECK_TIMEOUT=90 mgmt_post_check "$T/base.json" )"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$pat" ] || grep -qx -- "$pat" <<<"$out"; }; then pass=$((pass+1)); echo "PASS post:$name (rc=$rc)"
  else fail=$((fail+1)); echo "FAIL post:$name — want rc=$want${pat:+ + '$pat'}, got rc=$rc: $out"; fi
}
post_case clean-first         0 "ok"
post_case transient-recovers  0 "reg reg ok"
post_case regressed-deadline  2 "reg reg reg reg reg reg" "NEW firing alerts: KubeAPIDown"
# the FAKE clock bounds the polls: settle 0, every 30 s, deadline 90 s → readings at t=0,30,60,90 = 4
left="$(grep -c . "$T/hseq")"
if [ "$left" = 2 ]; then pass=$((pass+1)); echo "PASS post:deadline-poll-count (4 readings)"
else fail=$((fail+1)); echo "FAIL post:deadline-poll-count — $((6-left)) readings, want 4"; fi

# FU-300 — the apply loop's declared-window gate (mgmt_apply_window_gate) over a stubbed ConfigMap
# read. WCM = the raw `kubectl get cm responder-window -o json` the stub prints; WGET = ok | notfound
# | fail. rc 0 = proceed, 2 = deferred (the holding windows on stdout), 1 = unreadable (defer too).
FUT="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"; PAST="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
wrec() {  # <id> <until> [extra jq object fields] → one ConfigMap data entry
  jq -cn --arg id "$1" --arg u "$2" --argjson x "${3:-{\}}" \
    '{("w-" + $id): ({id:$id, by:"seat", until:$u, reason:("doing " + $id), node:"", alerts:["X"]} + $x | tojson)}'
}
wcm() { jq -cs '{data: (add // {})}'; }   # entries on stdin → a ConfigMap
win_case() {  # <name> <want-rc> <WGET> <cm-json> [grep -x pattern for the output | !pattern = must NOT appear]
  local name="$1" want="$2" how="$3" cm="$4" pat="${5:-}" out rc ok=1
  printf '%s' "$cm" >"$T/wcm.json"
  out="$( _mgmt_windows_get() { case "$how" in
            ok) cat "$T/wcm.json" ;;
            notfound) echo 'Error from server (NotFound): configmaps "responder-window" not found' >&2; return 1 ;;
            *) echo 'The connection to the server 192.168.2.51:6443 was refused' >&2; return 1 ;; esac; }
          mgmt_apply_window_gate )"; rc=$?
  [ "$rc" = "$want" ] || ok=0
  case "$pat" in '') ;; '!'*) grep -q -- "${pat#!}" <<<"$out" && ok=0 ;; *) grep -qx -- "$pat" <<<"$out" || ok=0 ;; esac
  if [ $ok = 1 ]; then pass=$((pass+1)); echo "PASS window:$name (rc=$rc)"
  else fail=$((fail+1)); echo "FAIL window:$name — want rc=$want${pat:+ + '$pat'}, got rc=$rc: $out"; fi
}
win_case no-configmap       0 notfound ''
win_case no-window          0 ok '{"data":{}}'
win_case no-data            0 ok '{}'
win_case expired-only       0 ok "$(wrec old "$PAST" | wcm)"
win_case live-window        2 ok "$(wrec router-move "$FUT" | wcm)" 'router-move (seat): doing router-move'
win_case live-node-window   2 ok "$(wrec nx-01 "$FUT" '{"node":"nx-01","by":"node-maintenance.sh"}' | wcm)" 'nx-01 (node-maintenance.sh): doing nx-01'
win_case admit-apply        0 ok "$(wrec watched "$FUT" '{"admit_apply":true}' | wcm)"
# --admit-reconciler admits ONE node's sync, never the root-wide apply
win_case admit-reconciler-only 2 ok "$(wrec canary "$FUT" '{"node":"wk-03","admit_reconciler":true}' | wcm)" 'canary (seat): doing canary'
win_case admit-plus-other   2 ok "$( { wrec watched "$FUT" '{"admit_apply":true}'; wrec other "$FUT"; } | wcm)" '!watched'
win_case expired-plus-admit 0 ok "$( { wrec old "$PAST"; wrec watched "$FUT" '{"admit_apply":true}'; } | wcm)"
win_case garbage-entry-skipped 0 ok '{"data":{"w-x":"not json"}}'
win_case unreadable-kubectl 1 fail ''
win_case unreadable-json    1 ok 'Warning: something devbox printed{'
win_case unreadable-empty   1 ok ''

# --- state compatibility of a provider-pin head (S9 #1988, 2026-10-04): mgmt_schema_upgrades over
# synthetic `tofu providers schema -json`, and the plan's managed-type side channel it reads ---
sch() {  # <file> <jq object of resource schema versions> [<jq object of identity versions>]
  jq -n --argjson r "$2" --argjson i "${3:-{\}}" '{provider_schemas:{"registry.opentofu.org/x/k":{
    resource_schemas:($r | with_entries(.value = {version:.value})),
    resource_identity_schemas:($i | with_entries(.value = {version:.value}))}}}' >"$1"
}
printf '%s\n' k_svc k_secret k_old >"$T/types"
sch "$T/sb.json" '{"k_svc":1,"k_secret":0,"k_old":0,"k_unused":0}' '{"k_secret":1}'
schema_case() {  # <name> <head resources> <head identities> <want lines ('|' for TAB, ';' between lines)>
  local got want
  sch "$T/sh.json" "$2" "$3"
  got="$(mgmt_schema_upgrades "$T/sb.json" "$T/sh.json" "$T/types" | tr '\t\n' '|;')"
  want="$4"; [ -n "$want" ] && want="$want;"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "PASS schema:$1"
  else fail=$((fail+1)); echo "FAIL schema:$1 — want '$want', got '$got'"; fi
}
schema_case same            '{"k_svc":1,"k_secret":0,"k_old":0}'            '{"k_secret":1}' ''
schema_case additive-type   '{"k_svc":1,"k_secret":0,"k_old":0,"k_new":3}'  '{"k_secret":1,"k_new":1}' ''
schema_case unused-raised   '{"k_svc":1,"k_secret":0,"k_old":0,"k_unused":4}' '{"k_secret":1}' ''
schema_case schema-raised   '{"k_svc":2,"k_secret":0,"k_old":0}'            '{"k_secret":1}' 'k_svc|schema 1|schema 2'
schema_case identity-raised '{"k_svc":1,"k_secret":0,"k_old":0}'            '{"k_secret":2}' 'k_secret|identity 1|identity 2'
schema_case identity-added  '{"k_svc":1,"k_secret":0,"k_old":0}'            '{"k_secret":1,"k_svc":0}' 'k_svc|identity none|identity 0'
schema_case removed         '{"k_svc":1,"k_secret":0}'                      '{"k_secret":1}' 'k_old|schema 0|removed'
schema_case lowered         '{"k_svc":0,"k_secret":0,"k_old":0}'            '{"k_secret":1}' ''
echo '{}' >"$T/sbad.json"
if out="$(mgmt_schema_upgrades "$T/sbad.json" "$T/sb.json" "$T/types")"; then fail=$((fail+1)); echo "FAIL schema:unreadable — rc 0 (must fail closed), out '$out'"
else pass=$((pass+1)); echo "PASS schema:unreadable (rc≠0)"; fi
jq -n '{resource_changes:[{address:"k_svc.a",mode:"managed",type:"k_svc",change:{actions:["no-op"]}},
  {address:"module.m.k_secret.b[\"x\"]",mode:"managed",type:"k_secret",change:{actions:["update"]}},
  {address:"data.k_svc.c",mode:"data",type:"k_data",change:{actions:["read"]}},
  {address:"k_old.d",mode:"managed",type:"k_old",change:{actions:["delete"]}}]}' | mgmt_plan_digest "$T/tp" >/dev/null
if [ "$(tr '\n' ' ' <"$T/tp.types")" = "k_old k_secret k_svc " ]; then pass=$((pass+1)); echo "PASS schema:plan-types-side-channel"
else fail=$((fail+1)); echo "FAIL schema:plan-types-side-channel — got '$(tr '\n' ' ' <"$T/tp.types")'"; fi

# the excluded-types path (review finding on PR#2205): a type the plan never carried — excluded by
# policy, so absent from resource_changes — still reaches the compare via the state / exclusion lists
printf '%s\n' 'module.m.k_old.x["a.b"]' 'data.k_data.y' >"$T/tp.excluded"
mgmt_judged_types "$T/tp" 'k_policy' >"$T/tp.types-all"
if [ "$(tr '\n' ' ' <"$T/tp.types-all")" = "k_old k_policy k_secret k_svc " ]; then pass=$((pass+1)); echo "PASS schema:excluded-types-reach-the-compare"
else fail=$((fail+1)); echo "FAIL schema:excluded-types-reach-the-compare — got '$(tr '\n' ' ' <"$T/tp.types-all")'"; fi
sch "$T/sh.json" '{"k_svc":1,"k_secret":0}' '{"k_secret":1}'
printf 'k_svc\n' >"$T/tq.types"; printf 'k_old.x\n' >"$T/tq.state"; mgmt_judged_types "$T/tq" '' >"$T/tp-union"
got="$(mgmt_schema_upgrades "$T/sb.json" "$T/sh.json" "$T/tp-union" | tr '\t\n' '|;')"
if [ "$got" = "k_old|schema 0|removed;" ]; then pass=$((pass+1)); echo "PASS schema:excluded-type-removal-caught"
else fail=$((fail+1)); echo "FAIL schema:excluded-type-removal-caught — got '$got'"; fi
# --- the tofu-provider-revert candidate (S9 #1988): mgmt_provider_pin_commit over a synthetic history ---
R="$T/pinhist"; git init -q -b master "$R"; mkdir -p "$R/tofu"
cp "$T/tofu/.terraform.lock.hcl" "$R/tofu/"; cp "$T/tofu/versions.tf" "$R/tofu/"; echo 'x' >"$R/tofu/main.tf"
git -C "$R" add -A && git -C "$R" commit -q -m base
sed -i "s/3.9.0/3.9.1/" "$R/tofu/.terraform.lock.hcl"; git -C "$R" commit -q -am "random 3.9.1 (#11)"; PIN1="$(git -C "$R" rev-parse HEAD)"
echo 'y' >>"$R/tofu/main.tf"; git -C "$R" commit -q -am "unrelated tofu edit (#12)"
pc() {  # <name> <provider> <version> <want: sha|before or 'rc1'>
  local got
  got="$(mgmt_provider_pin_commit "$R" HEAD tofu/.terraform.lock.hcl "$2" "$3" 2>/dev/null | tr '\t' '|')" || got=rc1
  if [ "$got" = "$4" ]; then pass=$((pass+1)); echo "PASS pincommit:$1"; else fail=$((fail+1)); echo "FAIL pincommit:$1 — want '$4', got '$got'"; fi
}
pc found-past-unrelated random 3.9.1 "$PIN1|3.9.0"
pc version-never-set   random 3.9.7 rc1
pc unknown-provider    kubernetes 3.2.1 rc1
sed -i "s/3.9.1/3.9.2/" "$R/tofu/.terraform.lock.hcl"; echo 'z' >>"$R/tofu/main.tf"; git -C "$R" commit -q -am "random 3.9.2 + a tf edit (#13)"
pc introducer-not-pin-only random 3.9.2 rc1
sed -i "s/3.9.2/3.9.3/" "$R/tofu/.terraform.lock.hcl"; sed -i 's/~> 3.6/~> 3.9/' "$R/tofu/versions.tf"; git -C "$R" commit -q -am "random 3.9.3 + constraint (#14)"; PIN4="$(git -C "$R" rev-parse HEAD)"
pc lock-plus-versions-tf random 3.9.3 "$PIN4|3.9.2"

# --- unexercised providers (S9 #1988, 2026-10-04): which provider an apply error lands on, and the
# record a successful changing apply leaves (mgmt_lock_versions / mgmt_unexercised / mgmt_record_exercised) ---
printf 'provider "registry.opentofu.org/hashicorp/kubernetes" {\n  version     = "3.2.1"\n  constraints = "~> 3.0"\n}\n\nprovider "registry.opentofu.org/hashicorp/helm" {\n  version = "3.0.2"\n}\n\nprovider "registry.opentofu.org/siderolabs/talos" {\n  version = "0.9.0"\n}\n' >"$T/ulock.hcl"
ux() {  # <name> <want ('|' TAB, ';' lines)> <got>
  if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS unex:$1"; else fail=$((fail+1)); echo "FAIL unex:$1 — want '$2', got '$3'"; fi
}
mgmt_lock_versions "$T/ulock.hcl" >"$T/uv"
ux lock-versions 'kubernetes|3.2.1;helm|3.0.2;talos|0.9.0;' "$(tr '\t\n' '|;' <"$T/uv")"
if mgmt_lock_versions "$T/nonexistent.hcl" >/dev/null; then ux lock-unreadable 'rc1' 'rc0'; else ux lock-unreadable 'rc1' 'rc1'; fi
printf 'kubernetes\t2.38.0\nhelm\t3.0.2\n' >"$T/uex"
printf 'kubernetes_deployment.a\tupdate\nmodule.m["x"].helm_release.b\tupdate\n' >"$T/uch"
ux new-kubernetes 'kubernetes|2.38.0|3.2.1;' "$(mgmt_unexercised "$T/uv" "$T/uex" "$T/uch" | tr '\t\n' '|;')"
printf 'helm_release.b\tupdate\n' >"$T/uch2"
ux only-exercised-touched '' "$(mgmt_unexercised "$T/uv" "$T/uex" "$T/uch2" | tr '\t\n' '|;')"
printf 'talos_machine_configuration_apply.w\tupdate\ndata.kubernetes_secret.s\tread\n' >"$T/uch3"
ux never-recorded-and-data-skipped 'talos|unknown|0.9.0;' "$(mgmt_unexercised "$T/uv" "$T/uex" "$T/uch3" | tr '\t\n' '|;')"
printf 'random_password.p\tcreate\n' >"$T/uch4"
ux provider-not-in-lock '' "$(mgmt_unexercised "$T/uv" "$T/uex" "$T/uch4" | tr '\t\n' '|;')"
cp "$T/uex" "$T/uex2"; mgmt_record_exercised "$T/uv" "$T/uex2" "$T/uch"
ux record-merges 'helm|3.0.2;kubernetes|3.2.1;' "$(tr '\t\n' '|;' <"$T/uex2")"
mgmt_record_exercised "$T/uv" "$T/uex-fresh" "$T/uch3"
ux record-from-nothing 'talos|0.9.0;' "$(tr '\t\n' '|;' <"$T/uex-fresh")"
ux after-record-clean '' "$(mgmt_unexercised "$T/uv" "$T/uex2" "$T/uch" | tr '\t\n' '|;')"

echo "mgmt-policy-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
