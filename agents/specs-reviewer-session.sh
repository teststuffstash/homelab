#!/usr/bin/env bash
# specs-reviewer-session — the SPECS REVIEWER's level-triggered tick (ADR-155; docs/agents/specs-reviewer.md).
#
# The second review identity: homelab-specs-reviewer[bot] gates spec ROWS and their evidence
# (`**/specs/**` + the head's CI evidence; brief = agents/lenses/specs.md), never code. GitHub
# counts approvals per identity and the island repo's master ruleset requires 2, so this verdict is
# the SECOND required approval — after the code reviewer's (homelab-reviewer) live APPROVED at head,
# never beside it. Runs INSIDE the `specs-review` CronWorkflow pod (agents/coordinator/
# specs-review-argo.yaml, the agent-coordinator image: Claude Code + the gh wrapper that prefers
# GH_TOKEN_FILE + jq/git/curl), from a fresh master clone of homelab, every 5 minutes.
#
# ONE LAYER, not reviewer-session.sh's launcher→pod shape, on purpose: that launcher exists to
# put the reviewer in a SCOPED pod of its own (per-PR identity labels, the subscription semaphore,
# the transcript uploader) because it reads hostile PR code in a repo it must not trust. This
# identity never reads code: its inputs are a diff of `**/specs/**`, a PR body and a CI log, and
# its LLM admission is the gateway's (`POST /sessions` bounds the rail — the semaphore the review
# workflow carries is the OLD proxy's capacity model). The sentinel's shape (scripts/iac-sentinel.sh
# in sentinel-argo.yaml) fits: one pod, one tick, holds no state, the mutex + activeDeadlineSeconds
# bound it, the next tick retries whatever this one left.
#
# WHAT A TICK DOES (every open, non-draft PR of $SPECS_REVIEW_REPOS; the content commit = newest
# NON-MERGE commit, the reviewer-session.sh / review-reflex.sh grammar — an update-branch merge is
# not new content):
#   skip     — our own LIVE verdict (APPROVED/CHANGES_REQUESTED, never DISMISSED) at the content
#              commit already exists; or no LIVE homelab-reviewer APPROVED at it (the operator's
#              "one old reviewer and THEN the new" — a ride is never spent on a PR the code reviewer
#              bounced; a Renovate PR gets that approval from the renovate-approve reflex, so this
#              holds for it too); or CI at head is not green; or label agent/error (touch nothing).
#   anomaly  — MORE THAN ONE live own verdict at the content commit: ONE comment starting
#              `AGENT_ERROR:` carrying a machine marker, no label (this identity has no
#              issues:write — the breaker label is the code reviewer's), idempotent per head.
#   mechanical — no `(^|/)specs/` path in the PR's files: `gh pr review --approve` with a fixed
#              body, no LLM. Many per tick, cheap — the price of GitHub's repo-wide count.
#   LLM pass — ONE per tick (the oldest candidate): admitted through the agent-gateway
#              `POST /sessions` seam (role `reviewer`, stack `platform`, harness `claude` — the
#              first real consumer, FU-270 dogfood); `decision: defer` = log + stop, the next tick
#              retries (never poll in-process); `dispatch` = the returned `env` map is exported
#              VERBATIM as the LLM env (GW-SESSIONS-ENV: nothing LLM-shaped is added) and the
#              session is ALWAYS released (`DELETE /sessions/{id}`, trap). Inputs = exactly the
#              lens's scope: specs.diff (merge-base..head, `**/specs/**` only), the PR body, the
#              specs trees at head (unchanged neighbours), the head's CI evidence (the ci run's
#              `evidence-render: BEGIN/END` block, counted only when its stamp names THIS head).
#              The lens is the WHOLE system prompt; a fetch failure is no review + exit 1 (a
#              blocking lens never degrades to advisory). The verdict is parsed from the model's
#              `Verdict:` line and SUBMITTED BY THIS SCRIPT — APPROVE → --approve,
#              CHANGES_REQUESTED → --request-changes, anything else = no terminal.
#   exit contract — every PR this tick posted on is re-read: a live own verdict at the content
#              commit must exist, else exit 10 (a silent green would mask a dead review plane).
#   metrics  — pushgateway job/specs-review: specs_review_last_tick_timestamp_seconds (the
#              SpecsReviewTickStale belt reads it), specs_review_shadow, specs_review_tick_verdicts
#              {kind} (the count THIS tick produced — a push REPLACES the group, so these are
#              per-tick gauges, not counters).
#
# SHADOW MODE: no token (the `specs-reviewer-git` Secret is `optional:true` in the CronWorkflow) =
# log "specs-reviewer-git absent — shadow, no verdicts", push the heartbeat, exit 0. It never
# reviews under another identity.
#
#   bash agents/specs-reviewer-session.sh              # one tick (the CronWorkflow's call)
#   bash agents/specs-reviewer-session.sh --self-test  # bash -n + the jq predicates on fixtures
#
# ⚠ Shell discipline (reviewer-session.sh's scars): assignment THEN export (set -u), no
# `$`-prefixed numbers in heredocs, PR bodies via --body-file, `gh` has no --arg.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
SPECS_REVIEW_REPOS="${SPECS_REVIEW_REPOS:-homelab}"      # the island repos; another island adds itself
SPECS_REVIEWER_LOGIN="homelab-specs-reviewer"           # literal, no [bot] suffix (gh api user 403s for an App token)
CODE_REVIEWER_LOGIN="${CODE_REVIEWER_LOGIN:-homelab-reviewer}"
GATEWAY_URL="${GATEWAY_URL:-http://agent-gateway.agent-egress.svc.cluster.local:8080}"
PUSHGATEWAY="${PUSHGATEWAY:-}"                           # empty = log-only
LENS_BASE="${LENS_BASE:-https://raw.githubusercontent.com/teststuffstash/homelab/master/agents/lenses}"
SPECS_PATH_RE='(^|/)specs/'
PR_LIST_LIMIT="${PR_LIST_LIMIT:-40}"                     # review-reflex.sh's ceiling: the rollup fragment is deep

