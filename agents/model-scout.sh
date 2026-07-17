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
# v2 (FU-062 canary leg, 2026-07-17): candidates get a CANARY RIDE before the digest — a tiny
# closed task (read README, echo its first heading — forces one real tool call) dispatched via
# agent-session.sh into $CANARY_PROJECT on an ephemeral budget-capped OpenRouterKey. `:free`
# candidates ride a `guardrail: only-free` key (FU-024: the egress proxy 403s any paid model on
# such a session BEFORE spend — the honor system is over); paid-but-≤-ceiling candidates get a
# $0.05 hard cap. Verdicts land twice: the ledger (agent-finalize's pushgateway metrics + the
# transcript bucket, model label = the candidate) and a comment on the digest issue. A canary
# failure never fails the tick. Graduation into the stacks.json chains REMAINS a human call.
#
#   Env (all optional): ORG=teststuffstash  DIGEST_REPO=homelab  PRICE_CEILING=0.50
#                       CANARY_PROJECT=openrouter-operator  MAX_CANARIES=3  CANARY=1 (0 = report-only)
#                       AGENT_TS_ENDPOINT/AGENT_TS_BUCKET + AGENT_TS_READER_*/AGENT_TS_WRITER_*
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
DIGEST_REPO="${DIGEST_REPO:-homelab}"
CEILING="${PRICE_CEILING:-0.50}"   # $/M headline gate for paid newcomers (:free always passes)
CANARY="${CANARY:-1}"              # 0 = v1 report-only behavior
CANARY_PROJECT="${CANARY_PROJECT:-openrouter-operator}"  # platform-stack fixer ns hosts the rides
MAX_CANARIES="${MAX_CANARIES:-3}"  # per tick — the rest of a big batch waits for graduation anyway
ENDPOINT="${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}"
BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
STATE="s3://${BUCKET}/_model-scout/known-models.json"
API="https://openrouter.ai/api/v1"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Canary one candidate model (FU-062/FU-024). Mints an ephemeral OpenRouterKey — only-free
# guardrail for :free ids (proxy 403s paid models pre-spend), a $0.05 cap otherwise — waits for
# the mint, then dispatches a headless agent-session ride on a trivial closed task. Echoes one
# markdown table row (the verdict) to stdout; all logs go to stderr so stdout stays parseable.
# Best-effort: any failure returns a row marked accordingly, never aborts the tick.
canary_one() {
  local id="$1" is_free="$2" sess cr secret verdict
  sess="scout-$(printf '%s' "$id" | tr '/:.' '---')"
  secret="${CANARY_PROJECT}-session-${sess}-openrouter"
  local guardrail_line="  budgetUSD: 0.05" ; local gname="\$0.05 cap"
  if [ "$is_free" = "true" ]; then
    guardrail_line=$'  budgetUSD: 0.01\n  guardrail: only-free' ; gname="only-free"
  fi
  # delete-then-create: PATCH can't extend expiry (openrouter-operator#6, coordinator README §4).
  kubectl -n "$CANARY_PROJECT" delete openrouterkey "${CANARY_PROJECT}-${sess}" --ignore-not-found >&2 2>/dev/null || true
  cat <<YAML | kubectl apply -f - >&2 2>/dev/null || { echo "| \`$id\` | ⚠ mint-failed |"; return 0; }
apiVersion: openrouter.teststuff.net/v1alpha1
kind: OpenRouterKey
metadata: { name: ${CANARY_PROJECT}-${sess}, namespace: ${CANARY_PROJECT} }
spec:
  project: ${CANARY_PROJECT}
  ephemeral: true
  session: ${sess}
  secretName: ${secret}
${guardrail_line}
YAML
  # Wait for the mint (bounded); a key that never mints ⇒ report and move on.
  local i=0; until [ -n "$(kubectl -n "$CANARY_PROJECT" get openrouterkey "${CANARY_PROJECT}-${sess}" -o jsonpath='{.status.openrouter.hash}' 2>/dev/null)" ]; do
    i=$((i+1)); [ "$i" -gt 40 ] && { echo "| \`$id\` | ⚠ key-never-minted (${gname}) |"; return 0; }; sleep 3
  done
  log "canary: dispatching $id (${gname})"
  # Headless ride; --harness opencode carries the model via -m. agent-finalize writes the ledger
  # row (model label = $id) + transcript. We read its exit_status from the stats line.
  local out; out="$(bash "$HERE/agent-session.sh" "$CANARY_PROJECT" --harness opencode --model "openrouter/$id" \
      --task "$sess" --openrouter-secret "$secret" \
      --run 'opencode run -m "$MODEL" "Reply with ONLY the first markdown heading text of README.md (no other words)."' 2>&1)" || true
  echo "$out" | grep -E "AGENT_RUN_STATS|PREFLIGHT|403|guardrail" >&2 || true
  verdict="$(printf '%s' "$out" | sed -n 's/.*AGENT_RUN_STATS \(.*\)/\1/p' | tail -1 | jq -r '.exit_status // "no-stats"' 2>/dev/null || echo "no-stats")"
  # Clean up the ephemeral key; the transcript/ledger row persists as the durable record.
  kubectl -n "$CANARY_PROJECT" delete openrouterkey "${CANARY_PROJECT}-${sess}" --ignore-not-found >&2 2>/dev/null || true
  echo "| \`$id\` | ${verdict} (${gname}) |"
}

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

  # 3b. Canary the top candidates (FU-062 v2). The list is small (new ∧ tools ∧ cheap); cap at
  # MAX_CANARIES so a rare flood doesn't run dozens of rides. Verdicts → a markdown block for the
  # digest. CANARY=0 restores v1 report-only.
  CANARY_BLOCK=""
  if [ "$CANARY" = "1" ]; then
    log "canary: riding up to ${MAX_CANARIES} candidate(s) in ns ${CANARY_PROJECT}"
    ROWS="$(jq -r '.[] | "\(.id) \((.id | endswith(":free")))"' "$WORK/candidates.json" | head -n "$MAX_CANARIES" \
      | while read -r cid cfree; do canary_one "$cid" "$cfree"; done)"
    CANARY_BLOCK=$'\n\n**Canary rides** (FU-062/FU-024 — trivial closed task, ephemeral capped key; `only-free` = proxy 403s any paid model pre-spend):\n\n| model | canary verdict |\n|---|---|\n'"$ROWS"$'\n\n*A `clean` verdict = the model completed a real tool-using task on a budget-capped key; it is evidence for graduation, not automatic graduation. Full outcome + transcript in the ledger (model label).*'
  fi

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
    + " `workerModelFallbacks` — evidence, not vibes."
  ' "$WORK/enriched.json")${CANARY_BLOCK}"
  log "→ posting digest issue on ${ORG}/${DIGEST_REPO}"
  gh issue create --repo "${ORG}/${DIGEST_REPO}" --title "$TITLE" --body "$BODY"
fi

# 5. Advance the snapshot (also when zero candidates — non-candidate newcomers are old news now).
s5 "${AGENT_TS_WRITER_ID:-}" "${AGENT_TS_WRITER_SECRET:-}" cp "$WORK/ids.json" "$STATE" >/dev/null
log "snapshot advanced (${CURRENT_N} known models); scout tick done"
