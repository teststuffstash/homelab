#!/usr/bin/env bash
# Set/update secret(s) in the homelab Infisical project (prod env, path / by default).
# Auth = a per-run super-admin login (scripts/infisical-login.sh — why no stored token works any
# more lives there); reaches Infisical via a short-lived port-forward.
#
#   devbox run infisical-secret API_TOKEN=s3cr3t
#   devbox run infisical-secret KEY1=val1 KEY2=val2
#   printf '%s' "$value" | devbox run infisical-secret KEY=-     # value from stdin, never argv
#   INFISICAL_ENV=staging INFISICAL_PATH=/svc devbox run infisical-secret KEY=val
#
# Then consume it with an ExternalSecret (see argocd/resources/extras/demo-externalsecret.yaml).
#
# Values with `$` (bcrypt/apr1 htpasswd lines) store intact: the CLI is the RESOLVED binary, not
# `devbox run --`, whose generated .cmd.sh re-evaluates its argv (`a$2y$10$x` arrived as `ay0` —
# the 2026-09-02 corruption). Each key is read back and compared before the script exits 0.
# A stdin value (`KEY=-`) loses its trailing newlines, like `$(cat)`. Through the `devbox run
# infisical-secret` TASK, argv is re-evaluated before this script runs — so a `$` value goes on
# stdin there (`KEY=-`), or call `bash scripts/infisical-secret.sh KEY='…'` directly. (The CLI's `KEY=@file` form
# stores the literal string `@file` on CLI 0.44.2 — do not use it.)
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 KEY=VALUE [KEY2=VALUE2 ...]   (env: INFISICAL_ENV=prod INFISICAL_PATH=/)" >&2; exit 2; }
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

# Resolve every value FIRST — before any other command can touch stdin. `KEY=-` = stdin, at most
# once; an empty value is refused before anything is written (an empty pipe must never blank a live secret).
declare -A VAL=()
ARGS=(); used_stdin=0
for kv in "$@"; do
  case "$kv" in *=*) ;; *) echo "infisical-secret: '$kv' is not KEY=VALUE" >&2; exit 2 ;; esac
  k="${kv%%=*}"; v="${kv#*=}"
  if [ "$v" = "-" ]; then
    [ "$used_stdin" = 0 ] || { echo "infisical-secret: $k: only one KEY=- per run (stdin is already read)" >&2; exit 2; }
    used_stdin=1; v="$(cat)"
  fi
  v="${v%$'\n'}"   # argv and stdin alike: no trailing newline (the read-back compares $(…) output)
  [ -n "$v" ] || { echo "infisical-secret: $k: empty value refused" >&2; exit 2; }
  VAL[$k]="$v"; ARGS+=("$k=$v")
done

# The login (wallet creds, resolved binaries, bounded port-forward, session HOME, EXIT trap).
# shellcheck source=scripts/infisical-login.sh
. ./scripts/infisical-login.sh
PROJECT_ID="$("$KUBECTL" "${INF_KC[@]}" -n infisical exec "$INF_PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc "select id from projects where slug='homelab';" | tr -d '[:space:]')"
[ -n "$PROJECT_ID" ] || { echo "infisical-secret: homelab project not found (tofu/infisical not applied?)" >&2; exit 1; }

COMMON=(--projectId "$PROJECT_ID" --domain "$INF_HOST/api"
        --env "${INFISICAL_ENV:-prod}" --path "${INFISICAL_PATH:-/}")
HOME="$INF_STAGE/.home" INFISICAL_TOKEN="$INF_TOKEN" "$INFISICAL" secrets set "${ARGS[@]}" "${COMMON[@]}" >/dev/null

# Read each key back: a stored value that differs from the staged bytes is a failure, never a
# warning (the corruption this script once caused was silent).
bad=0
for k in "${!VAL[@]}"; do
  got="$(HOME="$INF_STAGE/.home" INFISICAL_TOKEN="$INF_TOKEN" "$INFISICAL" secrets get "$k" --plain "${COMMON[@]}" 2>/dev/null)" || got=""
  if [ -n "$got" ] && [ "$got" = "${VAL[$k]}" ]; then
    echo "✓ $k stored and read back identical (${#got} chars)"
  else
    echo "✗ $k: read-back DIFFERS from the value sent" >&2; bad=1
  fi
done
exit "$bad"
