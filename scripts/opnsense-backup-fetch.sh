#!/usr/bin/env bash
# Fetch + decrypt the NEWEST FU-013 OPNsense config backup to <out> (mode 0600).
#
#   bash scripts/opnsense-backup-fetch.sh <out>
#
# Callers: the router rehearsal's identity carry (scripts/opnsense-drill.sh --router) and a
# standing router node's build (scripts/opnsense-router-node.sh) — docs/router-move.md. The
# restore recipe is docs/runbook.md §OPNsense config backup. Garage by port-forward through the API
# server: no dependency on the router's VIPs (the router may be the thing being rebuilt). The age
# identity is the wallet's `opnsense-config-backup-age-identity` (jail only). <out> holds every
# router secret: the caller owns deleting it; nothing here prints a value.
# Env: OPN_BACKUP_KUBECONFIG (default: the repo's tofu/kubeconfig).
# Exit: 0 fetched, 1 failed (nothing left behind but a possibly-empty <out>).
set -euo pipefail
out="${1:?usage: $0 <out>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
k="kubectl --kubeconfig ${OPN_BACKUP_KUBECONFIG:-$ROOT/tofu/kubeconfig}"
port=$((20000 + RANDOM % 20000)); rc=0; pf=''
cleanup() { rm -f "$out.age"; [ -z "$pf" ] || kill "$pf" 2>/dev/null || true; }
trap cleanup EXIT
AWS_ACCESS_KEY_ID="$($k -n opnsense-config-backup get secret opnsense-config-backup-s3 -o jsonpath='{.data.access_key_id}' | base64 -d)"
AWS_SECRET_ACCESS_KEY="$($k -n opnsense-config-backup get secret opnsense-config-backup-s3 -o jsonpath='{.data.secret_access_key}' | base64 -d)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
$k -n garage port-forward svc/garage "$port:3900" >/dev/null 2>&1 & pf=$!
for _ in $(seq 1 40); do timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null && break; sleep 0.5; done
s3="aws --region garage --endpoint-url http://127.0.0.1:$port s3"
obj="$($s3 ls s3://opnsense-config-backup/opnsense-fw/ | awk '{print $4}' | grep '\.xml\.age$' | sort | tail -1 || true)"
[ -n "$obj" ] || { echo "[opnsense-backup-fetch] no backup object found" >&2; exit 1; }
echo "[opnsense-backup-fetch] carry source: opnsense-fw/$obj" >&2
( umask 077
  $s3 cp --quiet "s3://opnsense-config-backup/opnsense-fw/$obj" "$out.age" \
  && keepassxc-cli show -q --no-password -k "$HOME/.claude/homelab-keepass/homelab.keyx" -a Password \
       "$HOME/.claude/homelab-keepass/homelab.kdbx" opnsense-config-backup-age-identity \
     | age -d -i - -o "$out" "$out.age" ) || rc=1
[ "$rc" -eq 0 ] && [ -s "$out" ] || { echo "[opnsense-backup-fetch] fetch/decrypt failed" >&2; exit 1; }
chmod 600 "$out"
