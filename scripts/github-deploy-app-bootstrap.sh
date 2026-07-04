#!/usr/bin/env bash
# github-deploy-app-bootstrap.sh — bootstrap the "homelab-deploy" GitHub App: the identity the sleep
# stack's DEPLOY pipeline uses to open its version-bump PR in sleep-iac (FU-025, docs/sleep-iac.md
# §"Deploy pipeline"). The sleep-tracking `deploy` workflow mints a short-lived, sleep-iac-scoped token
# from this App (actions/create-github-app-token) and runs scripts/deploy-pin.sh to push the
# `deploy/sleep-ingester` branch + open/auto-merge the chart-pin PR.
#
# Why a SEPARATE, minimal App (not homelab-agents/-merge): its key is copied into a GitHub Actions
# secret readable by sleep-tracking's CI plane (which runs semi-trusted agent-authored code). This App
# grants ONLY contents:write + pull_requests:write on sleep-iac, so a leaked secret can at most push a
# branch + open/merge a deploy PR there — nothing else, nowhere else. The secret is scoped to
# sleep-tracking alone (visibility=selected), not the whole org (tofu/github/actions_secrets.tf).
#
# Grant:  metadata:read · contents:WRITE (push the deploy branch) · pull_requests:WRITE (open + arm
#         auto-merge on the bump PR). Nothing more. No webhook/events.
#
# INSTALL TARGET is sleep-iac (where the App ACTS), NOT sleep-tracking: create-github-app-token resolves
# the installation from app-id + key + the target repo, so the App only needs to be installed on sleep-iac.
#
# ── Who runs this (the "sleep project administrator" question) ───────────────────────────────────────
# The manifest below creates an ORG-OWNED App (posts to /organizations/$ORG/settings/apps/new), which by
# default only an ORG OWNER can create. Two ways to NOT need the org owner day-to-day:
#   • App managers: an owner does the one-time Create, then delegates this specific App to a non-owner
#     member ("GitHub App managers" in Org Settings → GitHub Apps). That member can then install/rotate
#     it — the "sleep admin" pattern without full org ownership.
#   • Machine-user owned: set OWNER_KIND=user to POST to /settings/apps/new instead — the App is owned by
#     whoever is logged in (a dedicated "sleep-admin" account). Installing a user-owned App on the org's
#     sleep-iac still needs a one-time owner approval of the install request.
# Either way the CREATE + first INSTALL-on-org-repo need an owner once; ongoing use does not.
#
# Sibling of github-{agents,reviewer,merge}-app-bootstrap.sh, same shape. Key delivery: → ONE Infisical
# secret (source of truth, DEPLOY_GH_APP_PRIVATE_KEY) → published to the DEPLOY_APP_* Actions secrets by
# tofu/github/actions_secrets.tf (NOT ESO — GitHub Actions can't read Infisical). The App id also drives
# sleep-iac's required-approval BYPASS (tofu/github/repo_rulesets.tf), so the mechanical bump PR
# auto-merges on CI-green without an LLM review.
#
# Subcommands:  check | manifest | catch | convert <code> | install | secrets | verify
#   catch — listens on REDIRECT_PORT, captures the redirect 'code' byte-exact + converts (no copy-paste).
# Env (defaults): ORG=teststuffstash  REPOS="sleep-iac"  OWNER_KIND=org
#   APP_NAME=homelab-deploy  CRED_DIR=~/.claude/homelab-github-deploy  REDIRECT_PORT=8769
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-iac}"
APP_NAME="${APP_NAME:-homelab-deploy}"
OWNER_KIND="${OWNER_KIND:-org}" # org (owned by $ORG) | user (owned by the logged-in machine user)
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-deploy}"
REDIRECT_PORT="${REDIRECT_PORT:-8769}" # differs from agents(8766)/reviewer(8767)/merge(8768) so flows coexist

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

_manifest_action() { # where the Create form POSTs — org-owned vs user-owned
  [ "$OWNER_KIND" = "user" ] && echo "https://github.com/settings/apps/new" \
                             || echo "https://github.com/organizations/$ORG/settings/apps/new"
}

