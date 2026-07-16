#!/usr/bin/env bash
# github-labels-app-bootstrap.sh — bootstrap the "homelab-labels" GitHub App: the ISSUES-tier
# credential for claim-owned label sets (FU-068, docs/agents/agentstack.md §"The GitHub side").
#
# Why a SEPARATE App (not widen homelab-agents/homelab-reviewer): credentials stay per-purpose —
# this one is Issues:R/W + metadata:read ONLY (blast radius: can vandalize issues/labels; can
# NOT touch code, settings, or protection). It is installed org-wide on **All repositories** so
# new repos are covered without a click — the install itself is the one click ever. Consumer:
# provider-upjet-github's ProviderConfig (argocd/resources/crossplane/github-providerconfig.yaml)
# via the github-labels-provider-creds ExternalSecret ← the three Infisical keys minted here.
#
# Sibling of scripts/github-{agents,reviewer}-app-bootstrap.sh, same shape: automate everything
# GitHub has an API for; the browser is reduced to the two clicks it can't mint — one Create
# (App-manifest REST flow) and one Install (choose "All repositories").
#
# Subcommands:  check | manifest | catch | convert <code> | secrets | verify
#   catch — robust alternative to 'convert': listens on REDIRECT_PORT, captures the redirect
#           'code' byte-exact + converts immediately (no copy-paste truncation, no TTL race).
# Env (defaults): ORG=teststuffstash  APP_NAME=homelab-labels
#   CRED_DIR=~/.claude/homelab-github-labels  REDIRECT_PORT=8768
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
APP_NAME="${APP_NAME:-homelab-labels}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-labels}"
REDIRECT_PORT="${REDIRECT_PORT:-8768}"   # 8766=agents, 8767=reviewer — distinct so flows coexist

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

cmd_check() {
  say "Prerequisites"; need gh; need devbox; need jq
  gh auth status >/dev/null 2>&1 && echo "  gh: authed as $(gh api /user --jq .login 2>/dev/null)" || warn "gh not authed (gh auth login)"
  echo "  org=$ORG  app=$APP_NAME  install=ALL repositories  cred_dir=$CRED_DIR"
  say "What still needs the browser"
  cat <<EOF
  1. Create the App   -> 'manifest' then 'catch' (or 'convert <code>') — one Create click.
  2. Install the App  -> one Install click; choose **All repositories** on $ORG.
  Then: 'secrets' (pushes id/install-id/PEM to Infisical), 'verify'.
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-labels-app-manifest.html" manifest
  # Issues tier ONLY: issues:write (labels ride the Issues permission) + metadata:read (implicit
  # base). Deliberately NO contents/pull_requests/administration — see header.
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", issues:"write" },
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
      scripts/github-labels-app-bootstrap.sh catch
  then click "Create GitHub App for $ORG" in the browser; it captures the redirect + converts.

  MANUAL fallback: click "Create"; copy the 'code' from the localhost:$REDIRECT_PORT redirect URL
  (page won't load — fine; take ONLY the value after code=, drop any &state=...), then:
      scripts/github-labels-app-bootstrap.sh convert XXXX
EOF
}

# Exchange a manifest <code> for App creds. MUST be unauthenticated: the code IS the credential,
# and GitHub 404s this endpoint when a fine-grained PAT is attached (gh api always injects one).
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
  NEXT (one Install click): install on **All repositories** (that's the point — new repos free) —
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  Then:  scripts/github-labels-app-bootstrap.sh secrets
EOF
}

cmd_catch() {
  need jq; need curl; need python3
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  echo "  Now open /tmp/gh-labels-app-manifest.html and click \"Create GitHub App for $ORG\"."
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
  need gh; need jq; need devbox; need awk
  local app_id install_id pem pem_escaped
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
  install_id="${INSTALL_ID:-$(gh api "/orgs/$ORG/installations" --jq ".installations[] | select(.app_id==($app_id|tonumber)) | .id" 2>/dev/null || true)}"
  [ -n "$install_id" ] || die "installation not found — is the App INSTALLED on $ORG (All repositories)? Or pass INSTALL_ID="
  echo "$install_id" > "$CRED_DIR/installation-id"
  # The consumer templates these straight into terraform-provider-github's credentials JSON
  # (github-providerconfig.yaml), which requires the PEM \n-ESCAPED as ONE line — escape here,
  # once, at mint time (NOT in the ES template; ESO would need a double-unescape dance).
  pem_escaped=$(awk 'NR>1{printf "\\n"} {printf "%s", $0}' "$pem")
  say "Pushing the labels App credentials into Infisical (homelab/prod)"
  devbox run infisical-secret "LABELS_GH_APP_ID=$app_id" >/dev/null
  devbox run infisical-secret "LABELS_GH_APP_INSTALLATION_ID=$install_id" >/dev/null
  devbox run infisical-secret "LABELS_GH_APP_PRIVATE_KEY=$pem_escaped" >/dev/null
  say "Done. ESO materializes github-labels-provider-creds (crossplane-system) within its refresh;"
  echo "  then: scripts/github-labels-app-bootstrap.sh verify"
  echo "  Enable per repo by adding a labels: block to the stack's AgentStack claim (claim-first,"
  echo "  THEN drop the repo from tofu/github label_repos — docs/agents/agentstack.md)."
}

cmd_verify() {
  need devbox
  local K="devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig"
  say "provider-upjet-github + credentials chain"
  $K get provider.pkg provider-upjet-github 2>/dev/null || warn "Provider not installed (argocd/resources/crossplane/github-provider.yaml synced?)"
  $K -n crossplane-system get externalsecret github-labels-provider-creds 2>/dev/null \
    || warn "creds ExternalSecret absent (github-providerconfig.yaml synced?)"
  $K -n crossplane-system get secret github-labels-provider-creds 2>/dev/null \
    && echo "  → creds Secret present" || warn "no creds Secret yet (Infisical keys minted? run 'secrets')"
  $K get providerconfig.github.upbound.io github-labels 2>/dev/null || warn "ProviderConfig absent"
  say "Composed label sets (per claim-owned repo)"
  $K get issuelabels 2>/dev/null || echo "  (none yet — no claim carries a labels: block)"
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  catch)    cmd_catch ;;
  convert)  shift; cmd_convert "$@" ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|catch|convert|secrets|verify)" ;;
esac
