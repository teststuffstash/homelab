#!/usr/bin/env bash
# jail-transcripts-sync — push the jail seat's Claude Code session transcripts (JSONL only) to
# the LAN-only Garage bucket `jail-transcripts` — the jail leg of the §A1 capture contract
# (docs/agents/observability-and-retro.md; bucket + sensitivity rationale:
# agents/coordinator/jail-transcripts-workspace.yaml).
#
#   bash scripts/jail-transcripts-sync.sh              # sync the default project set
#   JAIL_TRANSCRIPTS_PROJECTS="all" bash scripts/...   # every ~/.claude/projects/* slug
#   JAIL_TRANSCRIPTS_PROJECTS="-workspace-homelab -workspace-idp" ...   # explicit set
#
# Run it from the session heartbeat sweep and at wind-down (meta-state.md §Re-arm).
#
# BEST-EFFORT BY DESIGN (ADR-108: the jail must be able to fix the cluster, so nothing in its
# toolchain may REQUIRE the cluster): every failure prints one loud JAIL-TRANSCRIPTS-SYNC line
# and the script exits 0 — the next sweep retries. Creds are read AT SYNC TIME from the
# in-cluster connection Secret via the jail's own kubeconfig — no wallet entry, nothing stored
# jail-side; the push depends on the cluster anyway (Garage lives there), so this adds no new
# dependency class.
#
# SCOPE: default = infra project slugs only. Personal-project transcripts (therapy/life/…)
# stay host-disk-only unless JAIL_TRANSCRIPTS_PROJECTS widens the set — the bucket is
# jail-only-readable, but there is no platform value to weigh against the exposure.
# memory/ and every non-JSONL file never sync (the *.jsonl include is the whole filter).
set -uo pipefail

say() { printf 'JAIL-TRANSCRIPTS-SYNC %s\n' "$*"; }
skip() { say "SKIPPED: $*"; exit 0; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="${JAIL_TRANSCRIPTS_SRC:-$HOME/.claude/projects}"
BUCKET="jail-transcripts"
ENDPOINT="${GARAGE_S3_ENDPOINT:-https://s3.teststuff.net}"
DEFAULT_PROJECTS="-workspace-homelab"

[ -d "$SRC" ] || skip "no transcript dir at $SRC"

# Project set: explicit list > "all" > the infra default.
case "${JAIL_TRANSCRIPTS_PROJECTS:-}" in
  all) PROJECTS="$(ls "$SRC")" ;;
  "")  PROJECTS="$DEFAULT_PROJECTS" ;;
  *)   PROJECTS="$JAIL_TRANSCRIPTS_PROJECTS" ;;
esac

# Tool discovery (board.sh pattern): PATH first, devbox profile as fallback.
KUBECTL="$(command -v kubectl || true)"; [ -n "$KUBECTL" ] || KUBECTL="$ROOT/.devbox/nix/profile/default/bin/kubectl"
AWS="$(command -v aws || true)";         [ -n "$AWS" ]     || AWS="$ROOT/.devbox/nix/profile/default/bin/aws"
[ -x "$KUBECTL" ] || skip "no kubectl (run once from the repo so the devbox profile exists)"
[ -x "$AWS" ] || skip "no aws cli (devbox profile missing)"
KCFG="$ROOT/tofu/kubeconfig"
[ -f "$KCFG" ] || skip "no $KCFG (jail kubeconfig absent)"

# Endpoint reachability — a miss under the egress policy HANGS rather than errors elsewhere in
# this repo; here a 5s bounded probe keeps the sweep snappy. Any HTTP answer (403 incl.) = up.
curl -s -o /dev/null --max-time 5 "$ENDPOINT" || skip "endpoint $ENDPOINT unreachable"

# Creds, read fresh per run. An empty field is a failed probe, never "sync without auth".
sec="$("$KUBECTL" --kubeconfig "$KCFG" -n agent-coordinator get secret jail-transcripts-s3 -o json 2>/dev/null)" || sec=""
[ -n "$sec" ] || skip "connection Secret jail-transcripts-s3 unreadable (workspace not reconciled yet?)"
AWS_ACCESS_KEY_ID="$(printf '%s' "$sec" | jq -r '.data.rw_access_key_id // empty | @base64d')"
AWS_SECRET_ACCESS_KEY="$(printf '%s' "$sec" | jq -r '.data.rw_secret_access_key // empty | @base64d')"
[ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || skip "connection Secret missing rw key fields"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_REGION=garage AWS_DEFAULT_REGION=garage

# Garage needs path-style addressing; keep it out of ~/.aws via a throwaway config.
CFG="$(mktemp)"; trap 'rm -f "$CFG"' EXIT
printf '[default]\ns3 =\n    addressing_style = path\n' > "$CFG"
export AWS_CONFIG_FILE="$CFG"

rc=0; synced=0
for p in $PROJECTS; do
  [ -d "$SRC/$p" ] || { say "no such project dir: $p (skipped)"; continue; }
  if out="$("$AWS" --endpoint-url "$ENDPOINT" s3 sync "$SRC/$p" "s3://$BUCKET/projects/$p" \
        --exclude '*' --include '*.jsonl' --no-progress 2>&1)"; then
    n="$(printf '%s' "$out" | grep -c '^upload:' || true)"
    synced=$((synced + n))
  else
    say "FAILED for $p: $(printf '%s' "$out" | tail -1)"; rc=1
  fi
done
say "done — $synced file(s) uploaded across [$PROJECTS]$([ "$rc" = 1 ] && printf ' (with failures — next sweep retries)')"
exit 0