cmd_check() {
  say "Prerequisites"; need gh; need devbox; need jq
  gh auth status >/dev/null 2>&1 && echo "  gh: authed as $(gh api /user --jq .login 2>/dev/null)" || warn "gh not authed (gh auth login)"
  echo "  org=$ORG  app=$APP_NAME  owner=$OWNER_KIND  install-on=[$REPOS]  cred_dir=$CRED_DIR"
  say "What still needs the browser"
  cat <<EOF
  1. Create the App   -> 'manifest' then 'catch'/'convert <code>' (one Create click).
  2. INSTALL the App  -> 'install' opens the page (uses the saved slug); pick sleep-iac.
                         ⚠ NOT optional — the deploy workflow's token mint 404s until it's installed.
  3. Publish secrets  -> 'secrets' (backs the key to Infisical), then
                         devbox run github-tofu apply   # DEPLOY_APP_* secrets + the sleep-iac bypass
  Then 'verify' (the sleep-tracking deploy workflow goes green + opens the sleep-iac PR).
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-deploy-app-manifest.html" action manifest
  action="$(_manifest_action)"
  # Deploy-bumper grant — see header. contents:write (push deploy branch) + pull_requests:write (open+merge).
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"write" },
      default_events:[] }')
  cat > "$out" <<HTML
<!doctype html><meta charset=utf-8><title>Create $APP_NAME GitHub App</title>
<body onload="document.forms[0].submit()">
<p>Submitting App manifest to GitHub… if nothing happens, click the button.</p>
<form action="$action" method="post">
  <input type="hidden" name="manifest" value='$manifest'>
  <button type="submit">Create the '$APP_NAME' App ($OWNER_KIND-owned)</button>
</form></body>
HTML
  say "Wrote $out  (owner=$OWNER_KIND → $action)"
  cat <<EOF
  Open it in a browser logged in as $( [ "$OWNER_KIND" = user ] && echo "the machine-user that will own the App" || echo "a $ORG owner (or an App-manager for a pre-existing App)"):
      xdg-open $out     # or: open $out  (macOS)

  ROBUST (recommended — no copy-paste): in ANOTHER shell first run
      scripts/github-deploy-app-bootstrap.sh catch
  then click "Create" in the browser; it captures the redirect + converts.

  MANUAL fallback: click "Create"; copy the 'code' from the localhost:$REDIRECT_PORT redirect URL
  (page won't load — fine; take ONLY the value after code=, drop any &state=...), then:
      scripts/github-deploy-app-bootstrap.sh convert XXXX
EOF
}

# Exchange a manifest <code> for App creds. MUST be unauthenticated (the code IS the credential; GitHub
# 404s this endpoint when a token is attached — gh api always injects one). Plain curl.
_convert_code() { # <code> -> JSON on stdout
  need curl; need jq
  local code="$1" http body
  body=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X POST \
           -H "Accept: application/vnd.github+json" \
           "https://api.github.com/app-manifests/$code/conversions")
  http=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$http" = "201" ] || die "conversion failed (HTTP $http): $(echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body")
  If 404 with a fresh code: don't attach a token (this endpoint is unauthenticated). If 'name already
  taken': the App exists — delete it in the owner's App settings, or reuse it (APP_ID=/APP_PRIVATE_KEY_FILE=)."
  echo "$body"
}

_save_conversion() { # <json> — persist id/pem/slug to CRED_DIR
  local resp="$1"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  echo "$resp" | jq -r '.id'   > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem'  > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  ⚠ REQUIRED NEXT — the App does NOTHING until it's INSTALLED on sleep-iac (the token mint 404s without
  an installation). Run this (opens the Install page for sleep-iac):
      scripts/github-deploy-app-bootstrap.sh install
  Then:  scripts/github-deploy-app-bootstrap.sh secrets   &&   devbox run github-tofu apply
EOF
}

