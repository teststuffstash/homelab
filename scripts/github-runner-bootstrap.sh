#!/usr/bin/env bash
# github-runner-bootstrap.sh — bootstrap the Tier-A self-hosted GitHub runner (ARC) + the ghcr
# pull credential. See docs/github-runner-bootstrap.md for the full runbook + context (docs/ci.md
# for the two-tier model). Idempotent; run subcommands in order.
#
# Design goal (per the homelab ethos): automate everything GitHub has an API for; reduce manual
# browser clicking to the two things GitHub has NO API to mint — creating the App and minting a
# PAT — and even the App is driven via the App-manifest REST flow (one "Create" click). Everything
# after (install-id discovery, secret delivery, repo/org wiring, verification) is scripted.
#
# Subcommands:
#   check                 prereqs + what's still missing                       (jail OK)
#   manifest              write a ready-to-submit GitHub App manifest (1 click) (browser host)
#   convert <code>        REST: turn the manifest <code> into App id + key      (browser host)
#   secrets               discover install-id + push all creds → Infisical      (jail OK)
#   access                ensure repo Actions enabled + report runner-group vis  (needs admin tok)
#   verify                live checks: controller, scale set, registered runner  (jail OK)
#
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking snore-recorder"
#                 SCALESET=homelab-ephemeral  CRED_DIR=~/.claude/homelab-github-arc
#                 REDIRECT_PORT=8765
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat   # never page gh output (esp. error bodies) into less

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-tracking snore-recorder}"
SCALESET="${SCALESET:-homelab-ephemeral}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-arc}"
REDIRECT_PORT="${REDIRECT_PORT:-8765}"
KC="${KUBECONFIG:-$PWD/tofu/kubeconfig}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
kc()   { devbox run --quiet -- kubectl --kubeconfig "$KC" "$@"; }

cmd_check() {
  say "Prerequisites"
  need gh; need devbox; need jq
  gh auth status >/dev/null 2>&1 && echo "  gh: authed as $(gh api /user --jq .login 2>/dev/null)" || warn "gh not authed (gh auth login)"
  echo "  org=$ORG  repos=[$REPOS]  scaleset=$SCALESET  cred_dir=$CRED_DIR"
  say "What still needs the browser (no GitHub API to mint these)"
  cat <<EOF
  1. Create the GitHub App     -> 'manifest' then 'convert' (one Create click), then INSTALL it on
                                  the org (one Install click; pick the two repos or All).
  2. Mint a ghcr pull PAT      -> github.com/settings/tokens : a CLASSIC PAT with scope 'read:packages'.
                                  (Fine-grained PATs CANNOT access Packages/ghcr — classic only.) Export it as GHCR_TOKEN.
  Then: 'secrets', 'access', 'verify'.
EOF
}

cmd_manifest() {
  need gh
  local out="/tmp/gh-app-manifest.html" name="homelab-arc-$(date +%s)"
  # ARC org-level runner scale set needs exactly: Organization > Self-hosted runners R/W (+ Metadata R).
  local manifest
  manifest=$(jq -nc --arg n "$name" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", organization_self_hosted_runners:"write" },
      default_events:[] }')
  cat > "$out" <<HTML
<!doctype html><meta charset=utf-8><title>Create ARC GitHub App</title>
<body onload="document.forms[0].submit()">
<p>Submitting App manifest to GitHub… if nothing happens, click the button.</p>
<form action="https://github.com/organizations/$ORG/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value='$manifest'>
  <button type="submit">Create the '$name' App on $ORG</button>
</form></body>
HTML
  say "Wrote $out"
  cat <<EOF
  Open it in a browser logged in as a $ORG owner:
      xdg-open $out     # or: open $out  (macOS)
  Click "Create". GitHub redirects to http://localhost:$REDIRECT_PORT/callback?code=XXXX
  (the page won't load — that's fine). Copy the 'code' value from the address bar, then:
      scripts/github-runner-bootstrap.sh convert XXXX
EOF
}

cmd_convert() {
  need gh; need jq
  local code="${1:?usage: convert <code-from-redirect-url>}"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  say "Exchanging manifest code for App credentials (POST /app-manifests/$code/conversions)"
  local resp; resp=$(gh api -X POST "/app-manifests/$code/conversions") \
    || die "conversion failed (code expired? it's one-shot + ~1h TTL — re-run 'manifest')"
  echo "$resp" | jq -r '.id'         > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.client_id'  > "$CRED_DIR/client-id"
  echo "$resp" | jq -r '.pem'        > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.client_secret // empty' > "$CRED_DIR/client-secret"
  echo "$resp" | jq -r '.webhook_secret // empty' > "$CRED_DIR/webhook-secret"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  NEXT (one click): install the App on the org —
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  choose the two repos (or All). Then mint the ghcr PAT (see 'check') and run:
      GHCR_TOKEN=ghp_... scripts/github-runner-bootstrap.sh secrets
EOF
}

