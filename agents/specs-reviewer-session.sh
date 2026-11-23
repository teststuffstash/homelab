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
#              commit already exists — unless it is CHANGES_REQUESTED and the PR body was edited
#              after it (the body-edit leg, review-reflex.sh's reviewable_again shape; lastEditedAt
#              via agents/pr-last-edited.sh); or no LIVE homelab-reviewer APPROVED at it (the operator's
#              "one old reviewer and THEN the new" — a ride is never spent on a PR the code reviewer
#              bounced; a Renovate PR gets that approval from the renovate-approve reflex, so this
#              holds for it too); or CI at head is not green; or label agent/error (touch nothing).
#   anomaly  — MORE THAN ONE live own verdict at the content commit: ONE comment starting
#              `AGENT_ERROR:` carrying a machine marker, no label (this identity has no
#              issues:write — the breaker label is the code reviewer's), idempotent per head.
#   mechanical — no specs path and no rule-test path (`review_path_re`) in the PR's files, or the
#              pass's touched-rules finds no rule: an approval with a fixed body, no LLM. Many per
#              tick, cheap — the price of GitHub's repo-wide count.
#   partial  — the model's `Verdict: PARTIAL READ — <files>` (the lens: a verdict claims the touched
#              contract was read in full): NO review is posted; ONE comment starting `PARTIAL READ:`
#              carrying a machine marker holds the content commit (classify → partial-held until a
#              push), metric kind=partial (the SpecsReviewPartialRead belt). The lever is the pack's
#              size, never a worker round — a worker cannot fix the reviewer's read.
#   LLM pass — ONE per tick (the oldest candidate): admitted through the agent-gateway
#              `POST /sessions` seam (role `reviewer`, stack `platform`, harness `claude` — the
#              first real consumer, FU-270 dogfood), authenticated as this pod's ServiceAccount
#              (GW-SESSIONS-AUTH: the projected `gateway-token`, `gw_curl`); `decision: defer` = log + stop, the next tick
#              retries (never poll in-process); `dispatch` = the returned `env` map is exported
#              VERBATIM as the LLM env (GW-SESSIONS-ENV: nothing LLM-shaped is added) and the
#              session is ALWAYS released (`DELETE /sessions/{id}`, trap). Inputs = the CONTEXT PACK
#              (ADR-156), ONE per touched spec root pair (touched_pairs: the claim's `specs` +
#              `extraSpecs`; a PR touching several roots gets one pass per root, one per tick,
#              each held as a SPECS ROOT REVIEW comment, and ONE verdict — aggregate_review),
#              built BEFORE admission by the pinned allure-behavior-snippets wheel
#              (`evidence-pack`, digest-checked): touched rules + their sections + the spec diff, the
#              specs tree (the diff base: pack_diff_base), the head's raw Allure results (the pack ci publishes to the bucket) with
#              evidence.json + digest.md + attachments, the base branch's evidence as baseline, the
#              PR body, the closing issue's acceptance text, the previous review, and process/ (the
#              pinned RULES, CONVENTIONS and briefs). When the pinned pack offers --mask-descriptions the pass is the
#              STAGED READ (review_run): pass 1 over the manifest's masked allow-list only, frozen
#              as pass1.md, then pass 2 (the review) over the full pack — one admission, one
#              LLM_TIMEOUT_S for both. A failed clone/wheel/pack is no review (fail
#              CLOSED); absent EVIDENCE is stated in the pack and becomes the brief's finding. The model is CONFINED: `env -i` with exactly the dispatch env + OTEL + a
#              throwaway HOME (never GH_TOKEN/GH_TOKEN_FILE), and an allow-listed tool scope —
#              `Read(//<inputs>/**)` + Glob, nothing else — so the token file, /proc and $HOME
#              are unreadable (a prompt-injected "quote X" from authored text has nothing to
#              reach). The system prompt is homelab's wiring lens + the pinned finding contract, rows
#              and evidence briefs; a lens fetch failure is no review + exit 1
#              (a blocking lens never degrades to advisory). The verdict is parsed from the model's
#              `Verdict:` line and SUBMITTED BY THIS SCRIPT, PINNED to the reviewed head (the head
#              is re-read right before the submit — moved = verdict dropped, next tick — and the
#              REST review carries `commit_id`): APPROVE → event APPROVE, CHANGES_REQUESTED →
#              REQUEST_CHANGES, anything else = no terminal.
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
# SHADOW RUN (`--shadow`, gateway/PLAN.md step 3 — the harness × rail cell experiments; NOT the
# tokenless shadow above): one explicit `harness` (+ optional `rail` / `tier` / `role`, all
# `POST /sessions` inputs) over an explicit PR list, each `<repo>#<n>[@<head sha>]` — the head the
# live reviewer judged. It builds the SAME context pack (build_pack, the live pass's builder), runs
# the SAME brief and prompt, and WRITES the verdict + findings + the gateway session row to files
# under --out (the specs-review-shadow WorkflowTemplate uploads them as an Argo artifact). It NEVER
# writes to GitHub: `gh` is wrapped by a read-only allow-list (gh_shadow_allows — a write is refused
# rc 97 before it reaches the CLI; pinned by --self-test), and it pushes no metrics. Replay
# fidelity: a judged head is fetched by sha; the base is merge-base(origin/<base>, head); the PR
# body is the edit current at the live review's time (`as_of` = the first own review AT that head,
# else now); the prior review is the newest own LLM review before `as_of`; the baseline is the
# newest first-parent commit of the pack's base with a bucket pack. Issue intent, the lens and
# the pinned wheel are TODAY's (stated in each record).
#
#   bash agents/specs-reviewer-session.sh              # one tick (the CronWorkflow's call)
#   bash agents/specs-reviewer-session.sh --self-test  # bash -n + the jq predicates on fixtures
#   bash agents/specs-reviewer-session.sh --shadow --harness claude|opencode|goose [--rail R] \
#        [--tier T] [--role reviewer] [--out DIR] homelab#2640@<sha> …   # a shadow cell run
#
# ⚠ Shell discipline (reviewer-session.sh's scars): assignment THEN export (set -u), no
# `$`-prefixed numbers in heredocs, PR bodies via --body-file, `gh` has no --arg.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/pr-last-edited.sh"   # pr_last_edited_merge — the body-edit leg of the skip (own CHANGES_REQUESTED only)

ORG="${ORG:-teststuffstash}"
SPECS_REVIEW_REPOS="${SPECS_REVIEW_REPOS:-homelab}"      # the island repos; another island adds itself
SPECS_REVIEWER_LOGIN="homelab-specs-reviewer"           # literal, no [bot] suffix (gh api user 403s for an App token)
CODE_REVIEWER_LOGIN="${CODE_REVIEWER_LOGIN:-homelab-reviewer}"
GATEWAY_URL="${GATEWAY_URL:-http://agent-gateway.agent-egress.svc.cluster.local:8080}"
# The control-plane caller token (GW-SESSIONS-AUTH, FU-270): the pod's projected ServiceAccount
# token, audience agent-gateway (specs-review-argo.yaml's `gateway-token` volume) — re-read per call,
# kubelet rotates it. Absent = the call goes without one: admitted and COUNTED while the gateway
# `observe`s, refused once it `enforce`s, so the absence is logged loudly (stderr), never silent.
GATEWAY_TOKEN_FILE="${GATEWAY_TOKEN_FILE:-/var/run/secrets/agent-gateway/token}"
# gw_curl <curl args…> — curl to the gateway's control plane carrying the caller header via
# `-H @<fd>` (the token never rides argv, which `ps` shows to every process in the pod).
gw_curl() {
  if [ -s "$GATEWAY_TOKEN_FILE" ]; then
    curl -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$GATEWAY_TOKEN_FILE")") "$@"
  else
    log "WARN no gateway caller token at ${GATEWAY_TOKEN_FILE} — this /sessions call is unauthenticated (GW-SESSIONS-AUTH: counted under observe, refused under enforce)" >&2
    curl "$@"
  fi
}
# The failure-ownership contract (GW-SESSIONS-OUTCOME, GW-SESSIONS-ADMIT §The retry contract):
# the pass classifies its OWN ride and reports it before the release; a strike re-admits at the SAME
# round with attempt + 1 — at most SPECS_REVIEW_AUTO_ATTEMPTS automatic re-admissions, and only while
# the tick's wall budget still holds a whole LLM_TIMEOUT_S pass (the workflow's 900 s deadline).
SPECS_REVIEW_AUTO_ATTEMPTS="${SPECS_REVIEW_AUTO_ATTEMPTS:-2}"
SPECS_REVIEW_BUDGET_S="${SPECS_REVIEW_BUDGET_S:-840}"     # the tick's wall budget, < the 900 s activeDeadlineSeconds
# outcome_class <harness rc> <result is JSON: 1|0> <parsed verdict> — the ride's class in the
# gateway's ONE vocabulary (sessions.schema.json outcome.class). A logic verdict (APPROVE or
# CHANGES_REQUESTED alike) is `clean`: the ride did its job — rounds are not strikes.
outcome_class() {
  if [ "$1" = 124 ]; then echo timeout
  elif [ "$1" != 0 ] || [ "$2" != 1 ]; then echo harness-death
  elif [ -z "$3" ]; then echo no-verdict
  else echo clean; fi
}
# gw_outcome <session id> <class> <subclass> — POST /sessions/{id}/outcome; prints the strike's
# class when the gateway counted one (else nothing). Non-fatal: a failed report is logged, and the
# session's release still happens (the gateway's own transport strikes stand either way).
gw_outcome() {
  local r
  r="$(gw_curl -fsS --max-time 10 -H 'Content-Type: application/json' -X POST "${GATEWAY_URL}/sessions/$1/outcome" \
        -d "$(jq -cn --arg c "$2" --arg s "$3" '{class: $c, subclass: $s}')" 2>/dev/null)" \
    || { log "WARN outcome report for session $1 ($2) FAILED — not counted" >&2; return 0; }
  jq -r '.strike.class // empty' <<< "$r" 2>/dev/null || true
}
PUSHGATEWAY="${PUSHGATEWAY:-}"                           # empty = log-only
LENS_BASE="${LENS_BASE:-https://raw.githubusercontent.com/teststuffstash/homelab/master/agents/lenses}"
SPECS_PATH_RE='(^|/)specs/'
# ── the pinned process (ADR-156): briefs + RULES/CONVENTIONS + touched-rules + the pack builder
# ship in ONE wheel, verified by digest and run with the image's stdlib python3 (pack, evidence and
# touched_rules import nothing outside the stdlib; the wheel is extracted, not zip-imported, because
# the pack copies process/ from package files).
SNIPPETS_VERSION="0.6.9"   # bump TOGETHER with gateway/scripts/lib/snippets.sh (CI evidence)
SNIPPETS_WHEEL="https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v${SNIPPETS_VERSION}/allure_behavior_snippets-${SNIPPETS_VERSION}-py3-none-any.whl"
SNIPPETS_SHA256="4ca24515835b0969a6b225eef6e48a2d6337ec984367e74b0b4a1dc9def6ef16"
# The evidence packs live in OUR storage since 2026-10-21 (the Actions artifact held ~2.1 GB of the
# org's 2 GB included storage — GithubStorageHeldHigh): CI writes evidence/<pr-N|branch>/<sha>.tar.gz
# into the repo's specs bucket (gateway/scripts/evidence-publish.sh), read here ANONYMOUSLY through
# Garage's web endpoint (Host = <bucket>.teststuff.net; the bucket is website-enabled, egress-cnp.yaml
# already admits ns garage). No reader key, no GitHub API call.
EVIDENCE_WEB="${EVIDENCE_WEB:-http://garage-s3.garage.svc.cluster.local:3902}"
# evidence_bucket <repo> → the website bucket its CI publishes packs to ("" = none: no evidence)
evidence_bucket() { case "$1" in homelab) printf 'gateway-specs';; oracle-fleet) printf 'oracle-specs';; esac; }
# pack_roots <repo> → "<specs-root> <tests-root>": where that repo's rules and their tests live.
# The CLAIM's `repos[].specs` {root, tests} when the AgentStack read serves one — the same field
# the worker launcher mounts the pinned process by (agent-session.sh REPLAY:specs-process-volume),
# so the ride, the trigger (review_path_re) and the pack read ONE home for a repo's roots. The
# per-repo case stays as the fallback: a repo whose claim has no field yet, and every run without
# a cluster (the jail, --self-test, CI). ONE read per tick (CLAIMS_JSON; a pre-set value is the
# self-test's seam); a failed read is said once, then the table answers — never a missing pack.
CLAIMS_JSON="${CLAIMS_JSON:-}"       # "" = not read yet; "null" = read failed (fallback table in force)
# claims_load — the one read. The tick and the shadow run call it in the MAIN shell before any
# `$( )` reader: an assignment inside a command substitution dies with the subshell, so a reader
# that loaded lazily would re-read the cluster on every call.
claims_load() {
  if [ -z "$CLAIMS_JSON" ]; then
    CLAIMS_JSON="$(kubectl get agentstacks.platform.teststuff.net -o json 2>/dev/null)" || CLAIMS_JSON="null"
    [ -n "$CLAIMS_JSON" ] || CLAIMS_JSON="null"
    # stderr: pack_roots is read inside `$( )` — a log line on stdout would BECOME the roots.
    [ "$CLAIMS_JSON" != null ] || log "WARN agentstacks read failed (no kubectl, no RBAC, no cluster) — pack roots come from the per-repo fallback table this tick" >&2
  fi
  return 0
}
claim_specs() {  # <repo> → "<root> <tests>" from its claim, or "" (no claim / no field / malformed)
  claims_load
  jq -r --arg p "$1" '[.items[]?.spec.repos[]? | select(.name == $p) | .specs | select(type == "object")
    | select((.root|type) == "string" and (.tests|type) == "string" and (.root|length) > 0 and (.tests|length) > 0)
    | "\(.root) \(.tests)"] | first // empty' <<< "$CLAIMS_JSON" 2>/dev/null || true
}
pack_roots() {
  local c; c="$(claim_specs "$1")"
  if [ -n "$c" ]; then printf '%s' "$c"; else case "$1" in homelab) printf 'gateway/specs gateway/tests';; *) printf 'specs tests';; esac; fi
}
# claim_specs_extra <repo> → one "<root> <tests|->" line per well-formed item of the claim's
# `repos[].extraSpecs` — the repo's FURTHER spec roots (a monorepo of islands: homelab's gateway
# owns `specs`, each island adds its own). `tests` is optional there: "-" = the root declares no
# tests root (and so no evidence pipeline). A malformed item is skipped, never fatal.
claim_specs_extra() {
  claims_load
  jq -r --arg p "$1" '.items[]?.spec.repos[]? | select(.name == $p) | .extraSpecs | select(type == "array") | .[]
    | select(type == "object") | select((.root|type) == "string" and (.root|length) > 0)
    | select(.tests == null or ((.tests|type) == "string" and (.tests|length) > 0))
    | "\(.root) \(.tests // "-")"' <<< "$CLAIMS_JSON" 2>/dev/null || true
}
# pack_root_pairs <repo> → every spec root pair of the repo, one "<root> <tests|->" line each:
# pack_roots's pair FIRST (the repo's primary root — the one its evidence bucket belongs to), then
# the claim's extraSpecs in claim order; a root named twice keeps its first line.
pack_root_pairs() {
  { local s t; read -r s t <<< "$(pack_roots "$1")"; printf '%s %s\n' "$s" "$t"; claim_specs_extra "$1"; } | awk 'NF == 2 && !seen[$1]++'
}
re_lit() { sed 's/[.]/\\./g' <<< "$1"; }   # a root as an ERE literal (roots admit `.`)
# review_path_re <repo> → the file-list trigger for the LLM pass: a specs path, or the repo's
# rule-test root (a changed test label reaches a rule without touching specs — touched-rules
# decides inside the pass; zero touched rules = the mechanical approval after all), or any extra
# root / its tests root (an extra root need not be named `specs`). One pair = the old expression.
review_path_re() {
  local _s t r x re; read -r _s t <<< "$(pack_roots "$1")"; re="$(printf '%s|^%s/' "$SPECS_PATH_RE" "$t")"
  while read -r r x; do
    [ -n "$r" ] || continue
    re="${re}|^$(re_lit "$r")/"; [ "$x" = - ] || re="${re}|^$(re_lit "$x")/"
  done < <(claim_specs_extra "$1")
  printf '%s' "$re"
}
# touched_pairs <repo> <files (one per line)> → the root pairs whose root/ or tests/ holds a
# changed file, in pack_root_pairs order; none → the primary pair alone (a stray `specs/` path
# outside every root: the pack over the primary root finds no rule → the mechanical approval,
# exactly the one-pair behaviour).
touched_pairs() {
  local r t hit=""
  while read -r r t; do
    [ -n "$r" ] || continue
    if grep -qE "^$(re_lit "$r")/" <<< "$2" || { [ "$t" != - ] && grep -qE "^$(re_lit "$t")/" <<< "$2"; }; then
      hit="${hit}${r} ${t}"$'\n'
    fi
  done < <(pack_root_pairs "$1")
  if [ -n "$hit" ]; then printf '%s' "$hit"; else printf '%s\n' "$(pack_roots "$1")"; fi
}
PR_LIST_LIMIT="${PR_LIST_LIMIT:-40}"                     # review-reflex.sh's ceiling: the rollup fragment is deep
LLM_TIMEOUT_S="${LLM_TIMEOUT_S:-600}"                    # the model's wall clock; < the 900 s pod deadline minus clone + submit
# THE STAGED READ (the rows brief's check 10 as two passes of one session): pass 1 reads the pack's
# MASKED surface (every description cell → its row key r<table>.<row>) and its findings are frozen
# as pass1.md; pass 2 is the review over the full pack + pass1.md + the key map, and carries the
# verdict. On whenever the pinned wheel's evidence-pack offers --mask-descriptions (a capability
# probe, so the pin bump IS the switch); 0 = the single pass. Both passes share LLM_TIMEOUT_S.
SPECS_STAGED_READ="${SPECS_STAGED_READ:-1}"
PASS1_TIMEOUT_S="${PASS1_TIMEOUT_S:-200}"                # pass 1's share; pass 2 gets what is left
STAGED=0                                                 # set per pass by build_pack
PACK_NOTE=""                                             # set per pass by build_pack: "" = the primary root

