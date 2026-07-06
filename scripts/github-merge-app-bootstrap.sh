#!/usr/bin/env bash
# github-merge-app-bootstrap.sh — bootstrap the "homelab-merge" GitHub App: the merge-serializer identity
# for the deterministic merge path (FU-041, docs/agents/merge-path.md). Used by the per-repo updater
# workflow (update-pr-branch.yml), which mints a homelab-merge[bot] token so its branch-update push
# RE-TRIGGERS CI — a bare GITHUB_TOKEN push would not, and a strict branch would never go green.
#
# Why a SEPARATE App (not reuse homelab-agents): the updater's key must be copied into a GitHub org Actions
# secret to be readable by the workflow, and the CI plane runs semi-trusted agent-authored code (an in-repo
# agent PR branch can add a workflow that reads org secrets). homelab-agents' key also mints the COORDINATOR
# token (issues:write, multi-repo, merge) — too broad to expose there. This App is minimal, so a leaked org
# secret only grants branch-updates. The updater never approves (no self-approval conflict → unlike the
# reviewer, the distinct identity is for BLAST RADIUS + audit legibility, not a hard GitHub constraint).
#
# Grant (the update-branch op + reading PR/check state, nothing more):
#   metadata:read · contents:WRITE (update-branch pushes a merge commit to the PR head) · pull_requests:WRITE
#   (update-branch is a /pulls/ mutation — a GitHub App needs BOTH pull_requests:write AND contents:write, or
#   the endpoint 403s "Resource not accessible by integration"; PR:read alone is NOT enough — learned the hard
#   way) · checks:READ + statuses:READ (require_passed_checks). NO issues — the conflict-labeling step uses
#   the workflow's GITHUB_TOKEN.
#
# Sibling of github-agents/reviewer-app-bootstrap.sh, same shape. Delivery target differs: the key goes to
# ONE Infisical secret (source of truth, MERGE_GH_APP_PRIVATE_KEY) → published to a GitHub org Actions
# secret by tofu/github/actions_secrets.tf (NOT ESO — GitHub Actions can't read Infisical).
#
# Subcommands:  check | manifest | catch | convert <code> | install | secrets | verify
#   catch — listens on REDIRECT_PORT, captures the redirect 'code' byte-exact + converts (no copy-paste).
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking snore-recorder openrouter-operator homelab"
#   APP_NAME=homelab-merge  CRED_DIR=~/.claude/homelab-github-merge  REDIRECT_PORT=8768
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
# homelab is a deploy TARGET (chart/image bump PRs land here), so its updater needs the App too
REPOS="${REPOS:-sleep-tracking snore-recorder openrouter-operator homelab}"
APP_NAME="${APP_NAME:-homelab-merge}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-merge}"
REDIRECT_PORT="${REDIRECT_PORT:-8768}"   # differs from agents(8766)/reviewer(8767) so flows coexist

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

cmd_check() {
  say "Prerequisites"; need gh; need devbox; need jq
  gh auth status >/dev/null 2>&1 && echo "  gh: authed as $(gh api /user --jq .login 2>/dev/null)" || warn "gh not authed (gh auth login)"
  echo "  org=$ORG  app=$APP_NAME  repos=[$REPOS]  cred_dir=$CRED_DIR"
  say "What still needs the browser"
  cat <<EOF
  1. Create the App   -> 'manifest' then 'catch'/'convert <code>' (one Create click).
  2. INSTALL the App  -> 'install' opens the page (uses the saved slug); pick the SAME repos ($REPOS).
                         ⚠ NOT optional — the updater 404s/403s until the App is installed.
  3. Publish secrets  -> 'devbox run github-tofu apply' (reads id+key from $CRED_DIR). 'secrets' also
                         backs the key up to Infisical. See docs/github-setup.md §4.
  Then 'verify' (checks the updater workflow actually goes green end-to-end).
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-merge-app-manifest.html" manifest
  # Merge-serializer grant — see header. contents:write (update-branch) + read-only PR/checks/statuses.
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"write", checks:"read", statuses:"read" },
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

  ROBUST (recommended — no copy-paste of the code): in ANOTHER shell first run
      scripts/github-merge-app-bootstrap.sh catch
  then click "Create GitHub App for $ORG" in the browser; it captures the redirect + converts.

  MANUAL fallback: click "Create"; copy the 'code' from the localhost:$REDIRECT_PORT redirect URL
  (page won't load — fine; take ONLY the value after code=, drop any &state=...), then:
      scripts/github-merge-app-bootstrap.sh convert XXXX
EOF
}

