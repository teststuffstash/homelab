#!/usr/bin/env bash
# github-app-bootstrap.sh — the SINGLE App-creation entrypoint (FU-098): the manifest is built
# FROM docs/github-apps.yaml (the declared state), so a created App can never diverge from the
# declaration. Replaces the creation halves of the six per-App scripts.
#
#   scripts/github-app-bootstrap.sh <slug> check|manifest|catch|convert <code>|secrets|verify
#
# check/manifest/catch/convert are fully generic (this file). secrets/verify stay app-specific
# plumbing (Infisical keys vs org Actions secrets vs paste-into-yaml) and DELEGATE to the app's
# legacy script (yaml `bootstrap.legacy`) until each is individually ported — the legacy
# scripts' own creation subcommands are retired stubs pointing back here.
#
# The two clicks GitHub reserves for the browser stay: one Create (manifest flow), one Install.
set -euo pipefail
cd "$(dirname "$0")/.."
export GH_PAGER=cat

SLUG="${1:?usage: github-app-bootstrap.sh <slug> <check|manifest|catch|convert|secrets|verify> — slugs: $(yq -r '.apps[].slug' docs/github-apps.yaml 2>/dev/null | tr '\n' ' ')}"
shift || true
ORG="${ORG:-teststuffstash}"
DECLARED=docs/github-apps.yaml

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 (run under devbox)"; }
need yq; need jq

app_json="$(yq -o=json "$DECLARED" | jq --arg s "$SLUG" '.apps[] | select(.slug==$s)')"
[ -n "$app_json" ] || die "slug '$SLUG' not declared in $DECLARED"
CRED_DIR="$(echo "$app_json" | jq -r '.bootstrap.cred_dir // ("~/.claude/homelab-github-" + (.slug | sub("^homelab-";"")))')"
CRED_DIR="${CRED_DIR/#\~/$HOME}"
REDIRECT_PORT="$(echo "$app_json" | jq -r '.bootstrap.redirect_port // 8766')"
LEGACY="$(echo "$app_json" | jq -r '.bootstrap.legacy // empty')"
INSTALLS="$(echo "$app_json" | jq -r '.installs // "selected"')"
# declared permissions → the manifest's default_permissions (org: prefix → organization_*)
PERMS_JSON="$(echo "$app_json" | jq '(.permissions // {}) | with_entries({key: (.key | sub("^org:"; "organization_")), value: .value.level})')"

cmd_check() {
  say "Declared state for $SLUG ($DECLARED)"
  echo "$app_json" | jq '{slug, app_id, installs, permissions: (.permissions | with_entries(.value = .value.level)), absent: (.absent // {} | keys)}'
  say "What still needs the browser"
  cat <<EOF
  1. Create the App   -> 'manifest' then 'catch' (or 'convert <code>') — one Create click.
  2. Install the App  -> one Install click; repository access: $INSTALLS.
  Then: 'secrets' (app-specific wiring${LEGACY:+ — delegates to scripts/$LEGACY}), 'verify'.
EOF
}