log() { printf '%s specs-review: %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ── the shared grammar (review-reflex.sh / reviewer-session.sh exit contract) ────────────────────
# One jq prelude every read below composes with. The content commit is the newest NON-MERGE commit
# (merge classified by GitHub's default message shapes — gh exposes no .parents[]); a review is at
# head when submitted at or after it (>=, the exit contract's filter) AND filed on the content commit
# or a later one (reviewed_current) — a review filed on an OLDER commit but submitted after a push
# (homelab#3444: read 536ed6a0, submitted 19 s after 75aaa056 landed) is about a head nobody read;
# a review with no commit field keeps the time test alone. A bot login is matched with the `[bot]`
# suffix stripped (REST says `x[bot]`, GraphQL says `x`).
# >>>REPLAY:specs-reviewable-again>>>
JQ_PRELUDE='
  def is_merge: (.messageHeadline // "") | (startswith("Merge branch ") or startswith("Merge remote-tracking branch ") or startswith("Merge pull request "));
  def content_ts: ([ .commits[]? | select(is_merge | not) | .committedDate ] | max) // "";
  def content_sha: ([ .commits[]? | select(is_merge | not) ] | sort_by(.committedDate) | last | .oid) // "";
  def login_of: (.author.login // "") | sub("\\[bot\\]$"; "");
  def reviewed_current($cs; $h): (.commit.oid // "") as $c | $c == "" or (([ $cs[] | select(.oid == $c) | .committedDate ] | max // "") >= $h);
  def live_verdicts($bot): content_ts as $h | (.commits // []) as $cs | [ .reviews[]? | select(login_of == $bot) | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | select(.submittedAt >= $h) | select(reviewed_current($cs; $h)) ];
  def green:
    ([ .statusCheckRollup[]? | {n: (.name // .context // ""), c: (.conclusion // .state // "")} ]) as $c
    # A CANCELLED run counts only when NO other run of the same check concluded: concurrency
    # cancels superseded runs (renovate-approve, 4× on #2636) and those rows stay in the rollup
    # beside the run that replaced them — read as red they wedge the PR forever.
    | ($c | length) > 0
      and ([ $c | group_by(.n)[] | [ .[].c | select(. != "CANCELLED") ] as $k
             | select(($k | length) == 0 or ([ $k[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) > 0) ] | length) == 0;
  def has_label($l): ([ .labels[]?.name ] | index($l)) != null;
  # THE BODY-EDIT LEG of reviewable_again (agents/review-reflex.sh: the code reviewer rule, same shape): a
  # CHANGES_REQUESTED verdict is answered by a newer content commit OR a newer PR-body edit; an
  # APPROVED one never re-opens on an edit. .lastEditedAt is merged in by agents/pr-last-edited.sh
  # for the PRs under an own live CHANGES_REQUESTED ("" = never edited); ABSENT = not read (the
  # read failed, or no own CHANGES_REQUESTED) — then nothing re-opens (the commit-time rule alone)
  # and an earlier own CHANGES_REQUESTED is not judged a loop.
  def own_live($me): live_verdicts($me) | sort_by(.submittedAt);
  def own_reopened($me): (own_live($me) | last) as $n
    | $n != null and $n.state == "CHANGES_REQUESTED" and ((.lastEditedAt // "") > $n.submittedAt);
  # an own live verdict superseded at the same content commit WITHOUT an answering body edit — the
  # dispatcher loop: an earlier APPROVED (never re-reviewed), or an earlier CHANGES_REQUESTED the
  # body was not edited after (judged only when .lastEditedAt was read).
  def own_unanswered($me): has("lastEditedAt") as $known | (.lastEditedAt // "") as $le
    | [ own_live($me) | .[0:-1][] | select(.state == "APPROVED" or ($known and $le <= .submittedAt)) ];
'

# own_cr_numbers <prs-json-array> → the PR numbers under a live own CHANGES_REQUESTED at the content
# commit: the only PRs whose body edit can re-open this reviewer (the set pr_last_edited_merge reads)
own_cr_numbers() {
  jq -r --arg me "$SPECS_REVIEWER_LOGIN" "$JQ_PRELUDE"'
    .[]? | select(.isDraft | not) | select([ live_verdicts($me)[] | select(.state == "CHANGES_REQUESTED") ] | length > 0) | .number' <<< "$1"
}

# classify <pr-json> → one word: error-label | own-anomaly | own-at-head | partial-held | code-not-approved | ci-not-green | candidate
classify() {
  jq -r --arg me "$SPECS_REVIEWER_LOGIN" --arg code "$CODE_REVIEWER_LOGIN" "$JQ_PRELUDE"'
    if has_label("agent/error") then "error-label"
    elif (own_unanswered($me) | length) > 0 then "own-anomaly"
    elif (live_verdicts($me) | length) > 0 and (own_reopened($me) | not) then "own-at-head"
    elif (content_sha | .[0:8]) as $h | ([ .comments[]? | select(login_of == $me) | select(.body | contains("<!-- specs-review partial-read head=" + $h)) ] | length) > 0 then "partial-held"
    elif ([ live_verdicts($code)[] | select(.state == "APPROVED") ] | length) == 0 then "code-not-approved"
    elif (green | not) then "ci-not-green"
    else "candidate" end' <<< "$1"
}
# <<<REPLAY:specs-reviewable-again<<<

# ── --self-test: bash -n on this file + the predicates on fixtures ──────────────────────────────
# Expectations are derived from the CONTRACT (review-reflex.sh's filters, the exit contract), not
# from running the code: a DISMISSED review is not a verdict; a review older than the content commit
# is not at head; an update-branch merge newer than the content commit does not move the head;
# `homelab-reviewer[bot]` (REST spelling) matches `homelab-reviewer`; a rollup with one FAILURE is
# not green; an empty rollup is not green.
self_test() {
  local fails=0
  bash -n "$0" || { echo "self-test: bash -n FAILED"; return 1; }
  CLAIMS_JSON=null   # hermetic: the self-test never reads a cluster — pack_roots answers from the table until the seam below
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
  # homelab#3444: the approval was SUBMITTED after the content commit (10:30 ≥ 10:00) but FILED on an
  # older commit (00000000…, the head the session read) → about an unread head → not the code gate.
  # Filed on the content commit, or on the later update-branch merge (GitHub re-points a review
  # across one), it is live; a commit gone from the PR (force-push) is not.
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .reviews[0].commit={oid:"0000aaaa"} | .commits=[{"oid":"0000aaaa","committedDate":"2026-10-16T09:00:00Z","messageHeadline":"fix: first"}] + .commits' <<< "$base"); check "code approval submitted after the push but filed on the older commit → code-not-approved (#3444)" code-not-approved "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .reviews[0].commit={oid:"aaaa1111"}' <<< "$base"); check "code approval filed on the content commit → candidate" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .reviews[0].commit={oid:"bbbb2222"} | .reviews[0].submittedAt="2026-10-16T11:30:00Z"' <<< "$base"); check "code approval filed on the later update-branch merge → candidate" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .reviews[0].commit={oid:"dead0000"}' <<< "$base"); check "code approval filed on a commit gone from the PR → code-not-approved" code-not-approved "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok]" '.reviews=$r | .reviews[1].commit={oid:"0000aaaa"} | .commits=[{"oid":"0000aaaa","committedDate":"2026-10-16T09:00:00Z","messageHeadline":"fix: first"}] + .commits' <<< "$base"); check "own verdict filed on an older commit is not own-at-head → candidate" candidate "$(classify "$j")"
  j=$(jq -c '.reviews=[]' <<< "$base");                                                 check "no code approval → code-not-approved" code-not-approved "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok]" '.reviews=$r' <<< "$base");               check "own live verdict at head → own-at-head" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_dismissed]" '.reviews=$r' <<< "$base");        check "own DISMISSED is not a verdict → candidate" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok,$own_rc]" '.reviews=$r' <<< "$base");       check "two own live verdicts → own-anomaly" own-anomaly "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .comments=[{"author":{"login":"homelab-specs-reviewer[bot]"},"body":"PARTIAL READ: … <!-- specs-review partial-read head=aaaa1111 -->"}]' <<< "$base"); check "partial-read marker at the content commit → partial-held" partial-held "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .comments=[{"author":{"login":"homelab-specs-reviewer[bot]"},"body":"PARTIAL READ: … <!-- specs-review partial-read head=00000000 -->"}]' <<< "$base"); check "partial-read marker at an OLDER content commit → candidate (a push released the hold)" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"ci","conclusion":"FAILURE"},{"name":"x","conclusion":"SUCCESS"}]' <<< "$base"); check "one FAILURE → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[]' <<< "$base"); check "empty rollup → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"approve","conclusion":"CANCELLED"},{"name":"approve","conclusion":"SUCCESS"},{"name":"ci","conclusion":"SUCCESS"}]' <<< "$base"); check "superseded CANCELLED beside its SUCCESS → candidate (#2636)" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"approve","conclusion":"CANCELLED"},{"name":"ci","conclusion":"SUCCESS"}]' <<< "$base"); check "only-CANCELLED check → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"ci","conclusion":"CANCELLED"},{"name":"ci","conclusion":"FAILURE"}]' <<< "$base"); check "CANCELLED beside a FAILURE → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .labels=[{"name":"agent/error"}]' <<< "$base"); check "agent/error → error-label (touch nothing)" error-label "$(classify "$j")"
  check "content sha skips the merge commit" aaaa1111 "$(jq -r "$JQ_PRELUDE"'content_sha' <<< "$base")"
  # the body-edit leg (review-reflex.sh reviewable_again: CHANGES_REQUESTED re-opens when the body's
  # lastEditedAt is newer than the verdict; APPROVED never does). Times from the fixtures above: the
  # content commit 10:00, own APPROVED 10:40, own CHANGES_REQUESTED 10:50 — an edit at 10:55 is after
  # the CR, one at 10:45 before it. .lastEditedAt "" = read, never edited; absent = not read.
  local own_rc2='{"author":{"login":"homelab-specs-reviewer"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-16T10:58:00Z"}'
  local own_ok2='{"author":{"login":"homelab-specs-reviewer"},"state":"APPROVED","submittedAt":"2026-10-16T10:58:00Z"}'
  j=$(jq -c --argjson r "[$code_ok,$own_rc]" '.reviews=$r | .lastEditedAt="2026-10-16T10:55:00Z"' <<< "$base"); check "body edited after own CHANGES_REQUESTED → candidate (re-review)" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc]" '.reviews=$r | .lastEditedAt=""' <<< "$base");                     check "own CHANGES_REQUESTED, body never edited → own-at-head" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc]" '.reviews=$r | .lastEditedAt="2026-10-16T10:45:00Z"' <<< "$base"); check "body edited BEFORE own CHANGES_REQUESTED → own-at-head" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc]" '.reviews=$r' <<< "$base");                                        check "own CHANGES_REQUESTED, edit not read (degraded) → own-at-head" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_ok]" '.reviews=$r | .lastEditedAt="2026-10-16T10:55:00Z"' <<< "$base"); check "body edited after own APPROVED → own-at-head (an approval never re-opens)" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc,$own_ok2]" '.reviews=$r | .lastEditedAt="2026-10-16T10:55:00Z"' <<< "$base"); check "CR, body edit, re-review APPROVED → own-at-head, not an anomaly" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc,$own_ok2]" '.reviews=$r' <<< "$base");                              check "CR then APPROVED, edit not read (degraded) → own-at-head, not an anomaly" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc,$own_rc2]" '.reviews=$r | .lastEditedAt=""' <<< "$base");           check "two own CHANGES_REQUESTED, body never edited → own-anomaly (a loop)" own-anomaly "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc,$own_rc2]" '.reviews=$r | .lastEditedAt="2026-10-16T10:55:00Z"' <<< "$base"); check "CR, body edit, CR again → own-at-head (the round answered, the next one stands)" own-at-head "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok,$own_rc,$own_rc2]" '.reviews=$r | .lastEditedAt="2026-10-16T10:59:00Z"' <<< "$base"); check "CR, edit, CR, edit again → candidate" candidate "$(classify "$j")"
  # own_cr_numbers — the GraphQL ask set: own live CHANGES_REQUESTED only (not an own APPROVED, not a
  # CR older than the content commit, not a draft)
  local crs; crs="$(jq -c --argjson a "[$code_ok,$own_rc]" --argjson b "[$code_ok,$own_ok]" --argjson c '[{"author":{"login":"homelab-specs-reviewer"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-16T09:00:00Z"}]' \
      '[ (.reviews=$a | .number=1 | .isDraft=false), (.reviews=$b | .number=2 | .isDraft=false), (.reviews=$c | .number=3 | .isDraft=false), (.reviews=$a | .number=4 | .isDraft=true) ]' <<< "$base")"
  check "own CR numbers: exactly the PR under a live own CHANGES_REQUESTED" "1" "$(own_cr_numbers "$crs" | paste -sd' ')"
  check "specs path predicate: gateway/specs/access.md" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'gateway/specs/access.md' >/dev/null; echo $?)"
  check "specs path predicate: specs/x.md at root" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'specs/x.md' >/dev/null; echo $?)"
  check "trigger: homelab rule-test path → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'gateway/tests/test_access.py' >/dev/null; echo $?)"
  check "trigger: homelab specs path → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'gateway/specs/access.md' >/dev/null; echo $?)"
  check "trigger: a non-gateway tests dir is NOT a homelab rule-test path" 1 "$(grep -cE "$(review_path_re homelab)" <<< 'scripts/tests/x.py' >/dev/null; echo $?)"
  # pack_roots: the claim's `repos[].specs` wins when present and well-formed; the per-repo table
  # answers a repo without the field, a malformed field (not two non-empty strings), and an
  # unreadable claim read (CLAIMS_JSON=null — the kubectl-less run). CLAIMS_JSON pre-set = the seam;
  # expectations come from the claim text below and the table, never from running the code.
  CLAIMS_JSON='{"items":[{"spec":{"repos":[{"name":"homelab","specs":{"root":"gateway/specs","tests":"gateway/tests"}},{"name":"moved","specs":{"root":"docs/specs","tests":"qa/rules"}},{"name":"half","specs":{"root":"specs"}},{"name":"typed","specs":{"root":["specs"],"tests":"tests"}},{"name":"plain"}]}}]}'
  check "pack roots: homelab (claim field)" "gateway/specs gateway/tests" "$(pack_roots homelab)"
  check "pack roots: a claim field moves the roots" "docs/specs qa/rules" "$(pack_roots moved)"
  check "pack roots: field without tests → table" "specs tests" "$(pack_roots half)"
  check "pack roots: non-string root → table" "specs tests" "$(pack_roots typed)"
  check "pack roots: repo without the field → table" "specs tests" "$(pack_roots plain)"
  check "pack roots: repo absent from every claim → table" "specs tests" "$(pack_roots some-island)"
  check "trigger follows the claim: moved repo's test root" 0 "$(grep -cE "$(review_path_re moved)" <<< 'qa/rules/test_x.py' >/dev/null; echo $?)"
  # several roots per repo (the claim's repos[].extraSpecs, tests optional): the pairs list the
  # primary pair first, then the extras in claim order; a malformed extra (no root, empty tests,
  # non-string) is skipped; a repo without extraSpecs keeps the one pair, and its trigger
  # expression is byte-for-byte the one-pair one (the oracle-fleet / single-field shape).
  CLAIMS_JSON='{"items":[{"spec":{"repos":[{"name":"homelab","specs":{"root":"gateway/specs","tests":"gateway/tests"},"extraSpecs":[{"root":"islands/scan/specs"},{"root":"islands/launch/specs","tests":"islands/launch/tests"},{"tests":"x"},{"root":"islands/bad/specs","tests":""},{"root":"gateway/specs"}]},{"name":"one","specs":{"root":"specs","tests":"tests"}}]}}]}'
  check "root pairs: primary first, extras in claim order, malformed and duplicate skipped" "gateway/specs gateway/tests|islands/scan/specs -|islands/launch/specs islands/launch/tests" "$(pack_root_pairs homelab | paste -sd'|')"
  check "root pairs: no extraSpecs → the one pair" "specs tests" "$(pack_root_pairs one)"
  check "pack roots: extras never change the primary pair" "gateway/specs gateway/tests" "$(pack_roots homelab)"
  check "trigger: one pair = the old expression, byte for byte" "$SPECS_PATH_RE|^tests/" "$(review_path_re one)"
  check "trigger: an island specs page → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'islands/scan/specs/x.md' >/dev/null; echo $?)"
  check "trigger: an extra root's tests root → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'islands/launch/tests/test_x.py' >/dev/null; echo $?)"
  check "trigger: an island README is NOT a spec path" 1 "$(grep -cE "$(review_path_re homelab)" <<< 'islands/scan/README.md' >/dev/null; echo $?)"
  check "touched pairs: an island page → that island's pair only" "islands/scan/specs -" "$(touched_pairs homelab 'islands/scan/specs/x.md')"
  check "touched pairs: a gateway page → the primary pair, exactly as before" "gateway/specs gateway/tests" "$(touched_pairs homelab "$(printf 'gateway/specs/a.md\ngateway/src/x.py')")"
  check "touched pairs: gateway + two islands → three, primary first" "gateway/specs|islands/scan/specs|islands/launch/specs" "$(touched_pairs homelab "$(printf 'islands/launch/tests/t.py\nislands/scan/specs/x.md\ngateway/tests/t.py')" | cut -d' ' -f1 | paste -sd'|')"
  check "touched pairs: a stray specs/ path under no root → the primary pair (pack finds no rule → mechanical)" "gateway/specs gateway/tests" "$(touched_pairs homelab 'docs/specs/x.md')"
  check "touched pairs: a root is a path prefix, not a substring" "gateway/specs gateway/tests" "$(touched_pairs homelab 'islands/scan/specsx/y.md')"
  # one pass per root, one verdict: a root's review is read back from its own marked comment at
  # the content commit only; the ONE review carries one Verdict line, CHANGES_REQUESTED when any
  # root's is (naming that root's IDs), and is never read as mechanical by prior_review_pick.
  local md; md="$(mktemp -d)"
  printf '## Specs review\nVerdict: APPROVE — no blocking check failed\nRows: fine\n' > "$md/r1.md"
  printf '## Specs review\nVerdict: CHANGES_REQUESTED — R-ROWS-1, E-NO_EVIDENCE/x\nF1 detail\n' > "$md/r2.md"
  printf '## Specs review\nVerdict: APPROVE — no rule touched: touched-rules (allure-behavior-snippets 0.6.9) found no rule this diff touches under islands/launch/specs.\n' > "$md/r3.md"
  local cmts; cmts="$(jq -cn --rawfile a "$md/r1.md" --rawfile b "$md/r2.md" '[{body:("SPECS ROOT REVIEW 1/2: x\n\n" + $a + "\n<!-- specs-review root=islands/scan/specs head=aaaa1111 -->\n")},{body:("old\n" + $b + "<!-- specs-review root=islands/launch/specs head=00000000 -->")}]')"
  check "root review: read back from its marked comment" "$(cat "$md/r1.md")" "$(root_review_of "$cmts" islands/scan/specs aaaa1111)"
  check "root review: a marker at an older content commit is not this head's" "" "$(root_review_of "$cmts" islands/launch/specs aaaa1111)"
  check "root review: a root with no comment → empty" "" "$(root_review_of "$cmts" gateway/specs aaaa1111)"
  root_comment islands/scan/specs 1 2 aaaa1111 "$md/r1.md" > "$md/rc.md"
  check "root comment: round-trips through root_review_of" "$(cat "$md/r1.md")" "$(root_review_of "$(jq -cn --rawfile b "$md/rc.md" '[{body:$b}]')" islands/scan/specs aaaa1111)"
  local agg; agg="$(aggregate_review aaaa1111bbbb islands/scan/specs="$md/r1.md" islands/launch/specs="$md/r2.md")"
  check "aggregate: any root CHANGES_REQUESTED → CHANGES_REQUESTED" CHANGES_REQUESTED "$(parse_verdict "$agg")"
  check "aggregate: the verdict names the requesting root and its IDs" "Verdict: CHANGES_REQUESTED — islands/launch/specs: R-ROWS-1, E-NO_EVIDENCE/x" "$(grep -m1 '^Verdict:' <<< "$agg")"
  check "aggregate: exactly one Verdict line" 1 "$(grep -c '^Verdict:' <<< "$agg")"
  check "aggregate: each root's body carried" 2 "$(grep -cE '^(Rows: fine|F1 detail)$' <<< "$agg")"
  agg="$(aggregate_review aaaa1111bbbb islands/scan/specs="$md/r1.md" islands/launch/specs="$md/r3.md")"
  check "aggregate: every root approved → APPROVE" APPROVE "$(parse_verdict "$agg")"
  check "aggregate: a no-rule root never makes the review read as mechanical (round memory)" 1 "$(prior_review_pick "$(jq -cn --arg b "$agg" '[{user:{login:"homelab-specs-reviewer[bot]"},state:"APPROVED",commit_id:"aaaa1111",submitted_at:"2026-11-14T00:00:00Z",body:$b}]')" | grep -c '^previous review: APPROVED')"
  # prior_for_root: a root's pass keeps only ITS section of a multi-root verdict (+ the first line and
  # the head trailer the pack's prior-ruling carry reads); a root without a section is round 1 for
  # it; a single-root review (no `### Root` section) passes whole. Built from aggregate_review's own
  # output, so the section shape is the producer's, not a copy.
  agg="$(aggregate_review aaaa1111bbbb islands/scan/specs="$md/r1.md" islands/launch/specs="$md/r2.md")"
  local prv; prv="$(printf 'previous review: CHANGES_REQUESTED at aaaa1111bbbb (2026-11-15T16:42:11Z)\n\n%s\n\n<!-- specs-review head=aaaa1111bbbb session=s1 -->\n' "$agg")"
  check "prior per root: the other root's findings are gone" 0 "$(prior_for_root "$prv" islands/scan/specs | grep -c 'F1 detail')"
  check "prior per root: this root's section kept" 1 "$(prior_for_root "$prv" islands/scan/specs | grep -c '^Rows: fine$')"
  check "prior per root: the head trailer kept (it sits in the LAST root's section)" 1 "$(prior_for_root "$prv" islands/scan/specs | grep -c '^<!-- specs-review head=aaaa1111bbbb')"
  check "prior per root: the first line kept" "previous review: CHANGES_REQUESTED at aaaa1111bbbb (2026-11-15T16:42:11Z)" "$(prior_for_root "$prv" islands/scan/specs | head -1)"
  check "prior per root: the last root keeps its findings and one trailer" "1 1" "$(prior_for_root "$prv" islands/launch/specs | grep -c 'F1 detail') $(prior_for_root "$prv" islands/launch/specs | grep -c 'specs-review head=')"
  check "prior per root: the aggregate Verdict line (naming other roots) is not carried" 0 "$(prior_for_root "$prv" islands/scan/specs | grep -c '^Verdict:')"
  check "prior per root: a root with no section → round 1 for it" 1 "$(prior_for_root "$prv" gateway/specs | grep -c '^previous review: none for root `gateway/specs`')"
  check "prior per root: a single-root review passes whole" "$(printf 'previous review: X\n\n## Specs review\nVerdict: APPROVE — ok')" "$(prior_for_root "$(printf 'previous review: X\n\n## Specs review\nVerdict: APPROVE — ok')" islands/scan/specs)"
  rm -rf "$md"
  # pack_diff_base: the PR's spec diff is what the PR itself changes. A real repo, built here: master
  # m0 → the goal branch adds launch/specs/a.md; master then adds retro/specs/guard.md and edits
  # shared.md (m1); the PR branches from the goal, edits launch/specs/a.md, merges master. Expected
  # from the contract (paths byte-identical to the merged-in master are not the PR's): three-dot
  # from the returned base lists ONLY launch/specs/a.md; a merge-only PR lists nothing; a PR on
  # master itself gets its base back unchanged; the head keeps its sha.
  local gr; gr="$(mktemp -d)"
  (
    set -e; cd "$gr"; git init -q -b master .; git config user.email t@t; git config user.name t
    mkdir -p launch/specs retro/specs; echo s > shared.md; echo o > launch/specs/o.md; git add -A; git commit -qm m0
    git checkout -qb goal; echo a > launch/specs/a.md; echo og > launch/specs/o.md; git add -A; git commit -qm goal
    git checkout -q master; echo g > retro/specs/guard.md; echo s2 > shared.md; git add -A; git commit -qm m1
    git checkout -qb pr goal; echo a2 > launch/specs/a.md; git commit -qam "pr edit"; git merge -q --no-edit master
    git checkout -qb pr-merge-only goal; git merge -q --no-edit master
    git checkout -qb pr-on-master master; echo x > retro/specs/guard.md; git commit -qam "master pr"
    # the goal edited launch/specs/o.md, master now edits it too, the PR's merge keeps MASTER's
    # version: head == M there, but the goal's edit is discarded — a change against the base
    git checkout -q master; echo om > launch/specs/o.md; git commit -qam "master o"
    git checkout -qb pr-discard goal; git merge -q --no-edit -X theirs master
  ) >/dev/null 2>&1 || { echo "  FAIL diff base: the fixture repo could not be built"; fails=$((fails+1)); }
  local hsha db; hsha="$(git -C "$gr" rev-parse pr)"
  db="$(pack_diff_base "$gr" goal pr master 2>/dev/null)"
  check "diff base: master's merged-in paths drop, the PR's own edit stays" "launch/specs/a.md" "$(git -C "$gr" diff --name-only "$db...pr" | paste -sd' ')"
  check "diff base: the head keeps its sha" "$hsha" "$(git -C "$gr" rev-parse pr)"
  db="$(pack_diff_base "$gr" goal pr-merge-only master 2>/dev/null)"
  check "diff base: a merge-only PR changes nothing of its own" "" "$(git -C "$gr" diff --name-only "$db...pr-merge-only")"
  check "diff base: a PR on the upstream itself keeps its base" master "$(pack_diff_base "$gr" master pr-on-master master 2>/dev/null)"
  check "diff base: no upstream merged in → the base unchanged" goal "$(pack_diff_base "$gr" goal goal master 2>/dev/null)"
  db="$(pack_diff_base "$gr" goal pr-discard master 2>/dev/null)"
  check "diff base: a base-side edit the merge discarded (head == upstream) stays the PR's change" "launch/specs/o.md" "$(git -C "$gr" diff --name-only "$db...pr-discard" | paste -sd' ')"
  rm -rf "$gr"
  CLAIMS_JSON=null
  check "pack roots: homelab, claim read failed → table" "gateway/specs gateway/tests" "$(pack_roots homelab 2>/dev/null)"
  check "pack roots: default island layout, claim read failed → table" "specs tests" "$(pack_roots some-island 2>/dev/null)"
  check "trigger: oracle-fleet root specs path → LLM pass" 0 "$(grep -cE "$(review_path_re oracle-fleet)" <<< 'specs/server/http.md' >/dev/null; echo $?)"
  check "trigger: oracle-fleet rule-test path → LLM pass" 0 "$(grep -cE "$(review_path_re oracle-fleet)" <<< 'tests/test_rt.py' >/dev/null; echo $?)"
  check "specs path predicate: docs/specs-reviewer.md is NOT a specs path" 1 "$(grep -cE "$SPECS_PATH_RE" <<< 'docs/agents/specs-reviewer.md' >/dev/null; echo $?)"
  check "verdict parse: APPROVE" APPROVE "$(parse_verdict "$(printf '## Specs review\nVerdict: APPROVE — no blocking check failed\nRows: …\n')")"
  check "verdict parse: CHANGES_REQUESTED" CHANGES_REQUESTED "$(parse_verdict "$(printf '## Specs review\nVerdict: CHANGES_REQUESTED — 1, 6\n')")"
  check "verdict parse: missing → empty" "" "$(parse_verdict "$(printf 'no verdict here\n')")"
  check "verdict parse: PARTIAL READ" PARTIAL "$(parse_verdict "$(printf '## Specs review\nVerdict: PARTIAL READ — spec-sections.md, digest.md\n')")"
  check "partial unread: the line's tail" "spec-sections.md, digest.md" "$(partial_unread "$(printf '## Specs review\nVerdict: PARTIAL READ — spec-sections.md, digest.md\n')")"
  check "outcome: a PARTIAL READ is clean (the model did its job; no strike)" clean "$(outcome_class 0 1 PARTIAL)"
  check "prompt: pass 1 honours pass1-prior.tsv when present (snippets#46 wording: re-list EVERY prior key)" 1 "$(pass1_prompt o/r 1 abc | grep -c 'pass1-prior.tsv, when present.*re-list EVERY one of them')"
  check "outcome: a verdict is clean (APPROVE)" clean "$(outcome_class 0 1 APPROVE)"
  check "outcome: a verdict is clean (CHANGES_REQUESTED — a round, not a strike)" clean "$(outcome_class 0 1 CHANGES_REQUESTED)"
  check "outcome: no parsable verdict → no-verdict" no-verdict "$(outcome_class 0 1 '')"
  check "outcome: the LLM_TIMEOUT_S kill → timeout" timeout "$(outcome_class 124 0 '')"
  check "outcome: a non-zero exit → harness-death" harness-death "$(outcome_class 1 1 '')"
  check "outcome: no JSON result → harness-death" harness-death "$(outcome_class 0 0 '')"
  check "outcome report: the strike class is read back" no-verdict \
    "$(curl() { printf '%s' '{"id":"s1","strike":{"class":"no-verdict","scope":"model"},"refuted":0,"replay":false}'; }; GATEWAY_TOKEN_FILE=/nonexistent gw_outcome s1 no-verdict rc=0 2>/dev/null)"
  check "outcome report: clean counts no strike" "" \
    "$(curl() { printf '%s' '{"id":"s1","strike":null,"refuted":0,"replay":false}'; }; GATEWAY_TOKEN_FILE=/nonexistent gw_outcome s1 clean rc=0 2>/dev/null)"
  check "outcome report: a failed POST is non-fatal and counts nothing" "" \
    "$(curl() { return 22; }; GATEWAY_TOKEN_FILE=/nonexistent gw_outcome s1 timeout rc=124 2>/dev/null)"
  check "env key guard rejects a shell-hostile key" 1 "$(valid_env_key 'FOO=bar; rm' && echo 0 || echo 1)"
  check "env key guard accepts ANTHROPIC_MODEL" 0 "$(valid_env_key 'ANTHROPIC_MODEL' && echo 0 || echo 1)"
  # GW-SESSIONS-AUTH: gw_curl carries the projected token as the caller header, read from the file
  # through an fd (never argv); no file = no header (and a stderr warning). `curl` is shadowed here.
  local tokd; tokd="$(mktemp -d)"; printf 'fake-caller-token-selftest' > "$tokd/token"
  check "caller header: the projected token rides as Authorization: Bearer" "Authorization: Bearer fake-caller-token-selftest" \
    "$(curl() { local a p=""; for a in "$@"; do [ "$p" = "-H" ] && case "$a" in @*) cat "${a#@}";; esac; p="$a"; done; }; GATEWAY_TOKEN_FILE="$tokd/token" gw_curl -X GET http://g/sessions/x)"
  check "caller header: never in curl's argv" 0 \
    "$(curl() { printf '%s\n' "$@"; }; GATEWAY_TOKEN_FILE="$tokd/token" gw_curl -X GET http://g/sessions/x | grep -c fake-caller-token-selftest)"
  check "caller header: no token file → no Authorization header" 0 \
    "$(curl() { printf '%s\n' "$@"; }; GATEWAY_TOKEN_FILE="$tokd/absent" gw_curl -X GET http://g/sessions/x 2>/dev/null | grep -c '^-H$')"
  rm -rf "$tokd"
  # the confinement contract (PR#2613 finding 1): the model's env is the dispatch env + OTEL +
  # HOME/PATH/TMPDIR, and NEVER the pod's GH_TOKEN / GH_TOKEN_FILE / GATEWAY_URL — asserted by
  # running the real builder with those set in THIS shell and a uc-1-shaped dispatch fixture.
  local d; d="$(mktemp -d)"
  printf '%s' '{"decision":"dispatch","session":{"id":"s1","token":"gws_x","expires_at":"2026-10-16T12:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/sonnet","env":{"ANTHROPIC_BASE_URL":"http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic","ANTHROPIC_AUTH_TOKEN":"gws_x","ANTHROPIC_MODEL":"sonnet"},"context_tokens":null}' > "$d/resp.json"
  local envout; envout="$(GH_TOKEN=leak-me GH_TOKEN_FILE=/var/run/x GATEWAY_URL=http://g OTEL_RESOURCE_ATTRIBUTES=role=t HOME="$d/fakehome" llm_env_args "$d/resp.json" "$d/home")"
  check "env builder: dispatch keys present" 3 "$(grep -cE '^ANTHROPIC_(BASE_URL|AUTH_TOKEN|MODEL)=' <<< "$envout")"
  check "env builder: ANTHROPIC_MODEL verbatim" "ANTHROPIC_MODEL=sonnet" "$(grep -E '^ANTHROPIC_MODEL=' <<< "$envout")"
  check "env builder: no GH_TOKEN / GH_TOKEN_FILE / GATEWAY_URL / PUSHGATEWAY" 0 "$(grep -cE '^(GH_TOKEN|GH_TOKEN_FILE|GATEWAY_URL|PUSHGATEWAY)=' <<< "$envout")"
  check "env builder: OTEL attribute carried" "OTEL_RESOURCE_ATTRIBUTES=role=t" "$(grep -E '^OTEL_RESOURCE_ATTRIBUTES=' <<< "$envout")"
  check "env builder: throwaway HOME" "HOME=$d/home" "$(grep -E '^HOME=' <<< "$envout")"
  # the seeded HOME carries NO permission rules (settings allow-rules union with --allowedTools):
  # the fake image HOME holds the agent images' real permissive settings.json + a .claude.json;
  # the .claude.json reaching the throwaway HOME proves the seeding ran at all.
  mkdir -p "$d/fakehome/.claude"
  printf '%s\n' '{"hasCompletedOnboarding":true}' > "$d/fakehome/.claude.json"
  printf '%s\n' '{"permissions":{"allow":["Bash(*)","Read(*)","Edit(*)","Write(*)","WebSearch(*)","WebFetch(*)"]},"skipDangerousModePermissionPrompt":true}' > "$d/fakehome/.claude/settings.json"
  HOME="$d/fakehome" llm_env_args "$d/resp.json" "$d/home3" >/dev/null
  check "seeded HOME: .claude.json carried (onboarding state)" 1 "$(grep -c hasCompletedOnboarding "$d/home3/.claude.json" 2>/dev/null || echo 0)"
  check "seeded HOME: no settings file carries a permissions key" 0 "$(cat "$d/home3/.claude/settings.json" "$d/home3/.claude/settings.local.json" 2>/dev/null | grep -c '"permissions"' || true)"
  printf '%s' '{"env":{"EVIL=x; rm -rf":"y"}}' > "$d/bad.json"
  check "env builder: shell-hostile key is a refusal" 1 "$(llm_env_args "$d/bad.json" "$d/home2" >/dev/null 2>&1 && echo 0 || echo 1)"
  # the pinned-verdict contract (PR#2613 round 2): review_submit re-reads the head right before
  # submitting and DROPS the verdict (rc 3, no API call) when it moved; when it did not, the POST
  # carries commit_id = the reviewed head. Seams injected: current_head (the re-read) and gh (the
  # write), both recorded — the expectation is the contract, not a paste of the function.
  : > "$d/gh.calls"
  gh() { printf '%s\n' "$*" >> "$d/gh.calls"; }
  current_head() { printf 'bbbb2222'; }
  printf 'body\n' > "$d/body.md"
  local rs=0; review_submit homelab 7 approve "$d/body.md" aaaa1111 >/dev/null 2>&1 || rs=$?
  check "pinned verdict: head moved → rc 3" 3 "$rs"
  check "pinned verdict: head moved → no API write" 0 "$(grep -c . "$d/gh.calls")"
  current_head() { printf 'aaaa1111'; }
  rs=0; review_submit homelab 7 request-changes "$d/body.md" aaaa1111 >/dev/null 2>&1 || rs=$?
  check "pinned verdict: head unchanged → rc 0" 0 "$rs"
  check "pinned verdict: POST carries commit_id=reviewed head + REQUEST_CHANGES" 1 "$(grep -c 'repos/teststuffstash/homelab/pulls/7/reviews.*commit_id=aaaa1111.*event=REQUEST_CHANGES' "$d/gh.calls")"
  unset -f gh current_head
  # issue intent from a `Refs #N` line when the PR closes nothing (pr-open.sh's unfinished-issue
  # form): the acceptance text still reaches the pack; no Refs line keeps the "none" note.
  gh() {
    case "$*" in
      *closingIssuesReferences*) return 0 ;;
      "pr view 5 "*body*) printf 'Refs #1012 remaining: the closeout\n' ;;
      "pr view 6 "*body*) printf 'no link here\n' ;;
      "issue view 1012 "*) printf '# T\n\n## Acceptance\n- a row\n' ;;
    esac
  }
  check "issue intent: a Refs line names the issue" 1 "$(issue_intent teststuffstash/oracle-fleet 5 | grep -c '^## teststuffstash/oracle-fleet#1012$')"
  check "issue intent: no link keeps the none note" 1 "$(issue_intent teststuffstash/oracle-fleet 6 | grep -c '^issue intent: none')"
  unset -f gh
  # round inputs (ADR-156 step 2): the acceptance section is cut at the next `## ` heading and
  # keeps `###`; an issue with none is passed whole under a note; the prior review is the newest
  # OWN LLM review in ANY state (a dismissed one is the round memory), never a mechanical approval
  # and never another identity's review.
  local issue; issue="$(printf '# t\n\n## Why\nbecause\n\n## Acceptance\n| a | b |\n### edge\nx\n\n## Notes\nno\n')"
  check "acceptance: section only" 4 "$(acceptance_of "$issue" | grep -c .)"
  check "acceptance: next ## heading ends it" 0 "$(acceptance_of "$issue" | grep -c 'Notes')"
  check "acceptance: none → whole body under a note" 1 "$(acceptance_of "$(printf '# t\nbody\n')" | grep -c 'no `## Acceptance` section')"
  local revs='[{"user":{"login":"homelab-specs-reviewer[bot]"},"state":"DISMISSED","commit_id":"aaaa1111aaaa1111","submitted_at":"2026-10-16T10:00:00Z","body":"## Specs review\nVerdict: CHANGES_REQUESTED — 6\nF1"},{"user":{"login":"homelab-specs-reviewer[bot]"},"state":"APPROVED","commit_id":"bbbb2222bbbb2222","submitted_at":"2026-10-16T11:00:00Z","body":"## Specs review\nVerdict: APPROVE — mechanical: no specs path"},{"user":{"login":"homelab-reviewer[bot]"},"state":"APPROVED","commit_id":"cccc","submitted_at":"2026-10-16T12:00:00Z","body":"## Specs review\nnot mine"}]'
  check "prior review: newest own LLM review, DISMISSED included" "previous review: DISMISSED at aaaa1111aaaa (2026-10-16T10:00:00Z)" "$(prior_review_pick "$revs" | head -1)"
  check "prior review: none → empty" "" "$(prior_review_pick '[]')"
  # evidence from the bucket (2026-10-21): the pack is ONE tarball per (prefix, sha), read through
  # the web endpoint — a file:// stand-in here; an absent key, an unbucketed repo, or a tarball
  # without evidence.json is rc 1 (the caller falls back / states the absence).
  mkdir -p "$d/pk" "$d/web/evidence/pr-7" && printf '{}' > "$d/pk/evidence.json" && tar -czf "$d/web/evidence/pr-7/aaaa1111.tar.gz" -C "$d/pk" .
  mkdir -p "$d/pk2" && printf 'x' > "$d/pk2/digest.md" && tar -czf "$d/web/evidence/pr-7/bbbb2222.tar.gz" -C "$d/pk2" .
  rs=0; EVIDENCE_WEB="file://$d/web" evidence_fetch homelab pr-7 aaaa1111 "$d/ev" || rs=$?
  check "evidence bucket: present → rc 0 + evidence.json unpacked" "0 1" "$rs $(find "$d/ev" -name evidence.json | wc -l)"
  rs=0; EVIDENCE_WEB="file://$d/web" evidence_fetch homelab pr-7 cccc3333 "$d/ev" || rs=$?
  check "evidence bucket: absent key → rc 1" 1 "$rs"
  rs=0; EVIDENCE_WEB="file://$d/web" evidence_fetch homelab pr-7 bbbb2222 "$d/ev" || rs=$?
  check "evidence bucket: a pack without evidence.json → rc 1" 1 "$rs"
  rs=0; EVIDENCE_WEB="file://$d/web" evidence_fetch some-island pr-7 aaaa1111 "$d/ev" || rs=$?
  check "evidence bucket: a repo with no bucket → rc 1" 1 "$rs"
  check "evidence bucket: oracle-fleet → oracle-specs" oracle-specs "$(evidence_bucket oracle-fleet)"
  # ── the shadow run (gateway/PLAN.md step 3: "the shadow path has no gh write call") ──
  # The allow-list's table. Expected values are GitHub's own semantics, not this code's: a review,
  # comment, edit, label, merge or workflow dispatch is a write; `gh api` without -X is POST as
  # soon as a field flag is present (gh api's documented default), so a "read-looking" api call
  # with -f is a write; graphql is POST by protocol, so only the query text decides.
  local a want
  while IFS='|' read -r want a; do
    [ -n "$want" ] || continue
    eval "set -- $a"
    check "shadow gh allow-list: gh $a → $want" "$want" "$(gh_shadow_allows "$@" && echo read || echo write)"
  done <<'ROWS'
