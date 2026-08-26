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
#   leg 3  the canary is a RAIL probe, not a capability probe, and it runs BEFORE the digest: for
#          each top-RANKED candidate, a trivial closed tool-call ride through OUR stack (harness →
#          egress proxy → pinned provider → guardrailed ephemeral key). A verdict is cell-keyed —
#          evidence about (model, harness, class) — and lands in the router's rotation store with
#          source=canary (the same store the own-outcomes feed reads).
#   leg 4  TYPED verdicts: each carries the launcher's error_class, never a bare `failed`. Two
#          sanity rules: contradiction (canary-fail ∧ benchmark-capable ⇒ suspect-infra, retry
#          once, else `inconclusive`) and common-cause (N canaries failing identically in one tick
#          = ONE scout-infra datum, zero per-model verdicts). Plus the FU-161 FILING GATE: a digest
#          whose every row is unbenched AND uncanaried posts to the scout log only — gh issue create
#          is SKIPPED with a log line saying why (no more zero-information graduation issues).
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

# OPERATOR INTAKE (2026-08-26, the 0731 case): --intake <id>[,<id>…] (or env SCOUT_INTAKE) rides
# EXPLICIT catalog ids through the SAME legs as newcomers — enrich → bench → rank → canary →
# rotation store → digest — so an "oldie" enters the system by the same structured path a
# new-model diff candidate does. The diff/snapshot half is BYPASSED and the snapshot NEVER
# advances: intake is stateless and idempotent. The price ceiling deliberately does not gate an
# intake (the operator asked by name); the `tools` requirement stands (a toolless model cannot
# ride any harness).
INTAKE="${SCOUT_INTAKE:-}"
while [ $# -gt 0 ]; do case "$1" in
  --intake) INTAKE="$2"; shift 2 ;;
  *) echo "model-scout: unknown arg $1 (only --intake <ids-csv>)" >&2; exit 2 ;;
esac; done

