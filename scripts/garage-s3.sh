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
CRED="${GARAGE_CRED_DIR:-$HOME/.claude/homelab-garage}"
export AWS_ACCESS_KEY_ID="$(cat "$CRED/browse-key-id")"
export AWS_SECRET_ACCESS_KEY="$(cat "$CRED/browse-secret")"
export AWS_REGION=garage AWS_DEFAULT_REGION=garage
# Garage requires path-style addressing — keep it out of the user's ~/.aws via a dedicated config.
export AWS_CONFIG_FILE="$CRED/aws-config"
[ -f "$AWS_CONFIG_FILE" ] || printf '[default]\ns3 =\n    addressing_style = path\n' > "$AWS_CONFIG_FILE"
exec aws --endpoint-url "${GARAGE_S3_ENDPOINT:-https://s3.teststuff.net}" "$@"
