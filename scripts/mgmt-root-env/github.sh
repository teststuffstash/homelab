# mgmt-root-env/github.sh — per-ROOT environment for the box's plans of tofu/github (FU-238).
# SOURCED by scripts/mgmt-lib.sh (mgmt_plan_root) and scripts/mgmt-probe.sh (the belt) right
# before tofu runs for this root; never run. Why a hook: the root's count-gated org secrets take
# the three App PRIVATE KEYS as variable VALUES (scripts/github-tf.sh does `cat pem` on the host),
# and a PEM cannot live in an EnvironmentFile line — so the keys are files under
# $MGMT_CRED_DIR (staged by scripts/mgmt-provision-secrets.sh, the wallet-files.sh layout) and
# this exports them for the one root that wants them. GITHUB_TOKEN (the read-only PAT) is a
# plain env line already. Without the keys the plan shows the six org secrets as destroys.
_gh_cred="${MGMT_CRED_DIR:-/var/lib/mgmt/cred}"
for _app in deploy renovate reviewer; do
  _d="$_gh_cred/homelab-github-$_app"
  if [ -s "$_d/app-id" ] && [ -s "$_d/private-key.pem" ]; then
    eval "export TF_VAR_${_app}_app_id=\"\$(tr -d '\n' <\"\$_d/app-id\")\""
    eval "export TF_VAR_${_app}_app_private_key=\"\$(cat \"\$_d/private-key.pem\")\""
  else
    echo "mgmt-root-env/github: $_d incomplete — the ${_app} App's org secret will plan as a DESTROY" >&2
  fi
done
unset _gh_cred _app _d
