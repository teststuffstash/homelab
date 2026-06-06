# Cloudflare auth = CLOUDFLARE_API_TOKEN env var, set to the scoped homelab-tofu-apply
# write token (see tofu/cloudflare-token/). Never put the token in tfvars/git.
#     export CLOUDFLARE_API_TOKEN=$(cat ~/.claude/cloudflare/write-key)
provider "cloudflare" {}

# This root is separate from tofu/ (own state), so it can't read the in-state Talos
# kubeconfig — it points at the file the main root writes out (tofu/kubeconfig).
provider "kubernetes" {
  config_path = "${path.module}/../kubeconfig"
}

provider "tls" {}
