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
#   metadata:read · contents:WRITE (update-branch = a merge commit on the PR head) · pull_requests:READ
#   (enumerate/inspect open PRs + auto-merge state) · checks:READ + statuses:READ (require_passed_checks).
#   NO issues, NO pull_requests:write — the conflict-labeling step uses the workflow's GITHUB_TOKEN.
#
# Sibling of github-agents/reviewer-app-bootstrap.sh, same shape. Delivery target differs: the key goes to
# ONE Infisical secret (source of truth, MERGE_GH_APP_PRIVATE_KEY) → published to a GitHub org Actions
# secret by tofu/github/actions_secrets.tf (NOT ESO — GitHub Actions can't read Infisical).
#
# Subcommands:  check | manifest | catch | convert <code> | secrets | verify
#   catch — listens on REDIRECT_PORT, captures the redirect 'code' byte-exact + converts (no copy-paste).
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking snore-recorder"
#   APP_NAME=homelab-merge  CRED_DIR=~/.claude/homelab-github-merge  REDIRECT_PORT=8768
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-tracking snore-recorder}"
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
  2. Install the App  -> one Install click; pick the SAME repos as the worker ($REPOS).
  Then: 'secrets' (pushes the key to Infisical), then publish it to GitHub Actions via
        tofu/github (TF_VAR_merge_gh_app_id + TF_VAR_merge_gh_app_private_key; see docs/github-setup.md §4).
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-merge-app-manifest.html" manifest
  # Merge-serializer grant — see header. contents:write (update-branch) + read-only PR/checks/statuses.
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"read", checks:"read", statuses:"read" },
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
  NEXT (one Install click): install on the SAME repos as the worker ($REPOS) —
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  Then:  scripts/github-merge-app-bootstrap.sh secrets
EOF
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
  say "Done. Publish to GitHub Actions org secrets via tofu (App key is copied into the CI plane HERE):"
  echo "  app id (NOT secret): $app_id  → set as var.merge_gh_app_id (tofu/github/variables.tf default or TF_VAR)"
  cat <<EOF
  export TF_VAR_merge_gh_app_id="$app_id"
  export TF_VAR_merge_gh_app_private_key="\$(cat "$pem")"   # or: infisical secrets get MERGE_GH_APP_PRIVATE_KEY --plain ...
  tofu -chdir=tofu/github apply    # OUTSIDE the jail, admin token — creates MERGE_GH_APP_ID + _PRIVATE_KEY org secrets
EOF
}

cmd_verify() {
  need gh
  say "GitHub org Actions secrets (names only — values are write-only)"
  gh secret list --org "$ORG" 2>/dev/null | grep -E 'MERGE_GH_APP_(ID|PRIVATE_KEY)' \
    && echo "  → both org Actions secrets present" \
    || warn "MERGE_GH_APP_ID / MERGE_GH_APP_PRIVATE_KEY not set yet (run 'secrets' then tofu apply)"
  say "App installed on the agent repos?"
  for r in $REPOS; do
    gh api "/repos/$ORG/$r/installation" --jq '.app_slug' 2>/dev/null | grep -q "$APP_NAME" \
      && echo "  $r: $APP_NAME installed" || warn "  $r: $APP_NAME NOT installed (one Install click)"
  done
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  catch)    cmd_catch ;;
  convert)  shift; cmd_convert "$@" ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|convert|secrets|verify)" ;;
esac