cmd_secrets() {
  need gh; need jq; need devbox
  local app_id install_id pem ghcr="${GHCR_TOKEN:-}"
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
  [ -n "$ghcr" ]   || die "no GHCR_TOKEN (mint a read:packages PAT — see 'check')"

  install_id="${INSTALL_ID:-}"
  if [ -z "$install_id" ]; then
    say "Discovering installation id (GET /orgs/$ORG/installations, app_id=$app_id)"
    install_id=$(gh api "/orgs/$ORG/installations" --jq ".installations[] | select(.app_id==($app_id|tonumber)) | .id" 2>/dev/null || true)
    [ -n "$install_id" ] || die "installation not found — is the App INSTALLED on $ORG? (see 'convert' output). Or pass INSTALL_ID= explicitly. (A fine-grained token may also lack org-admin to list installations.)"
    echo "$install_id" > "$CRED_DIR/installation-id"
  fi
  say "Pushing creds into Infisical (homelab/prod) via scripts/infisical-secret.sh"
  # The PEM is multiline. Use the Infisical CLI's file-load syntax (KEY=@/abs/path) so the newlines
  # survive byte-exact — a plain inline value escapes them to literal `\n` and ARC then rejects the
  # key. Pass an ABSOLUTE path (infisical resolves @paths from its own cwd, = the repo root).
  local pem_abs; pem_abs=$(cd "$(dirname "$pem")" && pwd)/$(basename "$pem")
  devbox run infisical-secret \
    "GHARC_APP_ID=$app_id" \
    "GHARC_INSTALL_ID=$install_id" \
    "GHARC_PRIVATE_KEY=@$pem_abs" \
    "SLEEP_GHCR_PULL_TOKEN=$ghcr"
  say "Done. ESO will render arc-github-app (arc-runners ns) + sleep-ingester-registry (sleep-tracking ns)."
  echo "  app_id=$app_id  install_id=$install_id"
}

cmd_access() {
  need gh
  for r in $REPOS; do
    say "Ensuring Actions enabled on $ORG/$r"
    gh api -X PUT "/repos/$ORG/$r/actions/permissions" -F enabled=true -f allowed_actions=all \
      && echo "  ok ($ORG/$r)" || warn "could not set (token scope? do it in repo Settings>Actions)"
  done
  say "Org runner-group visibility (informational — NON-BLOCKING)"
  # Capture stdout so a 403 response BODY (gh prints it to stdout on error) isn't dumped.
  if rg=$(gh api "/orgs/$ORG/actions/runner-groups" --jq '.runner_groups[] | "  group \(.name): visibility=\(.visibility)"' 2>/dev/null); then
    printf '%s\n' "$rg"
  else
    warn "can't read runner-groups — needs admin:org (a classic PAT) or a fine-grained token with the"
    warn "  org 'Self-hosted runners' permission. read:org/repo is NOT enough. This is OPTIONAL: ARC"
    warn "  registers as the GitHub App (which HAS that permission), and the 'Default' runner group is"
    warn "  available to all org repos by default — so the scale set works without this. Verify in the UI"
    warn "  only if you've restricted the Default group: Org > Settings > Actions > Runner groups."
  fi
  echo "  NOTE: the build-image workflow elevates its own GITHUB_TOKEN (permissions: packages: write),"
  echo "        so no org-wide default-token change is needed for ghcr push."
}

cmd_verify() {
  need devbox
  say "ARC controller (arc-systems)";      kc -n arc-systems get pods 2>/dev/null || warn "no arc-systems yet (ArgoCD synced?)"
  say "Runner scale set (arc-runners)";    kc -n arc-runners get autoscalingrunnerset,pods 2>/dev/null || warn "no arc-runners yet"
  say "arc-github-app secret (ESO)";        kc -n arc-runners get secret arc-github-app 2>/dev/null || warn "secret missing — run 'secrets' + check ESO"
  say "Registered with GitHub org"
  # Capture stdout so a 403 body isn't dumped (this read needs admin:org / runners perm).
  if r=$(gh api "/orgs/$ORG/actions/runners" --jq '.runners[] | "  \(.name)  \(.status)"' 2>/dev/null) && [ -n "$r" ]; then
    printf '%s\n' "$r"
  else
    echo "  (none online — scale-to-zero is normal, or token lacks runners read; trigger a job to spawn one)"
  fi
  cat <<EOF

  Smoke test (spawns one ephemeral runner pod, then scales back):
      gh workflow run -R $ORG/sleep-tracking ci.yaml --ref master
      kc -n arc-runners get pods -w        # watch a runner pod appear on a wk-metal node
EOF
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  convert)  shift; cmd_convert "$@" ;;
  secrets)  cmd_secrets ;;
  access)   cmd_access ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|convert|secrets|access|verify)" ;;
esac