# Exchange a manifest <code> for App creds. MUST be unauthenticated: the code IS the credential, and
# GitHub 404s this endpoint when a fine-grained PAT is attached (gh api always injects one). Plain curl.
_convert_code() {   # <code> -> JSON on stdout
  need curl; need jq
  local code="$1" http body
  body=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X POST \
           -H "Accept: application/vnd.github+json" \
           "https://api.github.com/app-manifests/$code/conversions")
  http=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$http" = "201" ] || die "conversion failed (HTTP $http): $(echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body")
  If HTTP 404 with a fresh code: don't attach a token (this endpoint is unauthenticated). If 'name already
  taken': the App exists — delete it in $ORG's App settings or reuse it (APP_ID=/APP_PRIVATE_KEY_FILE=)."
  echo "$body"
}

_save_conversion() {   # <json> — persist id/pem/slug to CRED_DIR (shared by convert + catch)
  local resp="$1"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  echo "$resp" | jq -r '.id'   > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem'  > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  ⚠ REQUIRED NEXT — the App does NOTHING until it's INSTALLED on the repos (the updater 404s / 403s
  without an installation). Run this (opens the Install page for the SAME repos as the worker, $REPOS):
      scripts/github-merge-app-bootstrap.sh install
  Then publish the org Actions secrets:  devbox run github-tofu apply   (reads id+key from $CRED_DIR)
EOF
}

# Open the App's Install page. Reads the slug we saved (no guessing the URL), so this works even when the
# App got a global-uniqueness suffix (homelab-merge-NNNN). Install on the SAME repos as the worker.
cmd_install() {
  local slug="${APP_SLUG:-$(cat "$CRED_DIR/slug" 2>/dev/null || true)}"
  [ -n "$slug" ] || die "no slug in $CRED_DIR/slug — run 'convert'/'catch' first (or pass APP_SLUG=)"
  local url="https://github.com/organizations/$ORG/settings/apps/$slug/installations"
  say "Install '$slug' on the agent repos: pick 'Only select repositories' → $REPOS"
  echo "  $url"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true
  else echo "  (open it manually — no xdg-open/open on PATH)"; fi
}

cmd_catch() {
  need jq; need curl; need python3
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  echo "  Now open /tmp/gh-merge-app-manifest.html and click \"Create GitHub App for $ORG\"."
  echo "  (If you haven't generated it yet: run 'manifest' first, in another shell.)"
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
            print(code)
            sys.stdout.flush()
            os._exit(0)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
)
  [ -n "$code" ] || die "no code captured"
  say "Captured code (${#code} chars) — converting (POST /app-manifests/<code>/conversions)"
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
  # No installation-id needed: the updater's actions/create-github-app-token resolves the installation
  # from app-id + private-key + repo automatically (unlike the reviewer's ESO GithubAccessToken generator).
  say "Pushing the merge App private key into Infisical (homelab/prod) — the source of truth"
  devbox run infisical-secret "MERGE_GH_APP_PRIVATE_KEY=$(cat "$pem")"
  say "Done (Infisical backup written). App id (NOT secret): $app_id"
  cat <<EOF
  If you haven't yet:  scripts/github-merge-app-bootstrap.sh install   # ⚠ REQUIRED — install on $REPOS
  Publish the org Actions secrets:  devbox run github-tofu apply       # reads id+key from $CRED_DIR
EOF
}

cmd_verify() {
  need gh
  # The ONLY reliable end-to-end check: does the updater workflow actually go green? That single signal
  # covers App-installed + org-secrets-set + permissions-correct all at once — a green run is impossible
  # unless all three hold. (Introspecting the install directly needs the App's own JWT, not a PAT; and
  # `gh secret list --org` needs the org-admin token, which isn't in this shell — so those checks lie.)
  say "Updater workflow status per repo (green ⇒ App installed + secrets set + permissions correct)"
  for r in $REPOS; do
    line="$(gh run list --repo "$ORG/$r" --workflow update-pr-branch.yml --limit 1 \
              --json conclusion,createdAt,url --jq '.[0] | "\(.conclusion)  \(.createdAt)  \(.url)"' 2>/dev/null || true)"
    case "$line" in
      success*) echo "  $r: ✅ $line" ;;
      "")       warn "  $r: no updater run yet — push the workflow / 'gh workflow run update-pr-branch.yml --repo $ORG/$r'" ;;
      *)        warn "  $r: ❌ $line
        └─ inspect: gh run view <id> --repo $ORG/$r --log-failed   (403 'not accessible by integration' ⇒ App perms; 404 'installation' ⇒ not installed)" ;;
    esac
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
