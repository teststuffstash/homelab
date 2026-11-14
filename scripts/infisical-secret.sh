#!/usr/bin/env bash
# Set/update secret(s) in the homelab Infisical project (prod env, path / by default).
# Auth = a per-run USER login as the Infisical super admin, creds from the KeePass wallet
# (`infisical-admin-email` / `-password`, Tier-0), passed to the CLI as env — the session token
# lives only for this run. Reaches Infisical via a short-lived port-forward. The bootstrap
# instance-admin token (infisical-bootstrap-secret) is NOT used: Infisical >= chart 1.12 rejects
# exp-less tokens past LEGACY_IDENTITY_ACCESS_TOKEN_EXPIRATION_ENFORCED_AT + 90d and caps every
# machine-identity token at MAX_MACHINE_IDENTITY_TOKEN_AGE (90d), so no stored token is durable.
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

KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")
SVC=svc/infisical-infisical-standalone-infisical
PORT=18080

# Wallet: explicit KP_DIR, else jail (~/.claude) or host (~/Projects/.claude-data) — keepass-env.sh's lookup.
KP=""
for d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
  [ -n "$d" ] && [ -f "$d/homelab.kdbx" ] && KP="$d" && break
done
[ -n "$KP" ] || { echo "infisical-secret: KeePass wallet not found — bash scripts/keepass-init.sh" >&2; exit 1; }
kp_get() { devbox run --quiet -- keepassxc-cli show -q --no-password -k "$KP/homelab.keyx" -a Password "$KP/homelab.kdbx" "$1" 2>/dev/null; }
ADMIN_EMAIL="$(kp_get infisical-admin-email)"; ADMIN_PASSWORD="$(kp_get infisical-admin-password)"
[ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ] || { echo "infisical-secret: wallet infisical-admin-email/-password unreadable" >&2; exit 1; }
PGPOD="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical get pods -l cnpg.io/cluster=infisical-pg -o jsonpath='{.items[0].metadata.name}')"
PROJECT_ID="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical exec "$PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc "select id from projects where slug='homelab';" | tr -d '[:space:]')"
[ -n "$PROJECT_ID" ] || { echo "homelab project not found" >&2; exit 1; }
ORG_ID="$(devbox run --quiet -- kubectl "${KC[@]}" -n infisical exec "$PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc "select \"orgId\" from projects where slug='homelab';" | tr -d '[:space:]')"
[ -n "$ORG_ID" ] || { echo "homelab project's org not found" >&2; exit 1; }

# The port-forward and the readiness loop call the RESOLVED binaries, not `devbox run`: two devbox
# runs at once (a backgrounded one + the loop) race on `.devbox/gen/scripts/.cmd.sh` and one of them
# gets `eval: kubectl: not found` (exit 127) — the port-forward died that way on the host, 2026-10-22.
KUBECTL="$(devbox run --quiet -- sh -c 'command -v kubectl')"
CURL="$(devbox run --quiet -- sh -c 'command -v curl')"
INFISICAL="$(devbox run --quiet -- sh -c 'command -v infisical')"
[ -x "$KUBECTL" ] && [ -x "$CURL" ] && [ -x "$INFISICAL" ] || { echo "infisical-secret: could not resolve kubectl/curl/infisical from the devbox env" >&2; exit 1; }

# Resolve every value BEFORE anything else reads stdin. `KEY=-` = stdin (once).
STAGE="$(umask 077; mktemp -d)"
declare -A VAL=()
ARGS=()
for kv in "$@"; do
  case "$kv" in *=*) ;; *) echo "infisical-secret: '$kv' is not KEY=VALUE" >&2; rm -rf "$STAGE"; exit 2 ;; esac
  k="${kv%%=*}"; v="${kv#*=}"
  [ "$v" = "-" ] && v="$(cat)"
  VAL[$k]="$v"; ARGS+=("$k=$v")
done
"$KUBECTL" "${KC[@]}" -n infisical port-forward "$SVC" "$PORT:8080" >/tmp/inf-secret-pf.log 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true; rm -rf "$STAGE"' EXIT
mkdir -m 700 "$STAGE/.home"   # the CLI writes its login session under $HOME — keep it in the run's tempdir
# BOUNDED wait + liveness check (2026-08-09): the old bare `until curl` spun FOREVER when the
# Infisical pod restarted mid-store and took the port-forward with it — the token store hung for
# hours inside a tofu apply wrapper whose whole design was "Infisical failures WARN, never
# abort". A wait that cannot fail defeats the caller's degrade path. 30s covers every healthy
# bring-up; a dead forward or a dead pod now exits loudly with the forward's own log.
tries=0
until "$CURL" -sf "http://127.0.0.1:$PORT/api/status" >/dev/null 2>&1; do
  kill -0 "$PF" 2>/dev/null || { echo "infisical-secret: port-forward DIED — $(tail -2 /tmp/inf-secret-pf.log 2>/dev/null | tr '\n' ' ')" >&2; exit 1; }
  tries=$((tries+1))
  [ "$tries" -ge 30 ] && { echo "infisical-secret: Infisical not reachable through the port-forward after 30s — see /tmp/inf-secret-pf.log" >&2; exit 1; }
  sleep 1
done

TOKEN="$(HOME="$STAGE/.home" INFISICAL_EMAIL="$ADMIN_EMAIL" INFISICAL_PASSWORD="$ADMIN_PASSWORD" \
  INFISICAL_ORGANIZATION_ID="$ORG_ID" "$INFISICAL" login --method=user \
  --domain "http://127.0.0.1:$PORT/api" --plain --silent)" || TOKEN=""
unset ADMIN_PASSWORD
[ -n "$TOKEN" ] || { echo "infisical-secret: admin login failed (wallet creds stale? Infisical down?)" >&2; exit 1; }

COMMON=(--projectId "$PROJECT_ID" --domain "http://127.0.0.1:$PORT/api"
        --env "${INFISICAL_ENV:-prod}" --path "${INFISICAL_PATH:-/}")
HOME="$STAGE/.home" INFISICAL_TOKEN="$TOKEN" "$INFISICAL" secrets set "${ARGS[@]}" "${COMMON[@]}" >/dev/null

# Read each key back: a stored value that differs from the staged bytes is a failure, never a
# warning (the corruption this script once caused was silent).
bad=0
for k in "${!VAL[@]}"; do
  got="$(HOME="$STAGE/.home" INFISICAL_TOKEN="$TOKEN" "$INFISICAL" secrets get "$k" --plain "${COMMON[@]}" 2>/dev/null)" || got=""
  if [ -n "$got" ] && [ "$got" = "${VAL[$k]}" ]; then
    echo "✓ $k stored and read back identical (${#got} chars)"
  else
    echo "✗ $k: read-back DIFFERS from the value sent" >&2; bad=1
  fi
done
exit "$bad"
