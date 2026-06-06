terraform {
  required_version = ">= 1.8"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# Auth comes from the CLOUDFLARE_API_TOKEN env var — your *admin* token, used ONCE
# to mint the scoped write token below. Run this root from outside the jail:
#     export CLOUDFLARE_API_TOKEN=<your admin token>
#     tofu -chdir=tofu/cloudflare-token apply
provider "cloudflare" {}
