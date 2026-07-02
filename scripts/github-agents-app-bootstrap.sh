#!/usr/bin/env bash
# github-agents-app-bootstrap.sh — bootstrap the low-privilege "homelab-agents" GitHub App that the
# agent platform uses against the project repos (homelab ADR-081, docs/agents/). Sibling of
# github-runner-bootstrap.sh and built the same way: automate everything GitHub has an API for;
# reduce the browser to the TWO clicks GitHub can't mint — one "Create" (via the App-manifest REST
# flow) and one "Install" (pick the selected repos). Everything else (App id, private key, install-id
# discovery, secret delivery) is scripted.
#
# The App stays small — metadata:read + contents:write + pull_requests:write + issues:write — and is
# the MAX; two consumers each scope down from it via their own ESO GithubAccessToken generator:
#   - workers — a ~1h token scoped to ONE repo, contents+PR only (clone + push branch + open PR; see
#     <project>/infra/agent/git-token.yaml). Branch protection + that branch+PR-only scope mean a
#     worker can never reach master — belt & suspenders.
#   - the coordinator — needs issues:write (move the agent/* labels) + pull_requests:write (merge PRs)
#     across the agent repos (agents/coordinator/). issues:write lives here for it; the worker token
#     stays narrow.
#
# Subcommands:
#   check              prereqs + what still needs the browser                 (jail OK)
#   manifest           write a ready-to-submit App manifest (1 Create click)  (browser host)
#   convert <code>     REST: turn the manifest <code> into App id + key        (browser host)
#   secrets            discover install-id + push the App creds → Infisical    (jail OK)
#   verify             the ESO secret + generator + minted token render        (jail OK)
#
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking snore-recorder agent-runtime"
#                 APP_NAME=homelab-agents  CRED_DIR=~/.claude/homelab-github-agents  REDIRECT_PORT=8766
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-tracking snore-recorder agent-runtime}"
APP_NAME="${APP_NAME:-homelab-agents}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-agents}"
REDIRECT_PORT="${REDIRECT_PORT:-8766}"
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
  echo "  org=$ORG  app=$APP_NAME  repos=[$REPOS]  cred_dir=$CRED_DIR"
  say "What still needs the browser (no GitHub API to mint these)"
  cat <<EOF
  1. Create the App   -> 'manifest' then 'convert <code>' (one Create click).
  2. Install the App  -> one Install click; pick the SELECTED repos ($REPOS).
  Then: 'secrets', then fill appID/installID into <project>/infra/agent/git-token.yaml, then 'verify'.
EOF
}

cmd_manifest() {
  need gh; need jq
  local out="/tmp/gh-agents-app-manifest.html"
  # Low-priv: workers clone+push+PR (contents+PR); the coordinator labels issues + merges PRs
  # (issues:write). No webhook/events.
  local manifest
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"write", issues:"write" },
      default_events:[] }')
  cat > "$out" <<HTML
<!doctype html><meta charset=utf-8><title>Create $APP_NAME GitHub App</title>
<body onload="document.forms[0].submit()">
<p>Submitting App manifest to GitHub… if nothing happens, click the button.</p>
<form action="https://github.com/organizations/$ORG/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value='$manifest'>
  <button type="submit">Create the '$APP_NAME' App on $ORG</button>
</form></body>
HTML
  say "Wrote $out"
  cat <<EOF
  Open it in a browser logged in as a $ORG owner:
      xdg-open $out     # or: open $out  (macOS)
  Click "Create". GitHub redirects to http://localhost:$REDIRECT_PORT/callback?code=XXXX
  (the page won't load — that's fine). Copy the 'code' from the address bar, then:
      scripts/github-agents-app-bootstrap.sh convert XXXX
EOF
}

cmd_convert() {
  need curl; need jq
  local code="${1:?usage: convert <code-from-redirect-url>}"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  say "Exchanging manifest code for App credentials (POST /app-manifests/$code/conversions)"
  # MUST be unauthenticated: the code IS the credential, and GitHub 404s this endpoint when a token is
  # attached (a fine-grained PAT in particular). `gh api` always injects one, so use plain curl here.
  local resp http; resp=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" "https://api.github.com/app-manifests/$code/conversions")
  http=${resp##*$'\n'}; resp=${resp%$'\n'*}
  [ "$http" = "201" ] || die "conversion failed (HTTP $http): $(echo "$resp" | jq -r '.message // .' 2>/dev/null || echo "$resp") — fresh code + no token attached? (one-shot, ~1h TTL)"
  echo "$resp" | jq -r '.id'  > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem' > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  NEXT (one Install click): install the App on the SELECTED repos ($REPOS) —
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  Then push the creds to Infisical:
      scripts/github-agents-app-bootstrap.sh secrets
EOF
}

cmd_secrets() {
  need gh; need jq; need devbox
  local app_id install_id pem
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"

  install_id="${INSTALL_ID:-}"
  if [ -z "$install_id" ]; then
    say "Discovering installation id (GET /orgs/$ORG/installations, app_id=$app_id)"
    install_id=$(gh api "/orgs/$ORG/installations" --jq ".installations[] | select(.app_id==($app_id|tonumber)) | .id" 2>/dev/null || true)
    [ -n "$install_id" ] || die "installation not found — is the App INSTALLED on $ORG? (see 'convert' output) Or pass INSTALL_ID="
    echo "$install_id" > "$CRED_DIR/installation-id"
  fi
  say "Pushing the App private key into Infisical (homelab/prod)"
  # The Infisical CLI escapes the PEM's newlines to literal \n; the ESO ExternalSecret un-escapes
  # them (template: replace "\\n" "\n"), same as the ARC runner. appID/installID aren't secret.
  devbox run infisical-secret "AGENTS_GH_APP_PRIVATE_KEY=$(cat "$pem")"
  say "Done. Now wire the per-project generator (non-secret ids — paste into git-token.yaml):"
  echo "  appID:     $app_id"
  echo "  installID: $install_id"
  echo "  Then:  kubectl apply -f <project>/infra/agent/git-token.yaml   (per project)"
}

cmd_verify() {
  need devbox
  say "App private-key secret (ESO → sleep-tracking ns)"
  kc -n sleep-tracking get secret agents-github-app 2>/dev/null || warn "missing — run 'secrets' + apply git-token.yaml + check ESO"
  say "Generator + minted token"
  kc -n sleep-tracking get githubaccesstoken,externalsecret agent-git-token 2>/dev/null || warn "not applied yet (kubectl apply -f sleep-tracking/infra/agent/git-token.yaml)"
  kc -n sleep-tracking get secret agent-git-token 2>/dev/null && echo "  → token secret present (key: token)" || warn "no token secret yet (check ExternalSecret status / appID+installID filled)"
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  convert)  shift; cmd_convert "$@" ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|convert|secrets|verify)" ;;
esac