ORG="${ORG:-teststuffstash}"
DIGEST_REPO="${DIGEST_REPO:-homelab}"
CEILING="${PRICE_CEILING:-0.50}"   # $/M headline gate for paid newcomers (:free always passes)
CANARY="${CANARY:-1}"              # 0 = v1 report-only behavior
CANARY_PROJECT="${CANARY_PROJECT:-openrouter-operator}"  # platform-stack fixer ns hosts the rides
MAX_CANARIES="${MAX_CANARIES:-3}"  # per tick — the rest of a big batch waits for graduation anyway
# ADR-112: a verdict is the (model × harness) cell VECTOR, never one harness's failure. The cron
# default stays the single opencode cell (cost + unchanged behavior); an intake run widens it,
# e.g. SCOUT_CANARY_HARNESSES="opencode goose". claude is NOT a valid cell yet — its in-cluster
# OpenRouter leg is the missing rail (chainless-redesign.md §The decisions (3)).
CANARY_HARNESSES="${SCOUT_CANARY_HARNESSES:-opencode}"
# Provider arms per cell + the retry/RESELECT budget (operator, 2026-08-26). Tokens are
# provider_slot INTEGERS (the M13 slot verb on the provider axis — the proxy resolves N against
# its eff-ranked eligible endpoints and echoes the slug) or explicit slugs (the operator escape
# hatch for named arms); "" = the proxy's own M4 pin, the cron default. SCOUT_CELL_ATTEMPTS caps
# rides per (model, harness) cell; a reselect ALWAYS moves to the NEXT arm (#783: serving-shaped
# failures exclude the (model, provider) pair — never a blind same-pair retry). With no arm list
# the old bench-contradiction single same-arm retry stands (cron behavior unchanged).
CELL_PROVIDERS="${SCOUT_CELL_PROVIDERS:-}"
CELL_ATTEMPTS="${SCOUT_CELL_ATTEMPTS:-2}"
ENDPOINT="${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}"
BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
STATE="s3://${BUCKET}/_model-scout/known-models.json"
API="https://openrouter.ai/api/v1"
MCP_UPSTREAM="${MCP_UPSTREAM:-https://mcp.openrouter.ai/mcp}"   # leg 2; same server the proxy uses
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# The canary machinery is split by the seam rule: the mint + ride + rotation-post I/O live in the
# `scout-seams` block below (replay-shadowable); the ORCHESTRATION — typed verdict classification,
# the contradiction rule, the common-cause rule, the merge into the ranked rows — lives in the
# `scout-canary` block, so fixtures compose and pin exactly that (legs 3–4, FU-161).

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
scout_state_write() { # <src-file> — non-zero = save failed (caller handles)
  s5 "${AGENT_TS_WRITER_ID:-}" "${AGENT_TS_WRITER_SECRET:-}" cp "$1" "$STATE" >/dev/null 2>&1
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

# LEG 3 (§M7) — the canary ride is I/O behind two seams, exactly like every other network touch in
# this tick. The mint (OpenRouterKey CR lifecycle — kubectl) and the ride (agent-session.sh
# dispatch) are ordinary shell functions so a replay fixture can redefine exactly them and leave
# the verdict rules (leg 4) under assertion. Do NOT inline a kubectl or an agent-session dispatch
# below. And the verdict feed into the router's rotation store (ADR-096) is itself a seam — a
# TokenReview-gated POST that no-ops without the in-cluster SA token (jail runs).
PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
# Overridable so a JAIL intake run can feed the store too: /rotation TokenReviews any
# agent-coordinator SA, and the jail can mint one (kubectl -n agent-coordinator create token …).
SA_TOKEN_FILE="${SCOUT_SA_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
rotation_post() { # <source> <entry-json> — one rotation-store entry (POST /rotation, best-effort)
  [ -s "$SA_TOKEN_FILE" ] || return 0
  curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $(cat "$SA_TOKEN_FILE")" \
    -d "$(jq -cn --arg s "$1" --argjson e "$2" '{source: $s, entries: [$e]}')" \
    "$PROXY/rotation" >/dev/null 2>&1 \
    && log "rotation: posted $2 (source=$1)" \
    || log "rotation: POST failed (non-fatal)"
}

scout_canary_mint() { # <id> <is_free> <harness> [cleanup] → 0 minted / cleaned; 1 = mint-failed; 2 = never-minted
  local id="$1" is_free="$2" harness="$3" mode="${4:-}"
  # The session (and so the key, the Secret, the pod name) is CELL-keyed — two harness cells of
  # one model must not share an idempotency key or the second cell reuses the first's ride.
  local sess="scout-$(printf '%s' "$id" | tr '/:.' '---')-${harness}"
  local key="${CANARY_PROJECT}-${sess}"
  if [ "$mode" = "cleanup" ]; then
    kubectl -n "$CANARY_PROJECT" delete openrouterkey "$key" --ignore-not-found >&2 2>/dev/null || true
    return 0
  fi
  # FU-024 only-free guardrail for :free ids (proxy 403s paid models pre-spend), $0.05 cap otherwise.
  local guardrail_line="  budgetUSD: 0.05"
  [ "$is_free" = "true" ] && guardrail_line=$'  budgetUSD: 0.01\n  guardrail: only-free'
  # delete-then-create: PATCH can't extend expiry (openrouter-operator#6, coordinator README §4).
  kubectl -n "$CANARY_PROJECT" delete openrouterkey "$key" --ignore-not-found >&2 2>/dev/null || true
  cat <<YAML | kubectl apply -f - >&2 2>/dev/null || return 1
apiVersion: openrouter.teststuff.net/v1alpha1
kind: OpenRouterKey
metadata: { name: ${key}, namespace: ${CANARY_PROJECT} }
spec:
  project: ${CANARY_PROJECT}
  ephemeral: true
  session: ${sess}
  secretName: ${CANARY_PROJECT}-session-${sess}-openrouter
${guardrail_line}
YAML
  # Wait for the mint (bounded); a key that never mints ⇒ report and move on.
  local i=0
  until [ -n "$(kubectl -n "$CANARY_PROJECT" get openrouterkey "$key" -o jsonpath='{.status.openrouter.hash}' 2>/dev/null)" ]; do
    i=$((i+1)); [ "$i" -gt 40 ] && return 2; sleep 3
  done
  return 0
}

scout_canary_ride() { # <id> <arm> <is_free> <harness> <attempt> → the AGENT_RUN_STATS json on stdout
  # <arm> = "" (proxy's own pin) | a provider_slot integer | a provider slug — rides in-band as
  # the `@` suffix our proxy resolves. The SESSION stays keyed on the bare (id, harness) cell;
  # the attempt number rides --round so each arm's pod/transcript is distinct.
  local id="$1" arm="$2" is_free="$3" harness="$4" attempt="${5:-1}" out
  local rid="$id"; [ -n "$arm" ] && rid="${id}@${arm}"
  local sess="scout-$(printf '%s' "$id" | tr '/:.' '---')-${harness}"
  local secret="${CANARY_PROJECT}-session-${sess}-openrouter"
  # Headless ride; --harness opencode carries the model via -m. agent-finalize writes the ledger
  # row (model label = $id) + transcript. We read its error_class from the stats line. The `retry`
  # marker is a label the contradiction rule stamps; production rides are identical either way.
  # The full provider-prefixed id must be composed launcher-side to reach opencode's -m correctly.
  # One trivial closed task, per (harness, provider-arm) attempt. goose takes the prompt via
  # `goose run --text` (the model reaches it as GOOSE_MODEL from --model — the launcher's own
  # threading; the `@` suffix rides inside it and resolves at the proxy).
  local prompt="Reply with ONLY the first markdown heading text of README.md (no other words)."
  case "$harness" in
    goose)
      out="$(bash "$HERE/agent-session.sh" "$CANARY_PROJECT" --harness goose --model "openrouter/$rid" \
          --task "$sess" --round "$attempt" --openrouter-secret "$secret" \
          --run "goose run --text \"$prompt\"" 2>&1)" || true ;;
    *)
      out="$(bash "$HERE/agent-session.sh" "$CANARY_PROJECT" --harness opencode --model "openrouter/$rid" \
          --task "$sess" --round "$attempt" --openrouter-secret "$secret" \
          --run "opencode run -m \"openrouter/$rid\" \"$prompt\"" 2>&1)" || true ;;
  esac
  printf '%s\n' "$out" | grep -E "AGENT_RUN_STATS|PREFLIGHT|403|guardrail" >&2 || true
  printf '%s' "$out" | sed -n 's/.*AGENT_RUN_STATS \(.*\)/\1/p' | tail -1
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

