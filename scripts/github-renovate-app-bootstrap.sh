#!/usr/bin/env bash
# github-renovate-app-bootstrap.sh — bootstrap the "homelab-renovate" GitHub App: the identity our
# SELF-HOSTED Renovate runs as (renovate[bot]) to open/manage dependency PRs on the app repos. The
# runner is a scheduled workflow (homelab `.github/workflows/renovate.yaml`) that mints a token from
# this App and runs `renovatebot/github-action` with autodiscover — so this App's *installations* are
# exactly the repos Renovate manages. FU-014.
#
# Why a dedicated App (not homelab-agents/-merge/-deploy): Renovate needs a broader grant (issues for
# the dependency dashboard, workflows to bump Action pins) and a distinct `renovate[bot]` identity, and
# its key becomes a GitHub Actions secret. Keeping it separate keeps every other App minimal.
#
# Grant: metadata:read · contents:WRITE (push renovate/* branches) · pull_requests:WRITE (open/label PRs
#   + set platform auto-merge) · issues:WRITE (the Dependency Dashboard issue) · workflows:WRITE (bump
#   `uses:` Action pins in .github/workflows). No webhook/events.
#
# INSTALL TARGET is each repo Renovate should manage (start: sleep-tracking). Renovate autodiscovers the
# App's installations, so "add a repo to Renovate" == "install this App on it".
#
# Ongoing dev is a non-owner "sleep admin" via GitHub App-managers, or OWNER_KIND=user machine-user —
# same options as github-deploy-app-bootstrap.sh (see its header).
#
# Sibling of github-{agents,reviewer,merge,deploy}-app-bootstrap.sh, same shape. Key delivery: → ONE
# Infisical secret (RENOVATE_GH_APP_PRIVATE_KEY) → published to the RENOVATE_APP_* org Actions secrets by
# tofu/github/actions_secrets.tf (the runner reads them). The reviewer-approves-Renovate reflex uses the
# EXISTING homelab-reviewer App (its id/key become REVIEWER_APP_* secrets — no new App for that half).
#
# Subcommands:  check | manifest | catch | convert <code> | install | secrets | verify
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking"  OWNER_KIND=org
#   APP_NAME=homelab-renovate  CRED_DIR=~/.claude/homelab-github-renovate  REDIRECT_PORT=8770
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-tracking}"
APP_NAME="${APP_NAME:-homelab-renovate}"
OWNER_KIND="${OWNER_KIND:-org}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-renovate}"
REDIRECT_PORT="${REDIRECT_PORT:-8770}" # differs from agents/reviewer/merge/deploy (8766-8769)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

_manifest_action() {
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
  2. INSTALL the App  -> 'install'; pick the repos Renovate manages ($REPOS). Renovate autodiscovers these.
  3. Publish secrets  -> 'secrets' (backs the key to Infisical), then
                         devbox run github-tofu apply   # RENOVATE_APP_* + REVIEWER_APP_* secrets
  Then trigger the runner: 'gh workflow run renovate.yaml --repo $ORG/homelab' and check for dep PRs.
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-renovate-app-manifest.html" action manifest
  action="$(_manifest_action)"
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"write", issues:"write", workflows:"write" },
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
  Open it in a browser logged in as $( [ "$OWNER_KIND" = user ] && echo "the machine-user that will own the App" || echo "a $ORG owner / App-manager").
      xdg-open $out
  ROBUST: in another shell run 'scripts/github-renovate-app-bootstrap.sh catch', then click Create.
  MANUAL: copy the ?code= from the localhost:$REDIRECT_PORT redirect, then 'convert XXXX'.
EOF
}

_convert_code() { # <code> -> JSON
  need curl; need jq
  local code="$1" http body
  body=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X POST \
           -H "Accept: application/vnd.github+json" \
           "https://api.github.com/app-manifests/$code/conversions")
  http=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$http" = "201" ] || die "conversion failed (HTTP $http): $(echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body")
  (404 = don't attach a token, the endpoint is unauthenticated; 'name taken' = the App exists, delete/reuse it)"
  echo "$body"
}

_save_conversion() { # <json>
  local resp="$1"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  echo "$resp" | jq -r '.id'   > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem'  > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  ⚠ REQUIRED NEXT — INSTALL the App on the repos Renovate manages ($REPOS):
      scripts/github-renovate-app-bootstrap.sh install
  Then:  scripts/github-renovate-app-bootstrap.sh secrets   &&   devbox run github-tofu apply
EOF
}

cmd_install() {
  local slug owner_path
  slug="${APP_SLUG:-$(cat "$CRED_DIR/slug" 2>/dev/null || true)}"
  [ -n "$slug" ] || die "no slug in $CRED_DIR/slug — run 'convert'/'catch' first (or pass APP_SLUG=)"
  [ "$OWNER_KIND" = "user" ] && owner_path="settings/apps/$slug/installations" \
                             || owner_path="organizations/$ORG/settings/apps/$slug/installations"
  say "Install '$slug' → 'Only select repositories' → $REPOS"
  echo "  https://github.com/$owner_path"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "https://github.com/$owner_path" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "https://github.com/$owner_path" >/dev/null 2>&1 || true
  else echo "  (open it manually)"; fi
}

cmd_catch() {
  need jq; need curl; need python3
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  echo "  Now open /tmp/gh-renovate-app-manifest.html and click Create. (Run 'manifest' first if needed.)"
  local code
  code=$(REDIRECT_PORT="$REDIRECT_PORT" python3 - <<'PY'
import http.server, urllib.parse, os, sys
port = int(os.environ["REDIRECT_PORT"])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("code", [None])[0]
        body = b"Got it \xe2\x80\x94 return to the terminal." if code else b"No 'code' in redirect."
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
  say "Exchanging manifest code for App credentials"
  _save_conversion "$(_convert_code "$code")"
}

cmd_secrets() {
  need jq; need devbox
  local app_id pem
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
  say "Pushing the renovate App private key into Infisical (homelab/prod)"
  devbox run infisical-secret "RENOVATE_GH_APP_PRIVATE_KEY=$(cat "$pem")"
  say "Done (Infisical backup). App id (NOT secret): $app_id"
  cat <<EOF
  If not yet:  scripts/github-renovate-app-bootstrap.sh install   # ⚠ install on $REPOS
  Publish the Actions secrets:  devbox run github-tofu apply       # RENOVATE_APP_* (+ REVIEWER_APP_*)
EOF
}

cmd_verify() {
  need gh
  say "Renovate runner — last run"
  gh run list --repo "$ORG/homelab" --workflow renovate.yaml --limit 1 \
    --json conclusion,createdAt,url --jq '.[0] | "  \(.conclusion)  \(.createdAt)  \(.url)"' 2>/dev/null \
    || warn "no renovate run yet — 'gh workflow run renovate.yaml --repo $ORG/homelab'"
  say "Open dependency PRs on $REPOS"
  for r in $REPOS; do
    n=$(gh pr list --repo "$ORG/$r" --label dependencies --state open --json number --jq 'length' 2>/dev/null || echo "?")
    echo "  $r: $n open dependency PR(s)"
  done
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