cmd_manifest() {
  local out="/tmp/gh-${SLUG}-manifest.html" manifest
  manifest=$(jq -nc --arg n "$SLUG" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" --argjson perms "$PERMS_JSON" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:$perms, default_events:[] }')
  cat > "$out" <<HTML
<!doctype html><meta charset=utf-8><title>Create $SLUG GitHub App</title>
<body onload="document.forms[0].submit()">
<p>Submitting App manifest to GitHub… if nothing happens, click the button.</p>
<form action="https://github.com/organizations/$ORG/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value='$manifest'>
  <button type="submit">Create the '$SLUG' App on $ORG</button>
</form></body>
HTML
  say "Wrote $out (permissions FROM $DECLARED — never edit them here)"
  cat <<EOF
  Open it in a browser logged in as a $ORG owner (xdg-open $out).
  ROBUST: in another shell run 'scripts/github-app-bootstrap.sh $SLUG catch' first, then click Create.
  MANUAL: click Create, copy the code= from the localhost:$REDIRECT_PORT redirect, then
      scripts/github-app-bootstrap.sh $SLUG convert XXXX
EOF
}

# The code IS the credential; this endpoint must be UNAUTHENTICATED (gh api attaches a token → 404).
_convert_code() {
  need curl
  local code="$1" http body
  body=$(curl -sS -o /dev/stdout -w '\n%{http_code}' -X POST \
           -H "Accept: application/vnd.github+json" \
           "https://api.github.com/app-manifests/$code/conversions")
  http=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$http" = "201" ] || die "conversion failed (HTTP $http): $(echo "$body" | jq -r '.message // .' 2>/dev/null || echo "$body")"
  echo "$body"
}

_save_conversion() {
  local resp="$1"
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  echo "$resp" | jq -r '.id'   > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem'  > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  NEXT (one Install click; repository access: $INSTALLS):
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  Then fill app_id/install_id for $SLUG in $DECLARED, and run:
      scripts/github-app-bootstrap.sh $SLUG secrets
EOF
}

cmd_catch() {
  need python3; need curl
  say "Listening on http://localhost:$REDIRECT_PORT for GitHub's manifest redirect"
  local code
  code=$(REDIRECT_PORT="$REDIRECT_PORT" python3 - <<'PY'
import http.server, urllib.parse, os, sys
port = int(os.environ["REDIRECT_PORT"])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("code", [None])[0]
        body = b"Got it \xe2\x80\x94 close this tab; return to the terminal." if code else b"No 'code' in redirect."
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
  _save_conversion "$(_convert_code "$code")"
}

# ── secrets: generic scaffold (cred-dir reads + install-id resolve) + per-slug pushes ──
# All six flows ported from the legacy per-App scripts 2026-07-26 (FU-098 completion): the
# variation is WHICH Infisical/Actions secrets each app feeds and what gets pasted where.
_load_creds() {
  APP_ID="${APP_ID:-$(cat "$CRED_DIR/app-id" 2>/dev/null || true)}"
  PEM="${APP_PRIVATE_KEY_FILE:-$CRED_DIR/private-key.pem}"
  [ -n "$APP_ID" ] || die "no App id (run 'convert' or pass APP_ID=)"
  [ -f "$PEM" ]    || die "no private key at $PEM (run 'convert' or pass APP_PRIVATE_KEY_FILE=)"
}
_resolve_install_id() { # needs gh with org read; writes CRED_DIR/installation-id
  INSTALL_ID="${INSTALL_ID:-$(gh api "/orgs/$ORG/installations" --jq ".installations[] | select(.app_id==($APP_ID|tonumber)) | .id" 2>/dev/null || true)}"
  [ -n "$INSTALL_ID" ] || die "installation not found — is the App INSTALLED on $ORG? Or pass INSTALL_ID="
  echo "$INSTALL_ID" > "$CRED_DIR/installation-id"
}

cmd_secrets() {
  need devbox; _load_creds
  case "$SLUG" in
    homelab-agents)
      need gh; _resolve_install_id
      say "Pushing the App private key into Infisical (homelab/prod)"
      # Infisical CLI escapes the PEM newlines; ESO un-escapes (template replace) — ARC pattern.
      devbox run infisical-secret "AGENTS_GH_APP_PRIVATE_KEY=$(cat "$PEM")"
      say "Wire the generators (non-secret ids): appID=$APP_ID installID=$INSTALL_ID"
      echo "  → agents/coordinator/git-token.yaml + the agentstack composition constants" ;;
    homelab-reviewer)
      need gh; _resolve_install_id
      say "Pushing the review App private key into Infisical (homelab/prod)"
      devbox run infisical-secret "REVIEWER_GH_APP_PRIVATE_KEY=$(cat "$PEM")"
      say "Paste appID=$APP_ID installID=$INSTALL_ID into agents/coordinator/reviewer-git.yaml, then apply it" ;;
    homelab-merge)
      # No install-id: the updater's create-github-app-token resolves it from app-id+key+repo.
      say "Pushing the merge App private key into Infisical (homelab/prod) — source of truth"
      devbox run infisical-secret "MERGE_GH_APP_PRIVATE_KEY=$(cat "$PEM")"
      echo "  Then publish the org Actions secrets:  devbox run github-tofu apply   (reads $CRED_DIR)" ;;
    homelab-renovate)
      say "Pushing the renovate App private key into Infisical (homelab/prod)"
      devbox run infisical-secret "RENOVATE_GH_APP_PRIVATE_KEY=$(cat "$PEM")"
      echo "  Then publish the Actions secrets:  devbox run github-tofu apply   (RENOVATE_APP_*)" ;;
    homelab-deploy)
      say "Pushing the deploy App private key into Infisical (homelab/prod) — source of truth"
      devbox run infisical-secret "DEPLOY_GH_APP_PRIVATE_KEY=$(cat "$PEM")"
      echo "  Then:  devbox run github-tofu apply   (DEPLOY_APP_* secrets + the bypass_actors)" ;;
    homelab-labels)
      need gh; need awk; _resolve_install_id
      # provider-upjet-github wants the PEM \n-ESCAPED as one line — escape ONCE at mint time.
      local pem_escaped; pem_escaped=$(awk 'NR>1{printf "\\n"} {printf "%s", $0}' "$PEM")
      say "Pushing the labels App credentials into Infisical (homelab/prod)"
      devbox run infisical-secret "LABELS_GH_APP_ID=$APP_ID" >/dev/null
      devbox run infisical-secret "LABELS_GH_APP_INSTALLATION_ID=$INSTALL_ID" >/dev/null
      devbox run infisical-secret "LABELS_GH_APP_PRIVATE_KEY=$pem_escaped" >/dev/null
      echo "  ESO materializes github-labels-provider-creds (crossplane-system) on its refresh" ;;
    *) die "no secrets flow for $SLUG (runner apps ride scripts/github-runner-bootstrap.sh)" ;;
  esac
}

