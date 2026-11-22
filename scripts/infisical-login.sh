# shellcheck shell=bash
# SOURCED, never run: a per-run USER login to the in-cluster Infisical as the super admin.
# Callers: scripts/infisical-secret.sh, scripts/infisical-harden.sh, tofu/infisical/apply.sh.
# Run from the repo root with `set -euo pipefail`.
#
# Why a login and not a stored token: Infisical >= chart 1.12 rejects exp-less tokens past
# LEGACY_IDENTITY_ACCESS_TOKEN_EXPIRATION_ENFORCED_AT + 90d and caps every machine-identity token
# at MAX_MACHINE_IDENTITY_TOKEN_AGE (90d) — the bootstrap instance-admin token in
# infisical-bootstrap-secret is dead and no stored token is durable (docs/secrets.md).
#
# Creds: wallet `infisical-admin-email` / `infisical-admin-password` (Tier-0), handed to the CLI
# as env — never argv. The CLI is the RESOLVED binary (`devbox run --` re-evaluates argv, `$`
# expands). Its session lives under a run tempdir HOME, removed on exit.
#
# Sets: INF_HOST (http://127.0.0.1:$INF_PORT), INF_TOKEN (session bearer), INF_ORG_ID, KUBECTL,
# CURL, INFISICAL, INF_STAGE. Installs an EXIT trap (port-forward kill + tempdir removal) — a
# caller must not replace it.

INF_PORT="${INF_PORT:-18080}"
INF_SVC=svc/infisical-infisical-standalone-infisical
INF_KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")
INF_HOST="http://127.0.0.1:$INF_PORT"

inf_die() { echo "infisical-login: $*" >&2; exit 1; }

# Wallet: explicit KP_DIR, else jail (~/.claude) or host (~/Projects/.claude-data) — keepass-env.sh's lookup.
INF_KP=""
for d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
  [ -n "$d" ] && [ -f "$d/homelab.kdbx" ] && INF_KP="$d" && break
done
[ -n "$INF_KP" ] || inf_die "KeePass wallet not found — bash scripts/keepass-init.sh"
inf_kp_get() { devbox run --quiet -- keepassxc-cli show -q --no-password -k "$INF_KP/homelab.keyx" -a Password "$INF_KP/homelab.kdbx" "$1" 2>/dev/null; }

# RESOLVED binaries, not `devbox run`: two devbox runs at once (the backgrounded port-forward +
# the readiness loop) race on .devbox/gen/scripts/.cmd.sh and one gets `eval: kubectl: not found`
# (the port-forward died that way on the host, 2026-10-22).
KUBECTL="$(devbox run --quiet -- sh -c 'command -v kubectl')"
CURL="$(devbox run --quiet -- sh -c 'command -v curl')"
INFISICAL="$(devbox run --quiet -- sh -c 'command -v infisical')"
[ -x "$KUBECTL" ] && [ -x "$CURL" ] && [ -x "$INFISICAL" ] || inf_die "could not resolve kubectl/curl/infisical from the devbox env"

# Org = the autoBootstrap org (a user login needs it; the DB is the one reader that has it). Keyed
# on organizations, NOT the homelab project: tofu/infisical creates that project, so a day-1
# rebuild would have no row to read.
INF_PGPOD="$("$KUBECTL" "${INF_KC[@]}" -n infisical get pods -l cnpg.io/cluster=infisical-pg -o jsonpath='{.items[0].metadata.name}')"
INF_ORG_ID="$("$KUBECTL" "${INF_KC[@]}" -n infisical exec "$INF_PGPOD" -c postgres -- \
  psql -U postgres -d infisical -tAc 'select id from organizations order by "createdAt" limit 1;' | tr -d '[:space:]')"
[ -n "$INF_ORG_ID" ] || inf_die "no organization in the Infisical DB — is autoBootstrap done?"

INF_STAGE="$(umask 077; mktemp -d)"
mkdir -m 700 "$INF_STAGE/.home"
INF_PF_LOG="$INF_STAGE/pf.log"
"$KUBECTL" "${INF_KC[@]}" -n infisical port-forward "$INF_SVC" "$INF_PORT:8080" >"$INF_PF_LOG" 2>&1 &
INF_PF=$!
trap 'kill "$INF_PF" 2>/dev/null || true; rm -rf "$INF_STAGE"' EXIT

# BOUNDED wait + liveness check — a wait that cannot fail hangs its caller (2026-08-09).
tries=0
until "$CURL" -sf "$INF_HOST/api/status" >/dev/null 2>&1; do
  kill -0 "$INF_PF" 2>/dev/null || inf_die "port-forward DIED — $(tail -2 "$INF_PF_LOG" 2>/dev/null | tr '\n' ' ')"
  tries=$((tries+1))
  [ "$tries" -ge 30 ] && inf_die "Infisical not reachable through the port-forward after 30s"
  sleep 1
done

INF_ADMIN_EMAIL="$(inf_kp_get infisical-admin-email)" || INF_ADMIN_EMAIL=""
INF_ADMIN_PASSWORD="$(inf_kp_get infisical-admin-password)" || INF_ADMIN_PASSWORD=""
[ -n "$INF_ADMIN_EMAIL" ] && [ -n "$INF_ADMIN_PASSWORD" ] || inf_die "wallet infisical-admin-email/-password unreadable"
INF_TOKEN="$(HOME="$INF_STAGE/.home" INFISICAL_EMAIL="$INF_ADMIN_EMAIL" INFISICAL_PASSWORD="$INF_ADMIN_PASSWORD" \
  INFISICAL_ORGANIZATION_ID="$INF_ORG_ID" "$INFISICAL" login --method=user \
  --domain "$INF_HOST/api" --plain --silent)" || INF_TOKEN=""
unset INF_ADMIN_PASSWORD INF_ADMIN_EMAIL
[ -n "$INF_TOKEN" ] || inf_die "admin login failed (wallet creds stale? Infisical down?)"