# Open the App's Install page (reads the saved slug → works even with a global-uniqueness suffix).
cmd_install() {
  local slug owner_path
  slug="${APP_SLUG:-$(cat "$CRED_DIR/slug" 2>/dev/null || true)}"
  [ -n "$slug" ] || die "no slug in $CRED_DIR/slug — run 'convert'/'catch' first (or pass APP_SLUG=)"
  [ "$OWNER_KIND" = "user" ] && owner_path="settings/apps/$slug/installations" \
                             || owner_path="organizations/$ORG/settings/apps/$slug/installations"
  local url="https://github.com/$owner_path"
  say "Install '$slug' → pick 'Only select repositories' → sleep-iac"
  echo "  $url"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true
  else echo "  (open it manually — no xdg-open/open on PATH)"; fi
}

cmd_catch() {
  need jq; need curl; need python3
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  echo "  Now open /tmp/gh-deploy-app-manifest.html and click \"Create\". (Run 'manifest' first if you haven't.)"
  local code
  code=$(REDIRECT_PORT="$REDIRECT_PORT" python3 - <<'PY'
import http.server, urllib.parse, os, sys
port = int(os.environ["REDIRECT_PORT"])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("code", [None])[0]
        body = b"Got it \xe2\x80\x94 you can close this tab; return to the terminal." if code else b"No 'code' in redirect."
        self.send_response(200 if code else 400)
        self.send_header("Content-Type", "text/plain; charset=utf-8"); self.end_headers()
        self.wfile.write(body)
        if code:
            print(code); sys.stdout.flush(); os._exit(0)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
)
  [ -n "$code" ] || die "no code captured"
  say "Captured code (${#code} chars) — converting"
  _save_conversion "$(_convert_code "$code")"
}

cmd_convert() {
  local code="${1:?usage: convert <code-from-redirect-url>}"
  say "Exchanging manifest code for App credentials (POST /app-manifests/$code/conversions)"
  _save_conversion "$(_convert_code "$code")"
}

cmd_secrets() {
  need jq; need devbox
  local app_id pem
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
  # No installation-id needed: the deploy workflow's actions/create-github-app-token resolves the
  # installation from app-id + key + the target repo (sleep-iac) automatically.
  say "Pushing the deploy App private key into Infisical (homelab/prod) — the source of truth"
  devbox run infisical-secret "DEPLOY_GH_APP_PRIVATE_KEY=$(cat "$pem")"
  say "Done (Infisical backup written). App id (NOT secret): $app_id"
  cat <<EOF
  If you haven't yet:  scripts/github-deploy-app-bootstrap.sh install   # ⚠ REQUIRED — install on sleep-iac
  Publish the Actions secrets + the sleep-iac approval bypass:
      devbox run github-tofu apply     # reads id+key from $CRED_DIR → DEPLOY_APP_* secrets + bypass_actors
EOF
}

cmd_verify() {
  need gh
  # Best single signal: does sleep-tracking's deploy workflow go green AND land a PR on sleep-iac? A green
  # deploy run implies App-installed + DEPLOY_APP_* secrets set + token mint OK; a merged deploy PR implies
  # the approval-bypass works. (Introspecting the install needs the App's own JWT, not a PAT.)
  say "sleep-tracking 'deploy' workflow — last run"
  gh run list --repo "$ORG/sleep-tracking" --workflow deploy.yaml --limit 1 \
    --json conclusion,createdAt,url --jq '.[0] | "  \(.conclusion)  \(.createdAt)  \(.url)"' 2>/dev/null \
    || warn "no deploy run yet — push an app change (src/chart/…) or 'gh workflow run deploy.yaml --repo $ORG/sleep-tracking'"
  say "sleep-iac deploy PR (branch deploy/sleep-ingester)"
  gh pr list --repo "$ORG/sleep-iac" --head deploy/sleep-ingester --state all --limit 1 \
    --json state,title,url,mergedAt --jq '.[0] | "  \(.state)  \(.title)  merged=\(.mergedAt)  \(.url)"' 2>/dev/null \
    || warn "no deploy PR yet (or the App can't see sleep-iac — check install + the bypass)"
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  catch)    cmd_catch ;;
  convert)  shift; cmd_convert "$@" ;;
  install)  cmd_install ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|catch|convert|install|secrets|verify)" ;;
esac