cmd_verify() {
  local KC="devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig"
  case "$SLUG" in
    homelab-agents)
      need devbox
      say "Central worker-token chain (FU-089: agent-coordinator ns)"
      $KC -n agent-coordinator get secret agents-github-app 2>/dev/null || warn "key Secret missing (secrets + git-token.yaml applied?)"
      $KC -n agent-coordinator get secret 2>/dev/null | grep -E "^agent-git-" || warn "no central agent-git-<repo> secrets (composition rendered? ESO synced?)" ;;
    homelab-reviewer)
      need devbox
      say "reviewer-git ESO chain (ns agent-coordinator)"
      $KC -n agent-coordinator get externalsecret reviewer-github-app reviewer-git 2>/dev/null || warn "ExternalSecrets not applied (reviewer-git.yaml)"
      $KC -n agent-coordinator get secret reviewer-git 2>/dev/null && echo "  → reviewer-git Secret present" || warn "no reviewer-git Secret yet" ;;
    homelab-merge)
      need gh
      # The one END-TO-END signal: a green updater run needs install + secrets + perms at once.
      say "Updater workflow per repo (green ⇒ installed + secrets + permissions all correct)"
      for r in $(yq -r '.apps[] | select(.slug=="homelab-merge") | .bootstrap.verify_repos[]?' "$DECLARED" 2>/dev/null); do
        line="$(gh run list --repo "$ORG/$r" --workflow update-pr-branch.yml --limit 1 --json conclusion,createdAt --jq '.[0] | "\(.conclusion) \(.createdAt)"' 2>/dev/null || true)"
        case "$line" in success*) echo "  $r: ✅ $line";; "") warn "  $r: no updater run yet";; *) warn "  $r: ❌ $line";; esac
      done ;;
    homelab-renovate)
      need gh
      say "Renovate runner — last run"
      gh run list --repo "$ORG/homelab" --workflow renovate.yaml --limit 1 --json conclusion,createdAt --jq '.[0] | "  \(.conclusion)  \(.createdAt)"' 2>/dev/null || warn "no renovate run yet" ;;
    homelab-deploy)
      need gh
      say "Deploy-pin flow — newest deploy-authored PR per target"
      for r in $(yq -r '.apps[] | select(.slug=="homelab-deploy") | .bootstrap.verify_repos[]?' "$DECLARED" 2>/dev/null); do
        gh pr list --repo "$ORG/$r" --author "app/homelab-deploy" --state all --limit 1 --json number,state,title --jq ".[0] | \"  $r: #\(.number) \(.state) \(.title)\"" 2>/dev/null || echo "  $r: none yet"
      done ;;
    homelab-labels)
      need devbox
      say "provider-upjet-github + credentials chain"
      $KC get provider.pkg provider-upjet-github 2>/dev/null || warn "Provider not installed"
      $KC -n crossplane-system get secret github-labels-provider-creds 2>/dev/null && echo "  → creds Secret present" || warn "no creds Secret (run 'secrets')"
      $KC get issuelabels 2>/dev/null || echo "  (no claim carries a labels: block yet)" ;;
    *) die "no verify flow for $SLUG" ;;
  esac
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  catch)    cmd_catch ;;
  convert)  shift; _save_conversion "$(_convert_code "${1:?usage: convert <code>}")" ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|catch|convert|secrets|verify)" ;;
esac
