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
# v3 legs 1–2 (FU-161, homelab#282 — §M7 legs 1–2). Digest #234 was 22 "new" candidates of which 20
# were a platform-wide `:batch` re-listing of years-old models, so the tick's two cheapest signals
# were both wrong: the diff called re-listings newcomers, and the canary slots went to whoever the
# diff listed first.
#   leg 1  the diff is by BASE id (`id` minus its `:variant` tag) and `:batch` is excluded outright.
#          A variant of a base we already know is a RE-LISTING — one digest summary line, never N
#          rows. #234's world reduces 22 → 2 under this rule (replayed: fixtures/scout-variant-*).
#   leg 2  one MCP `get-model` per surviving candidate puts the AA indices in the digest beside the
#          price, marks benchless newcomers `unbenched`, and RANKS candidates (free first, then
#          agentic/coding) before any canary slot is spent. Env-gated on $SCOUT_MCP_KEY: no key ⇒
#          every candidate `unbenched` and the tick carries on (see the seam's own header).
# Legs 3–4 (typed cell-keyed verdicts) are NOT built here.
#   leg 5  pool curation (§M13, ADR-104) — the table this leg will maintain now EXISTS and is
#          hand-seeded: `pools` in argocd/resources/openrouter-proxy/model-classes.json, drawn by
#          `/route` via class+slot (homelab#290). What is missing is exactly the weekly refresh:
#          re-rank each band by capability × task_market × effective price × rail-compat, keep the
#          bands disjoint and family-deduped, deepen `regular` past the 7-arm ask, bump
#          `pools.version`. It moves by PR until then — and the router self-test enforces the
#          curation invariants at edit time, so a refresh that breaks a band reds in CI.
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
#                       SCOUT_MCP_KEY (leg 2 benchmark cross-check; absent ⇒ all `unbenched`)
#                       MCP_UPSTREAM=https://mcp.openrouter.ai/mcp
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
MCP_UPSTREAM="${MCP_UPSTREAM:-https://mcp.openrouter.ai/mcp}"   # leg 2; same server the proxy uses
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
  # ADR-096: feed the verdict into the router's rotation store too (TokenReview-gated — the
  # in-cluster SA token authenticates us as an agent-coordinator SA). Best-effort: the digest
  # issue stays the human record; a miss here only leaves the router's copy stale.
  rotation_post "scout-canary" "$(jq -cn --arg m "$id" --arg v "$verdict" \
    '{model: $m, canary_verdict: $v}')" || true
  echo "| \`$id\` | ${verdict} (${gname}) |"
}

# POST one rotation entry to the egress proxy's control plane (router.py). No-op without the
# in-cluster SA token (jail runs) — the router's /rotation refuses unauthenticated writes.
PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
SA_TOKEN_FILE="/var/run/secrets/kubernetes.io/serviceaccount/token"
rotation_post() { # <source> <entry-json>
  [ -s "$SA_TOKEN_FILE" ] || return 0
  curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $(cat "$SA_TOKEN_FILE")" \
    -d "$(jq -cn --arg s "$1" --argjson e "$2" '{source: $s, entries: [$e]}')" \
    "$PROXY/rotation" >/dev/null 2>&1 \
    && log "rotation: posted $2 (source=$1)" \
    || log "rotation: POST failed (non-fatal)"
}

s5() { # <key_id> <key_secret> <s5cmd args…> — reader for get, write-only writer for put
  local id="$1" sec="$2"; shift 2
  AWS_ACCESS_KEY_ID="$id" AWS_SECRET_ACCESS_KEY="$sec" AWS_REGION=garage \
    s5cmd --endpoint-url "$ENDPOINT" "$@"
}

# ── I/O SEAMS ───────────────────────────────────────────────────────────────────────────────────
# Every network/S3 touch this tick makes is an ordinary shell function, so a replay fixture can
# redefine exactly those and leave the diff / rank / render arithmetic under assertion
# (agents/replay/README.md §When a clause depends on a sourced helper). Do NOT inline a curl, an
# s5cmd or a python lookup below — add a seam here instead, and never a `REPLAY_*` branch.
# >>>REPLAY:scout-seams>>>
scout_catalog() { curl -fsS "$API/models"; }   # the live /models catalog, raw

