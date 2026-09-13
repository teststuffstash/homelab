#!/usr/bin/env bash
# github-mgmt-pat-bootstrap.sh — mint + store + verify the management box's READ-ONLY GitHub
# token: what lets the box `tofu plan` the tofu/github root (FU-238, ADR-131 — the sentinel's L1
# and the drift belt), never apply it (applies stay on the host with the org-admin wallet).
#
# Sibling of github-exporter-pat-bootstrap.sh: a fine-grained PAT is CLICK-ONLY (GitHub has no
# API for it), so this drives the clicks, stores the value, and verifies the scopes — including
# that a WRITE is refused, which is the property the box's copy depends on. Differences from the
# exporter's: the store is the Tier-0 WALLET (scripts/mgmt-provision-secrets.sh ships it to the
# box as GITHUB_TOKEN), not Infisical — the box exists to work with the cluster down; and the
# mint-page expiry is stored beside the token (docs/secrets.md §Expiry belt: PATs are declared).
#
#   scripts/github-mgmt-pat-bootstrap.sh check     # what + order
#   scripts/github-mgmt-pat-bootstrap.sh create    # the mint page + the exact permission list
#   scripts/github-mgmt-pat-bootstrap.sh secrets   # paste (hidden) → wallet github-mgmt-readonly-pat (+ -expiry)
#   scripts/github-mgmt-pat-bootstrap.sh verify    # reads the root needs succeed; a write 403s
#
# Permission set = exactly what the root's resources refresh (tofu/github/*.tf): repositories,
# repo rulesets, a deploy key, the org ruleset, org Actions secrets (metadata only — values are
# write-only, the plan compares against state). If `verify` names a 403, widen ONE permission on
# the mint page and re-run; do not grant more than the 403 asks.
set -euo pipefail
ORG="${ORG:-teststuffstash}"
ENTRY="${ENTRY:-github-mgmt-readonly-pat}"
KP_DIR="${KP_DIR:-$HOME/.claude/homelab-keepass}"
DB="$KP_DIR/homelab.kdbx"; KEY="$KP_DIR/homelab.keyx"
export DEVBOX_QUIET=1
if command -v keepassxc-cli >/dev/null 2>&1; then kp() { keepassxc-cli "$@"; }; else kp() { devbox run --quiet -- keepassxc-cli "$@"; }; fi
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
has_entry() { kp show -q --no-password -k "$KEY" "$DB" "$1" >/dev/null 2>&1; }
kp_val() { kp show -q --no-password -k "$KEY" -a Password "$DB" "$1" 2>/dev/null; }

