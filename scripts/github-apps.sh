#!/usr/bin/env bash
# github-apps.sh — deep-verify report (/tmp): install matrix + declared-vs-live permissions.
# The ALWAYS-CURRENT view is SERVED by the github-exporter at /apps (FU-098) — never committed.
# App installs are CLICK-ONLY (not tofu), so this discovers the live state. Run OUTSIDE the jail.
#
# Auth is two-layer, because a plain admin PAT can list installations but NOT a `selected` install's
# repos (that needs an installation token):
#   • org-admin token (KeePass, via gh-admin-token.sh)  → /orgs/{org}/installations + /repos
#   • per-app INSTALLATION token, minted from the App's private key (JWT), keyed by the installation's
#     app_id → the cred dir's app-id (the same homelab-github-* dirs github-tf.sh resolves). /installation/
#     repositories then lists exactly the selected repos. Apps whose key isn't local show "(no local key)".
set -euo pipefail
ORG="${ORG:-teststuffstash}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/tmp/github-apps.md}" # FU-098 finale: the live view is SERVED (exporter /apps) — this deep-verify report is never committed
API="https://api.github.com"

command -v gh >/dev/null && command -v openssl >/dev/null && command -v jq >/dev/null && command -v curl >/dev/null \
  || { echo "need gh + openssl + jq + curl (devbox run github-apps)"; exit 1; }
ADMIN="$(GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" sh "${HERE}/scripts/gh-admin-token.sh")"
gha() { GH_TOKEN="$ADMIN" gh "$@"; }
gha api "/orgs/${ORG}/installations" >/dev/null 2>&1 || { echo "ERROR: admin token can't read installations (needs admin:org, run outside the jail)"; exit 1; }

mapfile -t REPOS < <(gha api "/orgs/${ORG}/repos" --paginate --jq '.[].name' | sort)

# app_id -> private-key path, from the cred dirs (same roots as github-tf.sh)
declare -A KEY
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for sub in "$d"/homelab-github-*; do
    [ -f "$sub/app-id" ] && [ -f "$sub/private-key.pem" ] || continue
    aid="$(cat "$sub/app-id")"; : "${KEY[$aid]:=$sub/private-key.pem}"
  done
done

b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_jwt() { # $1=app_id $2=keyfile → short-lived RS256 JWT
  local now h p si; now=$(date +%s)
  h="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64)"
  p="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+300))" "$1" | b64)"; si="$h.$p"
  printf '%s.%s' "$si" "$(printf '%s' "$si" | openssl dgst -sha256 -sign "$2" -binary | b64)"
}

declare -A CELL SEL
APPS=()
while IFS=$'\t' read -r id app_id slug selection; do
  [ -n "${slug:-}" ] || continue
  APPS+=("$slug"); SEL["$slug"]="$selection"
  if [ "$selection" = "all" ]; then
    for r in "${REPOS[@]}"; do CELL["$slug|$r"]=1; done; continue
  fi
  if [ -n "${KEY[$app_id]:-}" ]; then
    jwt="$(app_jwt "$app_id" "${KEY[$app_id]}")"
    itok="$(curl -sS -X POST -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
      "${API}/app/installations/${id}/access_tokens" | jq -r '.token // empty')"
    if [ -n "$itok" ]; then
      while read -r r; do [ -n "$r" ] && CELL["$slug|$r"]=1; done < <(
        curl -sS -H "Authorization: Bearer $itok" -H "Accept: application/vnd.github+json" \
          "${API}/installation/repositories?per_page=100" | jq -r '.repositories[].name')
    else SEL["$slug"]="selected · token failed"; fi
  else
    SEL["$slug"]="selected · no local key"
  fi
done < <(gha api "/orgs/${ORG}/installations" --paginate --jq '.installations[] | [.id, .app_id, .app_slug, .repository_selection] | @tsv')

# ── FU-098 verify leg: live permissions (GET /app, App JWT) vs docs/github-apps.yaml ──
# The API can READ App permissions but never WRITE them (UI-only + per-install approval), so
# declared-vs-live drift detection is the honest ceiling. Coverage = apps with a local key;
# the in-cluster github-exporter belt covers agents/reviewer continuously.
DECLARED="${HERE}/docs/github-apps.yaml"
declare -A LIVE DRIFT
DRIFT_FOUND=0
while IFS=$'\t' read -r id app_id slug selection; do
  [ -n "${slug:-}" ] && [ -n "${KEY[$app_id]:-}" ] || continue
  jwt="$(app_jwt "$app_id" "${KEY[$app_id]}")"
  LIVE["$slug"]="$(curl -sS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    "${API}/app" | jq -c '.permissions // {}')"