scout_state_read()  { # <dest-file> — non-zero = no snapshot yet (bootstrap tick)
  s5 "${AGENT_TS_READER_ID:-}" "${AGENT_TS_READER_SECRET:-}" cp "$STATE" "$1" >/dev/null 2>&1
}
scout_state_write() { # <src-file>
  s5 "${AGENT_TS_WRITER_ID:-}" "${AGENT_TS_WRITER_SECRET:-}" cp "$1" "$STATE" >/dev/null
}

scout_enrich() { # <candidates.json> → the enriched array on stdout
  # One /models fetch into the local cache, then one /endpoints fetch per candidate — the same
  # registry code the budget estimator uses, no math duplicated here. A failed lookup drops that
  # candidate's enrichment (the row still renders, with "—"); its warning goes to STDERR, because
  # stdout here is the JSON stream `jq -s` slurps.
  while IFS= read -r id; do
    python3 "$HERE/estimate_budget.py" --model "$id" --lookup \
      --registry-cache "$WORK/registry-cache.json" || log "lookup failed for ${id} (skipped)" >&2
  done < <(jq -r '.[].id' "$1") | jq -s .
}

# LEG 2 (§M7): the AA benchmark cross-check for ONE candidate — the MCP `get-model` reply, decoded,
# on stdout. Wire shape mirrors the proxy's `_mcp_call` (initialize, then tools/call, plain JSON-RPC
# over HTTP) against the same server and the same STANDARD account key that already pulls
# `list-benchmarks` (probed 2026-08-03 — model-routing.md §The OpenRouter API surface).
#
# ENV-GATED, and that is the ordinary path today: this reflex's CronWorkflow env carries GH_TOKEN
# and the transcript S3 keys, and NO OpenRouter account key (wiring one in is a manifest change on
# goal #278, not this leg). No key ⇒ non-zero ⇒ every candidate `unbenched` ⇒ the tick continues.
# A benchmark lookup that cannot run must never fail the tick or block the digest.
#
# ⚠ UNVERIFIED FROM THIS SEAT: the `arguments` envelope follows the probed `{request: {…}}` shape
# its sibling tools take, but `get-model`'s own signature has not been probed (no account key is
# reachable from the fixer pod). If it is wrong the reply carries a JSON-RPC `.error`, which the
# caller LOGS LOUDLY and turns into `unbenched` — so the first live hand-fire says so in the tick
# log instead of quietly benching nothing. Fixture: scout-bench-mcp-error.
scout_get_model() { # <model-id> → decoded get-model payload on stdout; non-zero = no bench data
  local id="$1" key="${SCOUT_MCP_KEY:-}"
  [ -n "$key" ] || { log "get-model: no \$SCOUT_MCP_KEY in this env — candidates ride unbenched" >&2; return 1; }
  local ct='Content-Type: application/json' ac='Accept: application/json, text/event-stream'
  # Cloudflare 403s a default UA on this host (measured 2026-07-27, openrouter-proxy.py).
  curl -fsS -m 20 -H "$ct" -H "$ac" -H "Authorization: Bearer $key" -H 'User-Agent: homelab-model-scout' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"homelab-model-scout","version":"1"}}}' \
    "$MCP_UPSTREAM" >/dev/null 2>&1 || return 1
  curl -fsS -m 30 -H "$ct" -H "$ac" -H "Authorization: Bearer $key" -H 'User-Agent: homelab-model-scout' \
    -d "$(jq -cn --arg m "$id" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"get-model",arguments:{request:{model:$m}}}}')" \
    "$MCP_UPSTREAM" \
    | jq -e 'if .error then . else ((.result.content[0].text // "{}") | fromjson) end' 2>/dev/null
}
# <<<REPLAY:scout-seams<<<

