#!/usr/bin/env bash
# cloudflare-token-audit — render the minted tokens' policies with permission-group NAMES.
#
# The problem (operator, 2026-08-09): `tofu plan/apply` on tofu/cloudflare-token shows
# permission groups as bare hex ids, so a scope change is approved half-blind and verified
# after the fact through the Cloudflare UI — which itself displays FEWER groups than the API
# has. This joins the LOCAL STATE's own data sources (name → id, incl. the full account-scope
# catalog from `account_all`) against each token's policies and prints a readable table.
# Run it after `plan` (state names are current enough) or after `apply` (exact).
#
#   devbox run cloudflare-token-audit
#
# Reads ONLY local state; prints names/ids/resources, never token values. A group id that no
# data source in state carries prints as the bare hex + a pointer to the catalog endpoint —
# absence of a name is a fact about our state, not proof the group is fine (look it up:
# GET /user/tokens/permission_groups with a capable token, or the endpoint's own docs page;
# the semantics authority is ALWAYS the endpoint's "accepted permissions" line, never the
# catalog name — the observability-read.tf audit-logs "take 3" lesson).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVBOX_QUIET=1

devbox run --quiet -- tofu -chdir=tofu/cloudflare-token show -json 2>/dev/null | jq -r '
  # name→id map from EVERY permission_groups_list data source in state
  ([.. | objects
      | select(.type? == "cloudflare_api_token_permission_groups_list")
      | .values.result[]? | {(.id): .name}] | add // {}) as $names
  | [.. | objects | select(.type? == "cloudflare_api_token") | .values]
  | .[]
  | "── \(.name) (id \(.id // "unminted"))",
    (.policies[]
      | "   policy [\(.effect)] resources: \(.resources | fromjson | keys | join(", "))",
        (.permission_groups[]
          | "     • \($names[.id] // "\(.id)  ⚠ name not in state — verify via the catalog/endpoint docs")")),
    ""
'