read|pr view 7 --repo o/r --json title,body,url -q .title
read|pr list --repo o/r --state open
read|issue view 3 --repo o/r --json title,body
read|run list --repo o/r --commit abc --workflow ci.yaml
read|api --paginate repos/o/r/pulls/7/files --jq '.[].filename'
read|api repos/o/r/commits/abc --jq .sha
read|api -X GET repos/o/r/pulls -f state=closed
read|api graphql -f 'query=query($o:String!){repository(owner:$o,name:"r"){id}}' -f o=x -F p=7
write|pr review 7 --approve
write|run download 5 --repo o/r -n gateway-evidence -D /tmp/x
write|pr comment 7 --body-file f.md
write|pr edit 7 --add-label agent/error
write|pr merge 7 --squash
write|issue comment 3 -b hi
write|issue edit 3 --add-label x
write|label create x
write|workflow run ci.yaml
write|api -X POST repos/o/r/pulls/7/reviews -f commit_id=a -f event=APPROVE
write|api repos/o/r/issues/7/labels -f 'labels[]=x'
write|api repos/o/r/issues/7/comments -F body=@f.md
write|api --method PATCH repos/o/r/pulls/7
write|api -XDELETE repos/o/r/issues/7/labels/x
write|api --method=PUT repos/o/r/pulls/7/merge
write|api repos/o/r/pulls/7/reviews --input body.json
write|api graphql -f 'query=mutation{addComment(input:{}){clientMutationId}}'
write|api graphql -F query=@q.graphql
write|api repos/o/r/pulls -X
ROWS
  # Dynamic: with the shadow gh installed, the LIVE writer (review_submit — the only verdict
  # path) and the anomaly comment are refused before the CLI; the read before them still reaches
  # it (proving the recorder sees calls at all — without that line this row could not fail).
  : > "$d/gh.calls"
  eval "$(grep -m1 '^current_head() {' "$0")"   # the REAL head re-read (the pinned-verdict rows above unset their stub)
  gh_real() { printf '%s\n' "$*" >> "$d/gh.calls"; [ "${1:-} ${2:-}" = "pr view" ] && printf 'aaaa1111'; return 0; }
  gh() { gh_shadow "$@"; }
  rs=0; review_submit homelab 7 approve "$d/body.md" aaaa1111 >/dev/null 2>&1 || rs=$?
  check "shadow: review_submit is refused rc 97" 97 "$rs"
  check "shadow: the head re-read (a read) reached the CLI" 1 "$(grep -c '^pr view 7' "$d/gh.calls")"
  check "shadow: no reviews POST reached the CLI" 0 "$(grep -c 'pulls/7/reviews' "$d/gh.calls")"
  rs=0; gh pr comment 7 --repo o/r --body-file "$d/body.md" >/dev/null 2>&1 || rs=$?
  check "shadow: an AGENT_ERROR comment is refused rc 97" 97 "$rs"
  check "shadow: no comment reached the CLI" 0 "$(grep -c '^pr comment' "$d/gh.calls")"
  unset -f gh gh_real
  gh_real() { command gh "$@"; }
  # Static: nothing on the shadow path bypasses the wrapper (`command gh` / an absolute gh path
  # skips the `gh` function) — gh_real is the one sanctioned call site.
  check "shadow: no gh bypass outside gh_real" 0 "$(declare -f build_pack shadow_main shadow_one shadow_release pr_body_as_of issue_intent evidence_fetch evidence_download evidence_baseline_download prior_review_pick llm_env_args harness_claude harness_opencode harness_goose | grep -cE 'command gh|/bin/gh|\\gh ')"
  # As-of reads (replay fidelity): the PR body is the edit current at the live review's time —
  # GitHub's userContentEdits `diff` is the full body at that edit, the oldest is the original;
  # #2635's shape (opened 16:59:02 without `Spec changes:`, edited 17:06:24, first review 17:06:02).
  gh_real() { printf '%s' '{"data":{"repository":{"pullRequest":{"title":"T","url":"U","body":"NEW","userContentEdits":{"nodes":[{"editedAt":"2026-10-16T17:06:24Z","diff":"NEW"},{"editedAt":"2026-10-16T16:59:02Z","diff":"OLD"}]}}}}}'; }
  gh() { gh_shadow "$@"; }
  check "as-of body: before the edit → the original" "OLD" "$(pr_body_as_of o/r 7 2026-10-16T17:06:02Z | tail -1)"
  check "as-of body: after the edit → the edited body" "NEW" "$(pr_body_as_of o/r 7 2026-10-16T17:10:46Z | tail -1)"
  gh_real() { printf '%s' '{"data":{"repository":{"pullRequest":{"title":"T","url":"U","body":"CUR","userContentEdits":{"nodes":[]}}}}}'; }
  check "as-of body: never edited → the current body" "CUR" "$(pr_body_as_of o/r 7 2026-10-16T17:06:02Z | tail -1)"
  unset -f gh gh_real
  gh_real() { command gh "$@"; }
  local srevs='[{"user":{"login":"homelab-specs-reviewer[bot]"},"commit_id":"h2","submitted_at":"2026-10-16T17:10:46Z"},{"user":{"login":"homelab-specs-reviewer[bot]"},"commit_id":"h2","submitted_at":"2026-10-16T17:06:02Z"},{"user":{"login":"homelab-reviewer[bot]"},"commit_id":"h2","submitted_at":"2026-10-16T17:00:00Z"}]'
  check "as-of: the FIRST own review at the judged head" "2026-10-16T17:06:02Z" "$(shadow_as_of "$srevs" h2)"
  check "as-of: no own review at that head → empty (caller uses now)" "" "$(shadow_as_of "$srevs" h9)"
  # The record never carries the session token (the artifact is readable by the namespace).
  printf '%s' '{"decision":"dispatch","session":{"id":"s1","token":"gws_secret","expires_at":"x"},"rail":"opencode","harness":"goose","model":"m","env":{"OPENAI_API_KEY":"gws_secret","OPENAI_BASE_URL":"u"},"context_tokens":null}' > "$d/disp.json"
  check "admission record: no session token anywhere" 0 "$(admission_summary 200 "$d/disp.json" | grep -c gws_secret)"
  check "admission record: the env KEYS kept" '["OPENAI_API_KEY","OPENAI_BASE_URL"]' "$(admission_summary 200 "$d/disp.json" | jq -c .env_keys)"
  printf '%s' '{"decision":"defer","reason":"role-rail-denied","retry_after_s":60}' > "$d/defer.json"
  check "admission record: a defer keeps its reason" role-rail-denied "$(admission_summary 200 "$d/defer.json" | jq -r .answer.reason)"
  # The review body reaches the log framed by its tag (the artifact store needs credentials the
  # reader may lack); a body line can never be mistaken for a marker of another tag.
  printf '## Specs review\nVerdict: APPROVE — x\n' > "$d/rv.md"
  check "shadow: review body framed in the log" "SHADOW-REVIEW-BEGIN t1|## Specs review|Verdict: APPROVE — x|SHADOW-REVIEW-END t1" "$(shadow_emit_review t1 "$d/rv.md" | paste -sd'|')"
  # Usage errors are rc 2 BEFORE any read (no harness, no PR list).
  rs=0; ( shadow_main --rail opencode homelab#1 ) >/dev/null 2>&1 || rs=$?
  check "shadow_main: no --harness → rc 2" 2 "$rs"
  rs=0; ( shadow_main --harness goose ) >/dev/null 2>&1 || rs=$?
  check "shadow_main: no PR → rc 2" 2 "$rs"
  # …and a run that gets past its flags has the read-only gh INSTALLED before its first read
  # (the token check is that first read's gate; with no token it stops right there, rc 2).
  check "shadow_main: gh is the read-only wrapper once a run starts" 1 "$( (GH_TOKEN="" GH_TOKEN_FILE=""; shadow_main --harness goose homelab#1 >/dev/null 2>&1 || true; declare -f gh) | grep -c 'gh_shadow "\$@"')"
  # ── the staged read: pass 1's world is the manifest's masked ALLOW-list, nothing else ──
  local pk="$d/pack"; mkdir -p "$pk/process/briefs" "$pk/tree" "$pk/evidence"
  for f in spec-sections.md spec-sections-masked.md digest.md masked/digest.md row-keys.tsv tree/a.md evidence/R-1.json process/briefs/rows.md; do
    mkdir -p "$pk/$(dirname "$f")"; printf 'x\n' > "$pk/$f"; done
  printf '%s' '{"masked":{"files":["spec-sections-masked.md","masked/digest.md"],"keys":"row-keys.tsv","tree":"unmasked"}}' > "$pk/manifest.json"
  check "pass 1 world: built from the declared list" 0 "$(pass1_inputs "$pk" "$d/p1"; echo $?)"
  check "pass 1 world: exactly the masked files + process/ + manifest" "manifest.json masked/digest.md process/briefs/rows.md spec-sections-masked.md" \
    "$(cd "$d/p1" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//')"
  local bad
  for bad in '["../x"]' '["/etc/passwd"]' '["row-keys.tsv"]' '["absent.md"]' '[]'; do
    printf '{"masked":{"files":%s}}' "$bad" > "$pk/manifest.json"
    check "pass 1 world: refuses masked.files=$bad" 1 "$(pass1_inputs "$pk" "$d/p1" >/dev/null 2>&1 && echo 0 || echo 1)"
  done
  printf '{}' > "$pk/manifest.json"
  check "pass 1 world: a pack with no masked section is a refusal" 1 "$(pass1_inputs "$pk" "$d/p1" >/dev/null 2>&1 && echo 0 || echo 1)"
  check "prompt: single pass names no pass1.md" 0 "$(STAGED=0 review_prompt o/r 1 abc | grep -c pass1.md)"
  check "prompt: staged pass 2 adjudicates the frozen pass 1" 1 "$(STAGED=1 review_prompt o/r 1 abc | grep -c 'survives, contradicted or withdrawn')"
  # review_run's order with the harness recorded: pass 1 in pass1/ with its own prompt and share,
  # frozen into the pack, THEN pass 2 in the pack; a silent pass 1 ends the run without pass 2.
  check "review_run: staged = pass 1 in pass1/ (200 s), then pass 2 in inputs/ seeing pass1.md" "pass1:PASS 1:200|inputs:PASS 2:frozen" "$(
    WORK="$d/rr"; mkdir -p "$WORK/inputs" "$WORK/pass1"; STAGED=1; PASS1_TIMEOUT_S=200; LLM_TIMEOUT_S=600
    harness_run() { local n; n="$(basename "$2")"
      case "$3" in *"PASS 1 of"*) printf '%s' "pass1:PASS 1:$5" >> "$WORK/calls"; printf -- '- r1.1 — check 10 — frozen\n' > "$WORK/result.txt";;
                   *"PASS 2 of"*) printf '|%s:PASS 2:%s' "$n" "$(grep -q frozen "$WORK/inputs/pass1.md" && echo frozen)" >> "$WORK/calls";; esac; }
    review_run claude o/r 1 abc m >/dev/null; cat "$WORK/calls")"
  check "review_run: an empty pass 1 → rc 1 and no pass 2" "1:" "$(
    WORK="$d/rr2"; mkdir -p "$WORK/inputs" "$WORK/pass1"; STAGED=1
    harness_run() { case "$3" in *"PASS 2 of"*) printf 'p2' >> "$WORK/calls";; *) : > "$WORK/result.txt";; esac; }
    rc=0; review_run claude o/r 1 abc m >/dev/null || rc=$?; printf '%s:%s' "$rc" "$(cat "$WORK/calls" 2>/dev/null)")"
  check "review_run: single pass = one call with the whole LLM_TIMEOUT_S" "inputs:600" "$(
    WORK="$d/rr3"; mkdir -p "$WORK/inputs"; STAGED=0; LLM_TIMEOUT_S=600
    harness_run() { printf '%s:%s' "$(basename "$2")" "$5" >> "$WORK/calls"; }
    review_run claude o/r 1 abc m >/dev/null; cat "$WORK/calls")"
  rm -rf "$d"
  [ "$fails" -eq 0 ] && { echo "self-test: ok"; return 0; }
  echo "self-test: $fails FAILED"; return 1
}

