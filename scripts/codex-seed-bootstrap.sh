#!/usr/bin/env bash
# codex-seed-bootstrap.sh — enrol the gateway's OWN ChatGPT/Codex login as the codex rail's seed
# (FU-270 leg E; docs/spikes/codex-subscription-rail.md §Lighting the rail; runbook §Secrets).
#
# What it produces: Infisical key CODEX_SEED_RECORD (homelab/prod, path /) holding the 4-field
# JSON record the gateway's SqliteStore imports (gateway/src/agent_gateway/sqlite_oauth.py):
#   {"access_token": …, "account_id": …, "expires_at": <access JWT exp, unix s>, "refresh_token": …}
# ESO materializes it as Secret agent-egress/codex-seed (key `record`, argocd/resources/agent-gateway/
# codex-seed.yaml); the gateway reads it at CODEX_SEED_FILE and imports it ONCE per content hash —
# rotations then live in GATEWAY_DB. Infisical holds the SEED ONLY, never a write-back; re-running
# this script with a fresh login IS the recovery operation for a lost rotation.
#
# Rulings this script encodes (operator, 2026-10-19):
#   * the gateway gets its OWN login — NEVER the homelab-codex jail's auth.json (native refresh rotates
#     with reuse detection: two refreshers on one token set revoke each other). The login happens in a
#     THROWAWAY CODEX_HOME that is shredded before this script exits.
#   * the browser consent is the third-party-console class (docs/secrets.md §Minting doctrine): the
#     device-auth URL + code are the only manual step; transfer and cleanup are this code.
#   * id_token and last_refresh are dropped on purpose — the record is exactly the Credential fields.
#
# Subcommands:  login | store | verify | all (default: login + store)
#   login   codex login --device-auth in a throwaway home → the record file (0600) → shred the home;
#           probes GET /backend-api/wham/usage with the new token (structure only — no values printed)
#   store   record file → Infisical → force-sync the ExternalSecret → read the k8s Secret back and
#           compare hashes (the `$`-expansion corruption class, infisical-secret.sh header) → shred
#   verify  print the cluster Secret's structure (names, expiry, lengths; never a token value) and
#           compare it to the record file if one exists
# Env (defaults): CODEX_BIN (codex on PATH, else the newest /nix/store/*-codex-*/bin/codex)
#                 CODEX_SEED_RECORD_FILE=$HOME/.cache/codex-seed/record.json
#                 INFISICAL_KEY=CODEX_SEED_RECORD  PROBE=1 (0 skips the usage probe)  KEEP_RECORD=0
set -euo pipefail
cd "$(dirname "$0")/.."
export NIX_CONFIG="experimental-features = nix-command flakes" DEVBOX_QUIET=1

INFISICAL_KEY="${INFISICAL_KEY:-CODEX_SEED_RECORD}"
RECORD="${CODEX_SEED_RECORD_FILE:-$HOME/.cache/codex-seed/record.json}"
NS=agent-egress
ES=codex-seed
USAGE_URL="${CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"
KC=(--kubeconfig "${KUBECONFIG:-$PWD/tofu/kubeconfig}")

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
kc()   { devbox run --quiet -- kubectl "${KC[@]}" "$@"; }

wipe() {  # shred then remove a file; never leaves a credential on disk by accident
  [ -e "$1" ] || return 0
  shred -u "$1" 2>/dev/null || rm -f "$1"
}

resolve_codex() {
  if [ -n "${CODEX_BIN:-}" ]; then [ -x "$CODEX_BIN" ] || die "CODEX_BIN=$CODEX_BIN is not executable"; echo "$CODEX_BIN"; return; fi
  if command -v codex >/dev/null 2>&1; then command -v codex; return; fi
  local nix; nix="$(ls -d /nix/store/*-codex-*/bin/codex 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$nix" ] && { echo "$nix"; return; }
  die "no codex CLI: set CODEX_BIN, or run this in a jail that has one (homelab-codex: npm @openai/codex)"
}