# >>>REPLAY:scout-diff>>>
# 1. Current catalog, trimmed to the diff/filter fields (estimate_budget.py keeps its own richer
#    registry cache for the enrichment step). Fail LOUD on an empty catalog — advancing the snapshot
#    to [] would make EVERY model "new" next tick and spam a 340-row digest.
scout_catalog | jq '[.data[] | {
    id,
    tools: ((.supported_parameters // []) | index("tools") != null),
    prompt: (((.pricing.prompt // "0") | tonumber) * 1e6)
  }]' > "$WORK/current.json"
CURRENT_N="$(jq length "$WORK/current.json")"
[ "$CURRENT_N" -gt 0 ] || { log "FATAL: /models returned an empty catalog — keeping the old snapshot"; exit 1; }
jq '[.[].id] | sort' "$WORK/current.json" > "$WORK/ids.json"
log "catalog: ${CURRENT_N} models"

# 2. Previous snapshot. First run = bootstrap: nothing to diff, just save the baseline.
#    The snapshot stays a list of FULL ids (leg 1 derives bases at diff time): a format change here
#    would orphan the live snapshot and make every model new on the very tick that ships this.
if ! scout_state_read "$WORK/known.json"; then
  log "no previous snapshot at ${STATE} — bootstrap tick (baseline saved, no digest)"
  scout_state_write "$WORK/ids.json"
  exit 0
fi

# 3. LEG 1 — newcomers BY BASE ID. `base(id)` is the id minus its `:variant` tag, and a new id has
#    three ways out of this clause:
#      `:batch`   → dropped outright. An async endpoint cannot serve an interactive session, and its
#                   discounted headline is exactly what slipped 20 re-listings under the ceiling on
#                   digest #234.
#      known base → a RE-LISTING, not a newcomer: it becomes one summary line, never N digest rows.
#      otherwise  → a genuine newcomer, and only these reach the filter/bench/canary path.
BASEDEF='def base: sub(":[^:]*$"; "");'
jq --slurpfile known "$WORK/known.json" \
   '[.[] | select(.id as $i | ($known[0] | index($i)) | not)]' \
   "$WORK/current.json" > "$WORK/new.json"
jq '[.[] | select(.id | endswith(":batch"))]' "$WORK/new.json" > "$WORK/sup-batch.json"
#    (`index()` evaluates its argument against ITS OWN input, so the base is bound to $b first —
#    `$kb | index(.id | base)` would look up `.id` on $kb, the array.)
jq "$BASEDEF"'
   ($known[0] | map(base) | unique) as $kb
   | [.[] | select(.id | endswith(":batch") | not)
          | (.id | base) as $b | select(($kb | index($b)) != null)]' \
   --slurpfile known "$WORK/known.json" "$WORK/new.json" > "$WORK/sup-variant.json"
jq "$BASEDEF"'
   ($known[0] | map(base) | unique) as $kb
   | [.[] | select(.id | endswith(":batch") | not)
          | (.id | base) as $b | select(($kb | index($b)) == null)]' \
   --slurpfile known "$WORK/known.json" "$WORK/new.json" > "$WORK/fresh.json"

jq --argjson c "$CEILING" \
   '[.[] | select(.tools) | select((.id | endswith(":free")) or .prompt <= $c)]' \
   "$WORK/fresh.json" > "$WORK/passed.json"
# Within-tick siblings collapse too — two variants of ONE new base are one newcomer. The
# representative is the cheapest listing (`:free` sorts first), so a base is never judged on its
# dearest variant.
jq "$BASEDEF"'
   [ group_by(.id | base)[]
     | sort_by([(if (.id | endswith(":free")) then 0 else 1 end), .prompt, .id])[0] ]
   | sort_by(.id)' "$WORK/passed.json" > "$WORK/candidates.json"

SUP_BATCH="$(jq length "$WORK/sup-batch.json")"
SUP_VARIANT="$(( $(jq length "$WORK/sup-variant.json") \
                 + $(jq length "$WORK/passed.json") - $(jq length "$WORK/candidates.json") ))"
log "new ids: $(jq length "$WORK/new.json") — suppressed ${SUP_BATCH} \`:batch\` + ${SUP_VARIANT} variant re-listing(s); candidates (new base ∧ tools ∧ (:free ∨ ≤\$${CEILING}/M)): $(jq length "$WORK/candidates.json")"

# One line for the whole suppressed set — §M7 leg 1's "one digest summary line, never N rows".
SUPPRESSED_LINE=""
if [ "$SUP_BATCH" -gt 0 ] || [ "$SUP_VARIANT" -gt 0 ]; then
  SUPPRESSED_LINE=$'\n\n*Suppressed by the base-id diff (§M7 leg 1): '"${SUP_BATCH}"' `:batch` re-listing(s) — an async endpoint cannot serve an interactive session — and '"${SUP_VARIANT}"' other suffix variant(s) of a base already known or already listed above. A variant is not a newcomer.*'
fi
# <<<REPLAY:scout-diff<<<

if [ "$(jq length "$WORK/candidates.json")" -gt 0 ]; then
  scout_enrich "$WORK/candidates.json" > "$WORK/enriched.json"

  # >>>REPLAY:scout-bench>>>
  # 3a. LEG 2 — one MCP `get-model` per surviving candidate. The AA composite indices go in the
  # digest beside the price (capability and cost in one row, so the graduation call has both), and
  # a newcomer the benchmark feed has never heard of is marked `unbenched` rather than dropped —
  # being unbenched is the NORMAL state of a genuine newcomer and is exactly what the canary rung
  # exists to answer.
  : > "$WORK/bench.jsonl"
  while IFS= read -r cid; do
    if reply="$(scout_get_model "$cid")"; then
      if [ -n "$(printf '%s' "$reply" | jq -r '.error.message // empty')" ]; then
        log "get-model: ${cid} → MCP error: $(printf '%s' "$reply" | jq -r '.error.message') (unbenched)"
        jq -cn --arg m "$cid" '{model:$m, benched:false}' >> "$WORK/bench.jsonl"
      else
        # The index FIELD NAMES are the probed ones (`list-benchmarks`, AA source); the envelope
        # get-model wraps them in is not something we can pin offline, so take the first object
        # carrying any of them rather than a path that would break on a reshuffle.
        printf '%s' "$reply" | jq -c --arg m "$cid" '
          [.. | objects | select(has("intelligence_index") or has("coding_index") or has("agentic_index"))] as $b
          | if ($b | length) == 0 then {model:$m, benched:false}
            else {model:$m, benched:true, intelligence: $b[0].intelligence_index,
                  coding: $b[0].coding_index, agentic: $b[0].agentic_index} end' >> "$WORK/bench.jsonl"
      fi
    else
      jq -cn --arg m "$cid" '{model:$m, benched:false}' >> "$WORK/bench.jsonl"
    fi
  done < <(jq -r '.[].id' "$WORK/candidates.json")
  jq -s . "$WORK/bench.jsonl" > "$WORK/bench.json"

  # 3b. RANK, before a single canary slot is spent: free first, then the agentic index (coding then
  # intelligence as fallbacks — a model benched on one axis still outranks an unbenched one), then
  # the headline price, then the id for determinism. `head -N` in diff order is what leg 2 kills.
  jq -n --slurpfile c "$WORK/candidates.json" --slurpfile b "$WORK/bench.json" \
        --slurpfile e "$WORK/enriched.json" '
    ($b[0] | INDEX(.model)) as $bench | ($e[0] | INDEX(.model)) as $enr
    | [ $c[0][] | { model: .id, free: (.id | endswith(":free")), headline: .prompt,
                    bench: ($bench[.id] // {benched:false}), enr: $enr[.id] } ]
    | map(. + {score: (if .bench.benched
                       then (.bench.agentic // .bench.coding // .bench.intelligence // -1)
                       else -1 end)})
    | sort_by([(if .free then 0 else 1 end), (- .score), .headline, .model])' > "$WORK/ranked.json"
  log "ranked: $(jq -r '[.[] | .model + (if .bench.benched then "" else " (unbenched)" end)] | join(", ")' "$WORK/ranked.json")"
  # <<<REPLAY:scout-bench<<<

  # 3c. Canary the top-RANKED candidates (FU-062 v2). The list is small (new base ∧ tools ∧ cheap);
  # cap at MAX_CANARIES so a rare flood doesn't run dozens of rides. Verdicts → a markdown block for
  # the digest. CANARY=0 restores v1 report-only.
  CANARY_BLOCK=""
  if [ "$CANARY" = "1" ]; then
    log "canary: riding up to ${MAX_CANARIES} candidate(s) in ns ${CANARY_PROJECT}"
    ROWS="$(jq -r '.[] | "\(.model) \(.free)"' "$WORK/ranked.json" | head -n "$MAX_CANARIES" \
      | while read -r cid cfree; do canary_one "$cid" "$cfree"; done)"
    CANARY_BLOCK=$'\n\n**Canary rides** (FU-062/FU-024 — trivial closed task, ephemeral capped key; `only-free` = proxy 403s any paid model pre-spend):\n\n| model | canary verdict |\n|---|---|\n'"$ROWS"$'\n\n*A `clean` verdict = the model completed a real tool-using task on a budget-capped key; it is evidence for graduation, not automatic graduation. Full outcome + transcript in the ledger (model label).*'
  fi

  # >>>REPLAY:scout-digest>>>
  # 4. The digest issue — a report for a human, so the graduation decision has the numbers in it.
  #    Rendered from the RANKED list, in rank order: the table is also the order canary slots were
  #    spent in, and the suppressed set rides as one line under it (leg 1).
  TITLE="🔭 model scout: $(jq length "$WORK/ranked.json") new candidate model(s) ($(date -u +%F))"
  BODY="$(jq -r --arg ceiling "$CEILING" '
    "Weekly model scout (REPORT-ONLY, FU-062 / docs/agents/model-routing.md §M7): models whose BASE"
    + " id is NEW on OpenRouter since the last tick, advertise `tools`, and are `:free` or ≤ $" + $ceiling
    + "/M headline. Ranked free-first, then by AA agentic/coding — the order canary slots are spent in.\n\n"
    + "| # | model | AA int/code/agentic | effective $/M in | price note | pinned provider | uptime | providers |\n"
    + "|---|---|---|---|---|---|---|---|\n"
    + (to_entries | map(((.key + 1) | tostring) as $n | .value
        | "| " + $n + " | `" + .model + "` | "
        + (if .bench.benched
           then ((.bench.intelligence // "—") | tostring) + " / " + ((.bench.coding // "—") | tostring)
                + " / " + ((.bench.agentic // "—") | tostring)
           else "`unbenched`" end)
        + " | " + (if .enr then "$" + (.enr.price_per_mtok | tostring) else "—" end) + " | "
        + (if (.enr.price_note // "") == "" then "—" else .enr.price_note end) + " | `"
        + (.enr.pinned_provider.provider // "—") + "` | "
        + (if .enr.pinned_provider.uptime then ((.enr.pinned_provider.uptime * 10 | round) / 10 | tostring) + "%" else "—" end)
        + " | " + ((.enr.provider_count // "—") | tostring) + " |")
       | join("\n"))
    + "\n\n*effective $/M = cache-aware per-provider min at 80% cache hit (§M3); pinned provider ="
    + " the tools-capable session pin `--lookup` would choose (§M4). AA indices = MCP `get-model`"
    + " (§M7 leg 2); `unbenched` = not in the Artificial-Analysis feed, which is the normal state of"
    + " a genuine newcomer — the canary rung, not the benchmark, is what speaks for those.*\n\n"
    + "**Graduation is a human call**: add worthy entries to `agents/stacks.json`"
    + " `workerModelFallbacks` — evidence, not vibes. The same commit MUST add the model_tiers"
    + " line (router-self-test enforces chain ⊆ tiers since 2026-08-03) — ready to paste:\n\n"
    + (map("`\"" + .model + "\": \""
        + (if (.model | endswith(":free")) then "free"
           elif (.enr.price_per_mtok == null) then "?"
           elif .enr.price_per_mtok == 0 then "free"
           elif .enr.price_per_mtok < 0.5 then "cheap"
           elif .enr.price_per_mtok < 3 then "large"
           else "premium" end)
        + "\"` (argocd/resources/openrouter-proxy/model-classes.json — merging rolls the proxy)")
       | join("\n"))
  ' "$WORK/ranked.json")${SUPPRESSED_LINE}${CANARY_BLOCK}"
  log "→ posting digest issue on ${ORG}/${DIGEST_REPO}"
  gh issue create --repo "${ORG}/${DIGEST_REPO}" --title "$TITLE" --body "$BODY"
  # <<<REPLAY:scout-digest<<<
fi

# 5. Advance the snapshot (also when zero candidates — non-candidate newcomers are old news now).
scout_state_write "$WORK/ids.json"
log "snapshot advanced (${CURRENT_N} known models); scout tick done"