# parse_verdict <review-body> → APPROVE | CHANGES_REQUESTED | PARTIAL | "" — the lens's `Verdict:` line, first match.
parse_verdict() {
  local line
  line="$(grep -m1 -E '^Verdict:[[:space:]]*(APPROVE|CHANGES_REQUESTED|PARTIAL READ)\b' <<< "$1" || true)"
  case "$line" in
    *"PARTIAL READ"*) printf 'PARTIAL';;
    *CHANGES_REQUESTED*) printf 'CHANGES_REQUESTED';;
    *APPROVE*) printf 'APPROVE';;
    *) printf '';;
  esac
}
# partial_unread <review-body> → what the PARTIAL READ line says was not finished (its tail), or ""
partial_unread() {
  grep -m1 -E '^Verdict:[[:space:]]*PARTIAL READ' <<< "$1" | sed -E 's/^Verdict:[[:space:]]*PARTIAL READ[[:space:]]*[—-]*[[:space:]]*//' || true
}
valid_env_key() { [[ "$1" =~ ^[A-Z][A-Z0-9_]*$ ]]; }

# acceptance_of <issue-body> → the issue's `## Acceptance` section (heading to the next `## `
# heading; `###` subsections stay), or the whole body under a note when it has none. Check 1
# grounds rows in this text, so it is copied verbatim, never summarised.
acceptance_of() {
  local sec; sec="$(awk '/^##[[:space:]]+Acceptance/{f=1; print; next} f && /^##[[:space:]]/{f=0} f' <<< "$1")"
  if [ -n "$sec" ]; then printf '%s\n' "$sec"; else printf '(no `## Acceptance` section, so the whole body)\n\n%s\n' "$1"; fi
}