# auth.json → record file. Python (stdlib only, -I) because the access JWT's exp claim is base64url.
# Prints a one-line summary with the account id masked; token values never reach stdout.
build_record() {  # $1 auth.json  $2 record out
  python3 -I - "$1" "$2" <<'PY'
import base64, json, os, sys, time
auth_path, out = sys.argv[1], sys.argv[2]
with open(auth_path, "rb") as f:
    auth = json.load(f)
if auth.get("auth_mode") != "chatgpt":
    sys.exit(f"auth_mode is {auth.get('auth_mode')!r}, expected 'chatgpt' (API-key logins are not a subscription rail)")
tokens = auth.get("tokens") or {}
access, refresh = tokens.get("access_token"), tokens.get("refresh_token")
if not access or not refresh:
    sys.exit("auth.json has no access_token/refresh_token — the device login did not complete")
parts = access.split(".")
if len(parts) != 3:
    sys.exit("access_token is not a JWT (3 parts expected)")
claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
exp = claims.get("exp")
if not isinstance(exp, (int, float)):
    sys.exit("access JWT carries no numeric exp claim")
account = tokens.get("account_id") or claims.get("https://api.openai.com/auth", {}).get("chatgpt_account_id")
if not account:
    sys.exit("no account id: neither tokens.account_id nor the JWT's chatgpt_account_id claim")
for name, value in (("access_token", access), ("refresh_token", refresh), ("account_id", account)):
    if not isinstance(value, str) or any(c in value for c in "\r\n"):
        sys.exit(f"{name} is not a single-line string")
    if "$" in value:  # infisical-secret.sh header: `$` is shell-expanded in transit and stored corrupted
        sys.exit(f"{name} contains '$' — it would be corrupted on the way to Infisical; store via the Infisical UI instead")
record = {"access_token": access, "account_id": account, "expires_at": exp, "refresh_token": refresh}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(record, f, separators=(",", ":"), sort_keys=True)
plan = claims.get("https://api.openai.com/auth", {}).get("chatgpt_plan_type", "?")
left = (exp - time.time()) / 3600
print(f"record: account …{account[-6:]}  plan={plan}  access expires {time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(exp))} "
      f"({left:.1f} h from now)  access_token {len(access)} chars  refresh_token {len(refresh)} chars")
if left <= 0:
    sys.exit("the access token is already expired — the gateway would have to refresh before its first use; seed from a fresh login instead")
PY
}

# One GET against the account usage endpoint with the new token. Prints status + the payload's
# field/type STRUCTURE (the spike's first real observation of this endpoint — GW-CODEX-HEADROOM
# marks it unverified) and nothing else: no values, no headers. Reads no quota, rotates nothing.
probe_usage() {  # $1 record file
  need curl; need python3
  local body status access account
  body="$(mktemp)"
  { read -r access; read -r account; } < <(python3 -I - "$1" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(r["access_token"]); print(r["account_id"])
PY
)
  status="$(curl -sS -o "$body" -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $access" -H "ChatGPT-Account-ID: $account" -H 'Accept: application/json' \
    "$USAGE_URL" || echo 000)"
  unset access
  case "$status" in
    200) say "usage probe: 200 — the token authenticates. Payload structure (types only):"
         python3 -I - "$body" <<'PY' || warn "usage payload is not JSON"
import json, sys
def shape(v, indent=2):
    pad = " " * indent
    if isinstance(v, dict):
        for k in sorted(v):
            t = type(v[k]).__name__
            print(f"{pad}{k}: {t}" if not isinstance(v[k], (dict, list)) else f"{pad}{k}:")
            shape(v[k], indent + 2)
    elif isinstance(v, list):
        print(f"{pad}[{len(v)} items]")
        if v: shape(v[0], indent + 2)
shape(json.load(open(sys.argv[1])))
PY
         ;;
    401) die "usage probe: 401 — the new token is rejected; do not store it" ;;
    000) warn "usage probe: no answer from $USAGE_URL (network) — continuing; the record is still valid locally" ;;
    *)   warn "usage probe: HTTP $status — unverified endpoint (source-derived path); continuing. Record the status in the spike." ;;
  esac
  rm -f "$body"
}

cmd_login() {
  need python3; need shred
  local codex home
  codex="$(resolve_codex)"
  say "codex CLI: $codex ($("$codex" --version 2>/dev/null || echo 'version unknown'))"
  mkdir -p "$(dirname "$RECORD")"; chmod 700 "$(dirname "$RECORD")"
  home="$(mktemp -d "$(dirname "$RECORD")/home.XXXXXX")"
  chmod 700 "$home"
  # shellcheck disable=SC2064  # expand $home now; the trap must survive `set -u` surprises later
  trap "find '$home' -type f -exec shred -u {} + 2>/dev/null; rm -rf '$home'" EXIT
  cat <<EOF

  This logs in the GATEWAY's account session — a SECOND device login, separate from the
  homelab-codex jail's. Open the URL codex prints in YOUR browser and enter the code
  (third-party-console step). Whether this login invalidates the jail's one is UNVERIFIED
  (spike §Canary preparation evidence): after storing, keep an eye on the jail's codex for
  a re-login prompt over the next days and record what you see in the spike.

EOF
  CODEX_HOME="$home" "$codex" login --device-auth
  [ -s "$home/auth.json" ] || die "no $home/auth.json after login"
  build_record "$home/auth.json" "$RECORD"
  say "record written: $RECORD (0600) — the throwaway CODEX_HOME is shredded on exit"
  [ "${PROBE:-1}" = 0 ] || probe_usage "$RECORD"
}

