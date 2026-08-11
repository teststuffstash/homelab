# tofu/cloudflare-token — the Cloudflare mint root

Mints every scoped Cloudflare API token as code (ADR-053): one `.tf` file per token, one
consumer per token. Separate root + state on purpose — this is the *privilege boundary*: you
run it with the **admin token** (the Tier-0 mint-root, host-side only); consumers only ever
get the scoped outputs.

**Who holds which token — scopes, canonical store, delivery, consumer — is the token matrix in
[`docs/cloudflare.md`](../../docs/cloudflare.md), the ONE table.** The `.tf` files here are the
ground truth for permission groups/resources; this README does not restate them (a scope table
lived here once and drifted — removed 2026-08-11).

## The admin token (Tier-0 mint-root — hand-made by construction)

Cloudflare dashboard → My Profile → API Tokens → **"Create Additional Tokens"** template,
expanded to the exact config below (dashboard names first; the API permission-group name —
what `cloudflare-token-audit` renders — in parens where it differs):

| Dashboard row | API permission group |
|---|---|
| User → API Tokens → **Edit** | `API Tokens Write` |
| Zone → Zone → **Read** | `Zone Read` |
| Account → Account Settings → **Read** | `Account Settings Read` |

Resources: Account = Include → the account; Zone = Include → **All zones**. No client-IP
filter. TTL: end date ≈1y out (current one → 2027-01-09, tracked in the `docs/cloudflare.md`
matrix). The zone/account **Read** rows are what let the mint resolve the zone/account
resources it scopes minted tokens to. The value lives in the host
admin wallet (`~/Documents/homelab-admin.kdbx`) ONLY — never the jail, never the cluster
(`docs/secrets.md` §Minting doctrine records why this one credential is manual). Renewal =
re-create in the dashboard before its `expires_on`, re-store in the admin wallet.

## Apply (operator, outside the jail)

```bash
export CLOUDFLARE_API_TOKEN=<admin token>   # from the admin wallet
devbox run cloudflare-token-tofu plan       # scripts/cloudflare-token-tf.sh
devbox run cloudflare-token-tofu apply      # prints the per-token store checklist
```

Minted values flow into the ordinary wallet: `keepass-init.sh` entry → `wallet-files.sh`
regenerates the jail cache → Infisical via ESO for cluster consumers — the apply's checklist
names each destination. Review minted reality with `devbox run cloudflare-token-audit`
(renders policies with permission-group NAMES).

## Notes

- Provider v5 "inconsistent result after apply" on a token modify = policy ORDERING, not
  failure — gotcha 3 in `docs/cloudflare.md`; policy order in `main.tf` is load-bearing.
- These are USER tokens (tied to the operator's Cloudflare user); migration to account tokens
  is opportunistic, per-token, at re-mint time (FU-157).
- `allowed_ips` (tfvars) pins a token to an egress IP. State is local + gitignored; token
  values live only in this state and their stores — never in git.