# prior_review_pick <REST-reviews-json-array> → the newest OWN review that came from an LLM pass
# (mechanical approvals carry no findings), in ANY state: a push dismisses the previous round's
# verdict, and that dismissed review is exactly the round memory (ADR-156 finding contract).
# Empty = round 1.
prior_review_pick() {
  jq -r --arg me "$SPECS_REVIEWER_LOGIN" '
    [ .[] | select(((.user.login // "") | sub("\\[bot\\]$"; "")) == $me)
          | select((.body // "") | contains("## Specs review"))
          | select((.body // "") | contains("Verdict: APPROVE — mechanical:") | not) ]
    | sort_by(.submitted_at) | last // empty
    | "previous review: \(.state) at \((.commit_id // "")[0:12]) (\(.submitted_at))\n\n\(.body)"' <<< "$1"
}

# prior_for_root <prior-review-text> <root> → the prior review as ONE root's pass may read it. A
# multi-root verdict (aggregate_review: one `### Root \`<root>\` — …` section per root) carries
# every root's findings, but a root's pass sees only its own root's pack — handed the whole review,
# it marks the other roots' findings "still open, not verifiable here". So it keeps the first line
# (state, head, time), that root's section and the `specs-review head=` trailer (the pack's
# prior-ruling carry reads it); a root with no section gets a round-1 line for that root. A review
# with no root sections (a single-root round) is passed whole: nothing in it names a root.
prior_for_root() {
  if ! grep -q '^### Root `' <<< "$1"; then printf '%s\n' "$1"; return 0; fi
  awk -v hdr="### Root \`$2\`" -v root="$2" '
    NR == 1 { first = $0; next }
    /^### Root `/ { insec = (index($0, hdr) == 1); if (insec) found = 1 }
    /<!--[[:space:]]*specs-review[[:space:]]+head=/ { trailer = $0; if (insec) intrailer = 1; else next }
    insec { sec = sec $0 "\n" }
    END {
      if (!found) {
        sub(/^previous review: /, "", first)
        printf "previous review: none for root `%s` — the newest own review (%s) covered other roots only; this is round 1 for this root\n", root, first
        exit
      }
      printf "%s\n\n(the section for root `%s` of a multi-root review; each other root is reviewed in its own pass)\n\n## Specs review\n%s", first, root, sec
      if (trailer != "" && !intrailer) printf "\n%s\n", trailer
    }' <<< "$1"
}

# ── several spec roots in one PR: one pass per root, one verdict ────────────────────────────
# touched-rules and evidence-pack take ONE specs root, so a PR touching N root pairs gets N packs,
# one per tick (each pass keeps the whole LLM_TIMEOUT_S). Each root's review is held as a COMMENT
# keyed `<!-- specs-review root=<root> head=<content sha8> -->`; when every touched root has one
# at the content commit, ONE review carries them all (GitHub counts one approval per identity):
# CHANGES_REQUESTED when any root's is. A push moves the content commit and every root re-runs; a
# body edit that re-opens our CHANGES_REQUESTED drops the root reviews held from before it.
# root_review_of <own-comments-json [{body}]> <root> <sha8> → that root's review body (from its
# `## Specs review` line to the marker), newest first; "" = not reviewed at this content commit
root_review_of() {
  jq -r --arg m "<!-- specs-review root=$2 head=$3 -->" '[ .[] | (.body // "") | select(contains($m)) ] | last // ""' <<< "$1" \
    | awk -v m="<!-- specs-review root=$2 head=$3 -->" 'index($0, m) {exit} /^## Specs review/{f=1} f'
}
# root_comment <root> <i> <n> <sha8> <review-file> → the comment body that holds one root's review
root_comment() {
  printf 'SPECS ROOT REVIEW %s/%s: `%s` at content commit %s. This PR touches %s spec roots; each gets its own pass (one per tick) and ONE verdict is posted when all have one.\n\n' "$2" "$3" "$1" "$4" "$3"
  cat "$5"
  printf '\n\n<!-- specs-review root=%s head=%s -->\n' "$1" "$4"
}
# aggregate_review <head> <root>=<review-file> … → the ONE review body: a single `Verdict:` line
# (CHANGES_REQUESTED naming each root's blocking IDs when any root requests changes, else APPROVE),
# then each root's body under `### Root` with its own `Verdict:` prefix dropped — so the body has
# one verdict line for parse_verdict and never reads as a mechanical approval to prior_review_pick.
aggregate_review() {
  local head="$1" kv root f v line tail rc_part="" roots="" sections=""; shift
  for kv in "$@"; do
    root="${kv%%=*}"; f="${kv#*=}"
    line="$(grep -m1 -E '^Verdict:' "$f" || true)"; v="$(parse_verdict "$line")"
    tail="$(sed -E 's/^Verdict:[[:space:]]*//' <<< "$line")"
    roots="${roots:+$roots, }\`${root}\`"
    [ "$v" = CHANGES_REQUESTED ] && rc_part="${rc_part:+$rc_part; }${root}: $(sed -E 's/^CHANGES_REQUESTED[[:space:]]*[—-]*[[:space:]]*//' <<< "$tail")"
    sections="${sections}"$'\n'"### Root \`${root}\` — ${tail:-no verdict line}"$'\n'"$(grep -v -E '^(## Specs review|Verdict:)' "$f")"$'\n'
  done
  printf '## Specs review\n'
  if [ -n "$rc_part" ]; then printf 'Verdict: CHANGES_REQUESTED — %s\n' "$rc_part"
  else printf 'Verdict: APPROVE — %s spec roots, each approved in its own pass: %s\n' "$#" "$roots"; fi
  printf '\nThis PR touches %s spec roots (head %s); each root was reviewed in its own pass, held as a `SPECS ROOT REVIEW` comment, and is carried here whole.\n%s' "$#" "${head:0:12}" "$sections"
}

# llm_env_args <dispatch-json> <home-dir> → one `K=V` per line: the COMPLETE env the model runs
# under (`env -i`). Exactly: the gateway's `env` map verbatim (keys validated — a shell-hostile
# key is a refusal, exit 1), the OTEL/telemetry vars this pod carries, PATH, and a throwaway
# HOME (created here; seeded with the image's .claude.json — onboarding/trust state — when
# present, never its credential files and NEVER its settings.json). GH_TOKEN, GH_TOKEN_FILE,
# PUSHGATEWAY, GATEWAY_URL and the rest of the pod env are NOT in it — the token file stays
# unreadable by construction (allow-listed Read).
# Why no settings.json (homelab#2654 follow-through): both agent images seed one with
# `permissions.allow: [Bash(*), Read(*), Edit(*), Write(*), WebSearch(*), WebFetch(*)]` (plus
# skipDangerousModePermissionPrompt, which only matters under bypass mode, never used here).
# Settings allow-rules UNION with --allowedTools, so copying it voided the allow-list: a
# prompt-injected diff could run Bash, Read the token file / /proc, and reach the network. The
# file's other levers (env, hooks, apiKeyHelper) would breach `env -i` the same way, so nothing
# from it is seeded — `claude -p --permission-mode default` needs none of it.
llm_env_args() {
  local resp="$1" home="$2" k v
  mkdir -p "$home/.claude"
  [ -f "${HOME:-/nonexistent}/.claude.json" ] && cp "${HOME}/.claude.json" "$home/.claude.json"
  printf 'HOME=%s\nPATH=%s\nTMPDIR=%s\n' "$home" "${PATH:-/usr/local/bin:/usr/bin:/bin}" "$home"
  for k in CLAUDE_CODE_ENABLE_TELEMETRY OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER OTEL_TRACES_EXPORTER OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_ENDPOINT OTEL_RESOURCE_ATTRIBUTES; do
    [ -n "${!k:-}" ] && printf '%s=%s\n' "$k" "${!k}"
  done
  while IFS= read -r k && IFS= read -r v; do
    valid_env_key "$k" || { log "refusing env key '${k}' from the gateway" >&2; return 1; }
    printf '%s=%s\n' "$k" "$v"
  done < <(jq -r '.env | to_entries[] | .key, .value' "$resp")
}

# current_head <repo> <pr> → the PR's headRefOid now (a seam: --self-test overrides it)
current_head() { gh pr view "$2" --repo "${ORG}/$1" --json headRefOid -q .headRefOid; }
# review_submit <repo> <pr> <approve|request-changes> <body-file> <reviewed-head>
#   → 0 submitted · 3 head moved (no verdict; the next tick reads the new head) · 1 submit failed
# The verdict is PINNED to the head that was reviewed (bot review, PR#2613 round 2): the LLM
# path holds its head for minutes (gateway + model), and a plain `gh pr review` attaches to
# whatever head exists at submit time — a push in that window would make an UNREVIEWED head read
# as `own-at-head` next tick (dismiss_stale_reviews_on_push only dismisses reviews submitted
# BEFORE the push). Two belts: re-read the head immediately before submitting and drop the
# verdict if it moved; and submit through the REST reviews endpoint with `commit_id` = the
# reviewed head, so a race lost between the re-read and the POST still lands on the OLD commit,
# where the push has already made it stale.
review_submit() {
  local repo="$1" num="$2" kind="$3" bodyfile="$4" reviewed="$5" now event
  now="$(current_head "$repo" "$num")" || { log "[$repo#$num] head re-read FAILED before submit — no verdict"; return 1; }
  if [ "$now" != "$reviewed" ]; then
    log "[$repo#$num] head moved before submit (${reviewed:0:8} → ${now:0:8}) — verdict dropped, the next tick reviews the new head"; return 3
  fi
  case "$kind" in approve) event=APPROVE;; request-changes) event=REQUEST_CHANGES;; *) log "review_submit: bad kind '$kind'"; return 1;; esac
  gh api -X POST "repos/${ORG}/${repo}/pulls/${num}/reviews" -f "commit_id=${reviewed}" -f "event=${event}" -F "body=@${bodyfile}" >/dev/null
}

# ── token: the gh wrapper prefers GH_TOKEN_FILE (live, ESO re-mints ~hourly); git/curl need the value ──
token() {
  if [ -n "${GH_TOKEN_FILE:-}" ] && [ -s "$GH_TOKEN_FILE" ]; then cat "$GH_TOKEN_FILE"; else printf '%s' "${GH_TOKEN:-}"; fi
}

# ── the pass's readers (the live tick and the shadow run share them) ────────────────────────────
# issue_intent <slug> <pr> → markdown: each closing issue's acceptance text, else the first `Refs #N`
# issue's (never fails the pass)
issue_intent() {
  local slug="$1" num="$2" refs r n body
  if ! refs="$(gh pr view "$num" --repo "$slug" --json closingIssuesReferences \
                --jq '.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name) \(.number)"' 2>/dev/null)"; then
    printf 'issue intent: the closing-issue lookup FAILED; pr-body.md names the reference, the acceptance text is not available\n'; return 0
  fi
  if [ -z "$refs" ]; then
    # A `Refs #N` line (agents/pr-open.sh's form for an issue the PR does not finish) still names
    # the intent the rows derive from — same repo only, the first one.
    n="$(gh pr view "$num" --repo "$slug" --json body --jq '.body // ""' 2>/dev/null \
          | grep -ioE '\brefs[[:space:]]+#[0-9]+\b' | sed -n 1p | grep -oE '[0-9]+')" || n=""
    [ -n "$n" ] && refs="$slug $n"
  fi
  if [ -z "$refs" ]; then
    printf 'issue intent: none, this PR closes no issue (check 1 grounds rows in the page prose, a use case or Spec changes:)\n'; return 0
  fi
  while read -r r n; do
    [ -n "$n" ] || continue
    if body="$(gh issue view "$n" --repo "$r" --json title,body --jq '"# " + .title + "\n\n" + (.body // "")' 2>/dev/null)"; then
      printf '## %s#%s\n\n%s\n\n' "$r" "$n" "$(acceptance_of "$body")"
    else
      printf '## %s#%s\n\nnot readable by this identity; the acceptance text is not available\n\n' "$r" "$n"
    fi
  done <<< "$refs"
}
# evidence_fetch <repo> <prefix> <sha> <dir> → evidence/<prefix>/<sha>.tar.gz unpacked into <dir>
# (rc 1 = absent, or the repo has no evidence bucket)
evidence_fetch() {
  local b; b="$(evidence_bucket "$1")"
  [ -n "$b" ] || return 1
  rm -rf "$4"; mkdir -p "$4"
  curl -fsS --max-time 60 -H "Host: ${b}.teststuff.net" "${EVIDENCE_WEB}/evidence/$2/$3.tar.gz" 2>/dev/null | tar -xz -C "$4" 2>/dev/null \
    && [ -s "$4/evidence.json" ] || return 1
}
# evidence_download <slug> <head> <dir> <pr-number> → the head's evidence pack unpacked into <dir>
# from the bucket's evidence/pr-<N>/<head> (rc 1 = none: ci published no pack at that head, or the
# repo has no evidence bucket — the pack states the absence)
evidence_download() {
  if evidence_fetch "${1#*/}" "pr-$4" "$2" "$3"; then
    log "evidence: bucket evidence/pr-$4/${2:0:8} → $(find "$3" -type f | wc -l) file(s)"; return 0
  fi
  log "evidence: no pack at bucket evidence/pr-$4/${2:0:8}"; return 1
}
# evidence_baseline_download <slug> <base> <dir> [<ancestor-of>] → "<evidence.json path> <commit sha>"
# from the bucket: the newest of the first 100 first-parent commits of <ancestor-of> (default
# origin/<base>) with a pack under evidence/<base>/ — ancestry by construction; "" = none. The
# gateway step runs only on gateway changes, so a commit without a pack is skipped. <ancestor-of>
# (the shadow run's replay) walks back from that rev instead — the baseline the live reviewer
# could have seen.
evidence_baseline_download() {
  local slug="$1" base="$2" dir="$3" anc="${4:-}" sha
  if [ -n "$(evidence_bucket "${slug#*/}")" ]; then
    while read -r sha; do
      [ -n "$sha" ] || continue
      if evidence_fetch "${slug#*/}" "$base" "$sha" "$dir"; then printf '%s %s\n' "$dir/evidence.json" "$sha"; return 0; fi
    done <<< "$(git -C "$WORK/repo" rev-list --first-parent -n 100 "${anc:-origin/${base}}" 2>/dev/null || true)"
  fi
  printf '\n'
}

# pack_diff_base <git-dir> <base-rev> <head-ref> <upstream-ref> → the rev evidence-pack diffs from
# (stdout; rc 0 always — a failed step answers <base-rev>, the unnarrowed diff, and says so on
# stderr). The PR's spec diff is what the PR ITSELF changes. A PR on a non-default base (a
# `goal/**` branch) that merged the default branch in carries the upstream's commits, already
# reviewed where they merged; three-dot `<base>...<head>` (the pinned pack's only diff form) shows
# them as the PR's. So: M = merge-base(upstream, head) — the newest upstream commit the head holds.
# When M is already inside B0 = merge-base(base, head), nothing was merged in: <base-rev> unchanged.
# Else every path the BASE side left alone since X = merge-base(B0, M) and whose content at head is
# byte-identical to M's (present in both, or absent from both) is not the PR's change — upstream
# content carried in whole. A path the base side changed since X stays in the diff even when head
# == M: there the merge DISCARDED the base's edit, and that is the PR's change. a synthetic commit = B0's tree with those paths taken from M, made
# an ANCESTOR of head by a graft in this throwaway clone (`git replace --graft`, the head keeps its
# sha and tree — the evidence stamp compares the sha), so three-dot's merge-base is that commit and
# the diff carries only paths the PR made differ. Path-level: a path both sides changed keeps the
# upstream's hunks too (no merge-tree, no conflict handling). Reads stay in the clone: no API call.
pack_diff_base() {
  local g="$1" base="$2" head="$3" up="$4" b0 m x idx tree bp n=0 p entry
  local -a parents
  b0="$(git -C "$g" merge-base "$base" "$head" 2>/dev/null)" || { printf '%s' "$base"; return 0; }
  m="$(git -C "$g" merge-base "$up" "$head" 2>/dev/null)" || { printf '%s' "$base"; return 0; }
  if git -C "$g" merge-base --is-ancestor "$m" "$b0" 2>/dev/null; then printf '%s' "$base"; return 0; fi
  x="$(git -C "$g" merge-base "$b0" "$m" 2>/dev/null)" || { printf '%s' "$base"; return 0; }
  idx="$(mktemp)"; rm -f "$idx"
  if ! GIT_INDEX_FILE="$idx" git -C "$g" read-tree "$b0"; then
    log "WARN pack diff base: read-tree ${b0:0:8} failed — the spec diff stays ${base}...head" >&2; printf '%s' "$base"; return 0
  fi
  # (paths B0→head changes MINUS paths M→head changes = where head == M and != B0) MINUS paths the
  # base side changed since X (X→B0)
  while IFS= read -r -d '' p; do
    entry="$(git -C "$g" ls-tree "$m" -- "$p")"
    if [ -n "$entry" ]; then
      GIT_INDEX_FILE="$idx" git -C "$g" update-index --add --cacheinfo "$(awk '{print $1}' <<< "$entry"),$(awk '{print $3}' <<< "$entry"),$p"
    else
      GIT_INDEX_FILE="$idx" git -C "$g" update-index --force-remove -- "$p"
    fi || { log "WARN pack diff base: index update for ${p} failed — the spec diff stays ${base}...head" >&2; rm -f "$idx"; printf '%s' "$base"; return 0; }
    n=$((n+1))
  done < <(comm -z -23 <(comm -z -23 <(git -C "$g" diff -z --no-renames --name-only "$b0" "$head" | sort -z) \
                                     <(git -C "$g" diff -z --no-renames --name-only "$m" "$head" | sort -z)) \
                      <(git -C "$g" diff -z --no-renames --name-only "$x" "$b0" | sort -z))
  if [ "$n" -eq 0 ]; then rm -f "$idx"; printf '%s' "$base"; return 0; fi
  mapfile -t parents < <(git -C "$g" rev-parse "${head}^@")
  if tree="$(GIT_INDEX_FILE="$idx" git -C "$g" write-tree)" \
     && bp="$(git -C "$g" -c user.name=specs-review -c user.email=specs-review@invalid commit-tree -p "$b0" -p "$m" -m "specs-review: diff base (${b0:0:8} + ${n} path(s) as at upstream ${m:0:8})" "$tree")" \
     && git -C "$g" replace -f --graft "$(git -C "$g" rev-parse "$head")" "${parents[@]}" "$bp"; then
    rm -f "$idx"
    log "pack diff base: head holds upstream ${m:0:8}; ${n} path(s) identical to it are not this PR's change (diff base ${bp:0:8})" >&2
    printf '%s' "$bp"; return 0
  fi
  rm -f "$idx"
  log "WARN pack diff base: synthetic base failed — the spec diff stays ${base}...head" >&2; printf '%s' "$base"
}

# ── the context pack (ADR-156): ONE builder for the live pass and the shadow run ────────────────
# build_pack <repo> <num> <base-branch> <head> [<specs-root> <tests-root|->] → builds $WORK/inputs
# (the model's cwd) and $WORK/lens.md (the system prompt) for ONE root pair (default: pack_roots). rc 0 built · 1 no review (logged; fail CLOSED) · 2 the head
# moved while fetching (logged; live only) · 4 touched-rules found no rule (the mechanical case).
# EVERY step is checked explicitly: the live caller runs under `|| LLM_RC=$?`, which suspends
# `set -e` (bot review, PR#2613 finding 2) — an unchecked failed fetch would hand the model an
# empty input set, and an empty diff reads as a clean APPROVE. A blocking lens fails CLOSED.
# SHADOW (set by shadow_main) changes four READS, never the pack's shape: the head is fetched by
# sha (a judged head may predate the PR's last push), the base rev is merge-base(origin/<base>,
# head), the PR body / prior review are as of $SHADOW_ASOF, and the baseline is an ancestor of
# that base.
build_pack() {
  local repo="$1" num="$2" base="$3" head="$4" specs_root="${5:-}" tests_root="${6:-}" primary_root _t
  read -r primary_root _t <<< "$(pack_roots "$repo")"
  [ -n "$specs_root" ] || { specs_root="$primary_root"; tests_root="$_t"; }
  PACK_NOTE=""
  local slug="${ORG}/${repo}" inputs="$WORK/inputs" lens="$WORK/lens.md"
  local ctx="$WORK/ctx"; mkdir -p "$ctx"
  # 1) the lens IS the system prompt — a fetch failure is no review (blocking never degrades)
  if ! curl -fsS --max-time 15 "${LENS_BASE}/specs.md" -o "$lens" || ! grep -q '^# LENS: specs' "$lens"; then
    log "[$repo#$num] LENS FETCH FAILED (${LENS_BASE}/specs.md) — no review; a blocking lens never degrades to advisory"; return 1
  fi
  # 2) inputs — the lens's scope and nothing else, built BEFORE admission (a session is held
  #    only while the model runs). The LLM's cwd holds ONLY these.
  local ah="http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$(token)" | base64 | tr -d '\n')"
  git clone -q -c "$ah" --no-tags --single-branch -b "$base" "https://github.com/${slug}.git" "$WORK/repo" \
    || { log "[$repo#$num] clone of ${slug}@${base} FAILED — no review"; return 1; }
  local base_rev="origin/${base}"
  if [ -z "${SHADOW:-}" ]; then
    git -C "$WORK/repo" fetch -q origin "pull/${num}/head:pr-${num}" \
      || { log "[$repo#$num] fetch of pull/${num}/head FAILED — no review"; return 1; }
    local fetched; fetched="$(git -C "$WORK/repo" rev-parse "pr-${num}")" || { log "[$repo#$num] rev-parse FAILED — no review"; return 1; }
    if [ "$fetched" != "$head" ]; then log "[$repo#$num] head moved while fetching (${head:0:8} → ${fetched:0:8}) — the next tick reads the new head"; return 2; fi
  else
    { git -C "$WORK/repo" fetch -q origin "$head" && git -C "$WORK/repo" branch -q -f "pr-${num}" "$head"; } \
      || { log "[$repo#$num] fetch of the judged head ${head:0:8} FAILED — no review"; return 1; }
    base_rev="$(git -C "$WORK/repo" merge-base "origin/${base}" "pr-${num}")" \
      || { log "[$repo#$num] merge-base origin/${base} × ${head:0:8} FAILED — no review"; return 1; }
    SHADOW_BASE_COMMIT="$base_rev"
  fi
  # 2a) the diff base: on a non-default base, the default branch's content the head merged in is
  #     not the PR's change (pack_diff_base). The default branch is the remote's HEAD symref — a
  #     git read, no API call; a default-branch PR skips it entirely (its three-dot already holds M).
  local diff_base="$base_rev" upstream
  upstream="$(git -C "$WORK/repo" ls-remote --symref origin HEAD 2>/dev/null | awk '$1 == "ref:" { sub("^refs/heads/", "", $2); print $2; exit }')" || upstream=""
  if [ -n "$upstream" ] && [ "$upstream" != "$base" ]; then
    if git -C "$WORK/repo" fetch -q origin "+refs/heads/${upstream}:refs/remotes/origin/${upstream}"; then
      diff_base="$(pack_diff_base "$WORK/repo" "$base_rev" "pr-${num}" "origin/${upstream}")"
    else
      log "[$repo#$num] WARN fetch of ${upstream} FAILED — the spec diff stays ${base}...head (upstream content the head merged in reads as the PR's)"
    fi
  fi
  # 2b) the pinned process: the wheel, verified by digest, extracted (never zip-imported)
  curl -fsSL --max-time 60 --retry 3 --retry-all-errors --retry-max-time 90 "$SNIPPETS_WHEEL" -o "$WORK/snippets.whl" \
    || { log "[$repo#$num] snippets wheel fetch FAILED — no review"; return 1; }
  [ "$(sha256sum "$WORK/snippets.whl" | cut -d' ' -f1)" = "$SNIPPETS_SHA256" ] \
    || { log "[$repo#$num] snippets wheel DIGEST MISMATCH (pinned ${SNIPPETS_SHA256:0:12}) — no review"; return 1; }
  python3 -m zipfile -e "$WORK/snippets.whl" "$WORK/snippets" \
    || { log "[$repo#$num] snippets wheel extract FAILED — no review"; return 1; }
  # 3) the context the pack carries but cannot fetch itself: PR body, issue intent, prior review
  if [ -z "${SHADOW:-}" ]; then
    gh pr view "$num" --repo "$slug" --json title,body,url -q '"# " + .title + "\n\n" + .url + "\n\n" + (.body // "")' > "$ctx/pr-body.md" \
      || { log "[$repo#$num] PR body read FAILED — no review"; return 1; }
  else
    pr_body_as_of "$slug" "$num" "$SHADOW_ASOF" > "$ctx/pr-body.md" \
      || { log "[$repo#$num] PR body (as of ${SHADOW_ASOF}) read FAILED — no review"; return 1; }
  fi
  [ -s "$ctx/pr-body.md" ] || { log "[$repo#$num] PR body read came back EMPTY — no review"; return 1; }
  issue_intent "$slug" "$num" > "$ctx/issue-intent.md"
  local revs prior
  if revs="$(gh api --paginate "repos/${slug}/pulls/${num}/reviews" --jq '.[]' 2>/dev/null | jq -s .)"; then
    [ -n "${SHADOW:-}" ] && revs="$(jq -c --arg t "$SHADOW_ASOF" '[ .[] | select((.submitted_at // "") < $t) ]' <<< "$revs")"
    prior="$(prior_review_pick "$revs")"
    [ -n "$prior" ] && prior="$(prior_for_root "$prior" "$specs_root")"
    printf '%s\n' "${prior:-previous review: none, this is round 1}" > "$ctx/prior-review.md"
  else
    printf 'previous review: the reviews read FAILED; treat this as round 1 and say so\n' > "$ctx/prior-review.md"
  fi
  # 3b) evidence: the head's raw Allure results + the base branch's evidence.json (the baseline),
  #     both from the bucket (evidence_fetch). Absent evidence is NOT a refusal: an empty results dir makes
  #     the pack say so, and the evidence brief turns that into E-STALE / NO_EVIDENCE findings.
  #     The repo's bucket is its PRIMARY root's (evidence_bucket: homelab →
  #     gateway-specs): an extra root has no evidence publisher, so its pack carries none and says
  #     why (PACK_NOTE → the prompt) instead of borrowing another root's records.
  local results="$WORK/head-ev/allure-results" bl_json="" bl_commit=""
  mkdir -p "$WORK/head-ev"
  if [ "$specs_root" = "$primary_root" ]; then
    evidence_download "$slug" "$head" "$WORK/head-ev" "$num" || true
    mkdir -p "$results"
    if read -r bl_json bl_commit <<< "$(evidence_baseline_download "$slug" "$base" "$WORK/base-ev" ${SHADOW:+"$base_rev"})" && [ -n "$bl_json" ]; then
      log "[$repo#$num] baseline: ${base}@${bl_commit:0:8}"
    else
      bl_json=""; log "[$repo#$num] baseline: none (no pack under evidence/${base}/ on the last 100 first-parent commits)"
    fi
  else
    mkdir -p "$results"
    PACK_NOTE=" This pack's specs root is ${specs_root} (tests root: $([ "$tests_root" = - ] && echo 'none declared' || echo "$tests_root")). No evidence pipeline publishes for this root yet, so the pack's evidence is absent by construction, not by a failed fetch."
    log "[$repo#$num] evidence: none for ${specs_root} (no evidence pipeline for an extra root; the pack states it)"
  fi
  # 3c) the context pack (allure-behavior-snippets evidence-pack): touched rules + sections + the
  #     spec diff + the specs tree + evidence + digest + attachments + baseline + process/ briefs.
  #     It IS the model's inputs dir. A pack failure is no review (fail closed).
  #     A root with no tests root ("-") passes its specs root as --tests-root: the pack's default
  #     (`tests`) would make homelab's top-level tests/ this root's, and the specs root holds no .py,
  #     so rules are reached through the spec pages alone.
  [ "$tests_root" = - ] && tests_root="$specs_root"
  log "[$repo#$num] pack roots: ${specs_root} ${tests_root}"
  local -a packargs=("$diff_base" "pr-${num}" "$results" --repo "$WORK/repo" --specs-root "$specs_root"
    --tests-root "$tests_root" --prior-review "$ctx/prior-review.md" --issue-intent "$ctx/issue-intent.md"
    --pr-body "$ctx/pr-body.md" --out "$inputs")
  [ -n "$bl_json" ] && packargs+=(--baseline "$bl_json" --baseline-commit "$bl_commit")
  STAGED=0
  if [ "$SPECS_STAGED_READ" = 1 ] && evidence_pack --help 2>/dev/null | grep -q -- '--mask-descriptions'; then
    packargs+=(--mask-descriptions); STAGED=1
  fi
  evidence_pack "${packargs[@]}" > "$WORK/pack.log" 2>&1 \
    || { log "[$repo#$num] evidence-pack FAILED — no review: $(tail -c 300 "$WORK/pack.log" | tr '\n' ' ')"; return 1; }
  local n_rules; n_rules="$(grep -c . "$inputs/touched-rules.txt" 2>/dev/null || true)"
  # the file list hit a specs/test path but no rule is touched (prose, a fixture, a helper):
  # nothing for either brief — the caller's mechanical approval, said so
  [ "${n_rules:-0}" -eq 0 ] && return 4
  log "[$repo#$num] pack: ${n_rules} touched rule(s): $(tr '\n' ' ' < "$inputs/touched-rules.txt" | head -c 300)"
  if [ "$STAGED" = 1 ]; then
    pass1_inputs "$inputs" "$WORK/pass1" \
      || { log "[$repo#$num] the pack offers --mask-descriptions but its manifest declares no usable masked surface (masked.files) — no review"; return 1; }
    log "[$repo#$num] staged read: pass 1 over $(jq -r '.masked.files | length' "$inputs/manifest.json") masked file(s)"
  fi
  # the system prompt: homelab's wiring lens + the pinned briefs (finding contract first)
  local b
  for b in finding-contract rows evidence; do
    [ -s "$inputs/process/briefs/$b.md" ] || { log "[$repo#$num] pack has no process/briefs/$b.md — no review"; return 1; }
    printf '\n\n---\n\n' >> "$lens"; cat "$inputs/process/briefs/$b.md" >> "$lens"
  done
  return 0
}

# evidence_pack <args…> — the pinned wheel's pack builder (stdlib python3, extracted wheel)
evidence_pack() {
  PYTHONPATH="$WORK/snippets" python3 -c 'import sys; sys.argv[0] = "evidence-pack"; from allure_behavior_snippets.pack import main; sys.exit(main())' "$@"
}
# pass1_inputs <pack> <dest> → pass 1's world: EXACTLY the files the pack's manifest declares masked
# (`masked.files`, pack-relative) + process/ + manifest.json. An ALLOW-list: a surface the producer
# left unmasked (tree/, evidence/, attachments/, the full sections) is absent from pass 1, never
# leaked into it. A path escaping the pack, the key map itself (`masked.keys`), a missing file
# or an empty list is a refusal: a pack that offers the staged read must carry its surface.
pass1_inputs() {
  local pack="$1" dest="$2" keys f
  keys="$(jq -r '.masked.keys // "row-keys.tsv"' "$pack/manifest.json" 2>/dev/null)" || return 1
  local -a files=(); mapfile -t files < <(jq -r '.masked.files[]? // empty' "$pack/manifest.json" 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 1
  rm -rf "$dest"; mkdir -p "$dest"
  for f in "${files[@]}"; do
    case "$f" in /*|..|../*|*/..|*/../*|"$keys") return 1;; esac
    [ -f "$pack/$f" ] || return 1
    mkdir -p "$dest/$(dirname "$f")" && cp "$pack/$f" "$dest/$f" || return 1
  done
  cp -r "$pack/process" "$dest/process" && cp "$pack/manifest.json" "$dest/manifest.json"
}
# pass1_prompt <slug> <num> <head> → pass 1 of the staged read: the rows brief's check 10, first half
pass1_prompt() {
  printf '%s' "You are the specs reviewer for pull request ${1}#${2} (head ${3}), on PASS 1 of a staged read. Your working directory holds the MASKED surface only (manifest.json, masked.files): every decision table's description cell is replaced by its row key r<table>.<row>; prose, headers, inputs, expected cells and worlds are in view. process/RULES.md, process/CONVENTIONS.md and process/briefs/rows.md are the pinned process. Do the first half of the rows brief's check 10: read every touched table's rows from their cells alone and record each row whose conditions or outcome cannot be placed without the hidden description, plus any other rows-brief finding the masked tables show. Never guess a description. Write ONLY a findings list, one line per finding: '- <row key or page anchor> — <rule or check> — <what the cells alone do not settle>', or the single line '- none'. No Verdict line: this list is frozen and handed to pass 2. pass1-prior.tsv, when present, lists row keys a prior round's pass 2 already ruled on (key, ruling, round, rule): re-list EVERY one of them, one line each, as '- <key> — prior: ruled <ruling> round <N>' without re-arguing it — a survives/noted key is not raised as new, a withdrawn/contradicted key is not raised again on the same grounds. Do not run commands, do not fetch anything."
}
# review_prompt <slug> <num> <head> → the user prompt every harness gets (the brief's entry point);
# on a staged read ($STAGED=1) it is pass 2 and adds the frozen pass 1's adjudication
review_prompt() {
  local staged=""
  [ "${STAGED:-0}" = 1 ] && staged=" This review is PASS 2 of a staged read: pass1.md is your frozen first pass over the masked surface (row keys r<table>.<row>; row-keys.tsv joins each key to its description). Before your new findings, mark EVERY pass-1 finding survives, contradicted or withdrawn against the revealed description and its cells. A finding the description alone explains SURVIVES (check 10: a condition that lives only in the description), the reveal never repairs it. Then the new intent findings. Never rewrite pass1.md."
  printf '%s' "You are the specs reviewer for pull request ${1}#${2} (head ${3}). Your working directory is the context pack and holds your ONLY inputs; your Read and Glob tools are scoped to it. Start with manifest.json (what the pack holds and what was not provided), then intent: pr-body.md, issue-intent.md, spec-sections.md (each touched rule's section at the head + the spec diff), tree/ (the specs at the head, for neighbours), process/RULES.md and process/CONVENTIONS.md (the pinned process your briefs cite). Then evidence: digest.md first (its Stamp:, Baseline: and precomputed findings), the per-rule <RULE>.md tables, evidence/<RULE>.json for ONE rule's records (never the whole evidence.json: it holds every touched rule and can exceed your context), baseline-evidence.json, and attachments/ where a row's value is still unproven. prior-review.md is your previous review of this PR: on a later round, mark each of its findings resolved or still open FIRST. Apply BOTH briefs (rows, evidence) under the finding contract and write ONLY the review body in its Output shape, starting with the line '## Specs review' and then the line 'Verdict: APPROVE — …' or 'Verdict: CHANGES_REQUESTED — <blocking finding IDs>'. Do not run commands, do not fetch anything, do not submit the review yourself: the launcher submits what you return.${PACK_NOTE:-}${staged}"
}

# ── the harnesses: ONE home per CLI invocation. Each runs CONFINED — `env -i` with exactly the
# lines of $WORK/env.list (llm_env_args: the gateway's dispatch env verbatim + OTEL + a throwaway
# HOME) — in the pack, bounded by LLM_TIMEOUT_S (124 = timed out). What a harness adds is never
# LLM-shaped (no base url, key or model: GW-SESSIONS-ENV) — only its prompt, system prompt and
# tool scope.
# harness_claude <inputs> <lens> <prompt> <model> → $WORK/result.json (claude's JSON result)
#   The allow-list tool scope (bot review, PR#2613 finding 1): `Read(//<inputs>/**)` (`//` =
#   filesystem root in Claude Code's rule grammar, so the leading `/` of the absolute path is
#   stripped) + Glob, permission-mode default — in `-p` mode a tool call outside the allow-list is
#   denied, not prompted; Grep/Bash/Write are not granted at all (Grep's rule grammar is not
#   path-scoped, and the inputs are small).
harness_claude() {
  local inputs="$1" lens="$2" prompt="$3" model="$4" limit="${5:-$LLM_TIMEOUT_S}"
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  (cd "$inputs" && timeout "${limit}" env -i "${envargs[@]}" claude -p "$prompt" --model "$model" --append-system-prompt-file "$lens" \
      --allowedTools "Read(//${inputs#/}/**)" "Glob" --permission-mode default --output-format json > "$WORK/result.json")
}
# harness_opencode <inputs> <lens> <prompt> → $WORK/result.txt (the final message, plain text)
#   SHADOW ONLY (no live consumer). System prompt = opencode's global rules file in the throwaway
#   HOME; tool scope = OPENCODE_PERMISSION (edit/bash/webfetch/external_directory denied — read,
#   glob, grep, list stay, inside the cwd). Model/provider come ONLY from the dispatch env (⚖
#   GW-SESSIONS-ENV verify rows: whatever opencode really reads is what the gateway must hand it).
harness_opencode() {
  local inputs="$1" lens="$2" prompt="$3" limit="${4:-$LLM_TIMEOUT_S}" home
  home="$(sed -n 's/^HOME=//p' "$WORK/env.list" | head -1)"
  mkdir -p "$home/.config/opencode" && cp "$lens" "$home/.config/opencode/AGENTS.md" || return 1
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  envargs+=('OPENCODE_PERMISSION={"edit":"deny","bash":"deny","webfetch":"deny","external_directory":"deny"}'
            OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_SHARE=1)
  (cd "$inputs" && timeout "${limit}" env -i "${envargs[@]}" opencode run "$prompt" < /dev/null > "$WORK/result.txt" 2> "$WORK/harness.err")  # opencode >=2 waits on piped stdin (agent-session.sh harness-run-cmd)
}
# harness_goose <inputs> <lens> <prompt> → $WORK/result.txt
#   SHADOW ONLY. System prompt = `--system`; tools = the `developer` builtin ONLY (--no-profile) —
#   goose has no path-scoped read, so this cell does NOT hold the allow-list half of the
#   confinement contract (its shell can read what the pod's uid can): recorded per run as
#   `confinement: "env-only"`, which is why shadow runs take merged, operator-authored PRs.
harness_goose() {
  local inputs="$1" lens="$2" prompt="$3" limit="${4:-$LLM_TIMEOUT_S}"
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  envargs+=(GOOSE_MODE=auto GOOSE_DISABLE_KEYRING=1 GOOSE_MAX_TURNS=60)
  (cd "$inputs" && timeout "${limit}" env -i "${envargs[@]}" goose run --no-session --no-profile --with-builtin developer -q \
      --system "$(cat "$lens")" -t "$prompt" > "$WORK/result.txt" 2> "$WORK/harness.err")
}

# harness_run <harness> <dir> <prompt> <model|""> <timeout_s> → the model's text in $WORK/result.txt
# (claude also leaves its JSON result in $WORK/result.json); rc = the harness's, 124 = timed out
harness_run() {
  local rc=0
  case "$1" in
    claude)   harness_claude "$2" "$WORK/lens.md" "$3" "$4" "$5" || rc=$?
              jq -r '.result // ""' "$WORK/result.json" > "$WORK/result.txt" 2>/dev/null || true;;
    opencode) harness_opencode "$2" "$WORK/lens.md" "$3" "$5" || rc=$?;;
    goose)    harness_goose "$2" "$WORK/lens.md" "$3" "$5" || rc=$?;;
    *) return 2;;
  esac
  return "$rc"
}
# review_run <harness> <slug> <num> <head> <model|""> → the review text in $WORK/result.txt (+ claude's
# $WORK/result.json), rc = the harness's. ONE admission covers both passes of a staged read: pass 1
# runs in $WORK/pass1 (its own Read scope — the full pack is out of reach) bounded by
# PASS1_TIMEOUT_S; its text is frozen as <pack>/pass1.md (claude's JSON kept as
# $WORK/pass1-result.json); pass 2 runs in the full pack with what is left of LLM_TIMEOUT_S. A pass 1
# that fails or says nothing ends the run with no pass 2 (rc ≠ 0: a harness death, never a verdict).
review_run() {
  local h="$1" slug="$2" num="$3" head="$4" model="$5" rc=0 t0 limit="$LLM_TIMEOUT_S"
  rm -f "$WORK/result.json" "$WORK/result.txt" "$WORK/pass1-result.json"
  if [ "${STAGED:-0}" = 1 ]; then
    t0="$SECONDS"
    harness_run "$h" "$WORK/pass1" "$(pass1_prompt "$slug" "$num" "$head")" "$model" "$PASS1_TIMEOUT_S" || rc=$?
    [ -f "$WORK/result.json" ] && mv "$WORK/result.json" "$WORK/pass1-result.json"
    if [ "$rc" -ne 0 ] || ! grep -q '[^[:space:]]' "$WORK/result.txt" 2>/dev/null; then
      log "pass 1 (masked) ended rc=${rc} with $(wc -c < "$WORK/result.txt" 2>/dev/null || echo 0) byte(s) — no pass 2"
      [ "$rc" -ne 0 ] || rc=1; rm -f "$WORK/result.txt"; return "$rc"
    fi
    mv "$WORK/result.txt" "$WORK/inputs/pass1.md"
    limit=$(( LLM_TIMEOUT_S - (SECONDS - t0) ))
    log "pass 1 (masked): $(grep -c '^- ' "$WORK/inputs/pass1.md" || true) finding line(s) frozen in $(( SECONDS - t0 )) s; pass 2 gets ${limit} s"
  fi
  harness_run "$h" "$WORK/inputs" "$(review_prompt "$slug" "$num" "$head")" "$model" "$limit" || rc=$?
  return "$rc"
}

# ── shadow run (--shadow): the read-only gh, the as-of readers, the per-PR record ───────────────
# gh_shadow_allows <gh args…> → 0 for a READ, 1 for anything else (an ALLOW-list: an unknown
# verb is a write until proven otherwise). `gh api` is a read only as GET: an explicit -X/--method
# other than GET refuses, and a field flag without -X makes gh POST (gh api's own default), so it
# refuses too; `gh api graphql` (always POST) passes only a query with no `mutation` and no
# `@file` field (a hidden body).
gh_shadow_allows() {
  case "${1:-} ${2:-}" in
    "pr view"|"pr list"|"pr diff"|"issue view"|"issue list"|"run list"|"run view") return 0;;
  esac
  [ "${1:-}" = api ] || return 1
  shift
  local a prev="" method="" fields=0 gql=0 body=""
  for a in "$@"; do
    case "$prev" in
      -X|--method) method="$a"; prev=""; continue;;
      -f|-F|--field|--raw-field) body="$body $a"; prev=""; continue;;
      --jq|-q|-H|--header|-t|--template|--cache|-p|--preview|--hostname) prev=""; continue;;
    esac
    case "$a" in
      --input|--input=*) return 1;;
      -X|--method) prev="$a";;
      -X?*) method="${a#-X}";;
      --method=*) method="${a#--method=}";;
      -f|-F|--field|--raw-field) prev="$a"; fields=$((fields+1));;
      --field=*|--raw-field=*) fields=$((fields+1)); body="$body ${a#*=}";;
      --jq|-q|-H|--header|-t|--template|--cache|-p|--preview|--hostname) prev="$a";;
      graphql) gql=1;;
    esac
  done
  [ -z "$prev" ] || return 1
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  if [ "$gql" = 1 ]; then
    { [ -z "$method" ] || [ "$method" = POST ]; } || return 1
    case "$body" in *[Mm][Uu][Tt][Aa][Tt][Ii][Oo][Nn]*|*=@*) return 1;; esac
    return 0
  fi
  [ "$method" = GET ] && return 0
  [ -z "$method" ] && [ "$fields" -eq 0 ] && return 0
  return 1
}
gh_real() { command gh "$@"; }   # a seam: --self-test records instead of executing
# gh_shadow <gh args…> → the read, or rc 97 (refused, logged) — installed as `gh` by shadow_main
gh_shadow() {
  if gh_shadow_allows "$@"; then gh_real "$@"; return $?; fi
  log "SHADOW: refused a GitHub write (gh $(printf '%s ' "${@:1:4}")…) — a shadow run never writes" >&2
  return 97
}
# pr_body_as_of <slug> <num> <iso-ts> → "# title\n\nurl\n\nbody" with the body as it read at <ts>:
# the newest userContentEdits entry at or before <ts> (its `diff` is the full body at that edit;
# the oldest entry is the body at creation); no edits = the current body.
pr_body_as_of() {
  local owner="${1%%/*}" name="${1##*/}" j
  j="$(gh api graphql -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){title url body userContentEdits(first:100){nodes{editedAt diff}}}}}' \
        -f o="$owner" -f n="$name" -F p="$2")" || return 1
  jq -r --arg t "$3" '.data.repository.pullRequest
    | ([ .userContentEdits.nodes[]? | select(.editedAt <= $t) | select(.diff != null) ] | sort_by(.editedAt) | last | .diff) as $b
    | "# " + .title + "\n\n" + .url + "\n\n" + ($b // .body // "")' <<< "$j"
}
# shadow_as_of <reviews-json> <head-sha> → submitted_at of the FIRST own review at <head> ("" = none)
shadow_as_of() {
  jq -r --arg me "$SPECS_REVIEWER_LOGIN" --arg h "$2" '
    [ .[] | select(((.user.login // "") | sub("\\[bot\\]$"; "")) == $me) | select((.commit_id // "") == $h) ]
    | sort_by(.submitted_at) | first | .submitted_at // empty' <<< "$1"
}
# shadow_record <file> <key=json …> → merge the pairs into the record (jq --argjson per pair)
shadow_record() {
  local f="$1" kv k v; shift
  [ -s "$f" ] || printf '{}' > "$f"
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    jq -c --arg k "$k" --argjson v "$v" '.[$k] = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}
js() { jq -cn --arg s "$1" '$s'; }   # a JSON string
# admission_summary <http> <resp-file> → the gateway's answer for the record WITHOUT the session
# token: `session.token` and the whole `env` map (it carries the token as the credential) are
# dropped, the env's KEYS kept — the GW-SESSIONS-ENV evidence is which vars a harness was handed
admission_summary() {
  jq -c --argjson h "$1" '{http:$h, answer:(del(.session.token) | del(.env))} + (if (.env | type) == "object" then {env_keys:(.env | keys)} else {} end)' "$2" 2>/dev/null \
    || jq -cn --argjson h "$1" '{http:$h}'
}

# shadow_one <repo> <num> <head|""> → one record under $SHADOW_OUT (rc 0 = recorded with a verdict,
# 1 = recorded without one: defer / error / timeout / no parsable verdict — the row says which)
shadow_one() {
  local repo="$1" num="$2" head="$3" slug="${ORG}/$1" pv base revs cell rec t0 rc=0
  cell="${SHADOW_HARNESS}@${SHADOW_RAIL:-policy}"
  t0="$(date +%s)"
  pv="$(gh pr view "$num" --repo "$slug" --json headRefOid,baseRefName)" || { log "[$repo#$num] shadow: PR read FAILED"; return 1; }
  [ -n "$head" ] || head="$(jq -r .headRefOid <<< "$pv")"
  if [ "${#head}" -ne 40 ]; then head="$(gh api "repos/${slug}/commits/${head}" --jq .sha)" || { log "[$repo#$num] shadow: cannot resolve ${head}"; return 1; }; fi
  base="$(jq -r .baseRefName <<< "$pv")"
  revs="$(gh api --paginate "repos/${slug}/pulls/${num}/reviews" --jq '.[]' 2>/dev/null | jq -s .)" || revs='[]'
  SHADOW_ASOF="$(shadow_as_of "$revs" "$head")"; local asof_src="first own review at head"
  [ -n "$SHADOW_ASOF" ] || { SHADOW_ASOF="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; asof_src="now (no own review at this head)"; }
  local tag="${repo}-${num}-${head:0:8}-${SHADOW_HARNESS}@${SHADOW_RAIL:-policy}"
  rec="$SHADOW_OUT/${tag}.json"; rm -f "$rec"
  WORK="$SHADOW_WORK/$tag"; rm -rf "$WORK"; mkdir -p "$WORK"; SHADOW_BASE_COMMIT=""
  shadow_record "$rec" "repo=$(js "$repo")" "pr=$num" "head=$(js "$head")" "as_of=$(js "$SHADOW_ASOF")" "as_of_source=$(js "$asof_src")" \
    "cell=$(jq -cn --arg h "$SHADOW_HARNESS" --arg r "$SHADOW_RAIL" --arg t "$SHADOW_TIER" --arg role "$SHADOW_ROLE" '{harness:$h, rail:(if $r == "" then null else $r end), tier:(if $t == "" then null else $t end), role:$role}')" \
    "today=$(jq -cn --arg l "$LENS_BASE" --arg w "$SNIPPETS_VERSION" '{lens:$l, snippets:$w, issue_intent:"current"}')" \
    "confinement=$(js "$([ "$SHADOW_HARNESS" = goose ] && echo env-only || echo env+tool-scope)")"
  log "[$repo#$num] SHADOW ${cell} at ${head:0:8} (as of ${SHADOW_ASOF}, ${asof_src})"
  # the FIRST touched root pair (touched_pairs): a shadow cell reviews one pack; a PR touching
  # several roots records which one it read
  local files sroot troot nroots
  files="$(gh api --paginate "repos/${slug}/pulls/${num}/files" --jq '.[].filename' 2>/dev/null)" || files=""
  nroots="$(touched_pairs "$repo" "$files" | grep -c .)"
  read -r sroot troot <<< "$(touched_pairs "$repo" "$files" | sed -n 1p)"
  shadow_record "$rec" "roots=$(jq -cn --arg r "$sroot" --arg t "$troot" --argjson n "$nroots" '{specs:$r, tests:$t, touched:$n}')"
  local prc=0; build_pack "$repo" "$num" "$base" "$head" "$sroot" "$troot" || prc=$?
  shadow_record "$rec" "base_commit=$(js "$SHADOW_BASE_COMMIT")" \
    "touched_rules=$(jq -Rsc 'split("\n") | map(select(. != ""))' "$WORK/inputs/touched-rules.txt" 2>/dev/null || echo null)"
  case "$prc" in
    0) ;;
    4) log "[$repo#$num] shadow: no rule touched — the mechanical approval (no LLM)"
       shadow_record "$rec" 'outcome="mechanical"' 'verdict="APPROVE"' "wall_s=$(( $(date +%s) - t0 ))"; return 0;;
    *) shadow_record "$rec" 'outcome="no-pack"' "wall_s=$(( $(date +%s) - t0 ))"; return 1;;
  esac
  # admission — the cell's explicit inputs (an explicit pair that cannot speak is the gateway's 400)
  local body http resp="$WORK/session.json"
  body="$(jq -cn --arg task "specs-shadow ${repo}#${num}@${head:0:8} ${cell}" --arg role "$SHADOW_ROLE" --arg h "$SHADOW_HARNESS" --arg r "$SHADOW_RAIL" --arg t "$SHADOW_TIER" \
    '{stack:"platform", role:$role, task:$task, round:0, harness:$h} + (if $r != "" then {rail:$r} else {} end) + (if $t != "" then {tier:$t} else {} end)')"
  http="$(gw_curl -sS --max-time 20 -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' -X POST "${GATEWAY_URL}/sessions" -d "$body" || echo 000)"
  http="${http:0:3}"   # a refused connect prints curl's 000 AND the fallback's
  shadow_record "$rec" "admission=$(admission_summary "$http" "$resp")"
  if [ "$http" != "200" ]; then
    log "[$repo#$num] shadow: POST /sessions HTTP ${http}: $(head -c 300 "$resp" 2>/dev/null | tr '\n' ' ')"
    shadow_record "$rec" 'outcome="admission-error"' "wall_s=$(( $(date +%s) - t0 ))"; return 1
  fi
  local decision; decision="$(jq -r '.decision // ""' "$resp")"
  if [ "$decision" != dispatch ]; then
    log "[$repo#$num] shadow: gateway ${decision:-?} reason=$(jq -r '.reason // ""' "$resp")"
    shadow_record "$rec" "outcome=$(js "${decision:-unknown}")" "wall_s=$(( $(date +%s) - t0 ))"; return 1
  fi
  SESSION_ID="$(jq -r '.session.id' "$resp")"
  log "[$repo#$num] shadow DISPATCH session=${SESSION_ID} rail=$(jq -r '.rail' "$resp") model=$(jq -r '.model' "$resp")"
  llm_env_args "$resp" "$WORK/home" > "$WORK/env.list" || { shadow_record "$rec" 'outcome="env-refused"'; shadow_release "$rec"; return 1; }
  local t1 model=""; t1="$(date +%s)"
  [ "$SHADOW_HARNESS" = claude ] && model="$(jq -r '.env.ANTHROPIC_MODEL // ""' "$resp")"
  if [ "$SHADOW_HARNESS" = claude ] && [ -z "$model" ]; then log "[$repo#$num] shadow: dispatch env carries no ANTHROPIC_MODEL"; rc=1
  else review_run "$SHADOW_HARNESS" "$slug" "$num" "$head" "$model" || rc=$?; fi
  shadow_record "$rec" "staged=$([ "$STAGED" = 1 ] && echo true || echo false)"
  if [ "$SHADOW_HARNESS" = claude ]; then
    shadow_record "$rec" "harness_usage=$(jq -c '{usage, num_turns, total_cost_usd, subtype}' "$WORK/result.json" 2>/dev/null || echo null)" \
      "pass1_usage=$(jq -c '{usage, num_turns, total_cost_usd, subtype}' "$WORK/pass1-result.json" 2>/dev/null || echo null)"
  fi
  [ -s "$WORK/inputs/pass1.md" ] && cp "$WORK/inputs/pass1.md" "$SHADOW_OUT/${tag}.pass1.md"
  shadow_record "$rec" "harness_rc=$rc" "timed_out=$([ "$rc" -eq 124 ] && echo true || echo false)" "model_wall_s=$(( $(date +%s) - t1 ))"
  [ -s "$WORK/harness.err" ] && cp "$WORK/harness.err" "$SHADOW_OUT/${tag}.stderr.txt"
  shadow_release "$rec"
  local review verdict
  review="$(awk '/^## Specs review/{f=1} f' "$WORK/result.txt" 2>/dev/null || true)"
  verdict="$(parse_verdict "$review")"
  printf '%s\n' "$review" > "$SHADOW_OUT/${tag}.review.md"
  [ -s "$WORK/result.txt" ] && cp "$WORK/result.txt" "$SHADOW_OUT/${tag}.raw.txt"
  shadow_record "$rec" "verdict=$(js "$verdict")" "outcome=$(js "$([ -n "$verdict" ] && echo reviewed || echo no-verdict)")" "wall_s=$(( $(date +%s) - t0 ))" \
    "verdict_line=$(js "$(grep -m1 '^Verdict:' <<< "$review" || true)")" \
    "result_head=$(js "$([ -n "$verdict" ] || head -c 400 "$WORK/result.txt" 2>/dev/null)")"
  shadow_emit_review "$tag" "$SHADOW_OUT/${tag}.review.md"
  log "[$repo#$num] shadow ${cell}: verdict=${verdict:-none} rc=${rc}"
  [ -n "$verdict" ]
}
# shadow_emit_review <tag> <file> → the review body on stdout between markers: the pod's log (Loki)
# is the durable copy a reader without the Argo artifact store's credentials can fetch
shadow_emit_review() {
  printf 'SHADOW-REVIEW-BEGIN %s\n' "$1"; cat "$2" 2>/dev/null || true; printf 'SHADOW-REVIEW-END %s\n' "$1"
}
# shadow_release <record> → DELETE the session (the live cleanup's retry), then GET its row into
# the record: the four token classes + requests, the gateway's own count for every harness
shadow_release() {
  [ -n "$SESSION_ID" ] || return 0
  gw_curl -fsS --max-time 10 --retry 5 --retry-delay 4 --retry-connrefused --retry-all-errors \
       -X DELETE "${GATEWAY_URL}/sessions/${SESSION_ID}" >/dev/null 2>&1 || log "WARN session ${SESSION_ID} release failed (expires by TTL)"
  local row; row="$(gw_curl -fsS --max-time 10 "${GATEWAY_URL}/sessions/${SESSION_ID}" 2>/dev/null)" || row="null"
  jq -e . >/dev/null 2>&1 <<< "$row" || row="null"
  shadow_record "$1" "session_row=$row"
  SESSION_ID=""
}

# shadow_main <flags…> <repo>#<n>[@<sha>] … → one record per PR under --out; exit 0 = every PR has
# a verdict, 3 = some row has none (it says why), 2 = usage / setup
shadow_main() {
  SHADOW=1; SHADOW_HARNESS=""; SHADOW_RAIL=""; SHADOW_TIER=""; SHADOW_ROLE="reviewer"; SHADOW_OUT="${SHADOW_OUT:-/work/shadow}"
  local -a prs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) SHADOW_HARNESS="${2:-}"; shift 2;;
      --rail)    SHADOW_RAIL="${2:-}"; shift 2;;
      --tier)    SHADOW_TIER="${2:-}"; shift 2;;
      --role)    SHADOW_ROLE="${2:-}"; shift 2;;
      --out)     SHADOW_OUT="${2:-}"; shift 2;;
      -*) log "shadow: unknown flag '$1'"; return 2;;
      *) prs+=("$1"); shift;;
    esac
  done
  case "$SHADOW_HARNESS" in claude|opencode|goose) ;; *) log "shadow: --harness claude|opencode|goose is required (got '${SHADOW_HARNESS}')"; return 2;; esac
  [ "${#prs[@]}" -gt 0 ] || { log "shadow: no PRs (<repo>#<n>[@<sha>] …)"; return 2; }
  gh() { gh_shadow "$@"; }   # from here on every gh call in this process is the read-only one
  [ -n "$(token)" ] || { log "shadow: no GitHub token (specs-reviewer-git) — a shadow run reads PRs and CI artifacts"; return 2; }
  _tok="$(token)"; export GH_TOKEN="$_tok"
  # attribution: the shadow's spend never reads as the live reviewer's
  OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:+${OTEL_RESOURCE_ATTRIBUTES},}shadow=true,cell=${SHADOW_HARNESS}@${SHADOW_RAIL:-policy}"
  mkdir -p "$SHADOW_OUT"; SHADOW_WORK="$(mktemp -d)"; SESSION_ID=""
  claims_load
  trap '[ -n "$SESSION_ID" ] && gw_curl -fsS --max-time 10 -X DELETE "${GATEWAY_URL}/sessions/${SESSION_ID}" >/dev/null 2>&1; rm -rf "$SHADOW_WORK"' EXIT
  local ref repo num head missing=0
  for ref in "${prs[@]}"; do
    if ! [[ "$ref" =~ ^([A-Za-z0-9._-]+)#([0-9]+)(@([0-9a-f]{7,40}))?$ ]]; then log "shadow: bad PR ref '$ref'"; missing=$((missing+1)); continue; fi
    repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"; head="${BASH_REMATCH[4]}"
    shadow_one "$repo" "$num" "$head" || missing=$((missing+1))
  done
  log "shadow: ${#prs[@]} PR(s), ${missing} without a verdict — records in ${SHADOW_OUT}"
  local f; for f in "$SHADOW_OUT"/*.json; do [ -s "$f" ] && printf 'SHADOW-RECORD %s\n' "$(jq -c . "$f")"; done
  [ "$missing" -eq 0 ] || return 3
}

if [ "${1:-}" = "--self-test" ]; then self_test; exit $?; fi
if [ "${1:-}" = "--shadow" ]; then shift; shadow_main "$@"; exit $?; fi

# ── metrics ──────────────────────────────────────────────────────────────────────────────────────
METRICS=""
metric() { METRICS="${METRICS}$1"$'\n'; }
N_MECH=0; N_APPROVE=0; N_RC=0; N_DEFER=0; N_ERR=0; N_PARTIAL=0
push_metrics() { # <shadow 0|1>
  metric "specs_review_last_tick_timestamp_seconds $(date +%s)"
  metric "specs_review_shadow $1"
  # every kind every tick, so a series never vanishes and an absent kind reads 0 (per-tick gauges)
  metric "specs_review_tick_verdicts{kind=\"mechanical\"} $N_MECH"
  metric "specs_review_tick_verdicts{kind=\"approve\"} $N_APPROVE"
  metric "specs_review_tick_verdicts{kind=\"request_changes\"} $N_RC"
  metric "specs_review_tick_verdicts{kind=\"defer\"} $N_DEFER"
  metric "specs_review_tick_verdicts{kind=\"error\"} $N_ERR"
  metric "specs_review_tick_verdicts{kind=\"partial\"} $N_PARTIAL"
  [ -n "$PUSHGATEWAY" ] || { log "metrics (no PUSHGATEWAY, log-only):"; printf '%s' "$METRICS"; return 0; }
  printf '%s' "$METRICS" | curl -fsS --max-time 10 --data-binary @- "${PUSHGATEWAY}/metrics/job/specs-review" >/dev/null 2>&1 \
    || log "pushgateway push failed (metrics stay in logs)"
}

if [ -z "$(token)" ]; then
  log "specs-reviewer-git absent — shadow, no verdicts (the Secret is optional; is it synced? agents/coordinator/specs-reviewer-git.yaml)"
  push_metrics 1
  exit 0
fi
_tok="$(token)"; export GH_TOKEN="$_tok"   # the shell's own gh calls + the wrapper's fallback

WORK="$(mktemp -d)"
SESSION_ID=""
cleanup() {
  if [ -n "$SESSION_ID" ]; then
    # retried: the gateway is ONE replica with an RWO store (Recreate), so a deploy leaves a few
    # seconds with no backend — 2026-10-16 the first live pass's release landed in one (old pod down
    # 15:31:13, new pod up 15:31:19) and the slot sat until the 4 h TTL. ~20 s of retries spans it.
    gw_curl -fsS --max-time 10 --retry 5 --retry-delay 4 --retry-connrefused --retry-all-errors \
         -X DELETE "${GATEWAY_URL}/sessions/${SESSION_ID}" >/dev/null 2>&1 \
      && log "session ${SESSION_ID} released" || log "WARN session ${SESSION_ID} release failed (expires by TTL)"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

POSTED=""          # "repo#N repo#M …" — the exit contract re-reads these
claims_load        # the tick's ONE claims read, in this shell (every root reader below is a `$( )`)
LLM_CANDIDATES=""  # "createdAt repo N base headSha contentSha since|-" lines, oldest first after sort

# ── the per-PR walk ─────────────────────────────────────────────────────────────────────────────
for repo in $SPECS_REVIEW_REPOS; do
  if ! prs="$(gh pr list --repo "${ORG}/${repo}" --state open --limit "$PR_LIST_LIMIT" \
        --json number,isDraft,createdAt,baseRefName,headRefOid,labels,reviews,commits,statusCheckRollup,comments 2>"$WORK/list.err")"; then
    log "[$repo] PR list FAILED — $(head -c 300 "$WORK/list.err" | tr '\n' ' ') — skipping repo this tick"; N_ERR=$((N_ERR+1)); continue
  fi
  # the body-edit leg (classify's own_reopened): .lastEditedAt for the PRs under an own live
  # CHANGES_REQUESTED only — ONE 1-point GraphQL query per repo per tick, none without such a PR; a
  # failed read degrades to the commit-time rule with a WARN, never aborts the tick (the shared home)
  # >>>REPLAY:specs-last-edited>>>
  # shellcheck disable=SC2178,SC2128 # prs is the tick's JSON string; shadow_main's local array of the same name misleads the check
  prs="$(pr_last_edited_merge "${ORG}/${repo}" "$prs" "$(own_cr_numbers "$prs")")"
  # <<<REPLAY:specs-last-edited<<<
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
      partial-held)      log "[$repo#$num] PARTIAL READ held at ${content_sha:0:8} — no verdict until a push moves the content commit"; continue;;
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
    if ! grep -qE "$(review_path_re "$repo")" <<< "$files"; then
      printf '## Specs review\nVerdict: APPROVE — mechanical: no specs path and no rule-test path in this diff — nothing for the specs gate to read; approved mechanically (ADR-155, the repo-wide count). Head %s.\n' "${head:0:12}" > "$WORK/mech-$num.md"
      rs=0; review_submit "$repo" "$num" approve "$WORK/mech-$num.md" "$head" || rs=$?
      case "$rs" in
        0) log "[$repo#$num] MECHANICAL approve at ${head:0:8} (no specs path)"; N_MECH=$((N_MECH+1)); POSTED="$POSTED $repo#$num";;
        3) ;;   # head moved — logged by review_submit; a push may have added a specs path, the next tick re-classifies
        *) log "[$repo#$num] mechanical approve FAILED"; N_ERR=$((N_ERR+1));;
      esac
      continue
    fi
    # re-opened by a body edit after our own CHANGES_REQUESTED at this content commit: the edit's
    # time rides along — a SPECS ROOT REVIEW comment older than it is the answered round's, not this one's
    since="$(jq -r --arg me "$SPECS_REVIEWER_LOGIN" "$JQ_PRELUDE"'if own_reopened($me) then .lastEditedAt else "-" end' <<< "$pr_json")"
    [ "$since" = - ] || log "[$repo#$num] PR body edited ${since} after our CHANGES_REQUESTED at ${content_sha:0:8} — reviewable again"
    LLM_CANDIDATES="${LLM_CANDIDATES}${created} ${repo} ${num} ${base} ${head} ${content_sha} ${since}"$'\n'
  done < <(jq -c '.[] | select(.isDraft | not)' <<< "$prs")
done

# ── ONE LLM pass per tick: the oldest candidate ─────────────────────────────────────────────────
pick="$(printf '%s' "$LLM_CANDIDATES" | grep . | sort | sed -n 1p || true)"
LLM_RC=0
if [ -z "$pick" ]; then
  log "no specs PR awaiting the LLM pass this tick"
else
  read -r _created repo num base head content_sha since <<< "$pick"
  n_cand="$(printf '%s' "$LLM_CANDIDATES" | grep -c . || true)"
  log "[$repo#$num] LLM pass (${n_cand} candidate(s); the rest wait for the next tick)"
  run_llm_pass() {
    local slug="${ORG}/${repo}" inputs="$WORK/inputs" lens="$WORK/lens.md" resp="$WORK/session.json"
    # 0) which root pairs the diff touches (touched_pairs): one = the pass as it always was; several
    #    = this tick reviews the first root without a SPECS ROOT REVIEW comment at the content
    #    commit, and the verdict waits for the last one (aggregate_review)
    local files c8="${content_sha:0:8}" sroot troot pending="" i n_roots own_comments="[]"
    files="$(gh api --paginate "repos/${slug}/pulls/${num}/files" --jq '.[].filename' 2>/dev/null)" \
      || { log "[$repo#$num] files re-read FAILED — no review"; return 1; }
    local -a pairs=(); mapfile -t pairs < <(touched_pairs "$repo" "$files")
    n_roots="${#pairs[@]}"
    if [ "$n_roots" -gt 1 ]; then
      own_comments="$(gh api --paginate "repos/${slug}/issues/${num}/comments" \
          --jq ".[] | select(.user.login == \"${SPECS_REVIEWER_LOGIN}[bot]\" or .user.login == \"${SPECS_REVIEWER_LOGIN}\") | {body, created_at}" 2>/dev/null \
          | jq -s --arg since "${since:--}" '[ .[] | select($since == "-" or (.created_at // "") > $since) ]')" \
        || { log "[$repo#$num] comments read FAILED — no review"; return 1; }
      for i in "${!pairs[@]}"; do
        read -r sroot troot <<< "${pairs[$i]}"
        root_review_of "$own_comments" "$sroot" "$c8" > "$WORK/root-$i.md"
        [ -s "$WORK/root-$i.md" ] || { [ -n "$pending" ] || pending="$i"; }
      done
      log "[$repo#$num] ${n_roots} spec roots touched ($(printf '%s, ' "${pairs[@]}" | sed 's/, $//')); $([ -n "$pending" ] && echo "reviewing #$((pending+1)) this tick" || echo "all reviewed — posting the verdict")"
    fi
    read -r sroot troot <<< "${pairs[${pending:-0}]}"
    local review="" verdict="" skip_llm=""
    [ "$n_roots" -gt 1 ] && [ -z "$pending" ] && skip_llm=all-done
    # 1)–3c) the lens + the context pack (build_pack — the shadow run builds the SAME one)
    local prc=0
    [ -n "$skip_llm" ] || build_pack "$repo" "$num" "$base" "$head" "$sroot" "$troot" || prc=$?
    case "$prc" in
      0) ;;
      2) return 0;;   # head moved while fetching — logged; the next tick reads the new head
      4) if [ "$n_roots" -gt 1 ]; then   # one root of several: its review is the fixed body, the verdict still waits
           printf '## Specs review\nVerdict: APPROVE — no rule touched: touched-rules (allure-behavior-snippets %s) found no rule this diff touches under %s.\n' "$SNIPPETS_VERSION" "$sroot" > "$WORK/root-$pending.md"
           skip_llm="root-mechanical"
         else
           printf '## Specs review\nVerdict: APPROVE — mechanical: touched-rules (allure-behavior-snippets %s) found no rule this diff touches. Head %s.\n' "$SNIPPETS_VERSION" "${head:0:12}" > "$WORK/mech-$num.md"
           local rs0=0; review_submit "$repo" "$num" approve "$WORK/mech-$num.md" "$head" || rs0=$?
           case "$rs0" in
             0) log "[$repo#$num] MECHANICAL approve at ${head:0:8} (no rule touched)"; N_MECH=$((N_MECH+1)); POSTED="$POSTED $repo#$num"; return 0;;
             3) return 0;;
             *) log "[$repo#$num] mechanical approve FAILED"; return 1;;
           esac
         fi;;
      *) return 1;;
    esac
    # 4) admission: POST /sessions (gateway/specs/endpoints/sessions.md, sessions.schema.json post.input)
    #    — in a loop over `attempt` (GW-SESSIONS-ADMIT §The retry contract): a strike on this pass
    #    re-admits at the SAME round with attempt + 1; the gateway's walk excludes the struck cell.
    local body http attempt=1
    while [ -z "$skip_llm" ]; do
    body="$(jq -cn --arg task "specs-review ${repo}#${num}" --argjson a "$attempt" '{stack:"platform", role:"reviewer", task:$task, round:0, attempt:$a, harness:"claude"}')"
    http="$(gw_curl -sS --max-time 20 -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' -X POST "${GATEWAY_URL}/sessions" -d "$body" || echo 000)"
    if [ "$http" != "200" ]; then
      log "[$repo#$num] POST /sessions HTTP ${http}: $(head -c 300 "$resp" 2>/dev/null | tr '\n' ' ')"; return 1
    fi
    local decision; decision="$(jq -r '.decision // ""' "$resp")" || return 1
    if [ "$decision" = "defer" ]; then
      log "[$repo#$num] gateway DEFER reason=$(jq -r '.reason' "$resp") retry_after_s=$(jq -r '.retry_after_s' "$resp") — the next tick retries"
      N_DEFER=$((N_DEFER+1)); return 0
    fi
    [ "$decision" = "dispatch" ] || { log "[$repo#$num] unknown decision '${decision}' from /sessions"; return 1; }
    SESSION_ID="$(jq -r '.session.id' "$resp")" || return 1
    log "[$repo#$num] DISPATCH session=${SESSION_ID} rail=$(jq -r '.rail' "$resp") model=$(jq -r '.model' "$resp") context_tokens=$(jq -r '.context_tokens' "$resp")"
    local model; model="$(jq -r '.env.ANTHROPIC_MODEL // ""' "$resp")"
    [ -n "$model" ] || { log "[$repo#$num] dispatch env carries no ANTHROPIC_MODEL — cannot run claude"; return 1; }
    # 5) the pass — CONFINED (bot review, PR#2613 finding 1). The model sees authored text from a
    #    public repo and its output is posted publicly, so its reach is bounded twice:
    #    • `env -i`: the process env is EXACTLY the gateway's dispatch env (GW-SESSIONS-ENV,
    #      verbatim, keys validated) + OTEL + a throwaway HOME — never GH_TOKEN / GH_TOKEN_FILE,
    #      never the pod's env (llm_env_args; pinned by --self-test);
    #    • an ALLOW-LIST tool scope (harness_claude).
    llm_env_args "$resp" "$WORK/home" > "$WORK/env.list" || { log "[$repo#$num] refusing the gateway's env map — no review"; return 1; }
    local rc=0
    # bounded INSIDE the workflow's 900 s activeDeadlineSeconds: a deadline kill skips the EXIT
    # trap, so the session would hold its rail slot until the gateway TTL (4 h) and the tick's
    # metrics push would never happen. 124 = timed out → no verdict, the next tick retries. A
    # staged read's two passes share the one LLM_TIMEOUT_S (review_run).
    review_run claude "$slug" "$num" "$head" "$model" || rc=$?
    [ -s "$WORK/pass1-result.json" ] && jq -r '"→ claude pass 1 (masked) \(.subtype // "done"): in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0) cache_read=\(.usage.cache_read_input_tokens // 0) turns=\(.num_turns // 0) cost_usd=\(.total_cost_usd // 0)"' "$WORK/pass1-result.json" 2>/dev/null || true
    local is_json=0 review="" verdict=""
    jq -e . "$WORK/result.json" >/dev/null 2>&1 && is_json=1
    if [ "$rc" -eq 0 ] && [ "$is_json" = 1 ]; then
      jq -r '"→ claude \(.subtype // "done"): in=\(.usage.input_tokens // 0) out=\(.usage.output_tokens // 0) cache_read=\(.usage.cache_read_input_tokens // 0) turns=\(.num_turns // 0) cost_usd=\(.total_cost_usd // 0)"' "$WORK/result.json"
      review="$(jq -r '.result // ""' "$WORK/result.json")"
      # the body starts at the lens's heading; anything the model said before it is dropped
      review="$(awk '/^## Specs review/{f=1} f' <<< "$review")"
      verdict="$(parse_verdict "$review")"
    fi
    # the ride's own outcome, reported BEFORE the release (GW-SESSIONS-OUTCOME)
    local cls struck; cls="$(outcome_class "$rc" "$is_json" "$verdict")"
    struck="$(gw_outcome "$SESSION_ID" "$cls" "rc=${rc} attempt=${attempt}")"
    log "[$repo#$num] outcome ${cls} reported for session ${SESSION_ID} (attempt ${attempt})${struck:+ — strike ${struck}}"
    [ "$cls" = clean ] && break
    gw_curl -fsS --max-time 10 --retry 5 --retry-delay 4 --retry-connrefused --retry-all-errors \
         -X DELETE "${GATEWAY_URL}/sessions/${SESSION_ID}" >/dev/null 2>&1 && log "session ${SESSION_ID} released" \
      || log "WARN session ${SESSION_ID} release failed (expires by TTL)"
    SESSION_ID=""
    if [ -n "$struck" ] && [ "$attempt" -le "$SPECS_REVIEW_AUTO_ATTEMPTS" ] \
       && [ $(( SECONDS + LLM_TIMEOUT_S )) -le "$SPECS_REVIEW_BUDGET_S" ]; then   # SECONDS = since this tick's shell started
      attempt=$(( attempt + 1 ))
      log "[$repo#$num] strike ${struck} — re-admitting at round 0, attempt ${attempt} (the gateway excludes the struck cell)"
      continue
    fi
    log "[$repo#$num] claude exited ${rc} / ${cls} — no verdict (attempt ${attempt}; ${struck:+the strike is counted; }the next tick retries)"
    return 1
    done
    if [ "$verdict" = PARTIAL ]; then
      # the lens's third line: no review, ONE hold comment keyed by the content commit (classify →
      # partial-held until a push). Not an error (the model did its job) and not a round (a worker
      # cannot fix the reviewer's read) — the lever is the pack's size.
      local unread; unread="$(partial_unread "$review")"
      printf 'PARTIAL READ: %s could not read the context pack in full at content commit %s — unfinished: %s. No verdict is posted on this head: an approval that did not read the touched contract is not a gate (agents/lenses/specs.md §Verdict mechanics). The hold releases when a push moves the content commit; the lever is the pack — a smaller PR, a narrower touched-rule scope, or the read-map unit — never a worker round. <!-- specs-review partial-read head=%s -->\n' \
        "$SPECS_REVIEWER_LOGIN" "${content_sha:0:8}" "${unread:-unstated}" "${content_sha:0:8}" > "$WORK/partial-$num.md"
      if gh pr comment "$num" --repo "${ORG}/${repo}" --body-file "$WORK/partial-$num.md" >/dev/null; then
        log "[$repo#$num] PARTIAL READ at ${content_sha:0:8} — held, no verdict (unfinished: ${unread:-unstated})"; N_PARTIAL=$((N_PARTIAL+1)); return 0
      fi
      log "[$repo#$num] PARTIAL READ at ${content_sha:0:8} but the hold comment FAILED — the next tick re-runs the pass"; return 1
    fi
    if [ "$n_roots" -gt 1 ]; then
      # several roots: this tick's root review is held as its comment; the verdict waits for the last
      if [ -n "$pending" ]; then
        [ "$skip_llm" = root-mechanical ] || printf '%s\n' "$review" > "$WORK/root-$pending.md"
        root_comment "$sroot" "$((pending+1))" "$n_roots" "$c8" "$WORK/root-$pending.md" > "$WORK/rootc-$num.md"
        gh pr comment "$num" --repo "$slug" --body-file "$WORK/rootc-$num.md" >/dev/null \
          || { log "[$repo#$num] SPECS ROOT REVIEW comment for ${sroot} FAILED — the next tick re-runs it"; return 1; }
        log "[$repo#$num] root ${sroot} reviewed ($(grep -m1 '^Verdict:' "$WORK/root-$pending.md" | cut -c1-120)) — held as a comment"
        for i in "${!pairs[@]}"; do [ -s "$WORK/root-$i.md" ] || return 0; done   # the verdict waits for the last root
      fi
      local -a agg=()
      for i in "${!pairs[@]}"; do read -r sroot troot <<< "${pairs[$i]}"; agg+=("${sroot}=$WORK/root-$i.md"); done
      review="$(aggregate_review "$head" "${agg[@]}")"; verdict="$(parse_verdict "$review")"
    fi
    printf '%s\n\n<!-- specs-review head=%s session=%s -->\n' "$review" "${head:0:12}" "$SESSION_ID" > "$WORK/review-$num.md"
    local kind
    case "$verdict" in
      APPROVE)           kind=approve;;
      CHANGES_REQUESTED) kind=request-changes;;
      *) log "[$repo#$num] no parsable Verdict: line in the model's result — no terminal (first 400 chars: $(head -c 400 <<< "$review" | tr '\n' ' '))"; return 1;;
    esac
    local rs=0; review_submit "$repo" "$num" "$kind" "$WORK/review-$num.md" "$head" || rs=$?
    case "$rs" in
      0) log "[$repo#$num] ${verdict} submitted, pinned to ${head:0:8}"
         if [ "$kind" = approve ]; then N_APPROVE=$((N_APPROVE+1)); else N_RC=$((N_RC+1)); fi
         POSTED="$POSTED $repo#$num";;
      3) return 0;;   # head moved — no verdict on this head; the next tick reads the new one
      *) log "[$repo#$num] review submit FAILED"; return 1;;
    esac
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
log "tick done: mechanical=$N_MECH approve=$N_APPROVE request_changes=$N_RC defer=$N_DEFER error=$N_ERR partial=$N_PARTIAL"
if [ "$TERMINAL_OK" -ne 1 ]; then exit 10; fi
exit "$LLM_RC"