cmd_store() {
  need devbox; need sha256sum
  [ -s "$RECORD" ] || die "no record file at $RECORD — run 'login' first (or point CODEX_SEED_RECORD_FILE at one)"
  python3 -I - "$RECORD" <<'PY' || exit 1
import json, sys, time
r = json.load(open(sys.argv[1]))
if sorted(r) != ["access_token", "account_id", "expires_at", "refresh_token"]:
    sys.exit(f"record keys are {sorted(r)} — the gateway accepts exactly the four Credential fields")
if r["expires_at"] <= time.time():
    sys.exit("record's access token is expired — seed from a fresh login (the gateway would refresh before first use; don't start a rail on a refresh)")
if any("$" in r[k] for k in ("access_token", "account_id", "refresh_token")):
    sys.exit("record contains '$' — see scripts/infisical-secret.sh header")
PY
  local want have
  want="$(sha256sum < "$RECORD" | cut -c1-64)"
  say "Infisical (homelab/prod) ← $INFISICAL_KEY  (sha256 $want)"
  bash scripts/infisical-secret.sh "$INFISICAL_KEY=$(cat "$RECORD")"
  say "ESO: force-sync ExternalSecret $NS/$ES (its refreshInterval is 1h)"
  kc -n "$NS" annotate externalsecret "$ES" force-sync="$(date +%s)" --overwrite >/dev/null
  local tries=0 empty; empty="$(printf '' | sha256sum | cut -c1-64)"
  until have="$(kc -n "$NS" get secret "$ES" -o jsonpath='{.data.record}' 2>/dev/null | base64 -d | sha256sum | cut -c1-64)" \
        && [ "$have" != "$empty" ]; do
    tries=$((tries+1)); [ "$tries" -ge 30 ] && die "Secret $NS/$ES has no 'record' key after 60s — kubectl -n $NS describe externalsecret $ES"
    sleep 2
  done
  if [ "$have" != "$want" ]; then
    die "READBACK MISMATCH: Secret $NS/$ES record sha256 $have ≠ local $want — the value was altered in transit (the \$-expansion class, scripts/infisical-secret.sh header). Fix the value via the Infisical UI, then 'verify'."
  fi
  say "verified: Secret $NS/$ES record == local record (sha256 $want)"
  if [ "${KEEP_RECORD:-0}" = 1 ]; then warn "KEEP_RECORD=1 — $RECORD kept on disk (a full refreshable credential; shred it yourself)"
  else wipe "$RECORD"; say "local record shredded"; fi
  cat <<EOF

Done. The gateway imports this seed ONCE (SHA-256-gated) on the codex rail's first use and
owns rotation from then on in GATEWAY_DB. Nothing to restart now: the deployed policy still omits
the codex rail — the policy block is the next FU-270 step after this one. A LATER re-run of this
script (a fresh login → a changed hash) is the lost-rotation recovery operation.
Watch: does the homelab-codex jail's login survive this second device login? Record it in
docs/spikes/codex-subscription-rail.md (unverified as of 2026-10-19).
EOF
}

cmd_verify() {
  need devbox; need python3
  local tmp; tmp="$(mktemp)"
  kc -n "$NS" get secret "$ES" -o jsonpath='{.data.record}' 2>/dev/null | base64 -d > "$tmp" || true
  [ -s "$tmp" ] || { rm -f "$tmp"; die "Secret $NS/$ES has no record — ESO found no $INFISICAL_KEY in Infisical (run 'store')"; }
  python3 -I - "$tmp" <<'PY'
import hashlib, json, sys, time
raw = open(sys.argv[1], "rb").read()
r = json.loads(raw)
exp = r.get("expires_at", 0)
print(f"  keys       : {sorted(r)}")
print(f"  account    : …{str(r.get('account_id',''))[-6:]}")
print(f"  expires_at : {time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(exp))}  ({(exp - time.time())/3600:+.1f} h)")
print(f"  lengths    : access {len(r.get('access_token',''))}  refresh {len(r.get('refresh_token',''))}")
print(f"  sha256     : {hashlib.sha256(raw).hexdigest()}")
PY
  if [ -s "$RECORD" ]; then
    if [ "$(sha256sum < "$RECORD" | cut -c1-64)" = "$(sha256sum < "$tmp" | cut -c1-64)" ]; then say "cluster Secret == $RECORD"
    else warn "cluster Secret ≠ $RECORD (a stale local file, or a corrupted store)"; fi
  fi
  wipe "$tmp"
  echo "  (the access token expiring is expected after import — the gateway rotates in GATEWAY_DB; the seed is only re-read on a hash change)"
}

case "${1:-all}" in
  login)  cmd_login ;;
  store)  cmd_store ;;
  verify) cmd_verify ;;
  all)    cmd_login; cmd_store ;;
  *) sed -n '2,32p' "$0"; exit 2 ;;
esac
