#!/usr/bin/env bash
# github-reviewer-app-bootstrap.sh — bootstrap the "homelab-reviewer" GitHub App: the review bot's
# identity for the agentic merge gate (agents/reviewer-session.sh, docs/agents/workflow.md).
#
# Why a SEPARATE App (not reuse homelab-agents): GitHub blocks self-approval. The worker opens the PR
# as homelab-agents[bot]; a native `gh pr review --approve` from that same bot fails ("Can not approve
# your own pull request"). So the reviewer needs a DISTINCT identity — this App → homelab-reviewer[bot].
# It's also strictly smaller: pull_requests:write + contents:read only (NO merge/contents:write —
# GitHub auto-merge does the merge once the approval + CI land).
#
# Sibling of scripts/github-agents-app-bootstrap.sh, same shape: automate everything GitHub has an API
# for; the browser is reduced to two clicks it can't mint — one Create (App-manifest REST flow) and one
# Install (pick the agent repos). Delivery target differs: one Infisical key, consumed by ONE ESO
# generator (agents/coordinator/reviewer-git.yaml) → the `reviewer-git` Secret the reviewer pod mounts.
#
# Subcommands:  check | manifest | convert <code> | secrets | verify
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
  # Minimal review-bot grant: read code (clone) + write PRs (submit reviews / request-changes). No more.
  manifest=$(jq -nc --arg n "$APP_NAME" --arg url "https://github.com/$ORG" \
    --arg redir "http://localhost:$REDIRECT_PORT/callback" '{
      name:$n, url:$url, redirect_url:$redir, public:false,
      default_permissions:{ metadata:"read", contents:"read", pull_requests:"write" },
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
  Click "Create"; copy the 'code' from the redirect URL (the page won't load — fine), then:
      scripts/github-reviewer-app-bootstrap.sh convert XXXX
EOF
}

cmd_convert() {
  need gh; need jq
  local code="${1:?usage: convert <code-from-redirect-url>}" resp
  mkdir -p "$CRED_DIR"; chmod 700 "$CRED_DIR"
  say "Exchanging manifest code for App credentials (POST /app-manifests/$code/conversions)"
  resp=$(gh api -X POST "/app-manifests/$code/conversions") \
    || die "conversion failed (code expired? it's one-shot + ~1h TTL — re-run 'manifest')"
  echo "$resp" | jq -r '.id'  > "$CRED_DIR/app-id"
  echo "$resp" | jq -r '.pem' > "$CRED_DIR/private-key.pem"
  echo "$resp" | jq -r '.slug' > "$CRED_DIR/slug"
  chmod 600 "$CRED_DIR"/*
  say "Saved App id=$(cat "$CRED_DIR/app-id") + private key to $CRED_DIR"
  cat <<EOF
  NEXT (one Install click): install on the SAME repos as the worker ($REPOS) —
      https://github.com/organizations/$ORG/settings/apps/$(echo "$resp" | jq -r .slug)/installations
  Then:  scripts/github-reviewer-app-bootstrap.sh secrets
EOF
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
  devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig -n agent-coordinator get externalsecret,githubaccesstoken reviewer-git reviewer-git-gen 2>/dev/null \
    || warn "not applied yet (fill appID/installID + kubectl apply -f agents/coordinator/reviewer-git.yaml)"
  devbox run --quiet -- kubectl --kubeconfig tofu/kubeconfig -n agent-coordinator get secret reviewer-git 2>/dev/null \
    && echo "  → reviewer-git Secret present (key: GH_TOKEN)" || warn "no reviewer-git Secret yet (check ExternalSecret status)"
}

case "${1:-check}" in
  check)    cmd_check ;;
  manifest) cmd_manifest ;;
  convert)  shift; cmd_convert "$@" ;;
  secrets)  cmd_secrets ;;
  verify)   cmd_verify ;;
  *) die "unknown subcommand '$1' (check|manifest|convert|secrets|verify)" ;;
esac
