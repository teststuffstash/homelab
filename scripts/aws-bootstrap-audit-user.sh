#!/usr/bin/env bash
# Bootstrap a least-privilege READ-ONLY AWS IAM user (homelab-aws-audit) + access key, for the
# Route53/ACM cruft inventory. Saves the key to ~/.claude/homelab-aws/{audit-key,audit-secret}.
# Idempotent. No secrets are committed — they only ever land in ~/.claude/.
#
# Run with ADMIN AWS creds available. Easiest, from the repo root:
#     devbox run -- bash scripts/aws-bootstrap-audit-user.sh
# If no admin creds are configured, it PROMPTS for a temporary admin access key (create one for
# your admin user in the console, paste the two values at the prompts, then DELETE it afterwards).
#
# (This is a one-off bootstrap — the audit user can later be declared in tofu/aws/.)
set -euo pipefail

USER=homelab-aws-audit
POLICY=arn:aws:iam::aws:policy/ReadOnlyAccess
DEST="$HOME/.claude/homelab-aws"

AWS=aws; command -v aws >/dev/null 2>&1 || AWS="$(cd "$(dirname "$0")/.." && pwd)/.devbox/nix/profile/default/bin/aws"

# 1. ensure working admin creds (prompt for a temp key if none)
if ! "$AWS" sts get-caller-identity >/dev/null 2>&1; then
  echo "No working AWS creds found — paste a TEMPORARY admin access key (delete it after):"
  read -rp  "  AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID
  read -rsp "  AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY; echo
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  "$AWS" sts get-caller-identity >/dev/null
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
