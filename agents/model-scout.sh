#!/usr/bin/env bash
# model-scout — the weekly REPORT-ONLY model-discovery reflex (FU-062, docs/agents/model-routing.md
# §M7). Sibling of review-reflex/ledger-reflex: deterministic, costs no LLM turn, runs on a CronJob
# in ns agent-coordinator (agents/coordinator/model-scout.yaml — deployed `suspend: true` until the
# first supervised run).
#
# Each tick, LEVEL-TRIGGERED against two sources of truth (the live catalog + one snapshot file):
#   1. fetch the current OpenRouter /models catalog
#   2. diff its ids against the previous tick's snapshot
#      (s3://<bucket>/_model-scout/known-models.json — scout state lives next to the ledger)
#   3. NEW + tool-capable + (`:free` or headline ≤ $PRICE_CEILING/M) models get enriched via
#      estimate_budget.py --lookup (cache-aware effective price, provider pin + uptime, provider
#      count — the same registry code the budget estimator uses, no math duplicated here)
#   4. any candidates → post ONE digest issue on $DIGEST_REPO; graduation into the stacks.json
#      chains stays a HUMAN call (newcomers earn chain slots with evidence, not vibes)
#   5. advance the snapshot (only after a successful digest — a failed post retries next tick)
#
# v1 is REPORT-ONLY by design:
#   TODO(FU-062): canary dispatch — run each newcomer on a small, closed, known-good issue and write
#     the outcome to the ledger. Gated on FU-024 (`guardrail: only-free` actually ENFORCED in the
#     openrouter-operator, so a scout canary key cannot spend) AND on defining the canary task.
#   TODO(FU-062): consequently NO key minting here in v1 — the scout only reads public catalog data.
#
#   Env (all optional): ORG=teststuffstash  DIGEST_REPO=homelab  PRICE_CEILING=0.50
#                       AGENT_TS_ENDPOINT/AGENT_TS_BUCKET + AGENT_TS_READER_*/AGENT_TS_WRITER_*
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
DIGEST_REPO="${DIGEST_REPO:-homelab}"
CEILING="${PRICE_CEILING:-0.50}"   # $/M headline gate for paid newcomers (:free always passes)
ENDPOINT="${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}"
BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
STATE="s3://${BUCKET}/_model-scout/known-models.json"
API="https://openrouter.ai/api/v1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

s5() { # <key_id> <key_secret> <s5cmd args…> — reader for get, write-only writer for put
  local id="$1" sec="$2"; shift 2
  AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$sec" AWS_REGION=garage \
    s5cmd --endpoint-url "$ENDPOINT" "$@"
}

# 1. Current catalog, trimmed to the diff/filter fields (estimate_budget.py keeps its own richer
#    registry cache for the enrichment step). Fail LOUD on an empty catalog — advancing the snapshot
#    to [] would make EVERY model "new" next tick and spam a 340-row digest.
curl -fsS "$API/models" | jq '[.data[] | {
    id,
    tools: ((.supported_parameters // []) | index("tools") != null),
    prompt: (((.pricing.prompt // "0") | tonumber) * 1e6)
  }]' > "$WORK/current.json"
CURRENT_N="$(jq length "$WORK/current.json")"
[ "$CURRENT_N" -gt 0 ] || { log "FATAL: /models returned an empty catalog — keeping the old snapshot"; exit 1; }
jq '[.[].id] | sort' "$WORK/current.json" > "$WORK/ids.json"
log "catalog: ${CURRENT_N} models"

# 2. Previous snapshot. First run = bootstrap: nothing to diff, just save the baseline.
if ! s5 "${AGENT_TS_READER_ID:-}" "${AGENT_TS_READER_SECRET:-}" \
      cp "$STATE" "$WORK/known.json" >/dev/null 2>&1; then
  log "no previous snapshot at ${STATE} — bootstrap tick (baseline saved, no digest)"
  s5 "${AGENT_TS_WRITER_ID:-}" "${AGENT_TS_WRITER_SECRET:-}" cp "$WORK/ids.json" "$STATE" >/dev/null
  exit 0
fi

# 3. New ids → scout candidates: tool-capable AND (:free OR headline ≤ ceiling).
jq --slurpfile known "$WORK/known.json" \
   '[.[] | select(.id as $i | ($known[0] | index($i)) | not)]' \
   "$WORK/current.json" > "$WORK/new.json"
jq --argjson c "$CEILING" \
   '[.[] | select(.tools) | select((.id | endswith(":free")) or .prompt <= $c)]' \
   "$WORK/new.json" > "$WORK/candidates.json"
log "new: $(jq length "$WORK/new.json") — candidates (tools ∧ (:free ∨ ≤\$${CEILING}/M)): $(jq length "$WORK/candidates.json")"

if [ "$(jq length "$WORK/candidates.json")" -gt 0 ]; then
  # Enrich each candidate with the registry verdict (one /models fetch into the local cache, then
  # one /endpoints fetch per candidate). --lookup warnings (tools, unknown ids) go to our stderr.
  while IFS= read -r id; do
    python3 "$HERE/estimate_budget.py" --model "$id" --lookup \
      --registry-cache "$WORK/registry-cache.json" || log "lookup failed for ${id} (skipped)"
  done < <(jq -r '.[].id' "$WORK/candidates.json") | jq -s . > "$WORK/enriched.json"

  # 4. The digest issue — a report for a human, so the graduation decision has the numbers in it.
  TITLE="🔭 model scout: $(jq length "$WORK/enriched.json") new candidate model(s) ($(date -u +%F))"
  BODY="$(jq -r --arg ceiling "$CEILING" '
    "Weekly model scout (REPORT-ONLY, FU-062 / docs/agents/model-routing.md §M7): models that are"
    + " NEW on OpenRouter since the last tick, advertise `tools`, and are `:free` or ≤ $" + $ceiling
    + "/M headline.\n\n"
    + "| model | effective $/M in | price note | pinned provider | uptime | providers |\n"
    + "|---|---|---|---|---|---|\n"
    + (map("| `" + .model + "` | $" + (.price_per_mtok | tostring) + " | "
        + (if .price_note == "" then "—" else .price_note end) + " | `"
        + (.pinned_provider.provider // "—") + "` | "
        + (if .pinned_provider.uptime then ((.pinned_provider.uptime * 10 | round) / 10 | tostring) + "%" else "—" end)
        + " | " + (.provider_count | tostring) + " |")
       | join("\n"))
    + "\n\n*effective $/M = cache-aware per-provider min at 80% cache hit (§M3); pinned provider ="
    + " the tools-capable session pin `--lookup` would choose (§M4).*\n\n"
    + "**Graduation is a human call**: add worthy entries to `agents/stacks.json`"
    + " `workerModelFallbacks` — evidence, not vibes. Canary dispatch is TODO(FU-062), gated on"
    + " FU-024 (enforced only-free guardrail)."
  ' "$WORK/enriched.json")"
  log "→ posting digest issue on ${ORG}/${DIGEST_REPO}"
  gh issue create --repo "${ORG}/${DIGEST_REPO}" --title "$TITLE" --body "$BODY"
fi

# 5. Advance the snapshot (also when zero candidates — non-candidate newcomers are old news now).
s5 "${AGENT_TS_WRITER_ID:-}" "${AGENT_TS_WRITER_SECRET:-}" cp "$WORK/ids.json" "$STATE" >/dev/null
log "snapshot advanced (${CURRENT_N} known models); scout tick done"
