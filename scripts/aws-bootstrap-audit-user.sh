#!/usr/bin/env bash
# Bootstrap a least-privilege READ-ONLY AWS IAM user (homelab-aws-audit) + access key, for the
# Route53/ACM cruft inventory. Saves the key to ~/.claude/homelab-aws/{audit-key,audit-secret}.
# Idempotent. No secrets are committed — they only ever land in ~/.claude/.
#
# Requires an already-AUTHENTICATED AWS session with admin rights (your SSO login). It does NOT
# prompt for or accept static keys — log in first, then run with your profile:
#     aws sso login --profile <p>
#     AWS_PROFILE=<p> bash scripts/aws-bootstrap-audit-user.sh
#
# Saves to ~/.claude/homelab-aws/ by default (the jail path). Running OUTSIDE the jail, point it at
# the host's bind-mounted copy so the jail can read it, e.g.:
#     AWS_PROFILE=<p> HOMELAB_AWS_DIR=$HOME/Projects/.claude-data/homelab-aws bash scripts/aws-bootstrap-audit-user.sh
#
# (This is a one-off bootstrap — the audit user can later be declared in tofu/aws/.)
set -euo pipefail

USER=homelab-aws-audit
POLICY=arn:aws:iam::aws:policy/ReadOnlyAccess
DEST="${HOMELAB_AWS_DIR:-$HOME/.claude/homelab-aws}"

AWS=aws; command -v aws >/dev/null 2>&1 || AWS="$(cd "$(dirname "$0")/.." && pwd)/.devbox/nix/profile/default/bin/aws"

# 1. require an authenticated session — fail with a login hint, never prompt for static keys
if ! "$AWS" sts get-caller-identity >/dev/null 2>&1; then
  echo "Not authenticated to AWS. Log in first, then re-run with your profile:" >&2
  echo "    aws sso login --profile <your-sso-profile>" >&2
  echo "    AWS_PROFILE=<your-sso-profile> bash $0" >&2
  exit 1
fi
echo "Acting as: $("$AWS" sts get-caller-identity --query Arn --output text)"

# 2. create the user (ignore if it already exists) + attach ReadOnlyAccess (idempotent)
"$AWS" iam create-user --user-name "$USER" >/dev/null 2>&1 && echo "created user $USER" || echo "user $USER already exists"
"$AWS" iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY"
echo "attached ReadOnlyAccess"

# 3. mint an access key and save it
read -r K S < <("$AWS" iam create-access-key --user-name "$USER" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
mkdir -p "$DEST"; chmod 700 "$DEST"
printf '%s' "$K" > "$DEST/audit-key"
printf '%s' "$S" > "$DEST/audit-secret"
chmod 600 "$DEST"/audit-*

echo "saved -> $DEST/{audit-key,audit-secret}   (AccessKeyId: $K)"
echo "Done. If you pasted a temporary admin key, DELETE it now (console or: aws iam delete-access-key)."
