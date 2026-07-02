#!/usr/bin/env bash
# github-reviewer-app-bootstrap.sh — bootstrap the "homelab-reviewer" GitHub App: the review bot's
# identity for the agentic merge gate (agents/reviewer-session.sh, docs/agents/workflow.md).
#
# Why a SEPARATE App (not reuse homelab-agents): GitHub blocks self-approval. The worker opens the PR
# as homelab-agents[bot]; a native `gh pr review --approve` from that same bot fails ("Can not approve
# your own pull request"). So the reviewer needs a DISTINCT identity — this App → homelab-reviewer[bot].
# Grant: metadata:read + pull_requests:write + contents:WRITE. contents:write is REQUIRED — GitHub only
# counts an approving review from a reviewer with repository *write* access; with contents:read the review
# is submitted but authorAssociation=NONE and does NOT satisfy the required-approval gate (learned
# 2026-07-02). Tradeoff accepted: the bot can push to branches (mitigated — session prompt says don't push,
# ~1h token, master still needs a PR + this approval). GitHub auto-merge still performs the merge itself.
#
# Sibling of scripts/github-agents-app-bootstrap.sh, same shape: automate everything GitHub has an API
# for; the browser is reduced to two clicks it can't mint — one Create (App-manifest REST flow) and one
# Install (pick the agent repos). Delivery target differs: one Infisical key, consumed by ONE ESO
# generator (agents/coordinator/reviewer-git.yaml) → the `reviewer-git` Secret the reviewer pod mounts.
#
# Subcommands:  check | manifest | catch | convert <code> | secrets | verify
#   catch — robust alternative to 'convert': listens on REDIRECT_PORT, captures the redirect 'code'
#           byte-exact + converts immediately (no copy-paste truncation, no &state, no TTL race).
# Env (defaults): ORG=teststuffstash  REPOS="sleep-tracking snore-recorder"
#   APP_NAME=homelab-reviewer  CRED_DIR=~/.claude/homelab-github-reviewer  REDIRECT_PORT=8767
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

ORG="${ORG:-teststuffstash}"
REPOS="${REPOS:-sleep-tracking snore-recorder}"
APP_NAME="${APP_NAME:-homelab-reviewer}"
CRED_DIR="${CRED_DIR:-$HOME/.claude/homelab-github-reviewer}"
REDIRECT_PORT="${REDIRECT_PORT:-8767}"   # differs from the agents App's 8766 so both flows can coexist

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
  1. Create the App   -> 'manifest' then 'convert <code>' (one Create click).
  2. Install the App  -> one Install click; pick the SAME repos as the worker ($REPOS).
  Then: 'secrets', paste appID/installID into agents/coordinator/reviewer-git.yaml, apply it, 'verify'.
EOF
}

cmd_manifest() {
  need jq
  local out="/tmp/gh-reviewer-app-manifest.html" manifest
  # Review-bot grant: write PRs (submit reviews) + contents:WRITE. contents:write is required for the
  # approval to COUNT (GitHub only counts reviews from a reviewer with repo write access — see header).
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"write", pull_requests:"write" },
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
      scripts/github-reviewer-app-bootstrap.sh catch
  then click "Create GitHub App for $ORG" in the browser; it captures the redirect + converts.

  MANUAL fallback: click "Create"; copy the 'code' from the localhost:$REDIRECT_PORT redirect URL
  (page won't load — fine; take ONLY the value after code=, drop any &state=...), then:
      scripts/github-reviewer-app-bootstrap.sh convert XXXX
EOF
}

# Exchange a manifest <code> for App creds. MUST be unauthenticated: the code IS the credential, and
# GitHub 404s this endpoint when a fine-grained PAT is attached (gh api always injects one). Plain curl,
# no Authorization header, is the documented flow. Echoes the JSON on success; dies on non-201.
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
  Then:  scripts/github-reviewer-app-bootstrap.sh secrets
EOF
}

cmd_catch() {
  need jq; need curl; need python3
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  echo "  Now open /tmp/gh-reviewer-app-manifest.html and click \"Create GitHub App for $ORG\"."
  echo "  (If you haven't generated it yet: run 'manifest' first, in another shell.)"
  # Block until the browser redirect hits us; print ONLY the captured code on stdout.
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
            print(code)          # -> captured by the shell
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
  need gh; need jq; need devbox
  local app_id install_id pem
  app_id="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  pem="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$app_id" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$pem" ]    || die "no private key at $pem (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
  install_id="${INSTALL_ID:-$(gh api "/orgs/$ORG/installations" --jq ".installations[] | select(.app_id==($app_id|tonumber)) | .id" 2>/dev/null || true)}"
  [ -n "$install_id" ] || die "installation not found — is the App INSTALLED on $ORG? Or pass INSTALL_ID="
  echo "$install_id" > "$CRED_DIR/installation-id"
  say "Pushing the review App private key into Infisical (homelab/prod)"
  devbox run infisical-secret "REVIEWER_GH_APP_PRIVATE_KEY=$(cat "$pem")"
  say "Done. Paste these NON-secret ids into agents/coordinator/reviewer-git.yaml, then apply it:"
  echo "  appID:     $app_id"
  echo "  installID: $install_id"
  echo "  kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/reviewer-git.yaml"
}

cmd_verify() {
  need devbox
  say "reviewer-git ESO chain (ns agent-coordinator)"
  # Query each kind by its own name — a combined `get es,gat name1 name2` cross-products the
  # names over both kinds and exits non-zero on the (expected) missing combinations.
  devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig -n agent-coordinator get externalsecret reviewer-github-app reviewer-git 2>/dev/null \
    || warn "ExternalSecrets not applied yet (fill appID/installID + kubectl apply -f agents/coordinator/reviewer-git.yaml)"
  devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig -n agent-coordinator get githubaccesstoken reviewer-git-gen 2>/dev/null || true
  devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig -n agent-coordinator get secret reviewer-git 2>/dev/null \
    && echo "  → reviewer-git Secret present (key: GH_TOKEN)" || warn "no reviewer-git Secret yet (check ExternalSecret status)"
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
