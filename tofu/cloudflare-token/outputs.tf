output "tofu_apply_token" {
  description = "The scoped write token. Save it for tofu/cloudflare/: tofu -chdir=tofu/cloudflare-token output -raw tofu_apply_token"
  value       = cloudflare_api_token.tofu_apply.value
  sensitive   = true
}

output "tofu_apply_token_id" {
  value = cloudflare_api_token.tofu_apply.id
}
