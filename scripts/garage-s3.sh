#!/usr/bin/env bash
# garage-s3 — the AWS CLI, pre-configured for the homelab Garage S3 with a read-only browse key.
#
#   devbox run garage-s3 s3 ls                                   # list buckets
#   devbox run garage-s3 s3 ls s3://sleep-snore/ --recursive     # list objects
#   devbox run garage-s3 s3 cp s3://sleep-db/sleep.sqlite /tmp/  # download an object
#
# Creds: the read-only `homelab-browse` key in ~/.claude/homelab-garage/ (read on the sleep buckets;
# grant more with `kubectl -n garage exec garage-0 -- /garage bucket allow --read <b> --key homelab-browse`).
# Endpoint defaults to https://s3.teststuff.net (LAN VIP). When that isn't routable (e.g. from the
# jail), port-forward and override: GARAGE_S3_ENDPOINT=http://127.0.0.1:3900.
set -euo pipefail
# Find the browse-key dir. ~/.claude in the jail is bind-mounted to ~/Projects/.claude-data on the
# host, so the path differs by where you run this — try the likely candidates.
# FU-001: creds come from the KeePass wallet (garage-browse-{key-id,secret}); the flat
# homelab-garage/ files are the legacy fallback. aws-config is a non-secret regenerable cache.
CRED=""
for d in "${GARAGE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data" "$PWD/../.claude-data"; do
  [ -n "$d" ] && { [ -f "$d/homelab-keepass/homelab.kdbx" ] || [ -f "$d/homelab-garage/browse-key-id" ] || [ -f "$d/browse-key-id" ]; } && { CRED="$d"; break; }
done
[ -n "$CRED" ] || { echo "ERROR: neither the KeePass wallet nor homelab-garage/browse-key-id found (set GARAGE_CRED_DIR=…)" >&2; exit 1; }
if [ -f "$CRED/homelab-keepass/homelab.kdbx" ]; then
  _kp_get() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli show -q --no-password \
                -k "$CRED/homelab-keepass/homelab.keyx" -a Password "$CRED/homelab-keepass/homelab.kdbx" "$1" 2>/dev/null; }
  export AWS_ACCESS_KEY_ID="$(_kp_get garage-browse-key-id)"
  export AWS_SECRET_ACCESS_KEY="$(_kp_get garage-browse-secret)"
  GARAGE_DIR="$CRED/homelab-garage"
else
  GARAGE_DIR="$CRED/homelab-garage"; [ -f "$GARAGE_DIR/browse-key-id" ] || GARAGE_DIR="$CRED"
  export AWS_ACCESS_KEY_ID="$(cat "$GARAGE_DIR/browse-key-id")"
  export AWS_SECRET_ACCESS_KEY="$(cat "$GARAGE_DIR/browse-secret")"
fi
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || { echo "ERROR: empty garage browse creds (wallet entry missing? run scripts/keepass-init.sh)" >&2; exit 1; }
export AWS_REGION=garage AWS_DEFAULT_REGION=garage
# Garage requires path-style addressing — keep it out of the user's ~/.aws via a dedicated config.
mkdir -p "$GARAGE_DIR" && chmod 700 "$GARAGE_DIR"
export AWS_CONFIG_FILE="$GARAGE_DIR/aws-config"
[ -f "$AWS_CONFIG_FILE" ] || printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"
exec aws --endpoint-url "${GARAGE_S3_ENDPOINT:-https://s3.teststuff.net}" "$@"