done < <(gha api "/orgs/${ORG}/installations" --paginate --jq '.installations[] | [.id, .app_id, .app_slug, .repository_selection] | @tsv')

perm_rows() { # render per-app declared-vs-live rows; sets DRIFT_FOUND on any mismatch
  local slug base decl live
  for slug in "${!LIVE[@]}"; do
    base="${slug%-[0-9]*}" # live slugs carry numeric suffixes (homelab-agents-1234)
    decl="$(yq -o=json "$DECLARED" | jq -c --arg s "$base" '.apps[] | select(.slug==$s) |
      ((.permissions // {}) | with_entries(.value = .value.level))' 2>/dev/null)"
    [ -n "$decl" ] || { printf '| `%s` | ⚠ not declared in github-apps.yaml | — |\n' "$slug"; DRIFT_FOUND=1; continue; }
    live="${LIVE[$slug]}"
    # org: prefixed declared keys map to the API's organization_* names
    diff="$(jq -nr --argjson d "$decl" --argjson l "$live" '
      def norm: with_entries(.key |= sub("^org:"; "organization_"));
      ($d|norm) as $D |
      ([($D|keys[]) as $k | select(($l[$k] // "absent") != $D[$k]) | "\($k): declared \($D[$k]) / live \($l[$k] // "absent")"] +
       [($l|keys[]) as $k | select(($D[$k] // "") == "" and $k != "metadata") | "\($k): live \($l[$k]) / UNDECLARED (over-grant?)"]) | join("<br>")')"
    if [ -n "$diff" ]; then
      printf '| `%s` | ⚠ DRIFT | %s |\n' "$slug" "$diff"; DRIFT_FOUND=1
    else
      printf '| `%s` | ✓ in sync | |\n' "$slug"
    fi
  done
}
PERM_SECTION="$(perm_rows)"
# perm_rows runs in a $() subshell — its DRIFT_FOUND can't propagate; derive from the output.
case "$PERM_SECTION" in *"⚠"*) DRIFT_FOUND=1 ;; esac

{
  echo "# GitHub App installations"; echo
  echo "_Generated by \`scripts/github-apps.sh\` on $(date -u +%Y-%m-%d) — click-only (not tofu), regenerate after any install/removal. ✓ = installed. \`selected · no local key\` = the App's private key isn't in a homelab-github-* cred dir here, so its repos couldn't be enumerated (run where the key lives)._"; echo
  printf '| App (scope) |'; for r in "${REPOS[@]}"; do printf ' %s |' "$r"; done; printf '\n'
  printf '%s' '|---|'; for _ in "${REPOS[@]}"; do printf '%s' '---|'; done; printf '\n'
  while read -r a; do
    printf '| `%s` (%s) |' "$a" "${SEL[$a]}"
    for r in "${REPOS[@]}"; do [ -n "${CELL[$a|$r]:-}" ] && printf ' ✓ |' || printf '  |'; done; printf '\n'
  done < <(printf '%s\n' "${APPS[@]}" | sort -u)
  echo
  echo "## Permissions — live vs declared (FU-098)"; echo
  echo "_Declared state: [\`docs/github-apps.yaml\`](github-apps.yaml) (the change-flow source; PR it FIRST, then click). Verified here for apps with a local key; the github-exporter alert watches agents/reviewer continuously. Drift in EITHER direction is flagged — an undeclared live grant is blast radius._"; echo
  echo "| App | Verdict | Drift detail |"
  echo "|---|---|---|"
  [ -n "$PERM_SECTION" ] && printf '%s\n' "$PERM_SECTION" || echo "| _(no local keys — permissions unverifiable from here)_ | | |"
} > "$OUT"
echo "→ wrote ${OUT} (${#APPS[@]} apps × ${#REPOS[@]} repos; permission drift: $([ "$DRIFT_FOUND" = 1 ] && echo YES || echo none)"
[ "${1:-}" = "--lint" ] && [ "$DRIFT_FOUND" = 1 ] && exit 1
exit 0
