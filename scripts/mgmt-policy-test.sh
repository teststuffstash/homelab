#!/usr/bin/env bash
# mgmt-policy-test — fixture test of the management sentinel's STAGE-1 checker (mgmt_stage1 in
# scripts/mgmt-lib.sh) against policy/mgmt/plan-input.yaml as committed HERE: a synthetic repo, a
# clean dashboard edit must pass, every deny rule must fire exactly on its own change, a symlink
# is caught, a foreign-root-only change selects no root. `devbox run mgmt-policy-test`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export REPO="$HERE/.."
# shellcheck source=mgmt-lib.sh
. "$HERE/mgmt-lib.sh"
POL="$REPO/policy/mgmt/plan-input.yaml"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git -C "$T" init -q -b master
mkdir -p "$T/tofu/dashboards" "$T/tofu/provisioning" "$T/tofu/github" "$T/tofu/cloudflare" "$T/tofu/cloudflare-token"
echo '{"title":"x"}' >"$T/tofu/dashboards/x.json"
printf 'resource "kubernetes_config_map" "x" {\n  data = { "x.json" = file("${path.module}/dashboards/x.json") }\n}\n' >"$T/tofu/monitoring.tf"
printf 'terraform {\n  required_providers {}\n}\n' >"$T/tofu/versions.tf"
echo 'x' >"$T/tofu/provisioning/main.tf"; echo 'x' >"$T/tofu/github/main.tf"; echo 'x' >"$T/tofu/cloudflare/main.tf"; echo 'x' >"$T/tofu/cloudflare-token/main.tf"
git -C "$T" add -A && git -C "$T" commit -q -m base
BASE="$(git -C "$T" rev-parse HEAD)"

pass=0; fail=0
case_() {  # <name> <expected-rule|none|noroot> <shell to make the change>
  local name="$1" want="$2" shell="$3" head hits got roots
  git -C "$T" checkout -q -b "c-$name" "$BASE"
  ( cd "$T" && eval "$shell" ) >/dev/null 2>&1
  git -C "$T" add -A && git -C "$T" commit -q -m "$name" && head="$(git -C "$T" rev-parse HEAD)"
  roots="$(git -C "$T" diff --name-only "$BASE" "$head" | mgmt_roots_touched "$POL" | tr '\n' ' ')"
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
case_ tfvars            deny_paths    'echo "a=1" > tofu/x.auto.tfvars'
case_ shell-script      deny_paths    'echo "#!/bin/sh" > tofu/apply.sh'
case_ tfvars-json       deny_paths    'echo "{}" > tofu/x.auto.tfvars.json'
case_ tf-json           deny_paths    'echo "{}" > tofu/evil.tf.json'
case_ remote-module     deny_patterns 'printf "module \"m\" { source = \"git::https://x/y.git\" }\n" >> tofu/monitoring.tf'
case_ data-external     deny_patterns 'printf "data \"external\" \"x\" {}\n" >> tofu/monitoring.tf'
case_ data-http         deny_patterns 'printf "data \"http\" \"x\" {}\n" >> tofu/monitoring.tf'
case_ provisioner       deny_patterns 'printf "  provisioner \"local-exec\" {}\n" >> tofu/monitoring.tf'
case_ required-providers deny_patterns 'printf "terraform { required_providers { x = {} } }\n" >> tofu/monitoring.tf'
case_ backend           deny_patterns 'printf "terraform { backend \"s3\" {} }\n" >> tofu/monitoring.tf'
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
case_ provisioning-only none          'echo "y" > tofu/provisioning/main.tf'
# a deny hit in a FOREIGN root must not fire (not this box's business)
case_ foreign-deny      noroot        'printf "data \"external\" \"x\" {}\n" >> tofu/cloudflare-token/main.tf'
echo "mgmt-policy-test: PASS $pass/$((pass+fail))"
[ $fail = 0 ]
