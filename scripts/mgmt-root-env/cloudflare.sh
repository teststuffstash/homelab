# mgmt-root-env/cloudflare.sh — per-ROOT environment for the box's plans of tofu/cloudflare (FU-238).
# SOURCED by scripts/mgmt-lib.sh (mgmt_plan_root / mgmt_plan_changes) and scripts/mgmt-probe.sh
# right before tofu runs for this root, with $dir = the root's directory in the tree being
# planned; never run. Why a hook: the root's kubernetes provider reads a FILE by relative path
# (`config_path = "${path.module}/../kubeconfig"`, providers.tf — the main root writes it out,
# gitignored), so a PR head's ephemeral worktree never carries it and the plan died on
# `'config_path' refers to an invalid path` (the box's first cloudflare verdict, homelab#1634).
# The box keeps its copy at /var/lib/mgmt/kubeconfig (mgmt-provision-secrets.sh); the jail's is
# the checkout's own. A symlink in the worktree is DATA placed by the trusted tree, not PR content
# executed — the same class as the github hook's exported key values.
_cf_kc=""
for _c in "${MGMT_KUBECONFIG:-}" "${KUBECONFIG:-}" /var/lib/mgmt/kubeconfig "${REPO:-}/tofu/kubeconfig"; do
  [ -n "$_c" ] && [ -f "$_c" ] && _cf_kc="$_c" && break
done
if [ -n "${dir:-}" ] && [ -d "$dir" ] && [ ! -e "$dir/../kubeconfig" ]; then
  if [ -n "$_cf_kc" ]; then ln -s "$_cf_kc" "$dir/../kubeconfig"
  else echo "mgmt-root-env/cloudflare: no kubeconfig found (MGMT_KUBECONFIG / KUBECONFIG / /var/lib/mgmt/kubeconfig / \$REPO/tofu/kubeconfig) — the kubernetes half will error" >&2; fi
fi
unset _cf_kc _c