log() { printf '%s specs-review: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ── the shared grammar (review-reflex.sh / reviewer-session.sh exit contract) ────────────────────
# One jq prelude every read below composes with. The content commit is the newest NON-MERGE commit
# (merge classified by GitHub's default message shapes — gh exposes no .parents[]); a review is at
# head when submitted at or after it (>=, the exit contract's filter); a bot login is matched with
# the `[bot]` suffix stripped (REST says `x[bot]`, GraphQL says `x`).
JQ_PRELUDE='
  def is_merge: (.messageHeadline // "") | (startswith("Merge branch ") or startswith("Merge remote-tracking branch ") or startswith("Merge pull request "));
  def content_ts: ([ .commits[]? | select(is_merge | not) | .committedDate ] | max) // "";
  def content_sha: ([ .commits[]? | select(is_merge | not) ] | sort_by(.committedDate) | last | .oid) // "";
  def login_of: (.author.login // "") | sub("\\[bot\\]$"; "");
  def live_verdicts($bot): content_ts as $h | [ .reviews[]? | select(login_of == $bot) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | select(.submittedAt >= $h) ];
  def green:
    ([ .statusCheckRollup[]? | (.conclusion // .state // "") ]) as $c
    | ($c | length) > 0 and ([ $c[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) == 0;
  def has_label($l): ([ .labels[]?.name ] | index($l)) != null;
'

# classify <pr-json> → one word: error-label | own-anomaly | own-at-head | code-not-approved | ci-not-green | candidate
classify() {
  jq -r --arg me "$SPECS_REVIEWER_LOGIN" --arg code "$CODE_REVIEWER_LOGIN" "$JQ_PRELUDE"'
    if has_label("agent/error") then "error-label"
    elif (live_verdicts($me) | length) > 1 then "own-anomaly"
    elif (live_verdicts($me) | length) == 1 then "own-at-head"
    elif ([ live_verdicts($code)[] | select(.state == "APPROVED") ] | length) == 0 then "code-not-approved"
    elif (green | not) then "ci-not-green"
    else "candidate" end' <<< "$1"
}

# ── --self-test: bash -n on this file + the predicates on fixtures ──────────────────────────────
# Expectations are derived from the CONTRACT (review-reflex.sh's filters, the exit contract), not
# from running the code: a DISMISSED review is not a verdict; a review older than the content commit
# is not at head; an update-branch merge newer than the content commit does not move the head;
# `homelab-reviewer[bot]` (REST spelling) matches `homelab-reviewer`; a rollup with one FAILURE is
# not green; an empty rollup is not green.
self_test() {
  local fails=0
  bash -n "$0" || { echo "self-test: bash -n FAILED"; return 1; }
  check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: expected '$2' got '$3'"; fails=$((fails+1)); fi
  }
  local base='{"labels":[],"commits":[{"oid":"aaaa1111","committedDate":"2026-10-16T10:00:00Z","messageHeadline":"fix: rows"},{"oid":"bbbb2222","committedDate":"2026-10-16T11:00:00Z","messageHeadline":"Merge branch master into fix/x"}],"statusCheckRollup":[{"name":"ci","conclusion":"SUCCESS"}],"reviews":[]}'
  local code_ok='{"author":{"login":"homelab-reviewer[bot]"},"state":"APPROVED","submittedAt":"2026-10-16T10:30:00Z"}'
  local code_old='{"author":{"login":"homelab-reviewer"},"state":"APPROVED","submittedAt":"2026-10-16T09:30:00Z"}'
  local own_ok='{"author":{"login":"homelab-specs-reviewer"},"state":"APPROVED","submittedAt":"2026-10-16T10:40:00Z"}'
  local own_dismissed='{"author":{"login":"homelab-specs-reviewer"},"state":"DISMISSED","submittedAt":"2026-10-16T10:40:00Z"}'
  local own_rc='{"author":{"login":"homelab-specs-reviewer[bot]"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-16T10:50:00Z"}'
  local j
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r' <<< "$base");                       check "code approved at head → candidate" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_old]" '.reviews=$r' <<< "$base");                      check "code approval older than content → code-not-approved" code-not-approved "$(classify "$j")"
  j=$(jq -c '.reviews=[]' <<< "$base");                                                 check "no code approval → code-not-approved" code-not-approved "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok]" '.reviews=$r' <<< "$base");               check "own live verdict at head → own-at-head" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_dismissed]" '.reviews=$r' <<< "$base");        check "own DISMISSED is not a verdict → candidate" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok,$own_rc]" '.reviews=$r' <<< "$base");       check "two own live verdicts → own-anomaly" own-anomaly "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"ci","conclusion":"FAILURE"},{"name":"x","conclusion":"SUCCESS"}]' <<< "$base"); check "one FAILURE → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[]' <<< "$base"); check "empty rollup → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .labels=[{"name":"agent/error"}]' <<< "$base"); check "agent/error → error-label (touch nothing)" error-label "$(classify "$j")"
  check "content sha skips the merge commit" aaaa1111 "$(jq -r "$JQ_PRELUDE"'content_sha' <<< "$base")"
  check "specs path predicate: gateway/specs/access.md" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'gateway/specs/access.md' >/dev/null; echo $?)"
  check "specs path predicate: specs/x.md at root" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'specs/x.md' >/dev/null; echo $?)"
  check "specs path predicate: docs/specs-reviewer.md is NOT a specs path" 1 "$(grep -cE "$SPECS_PATH_RE" <<< 'docs/agents/specs-reviewer.md' >/dev/null; echo $?)"
  check "verdict parse: APPROVE" APPROVE "$(parse_verdict "$(printf '## Specs review\nVerdict: APPROVE — no blocking check failed\nRows: …\n')")"
  check "verdict parse: CHANGES_REQUESTED" CHANGES_REQUESTED "$(parse_verdict "$(printf '## Specs review\nVerdict: CHANGES_REQUESTED — 1, 6\n')")"
  check "verdict parse: missing → empty" "" "$(parse_verdict "$(printf 'no verdict here\n')")"
  check "env key guard rejects a shell-hostile key" 1 "$(valid_env_key 'FOO=bar; rm' && echo 0 || echo 1)"
  check "env key guard accepts ANTHROPIC_MODEL" 0 "$(valid_env_key 'ANTHROPIC_MODEL' && echo 0 || echo 1)"
  [ "$fails" -eq 0 ] && { echo "self-test: ok"; return 0; }
  echo "self-test: $fails FAILED"; return 1
}

# parse_verdict <review-body> → APPROVE | CHANGES_REQUESTED | "" — the lens's `Verdict:` line, first match.
parse_verdict() {
  local line
  line="$(grep -m1 -E '^Verdict:[[:space:]]*(APPROVE|CHANGES_REQUESTED)\b' <<< "$1" || true)"
  case "$line" in
    *CHANGES_REQUESTED*) printf 'CHANGES_REQUESTED';;
    *APPROVE*) printf 'APPROVE';;
    *) printf '';;
  esac
}
valid_env_key() { [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi

# ── metrics ──────────────────────────────────────────────────────────────────────────────────────
METRICS=""
metric() { METRICS="${METRICS}$1"$'\n'; }
N_MECH=0; N_APPROVE=0; N_RC=0; N_DEFER=0; N_ERR=0
push_metrics() { # <shadow 0|1>
  metric "specs_review_last_tick_timestamp_seconds $(date +%s)"
  metric "specs_review_shadow $1"
  # every kind every tick, so a series never vanishes and an absent kind reads 0 (per-tick gauges)
  metric "specs_review_tick_verdicts{kind=\"mechanical\"} $N_MECH"
  metric "specs_review_tick_verdicts{kind=\"approve\"} $N_APPROVE"
  metric "specs_review_tick_verdicts{kind=\"request_changes\"} $N_RC"
  metric "specs_review_tick_verdicts{kind=\"defer\"} $N_DEFER"
  metric "specs_review_tick_verdicts{kind=\"error\"} $N_ERR"
  [ -n "$PUSHGATEWAY" ] || { log "metrics (no PUSHGATEWAY, log-only):"; printf '%s' "$METRICS"; return 0; }
  printf '%s' "$METRICS" | curl -fsS --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/specs-review" >/dev/null 2>&1 \
    || log "pushgateway push failed (metrics stay in logs)"
}

# ── token: the gh wrapper prefers GH_TOKEN_FILE (live, ESO re-mints ~hourly); git/curl need the value ──
token() {
  if [ -n "${GH_TOKEN_FILE:-}" ] && [ -s "$GH_TOKEN_FILE" ]; then cat "$GH_TOKEN_FILE"; else printf '%s' "${GH_TOKEN:-}"; fi
}
if [ -z "$(token)" ]; then
  log "specs-reviewer-git absent — shadow, no verdicts (the Secret is optional; cutover order in agents/coordinator/scaffold/specs-reviewer-git.yaml)"
  push_metrics 1
  exit 0
fi
_tok="$(token)"; export GH_TOKEN="$_tok"   # the shell's own gh calls + the wrapper's fallback

WORK="$(mktemp -d)"
SESSION_ID=""
cleanup() {
  if [ -n "$SESSION_ID" ]; then
    curl -fsS --max-time 10 -X DELETE "${GATEWAY_URL}/sessions/${SESSION_ID}" >/dev/null 2>&1 \
      && log "session ${SESSION_ID} released" || log "WARN session ${SESSION_ID} release failed (expires by TTL)"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

POSTED=""          # "repo#N repo#M …" — the exit contract re-reads these
LLM_CANDIDATES=""  # "createdAt repo N base headSha" lines, oldest first after sort

# review_submit <repo> <pr> <approve|request-changes> <body-file> → 0 on submit
review_submit() {
  gh pr review "$2" --repo "${ORG}/$1" "--$3" --body-file "$4"
}

# ── the per-PR walk ─────────────────────────────────────────────────────────────────────────────
for repo in $SPECS_REVIEW_REPOS; do
  if ! prs="$(gh pr list --repo "${ORG}/${repo}" --state open --limit "$PR_LIST_LIMIT" \
        --json number,isDraft,createdAt,baseRefName,headRefOid,labels,reviews,commits,statusCheckRollup,comments 2>"$WORK/list.err")"; then
    log "[$repo] PR list FAILED — $(head -c 300 "$WORK/list.err" | tr '\n' ' ') — skipping repo this tick"; N_ERR=$((N_ERR+1)); continue
  fi
  n_open="$(jq -r '[ .[] | select(.isDraft | not) ] | length' <<< "$prs")"
  log "[$repo] $n_open open non-draft PR(s)"
  while IFS= read -r pr_json; do
    [ -n "$pr_json" ] || continue
    num="$(jq -r '.number' <<< "$pr_json")"
    head="$(jq -r '.headRefOid' <<< "$pr_json")"
    content_sha="$(jq -r "$JQ_PRELUDE"'content_sha' <<< "$pr_json")"
    base="$(jq -r '.baseRefName' <<< "$pr_json")"
    created="$(jq -r '.createdAt' <<< "$pr_json")"
    cls="$(classify "$pr_json")"
    case "$cls" in
      error-label)       log "[$repo#$num] agent/error present — touching nothing"; continue;;
      own-at-head)       log "[$repo#$num] own live verdict at ${content_sha:0:8} — nothing to do"; continue;;
      code-not-approved) log "[$repo#$num] no live ${CODE_REVIEWER_LOGIN} APPROVED at ${content_sha:0:8} — the code gate goes first"; continue;;
      ci-not-green)      log "[$repo#$num] CI not green at ${head:0:8} — waiting"; continue;;
      own-anomaly)
        # the breaker: one AGENT_ERROR comment per content commit, keyed by a machine marker
        if jq -e --arg me "$SPECS_REVIEWER_LOGIN" --arg h "${content_sha:0:8}" "$JQ_PRELUDE"'
             [ .comments[]? | select(login_of == $me) | select(.body | contains("<!-- specs-review agent-error head=" + $h)) ] | length > 0' <<< "$pr_json" >/dev/null; then
          log "[$repo#$num] ANOMALY already reported at ${content_sha:0:8} — silent"; continue
        fi
        printf 'AGENT_ERROR: %s has MORE THAN ONE live verdict at content commit %s — a dispatcher loop, not iteration. No further specs verdicts on this head; a human or the coordinator dismisses the extra review (this identity has no issues:write, so no label). <!-- specs-review agent-error head=%s -->\n' \
          "$SPECS_REVIEWER_LOGIN" "${content_sha:0:8}" "${content_sha:0:8}" > "$WORK/anomaly.md"
        gh pr comment "$num" --repo "${ORG}/${repo}" --body-file "$WORK/anomaly.md" >/dev/null && log "[$repo#$num] ANOMALY reported (AGENT_ERROR comment)"
        N_ERR=$((N_ERR+1)); continue;;
      candidate) ;;
      *) log "[$repo#$num] classify returned '$cls' — refusing to act"; N_ERR=$((N_ERR+1)); continue;;
    esac
    # files: REST + --paginate (gh pr view --json files caps at 100 and a truncated list could
    # mis-classify a specs PR as mechanical)
    if ! files="$(gh api --paginate "repos/${ORG}/${repo}/pulls/${num}/files" --jq '.[].filename' 2>"$WORK/files.err")"; then
      log "[$repo#$num] files read FAILED — $(head -c 200 "$WORK/files.err" | tr '\n' ' ') — skipping this tick"; N_ERR=$((N_ERR+1)); continue
    fi
    if ! grep -qE "$SPECS_PATH_RE" <<< "$files"; then
      printf '## Specs review\nVerdict: APPROVE — mechanical: no `**/specs/**` path in this diff — nothing for the specs gate to read; approved mechanically (ADR-155, the repo-wide count). Head %s.\n' "${head:0:12}" > "$WORK/mech-$num.md"
      if review_submit "$repo" "$num" approve "$WORK/mech-$num.md"; then
        log "[$repo#$num] MECHANICAL approve at ${head:0:8} (no specs path)"; N_MECH=$((N_MECH+1)); POSTED="$POSTED $repo#$num"
      else
        log "[$repo#$num] mechanical approve FAILED"; N_ERR=$((N_ERR+1))
      fi
      continue
    fi
    LLM_CANDIDATES="${LLM_CANDIDATES}${created} ${repo} ${num} ${base} ${head}"$'\n'
  done < <(jq -c '.[] | select(.isDraft | not)' <<< "$prs")