# 1b. OPERATOR INTAKE — explicit ids replace the diff as the candidate source; everything
#     downstream (enrich → bench → rank → canary → store → digest) is identical. No snapshot
#     read, no advance: stateless and idempotent.
if [ -n "${INTAKE:-}" ]; then
  printf '%s' "$INTAKE" | tr ',' '\n' | jq -R 'select(length > 0)' | jq -s . > "$WORK/intake-ids.json"
  jq --slurpfile want "$WORK/intake-ids.json" \
     '[.[] | select(.id as $i | ($want[0] | index($i)) != null)]' \
     "$WORK/current.json" > "$WORK/intake-found.json"
  MISSING="$(jq -r --slurpfile got "$WORK/intake-found.json" \
     '[.[] | select(. as $i | ($got[0] | map(.id) | index($i)) | not)] | join(", ")' "$WORK/intake-ids.json")"
  [ -n "$MISSING" ] && log "intake: NOT in the live catalog (skipped): ${MISSING}"
  TOOLLESS="$(jq -r '[.[] | select(.tools | not) | .id] | join(", ")' "$WORK/intake-found.json")"
  [ -n "$TOOLLESS" ] && log "intake: no \`tools\` support (skipped — cannot ride any harness): ${TOOLLESS}"
  jq '[.[] | select(.tools)]' "$WORK/intake-found.json" > "$WORK/candidates.json"
  SUPPRESSED_LINE=""
  log "intake: $(jq length "$WORK/candidates.json") candidate(s) by operator request — diff/snapshot bypassed, ceiling not applied"