cmd_check() {
  say "What this sets up"
  cat <<EOT
  1. 'create'  -> the fine-grained-PAT page + the exact settings (browser, as an org ADMIN of $ORG).
  2. 'secrets' -> prompts for the token + its expiry date (no shell history) and stores both in
                  the wallet ($DB: $ENTRY, $ENTRY-expiry).
  3. 'verify'  -> every read the tofu/github root performs succeeds; a write is refused (403).
  Then: scripts/mgmt-provision-secrets.sh --push ships it to the box as GITHUB_TOKEN (FU-238's
  wiring PR adds that row + the policy root), and the box's next sentinel/belt tick plans the root.
EOT
}
cmd_create() {
  local url="https://github.com/settings/personal-access-tokens/new"
  say "Create the fine-grained PAT (browser, logged in as an org ADMIN of $ORG)"
  cat <<EOT
  $url
  Token name:        homelab-mgmt-readonly
  Resource owner:    $ORG                    <- NOT your user; the org must be selected
  Expiration:        1 year (custom, the max) — note the date, 'secrets' asks for it
  Repository access: All repositories        (the root manages 13 repos + rulesets on each)
  Permissions (ALL Read-only — the box plans, never applies):
    Repository -> Administration: Read-only  (repo settings, repo rulesets, deploy keys)
    Repository -> Contents: Read-only        (default branch / archived state the provider refreshes)
    Repository -> Actions: Read-only         (Actions permissions block on github_repository)
                                             (Metadata: Read-only is added automatically)
    Organization -> Administration: Read-only  (the org ruleset)
    Organization -> Secrets: Read-only         (org Actions secrets — names + visibility, never values)
  Then:  scripts/github-mgmt-pat-bootstrap.sh secrets
EOT
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true; fi
}
cmd_secrets() {
  [ -f "$DB" ] && [ -f "$KEY" ] || die "wallet not found at $KP_DIR (KP_DIR=… to point elsewhere; scripts/keepass-init.sh creates it)"
  local token="${GITHUB_MGMT_TOKEN:-}" expiry="${GITHUB_MGMT_EXPIRY:-}"
  if [ -z "$token" ]; then printf 'Paste the github_pat_... value (input hidden): '; read -rs token; echo; fi
  [ -n "$token" ] || die "no token given"
  case "$token" in github_pat_*) ;; *) warn "value doesn't start with github_pat_ — storing anyway" ;; esac
  if [ -z "$expiry" ]; then printf 'Expiry date from the mint page (YYYY-MM-DD): '; read -r expiry; fi
  [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "expiry must be YYYY-MM-DD"
  say "Storing in the wallet as $ENTRY (+ $ENTRY-expiry) — the box's source (mgmt-provision-secrets.sh)"
  for pair in "$ENTRY=$token" "$ENTRY-expiry=$expiry"; do
    local title="${pair%%=*}" value="${pair#*=}"
    if has_entry "$title"; then
      printf '%s\n' "$value" | kp edit -q --no-password -k "$KEY" --password-prompt "$DB" "$title" >/dev/null && echo "  ~ $title (rotated)"
    else
      printf '%s\n' "$value" | kp add -q --no-password -k "$KEY" --password-prompt "$DB" "$title" >/dev/null && echo "  + $title"
    fi
  done
  echo "  Then:  scripts/github-mgmt-pat-bootstrap.sh verify"
}
_get() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com$2"; }
cmd_verify() {
  need curl
  local token="${GITHUB_MGMT_TOKEN:-}"
  [ -n "$token" ] || token="$(kp_val "$ENTRY")"
  [ -n "$token" ] || die "no token: wallet entry $ENTRY is empty (run 'secrets' first) and GITHUB_MGMT_TOKEN is unset"
  local fail=0 code
  check() { # <label> <path> <expected-code> <hint>
    code="$(_get "$token" "$2")"
    if [ "$code" = "$3" ]; then echo "  ✅ $1 ($code)"; else echo "  ❌ $1 → HTTP $code (want $3): $4"; fail=1; fi
  }
  say "Reads the tofu/github root performs"
  check "repository"           "/repos/$ORG/homelab"                          200 "repo Metadata/Administration:read"
  check "repo rulesets"        "/repos/$ORG/homelab/rulesets"                 200 "repo Administration:read"
  check "deploy keys"          "/repos/$ORG/rasmus-soot-cv/keys"              200 "repo Administration:read (deploy keys)"
  check "actions permissions"  "/repos/$ORG/homelab/actions/permissions"      200 "repo Actions:read / Administration:read"
  check "org ruleset list"     "/orgs/$ORG/rulesets"                          200 "org Administration:read"
  check "org actions secrets"  "/orgs/$ORG/actions/secrets"                   200 "org Secrets:read"
  say "A WRITE must be refused (the box's copy depends on it)"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH -H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" --data '{}' "https://api.github.com/repos/$ORG/homelab")"
  if [ "$code" = 403 ]; then echo "  ✅ PATCH repo refused (403)"; else echo "  ❌ PATCH repo → HTTP $code — this token can WRITE; re-mint read-only"; fail=1; fi
  say "Expiry declared"
  local exp; exp="$(kp_val "$ENTRY-expiry" || true)"
  [ -n "$exp" ] && echo "  ✅ $ENTRY-expiry = $exp" || { echo "  ❌ $ENTRY-expiry missing (run 'secrets')"; fail=1; }
  [ $fail = 0 ] && say "OK — next: the FU-238 wiring PR (provision row GITHUB_TOKEN=$ENTRY, policy root github apply:false), then mgmt-provision-secrets.sh --push"
  [ $fail = 0 ]
}
case "${1:-check}" in
  check)   cmd_check ;;
  create)  cmd_create ;;
  secrets) cmd_secrets ;;
  verify)  cmd_verify ;;
  *) die "unknown subcommand '$1' (check|create|secrets|verify)" ;;
esac