done

# ── ONE LLM pass per tick: the oldest candidate ─────────────────────────────────────────────────
pick="$(printf '%s' "$LLM_CANDIDATES" | grep . | sort | sed -n 1p || true)"
LLM_RC=0
if [ -z "$pick" ]; then
  log "no specs PR awaiting the LLM pass this tick"
else
  read -r _created repo num base head <<< "$pick"
  n_cand="$(printf '%s' "$LLM_CANDIDATES" | grep -c . || true)"
  log "[$repo#$num] LLM pass (${n_cand} candidate(s); the rest wait for the next tick)"
  run_llm_pass() {
    local slug="${ORG}/${repo}" inputs="$WORK/inputs" lens="$WORK/lens.md" resp="$WORK/session.json"
    mkdir -p "$inputs"
    # 1) the lens IS the system prompt — a fetch failure is no review (blocking never degrades)
    if ! curl -fsS --max-time 15 "${LENS_BASE}/specs.md" -o "$lens" || ! grep -q '^# LENS: specs' "$lens"; then
      log "[$repo#$num] LENS FETCH FAILED (${LENS_BASE}/specs.md) — no review; a blocking lens never degrades to advisory"; return 1
    fi
    # 2) admission: POST /sessions (gateway/specs/endpoints/sessions.md, sessions.schema.json post.input)
    local body http
    body="$(jq -cn --arg task "specs-review ${repo}#${num}" '{stack:"platform", role:"reviewer", task:$task, round:0, harness:"claude"}')"
    http="$(curl -sS --max-time 20 -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' -X POST "${GATEWAY_URL}/sessions" -d "$body" || echo 000)"
    if [ "$http" != "200" ]; then
      log "[$repo#$num] POST /sessions HTTP ${http}: $(head -c 300 "$resp" 2>/dev/null | tr '\n' ' ')"; return 1
    fi
    local decision; decision="$(jq -r '.decision // ""' "$resp")"
    if [ "$decision" = "defer" ]; then
      log "[$repo#$num] gateway DEFER reason=$(jq -r '.reason' "$resp") retry_after_s=$(jq -r '.retry_after_s' "$resp") — the next tick retries"
      N_DEFER=$((N_DEFER+1)); return 0
    fi
    [ "$decision" = "dispatch" ] || { log "[$repo#$num] unknown decision '${decision}' from /sessions"; return 1; }
    SESSION_ID="$(jq -r '.session.id' "$resp")"
    log "[$repo#$num] DISPATCH session=${SESSION_ID} rail=$(jq -r '.rail' "$resp") model=$(jq -r '.model' "$resp") context_tokens=$(jq -r '.context_tokens' "$resp")"
    # 3) the env map, VERBATIM (GW-SESSIONS-ENV) — keys validated, values untouched, nothing added
    local k v; while IFS= read -r k && IFS= read -r v; do
      valid_env_key "$k" || { log "[$repo#$num] refusing env key '${k}' from the gateway"; return 1; }
      export "$k=$v"
    done < <(jq -r '.env | to_entries[] | .key, .value' "$resp")
    local model="${ANTHROPIC_MODEL:-}"
    [ -n "$model" ] || { log "[$repo#$num] dispatch env carries no ANTHROPIC_MODEL — cannot run claude"; return 1; }
    # 4) inputs — the lens's scope and nothing else (the LLM's cwd holds ONLY these)
    local ah="http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$(token)" | base64 | tr -d '\n')"
    git clone -q -c "$ah" --no-tags --single-branch -b "$base" "https://github.com/${slug}.git" "$WORK/repo"
    git -C "$WORK/repo" fetch -q origin "pull/${num}/head:pr-${num}"
    local fetched; fetched="$(git -C "$WORK/repo" rev-parse "pr-${num}")"
    if [ "$fetched" != "$head" ]; then log "[$repo#$num] head moved while fetching (${head:0:8} → ${fetched:0:8}) — the next tick reads the new head"; return 0; fi
    git -C "$WORK/repo" diff "origin/${base}...pr-${num}" -- ':(glob)**/specs/**' > "$inputs/specs.diff"
    git -C "$WORK/repo" diff --stat "origin/${base}...pr-${num}" > "$inputs/diffstat.txt"
    gh pr view "$num" --repo "$slug" --json title,body,url -q '"# " + .title + "\n\n" + .url + "\n\n" + (.body // "")' > "$inputs/pr-body.md"
    mkdir -p "$inputs/tree"
    local specdirs; specdirs="$(git -C "$WORK/repo" ls-tree -r --name-only "pr-${num}" | grep -E "$SPECS_PATH_RE" | sed -E 's#^((.*/)?specs)/.*#\1#' | sort -u || true)"
    if [ -n "$specdirs" ]; then
      # shellcheck disable=SC2086 — the dir list is word-split on purpose
      git -C "$WORK/repo" archive --format=tar "pr-${num}" -- $specdirs | tar -x -C "$inputs/tree"
    fi
    # 5) evidence — the head's ci run log, the evidence-render BEGIN/END block, stamp must name THIS head
    evidence_at_head "$slug" "$head" > "$inputs/evidence.md"
    # 6) the pass: lens = whole system prompt; cwd = inputs; read-only tools
    local otel="${OTEL_RESOURCE_ATTRIBUTES:-service.name=claude-code,role=specs-reviewer,stack=platform},project=${repo},pr=${num}"
    export OTEL_RESOURCE_ATTRIBUTES="$otel"
    local prompt
    prompt="You are the specs reviewer for pull request ${slug}#${num} (head ${head}). Your working directory holds your ONLY inputs: pr-body.md (title, URL, body — read Spec changes: and the closing issue reference), specs.diff (the **/specs/** diff from the merge-base to the head; empty means a specs path was touched but has no textual diff), diffstat.txt (file names only, for the removed-row check), tree/ (every specs/ tree at the head — the unchanged neighbours a row may reference), evidence.md (the head's CI evidence, or the words 'evidence: none at head'). Apply your brief's checks to every added, changed and removed row and write ONLY the review body in your brief's Output shape, starting with the line '## Specs review' and then the line 'Verdict: APPROVE — …' or 'Verdict: CHANGES_REQUESTED — <failing check numbers>'. Do not run commands, do not fetch anything, do not submit the review yourself — the launcher submits what you return."
    local rc=0
    (cd "$inputs" && claude -p "$prompt" --model "$model" --append-system-prompt-file "$lens" \
        --allowedTools "Read,Grep,Glob" --permission-mode default --output-format json > "$WORK/result.json") || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e . "$WORK/result.json" >/dev/null 2>&1; then
      log "[$repo#$num] claude exited ${rc} / no JSON result — no verdict"; return 1
    fi
    jq -r '"→ claude \(.subtype // "done"): in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0) cache_read=\(.usage.cache_read_input_tokens // 0) turns=\(.num_turns // 0) cost_usd=\(.total_cost_usd // 0)"' "$WORK/result.json"
    local review; review="$(jq -r '.result // ""' "$WORK/result.json")"
    # the body starts at the lens's heading; anything the model said before it is dropped
    review="$(awk '/^## Specs review/{f=1} f' <<< "$review")"
    local verdict; verdict="$(parse_verdict "$review")"
    printf '%s\n\n<!-- specs-review head=%s session=%s -->\n' "$review" "${head:0:12}" "$SESSION_ID" > "$WORK/review-$num.md"
    case "$verdict" in
      APPROVE)           review_submit "$repo" "$num" approve "$WORK/review-$num.md" && { log "[$repo#$num] APPROVE submitted"; N_APPROVE=$((N_APPROVE+1)); };;
      CHANGES_REQUESTED) review_submit "$repo" "$num" request-changes "$WORK/review-$num.md" && { log "[$repo#$num] CHANGES_REQUESTED submitted"; N_RC=$((N_RC+1)); };;
      *) log "[$repo#$num] no parsable Verdict: line in the model's result — no terminal (first 400 chars: $(head -c 400 <<< "$review" | tr '\n' ' '))"; return 1;;
    esac
    POSTED="$POSTED $repo#$num"
  }
  # evidence_at_head <slug> <head> → markdown on stdout (never fails the pass; absence is a statement)
  evidence_at_head() {
    local slug="$1" head="$2" run_id log_file block stamp
    run_id="$(gh run list --repo "$slug" --commit "$head" --workflow ci.yaml --status completed --json databaseId,conclusion --limit 3 \
               --jq '[ .[] | select(.conclusion == "success") ] | .[0].databaseId // empty' 2>/dev/null || true)"
    if [ -z "$run_id" ]; then printf 'evidence: none at head — no completed, successful `ci` run found for %s\n' "$head"; return 0; fi
    log_file="$WORK/run-$run_id.log"
    if ! gh run view "$run_id" --repo "$slug" --log > "$log_file" 2>/dev/null; then printf 'evidence: none at head — `gh run view %s --log` failed\n' "$run_id"; return 0; fi
    # `gh run view --log` lines are `<job>\t<step>\t<text>`; the render marks its block
    block="$(awk '/evidence-render: BEGIN/{f=1; next} /evidence-render: END/{f=0} f{ sub(/^[^\t]*\t[^\t]*\t/, ""); sub(/^[0-9T:.Z-]+ /, ""); print }' "$log_file" || true)"
    if [ -z "$block" ]; then printf 'evidence: none at head — ci run %s logged no `evidence-render: BEGIN/END` block (the gateway-ci step did not run on this head, or the image predates the stdout render)\n' "$run_id"; return 0; fi
    stamp="$(grep -m1 -oE 'git [0-9a-f]{12}' <<< "$block" || true)"
    if [ "$stamp" != "git ${head:0:12}" ]; then
      printf 'evidence: none at head — ci run %s rendered evidence stamped `%s`, which does not name this head (%s)\n' "$run_id" "${stamp:-<no stamp>}" "${head:0:12}"; return 0
    fi
    printf 'evidence: ci run %s, stamped at THIS head (%s)\n\n%s\n' "$run_id" "${head:0:12}" "$block"
  }
  run_llm_pass || LLM_RC=$?
  [ "$LLM_RC" -eq 0 ] || N_ERR=$((N_ERR+1))
fi

# ── exit contract: every PR we posted on carries a live own verdict at its content commit ──────
TERMINAL_OK=1
for ref in $POSTED; do
  repo="${ref%%#*}"; num="${ref##*#}"
  if ! state="$(gh pr view "$num" --repo "${ORG}/${repo}" --json reviews,commits 2>/dev/null)"; then
    log "exit-contract: [$ref] re-read FAILED — cannot prove a terminal; failing closed"; TERMINAL_OK=0; continue
  fi
  n="$(jq -r --arg me "$SPECS_REVIEWER_LOGIN" "$JQ_PRELUDE"'live_verdicts($me) | length' <<< "$state")"
  if [ "${n:-0}" -ge 1 ]; then log "exit-contract: [$ref] terminal OK — live ${SPECS_REVIEWER_LOGIN} verdict at head"
  else log "exit-contract: [$ref] NO TERMINAL — a verdict was submitted but no live own verdict reads back at the content commit"; TERMINAL_OK=0; fi
done

push_metrics 0
log "tick done: mechanical=$N_MECH approve=$N_APPROVE request_changes=$N_RC defer=$N_DEFER error=$N_ERR"
if [ "$TERMINAL_OK" -ne 1 ]; then exit 10; fi
exit "$LLM_RC"