else

# 2. Previous snapshot. First run = bootstrap: nothing to diff, just save the baseline.
#    The snapshot stays a list of FULL ids (leg 1 derives bases at diff time): a format change here
#    would orphan the live snapshot and make every model new on the very tick that ships this.
if ! scout_state_read "$WORK/known.json"; then
  log "no previous snapshot at ${STATE} — bootstrap tick (baseline saved, no digest)"
  scout_state_write "$WORK/ids.json" || log "scout: bootstrap snapshot write failed (non-fatal)"
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
fi # end of the diff-vs-intake candidate source split
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

  # >>>REPLAY:scout-canary>>>
  # 3c. LEG 3 (§M7) — canary the top-RANKED candidates BEFORE the digest. The canary is a RAIL
  # probe, not a capability probe: capability comes from the benchmark feed (leg 2); the canary
  # answers the one question no benchmark can — does this model complete a tool-call loop through
  # OUR stack (harness → egress proxy → pinned provider → guardrailed ephemeral key). Rung 1 = the
  # trivial closed ride, cents on ANY model. The list is small (new base ∧ tools ∧ cheap); cap at
  # MAX_CANARIES so a rare flood doesn't run dozens of rides. Verdicts are CELL-KEYED — evidence
  # about (model, harness=opencode, class), never "the model" — and land in the router's rotation
  # store with source=canary (the same store the own-outcomes feed reads, §M7 leg 3). CANARY=0
  # restores v1 report-only.
  #
  # LEG 4 (§M7) — TYPED verdicts: each carries the launcher's error_class, never a bare `failed`
  # (2026-08-10: ling-3.0-flash, coding 50.6, posted `failed` on "echo the README heading"). Two
  # sanity rules:
  #   contradiction  canary-fail ∧ benchmark-capable ⇒ suspect-infra, retry once, else `inconclusive`
  #   common-cause   N canaries failing IDENTICALLY in one tick = ONE scout-infra datum, zero
  #                  per-model verdicts
  #
  # `scout_classify` maps an AGENT_RUN_STATS line to a TYPED verdict. The canary is an adhoc ride
  # (no PR expected), so `no-artifact` is the NORMAL successful end-state → `clean`; a `failed`
  # exit carries the launcher's error_class (never the bare word). Verdicts: clean | error_class |
  # harness-death | auth-storm | budget-403 | timeout | unknown | no-stats | mint-failed |
  # key-never-minted | suspect-infra | inconclusive — never `failed`.
  scout_classify() { # <stats-json-or-empty> → one typed verdict word
    local stats="$1" v
    [ -n "$stats" ] || { echo "no-stats"; return 0; }
    v="$(printf '%s' "$stats" | jq -r '
      (.exit_status // "") as $s
      | (.error_class // "") as $ec
      | if $s == "no-artifact" or $s == "clean" then "clean"
      elif $s == "failed" then
        # NEW: platform-artifacts (v2 runner death, zero spend, no model blame)
        # when error_class is "nonzero-exit-1" with no other context, classify as void
        # rather than leaking a bare generic exit code as model evidence.
        if $ec == "nonzero-exit-1" then "void"
        elif $ec != "" then $ec
        else "unknown" end
      elif $s == "" then (if $ec != "" then $ec else "unknown" end)
      elif (["harness-death","auth-storm","budget-403","timeout"] | index($s)) then $s
      else $s end' 2>/dev/null)" || v=""
    [ -n "$v" ] || v="unknown"
    printf '%s\n' "$v"
  }

  # Canary one candidate (FU-062/FU-024 + FU-161 legs 3–4). Mints an ephemeral key (seam), rides
  # the trivial closed task (seam), classifies the TYPED verdict, and applies the contradiction
  # rule. Echoes the verdict word to stdout; all logs go to stderr so stdout stays parseable.
  # Best-effort: any failure returns a marked verdict, never aborts the tick.
  canary_one() { # <id> <is_free> <benched> <harness> → one typed CELL verdict word
    # The cell = (model, harness). Inside it, ARMS: the CELL_PROVIDERS tokens (provider_slot
    # ints / slugs, ridden as the `@` suffix), or one default arm (the proxy's own M4 pin).
    # SCOUT_CELL_ATTEMPTS is the retry/RESELECT budget: a non-clean attempt moves to the NEXT
    # arm (#783 — never a blind same-pair retry), except the legacy single same-arm
    # bench-contradiction retry when no arm list is configured (cron behavior unchanged).
    # Every ATTEMPT writes its own row (model, harness, provider, attempt, verdict) — the
    # provider-attributable evidence the strike store cannot record yet.
    local id="$1" is_free="$2" benched="$3" harness="$4" gname cell_verdict="" v mrc attempt=0 arm
    local arms="${CELL_PROVIDERS:-}"
    [ -n "$arms" ] || arms="_default"
    if [ "$is_free" = "true" ]; then gname="only-free"; else gname="\$0.05 cap"; fi
    scout_canary_mint "$id" "$is_free" "$harness" || mrc=$?
    case "${mrc:-0}" in
      0) : ;;
      1) echo "mint-failed"; return 0 ;;
      2) echo "key-never-minted"; return 0 ;;
    esac
    for arm in $arms; do
      attempt=$((attempt+1))
      [ "$attempt" -le "${CELL_ATTEMPTS:-2}" ] || { log "canary: $id/$harness — attempts budget (${CELL_ATTEMPTS:-2}) spent"; break; }
      [ "$arm" = "_default" ] && arm=""
      log "canary: dispatching $id harness=$harness arm=${arm:-<proxy-pin>} attempt=$attempt (${gname})"
      v="$(scout_classify "$(scout_canary_ride "$id" "$arm" "$is_free" "$harness" "$attempt")")"
      jq -cn --arg m "$id" --arg h "$harness" --arg p "$arm" --arg v "$v" \
        --argjson a "$attempt" --argjson f "$([ "$is_free" = "true" ] && echo true || echo false)" \
        '{model:$m, harness:$h, provider:$p, attempt:$a, canary_verdict:$v, free:$f}' >> "$WORK/canary.jsonl"
      cell_verdict="$v"
      [ "$v" = "clean" ] && break
      # Legacy contradiction retry — only when no arm list gives the budget anything to reselect.
      if [ "${CELL_PROVIDERS:-}" = "" ] && [ "$v" != "void" ] && [ "$benched" = "true" ] && [ "$attempt" -lt "${CELL_ATTEMPTS:-2}" ]; then
        attempt=$((attempt+1))
        log "canary: $id/$harness — contradiction (bench-capable, rail ${v}) — one same-arm retry"
        v="$(scout_classify "$(scout_canary_ride "$id" "" "$is_free" "$harness" "$attempt")")"
        jq -cn --arg m "$id" --arg h "$harness" --arg p "" --arg v "$v" \
          --argjson a "$attempt" --argjson f "$([ "$is_free" = "true" ] && echo true || echo false)" \
          '{model:$m, harness:$h, provider:$p, attempt:$a, canary_verdict:$v, free:$f}' >> "$WORK/canary.jsonl"
        if [ "$v" = "clean" ]; then cell_verdict="clean"
        else cell_verdict="inconclusive"; log "canary: $id/$harness — retry ${v} — inconclusive"; fi
      fi
    done
    # A multi-arm walk that never went clean: bench-capable ⇒ inconclusive (the contradiction
    # rule, provider-generalized — the per-arm rows carry the typed detail); unbenched ⇒ the
    # last typed verdict stands.
    if [ "$cell_verdict" != "clean" ] && [ -n "${CELL_PROVIDERS:-}" ] && [ "$benched" = "true" ]; then
      cell_verdict="inconclusive"
    fi
    scout_canary_mint "$id" "$is_free" "$harness" cleanup || true
    printf '%s' "${cell_verdict:-no-stats}"
  }

  CANARY_BLOCK=""
  if [ "$CANARY" = "1" ]; then
    log "canary: riding up to ${MAX_CANARIES} candidate(s) in ns ${CANARY_PROJECT}"
    : > "$WORK/canary.jsonl"
    : > "$WORK/canary-cells.jsonl"
    jq -r --argjson n "$MAX_CANARIES" '.[0:$n][] | "\(.model) \(.free) \(.bench.benched)"' "$WORK/ranked.json" \
      | while read -r cid cfree cbenched; do
          for ch in ${CANARY_HARNESSES:-opencode}; do
            verdict="$(canary_one "$cid" "$cfree" "$cbenched" "$ch")"
            jq -cn --arg m "$cid" --arg h "$ch" --arg v "$verdict" --argjson f "$cfree" \
              '{model:$m, harness:$h, canary_verdict:$v, free:$f}' >> "$WORK/canary-cells.jsonl"
          done
        done
    # Common-cause (leg 4): the WHOLE tick's verdicts (≥2 of them) identical and non-clean ⇒ the
    # scout's own plumbing is the common factor, not the models — ONE scout-infra datum, zero
    # per-model verdicts. Deliberately whole-set, NOT any-subset (homelab#506 ruling, 2026-08-18):
    # a clean sibling REFUTES the scout-infra hypothesis by construction (the stack demonstrably
    # completed a loop), so a partial identical-failure group stays per-model and rides the
    # contradiction rule's retry instead. The founding case (#234) was all-canaries-bogus.
    COMMON_CAUSE="$(jq -s -r '
      map(.canary_verdict) as $v
      | if ($v | length) >= 2 and (all($v[]; . == $v[0])) and ($v[0] != "clean") then $v[0]
        else empty end' "$WORK/canary-cells.jsonl" 2>/dev/null || true)"
    if [ -n "$COMMON_CAUSE" ]; then
      log "canary: common cause — all canaried verdicts identical (${COMMON_CAUSE}) — ONE scout-infra datum, zero per-model verdicts (leg 4)"
      rotation_post "canary" "$(jq -cn --arg v "$COMMON_CAUSE" '{model:"_scout-infra", canary_verdict:$v}')" || true
      : > "$WORK/canary.jsonl"
      : > "$WORK/canary-cells.jsonl"
      CANARY_BLOCK=$'\n\n**Canary rides** (FU-062/FU-024/FU-161 — trivial closed rail ride, ephemeral capped key):\n\n*Common cause: every canaried verdict was identical (`'"${COMMON_CAUSE}"$'`) — ONE `_scout-infra` datum posted to the rotation store, zero per-model verdicts (leg 4). The rail, not the models, is the likely cause.*'
    else
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        # ADR-096: the verdict feed into the router's rotation store (TokenReview-gated; a miss
        # here only leaves the router's copy stale — the digest stays the human record).
        rotation_post "canary" "$entry" || true
      done < "$WORK/canary.jsonl"
    fi
    # Merge the typed verdicts into the ranked rows so the digest's canary column carries them
    # (uncanaried rows keep "—"). ranked.json is ONE array (slurp → [$r[0]]); canary.jsonl is a
    # STREAM of objects (slurp → $c is the array itself). temp+mv: the slurpfile must read the
    # pre-merge ranked.json.
    # The digest's canary column carries the CELL VECTOR (ADR-112): "opencode=clean goose=…".
    jq -n --slurpfile r "$WORK/ranked.json" --slurpfile c "$WORK/canary-cells.jsonl" '
      ($c | group_by(.model) | map({key: .[0].model,
            value: (map(.harness + "=" + .canary_verdict) | join(" "))}) | from_entries) as $cv
      | [ $r[0][] | . + {canary: ($cv[.model] // "")} ]' \
      > "$WORK/ranked.canary.json" && mv "$WORK/ranked.canary.json" "$WORK/ranked.json"
    if [ -s "$WORK/canary.jsonl" ]; then
      ROWS="$(jq -s -r '.[] | "| `" + .model + "` | " + .harness + " | "
        + (if .provider == "" then "proxy pin" else .provider end)
        + " | " + (.attempt | tostring) + " | " + .canary_verdict
        + (if .free then " (only-free)" else " ($0.05 cap)" end) + " |"' "$WORK/canary.jsonl")"
      CANARY_BLOCK=$'\n\n**Canary rides** (FU-062/FU-024/FU-161 + ADR-112 cells — one row per ATTEMPT: (model × harness × provider-arm); `proxy pin` = the M4 default, a named arm = the `@` provider_slot/slug pin with fallbacks OFF; `only-free` = proxy 403s any paid model pre-spend):\n\n| model | harness | provider arm | attempt | verdict |\n|---|---|---|---|---|\n'"$ROWS"$'\n\n*A TYPED verdict carries the launcher'"'"'s `error_class`, never a bare `failed`: `clean` = the model completed a real tool-calling ride on a budget-capped key; `auth-storm`/`timeout`/`harness-death`/`budget-403`/… = the rail or the key failed, typed; `suspect-infra`/`inconclusive` = a benchmark-capable model that fails the rail (contradiction rule, leg 4). A canary verdict is evidence for graduation, not automatic graduation. Full outcome + transcript in the ledger (model label).*'
    fi
  fi
  # <<<REPLAY:scout-canary<<<

  # >>>REPLAY:scout-digest>>>
  # 4. The digest issue — a report for a human, so the graduation decision has the numbers in it.
  #    Rendered from the RANKED list, in rank order: the table is also the order canary slots were
  #    spent in, and the suppressed set rides as one line under it (leg 1).
  #    FU-161 FILING GATE (homelab#877): a digest whose every row is unbenched AND uncanaried-with-evidence
  #    carries ZERO graduation evidence (no benchmark index, no typed canary verdict carrying model signal).
  #    Evidence verdicts: `clean` (model succeeded) or error_class values (model-specific errors).
  #    Non-evidence verdicts: `void`, `no-stats`, `unknown`, `mint-failed`, `key-never-minted`,
  #    `harness-death`, `auth-storm`, `budget-403`, `timeout`, `suspect-infra`, `inconclusive`
  #    (all platform/rail faults, not model outcomes). Such a tick posts to the scout log LOUDLY,
  #    and `gh issue create` is SKIPPED (the digests that filed nothing but zero-evidence — #874 is
  #    the live counterexample — are what this gate exists to stop). The snapshot still advances
  #    either way (point 5). Strategy (homelab#877): skip loudly, log withheld model ids so
  #    newcomers are recoverable from the tick's own output.
  BENCHED_N="$(jq '[.[] | select(.bench.benched)] | length' "$WORK/ranked.json")"
  # Evidence is judged per ATTEMPT row (a cell whose second arm went clean is evidence even
  # though its first arm died) — same non-evidence list, now against canary.jsonl.
  # ⚠ jq 1.6 on a MISSING input file prints a result AND exits non-zero, so `jq … || echo 0`
  # captures "0\n0" and inverts the gate (found by the bench fixtures, 2026-08-26) — existence
  # is tested first and the value is integer-normalized, never trusted.
  EVIDENCE_CANARIED_N=0
  if [ -s "$WORK/canary.jsonl" ]; then
    EVIDENCE_CANARIED_N="$(jq -s '[group_by(.model)[] | select(any(.[];
        (.canary_verdict != "void" and .canary_verdict != "no-stats" and .canary_verdict != "unknown"
         and .canary_verdict != "mint-failed" and .canary_verdict != "key-never-minted"
         and .canary_verdict != "harness-death" and .canary_verdict != "auth-storm"
         and .canary_verdict != "budget-403" and .canary_verdict != "timeout"
         and .canary_verdict != "suspect-infra" and .canary_verdict != "inconclusive")))] | length' \
      "$WORK/canary.jsonl" 2>/dev/null)" || EVIDENCE_CANARIED_N=0
    case "$EVIDENCE_CANARIED_N" in ''|*[!0-9]*) EVIDENCE_CANARIED_N=0;; esac
  fi
  if [ "$BENCHED_N" -eq 0 ] && [ "$EVIDENCE_CANARIED_N" -eq 0 ]; then
    # This branch means NOTHING carried evidence — list every ranked row with its cell vector
    # (the .canary field is the joined "harness=verdict" string since the ADR-112 cells).
    WITHHELD="$(jq -r '[.[] | .model + " (canary: " + (if (.canary // "") == "" then "none" else .canary end) + ")"] | join(", ")' "$WORK/ranked.json")"
    log "scout: digest SKIPPED — every row unbenched AND lacks evidence-bearing canary (FU-161 filing gate): ${WITHHELD} — gh issue create NOT run"
    log "scout: (unbenched models without benched baseline or evidence-bearing canary verdicts are not graduation candidates; see docs/agents/model-routing.md §M7 leg 4)"
  else
    TITLE="🔭 model scout: $(jq length "$WORK/ranked.json") new candidate model(s) ($(date -u +%F))"
    [ -n "${INTAKE:-}" ] && TITLE="🔭 model scout: operator intake — $(jq length "$WORK/ranked.json") model(s) ($(date -u +%F))"
    BODY="$(jq -r --arg ceiling "$CEILING" '
      "Weekly model scout (REPORT-ONLY, FU-062 / docs/agents/model-routing.md §M7): models whose BASE"
      + " id is NEW on OpenRouter since the last tick, advertise `tools`, and are `:free` or ≤ $" + $ceiling
      + "/M headline. Ranked free-first, then by AA agentic/coding — the order canary slots are spent in.\n\n"
      + "| # | model | AA int/code/agentic | effective $/M in | price note | pinned provider | uptime | providers | canary |\n"
      + "|---|---|---|---|---|---|---|---|---|\n"
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
          + " | " + ((.enr.provider_count // "—") | tostring) + " | "
          + (if (.canary // "") == "" then "—" else .canary end) + " |")
         | join("\n"))
      + "\n\n*effective $/M = cache-aware per-provider min at 80% cache hit (§M3); pinned provider ="
      + " the tools-capable session pin `--lookup` would choose (§M4). AA indices = MCP `get-model`"
      + " (§M7 leg 2); `unbenched` = not in the Artificial-Analysis feed, which is the normal state of"
      + " a genuine newcomer — the canary rung, not the benchmark, is what speaks for those. `canary` ="
      + " the rung-1 rail-probe verdict (§M7 leg 3), typed (`error_class` vocabulary); `—` = not"
      + " canaried this tick.*\n\n"
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
  fi
  # <<<REPLAY:scout-digest<<<
fi

# 5. Advance the snapshot (also when zero candidates — non-candidate newcomers are old news now).
#    NEVER in intake mode: intake is stateless by contract — advancing here would mark every
#    model current at intake time as "known" and silently swallow the next cron tick's real diff.
if [ -n "${INTAKE:-}" ]; then
  log "intake done — snapshot untouched (stateless by contract)"
  exit 0
fi
scout_state_write "$WORK/ids.json" || log "scout: snapshot write failed (non-fatal, next tick will retry)"
log "snapshot advanced (${CURRENT_N} known models); scout tick done"
