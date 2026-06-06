# tofu/cloudflare-token

Mints the least-privilege **`homelab-tofu-apply`** Cloudflare write token that
`tofu/cloudflare/` runs with. Separate root + state on purpose: this is the *privilege
boundary*. You run it once with your admin token (from outside the jail); the agent only
ever gets the scoped output.

## Token scope

| Policy | Permission groups | Resource |
|---|---|---|
| zone | `DNS Write`, `SSL and Certificates Write`, `Zone WAF Write` | `teststuff.net` zone only |
| account | `Cloudflare Tunnel Write` | account (tunnels are account-level) |

That's exactly what `tofu/cloudflare/` needs — DNS records, the mTLS client cert + hostname
association, the WAF rule, and the tunnel + its config. Nothing else.

## Apply (you, outside the jail)

```bash
# 1. Create an admin API token in the dashboard (My Profile -> API Tokens), or use an
#    existing admin token. It needs: API Tokens Write, plus read on the zone/account.
export CLOUDFLARE_API_TOKEN=<your admin token>

# 2. Mint the scoped token.
tofu -chdir=tofu/cloudflare-token init
tofu -chdir=tofu/cloudflare-token apply

# 3. Hand the scoped token to the jail-readable secret dir (host path shown).
tofu -chdir=tofu/cloudflare-token output -raw tofu_apply_token \
  > ~/Projects/.claude-data/cloudflare/write-key
chmod 600 ~/Projects/.claude-data/cloudflare/write-key
```

The agent then applies `tofu/cloudflare/` with `CLOUDFLARE_API_TOKEN=$(cat ~/.claude/cloudflare/write-key)`.

## Notes

- Set `allowed_ips` (tfvars or `-var`) to pin the token to your egress IP for extra safety.
- `expires_on` defaults to 2027-01-01 — rotate by re-applying before then.
- State is local + gitignored like the other roots. The token **value** lives only in this
  state and in `~/.claude/cloudflare/` — never in git.
