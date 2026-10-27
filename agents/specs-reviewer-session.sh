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
#   mechanical — no specs path and no rule-test path (`review_path_re`) in the PR's files, or the
#              pass's touched-rules finds no rule: an approval with a fixed body, no LLM. Many per
#              tick, cheap — the price of GitHub's repo-wide count.
#   LLM pass — ONE per tick (the oldest candidate): admitted through the agent-gateway
#              `POST /sessions` seam (role `reviewer`, stack `platform`, harness `claude` — the
#              first real consumer, FU-270 dogfood), authenticated as this pod's ServiceAccount
#              (GW-SESSIONS-AUTH: the projected `gateway-token`, `gw_curl`); `decision: defer` = log + stop, the next tick
#              retries (never poll in-process); `dispatch` = the returned `env` map is exported
#              VERBATIM as the LLM env (GW-SESSIONS-ENV: nothing LLM-shaped is added) and the
#              session is ALWAYS released (`DELETE /sessions/{id}`, trap). Inputs = the CONTEXT PACK
#              (ADR-156), built BEFORE admission by the pinned allure-behavior-snippets wheel
#              (`evidence-pack`, digest-checked): touched rules + their sections + the spec diff, the
#              specs tree, the head's raw Allure results (the pack ci publishes to the bucket) with
#              evidence.json + digest.md + attachments, the base branch's evidence as baseline, the
#              PR body, the closing issue's acceptance text, the previous review, and process/ (the
#              pinned RULES, CONVENTIONS and briefs). A failed clone/wheel/pack is no review (fail
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
# newest base push run whose commit is an ancestor of the pack's base. Issue intent, the lens and
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
SNIPPETS_VERSION="0.6.2"   # bump TOGETHER with gateway/scripts/lib/snippets.sh (CI evidence)
SNIPPETS_WHEEL="https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v${SNIPPETS_VERSION}/allure_behavior_snippets-${SNIPPETS_VERSION}-py3-none-any.whl"
SNIPPETS_SHA256="32da3c184d658f9acf241ba734a9f32fb5c557ddc47246a0c8d35d9441846f2d"
EVIDENCE_ARTIFACT="${EVIDENCE_ARTIFACT:-gateway-evidence}"   # the LEGACY ci run artifact (fallback only, see evidence_fetch)
# The evidence packs live in OUR storage since 2026-10-21 (the Actions artifact held ~2.1 GB of the
# org's 2 GB included storage — GithubStorageHeldHigh): CI writes evidence/<pr-N|branch>/<sha>.tar.gz
# into the repo's specs bucket (gateway/scripts/evidence-publish.sh), read here ANONYMOUSLY through
# Garage's web endpoint (Host = <bucket>.teststuff.net; the bucket is website-enabled, egress-cnp.yaml
# already admits ns garage). No reader key, no GitHub API call.
EVIDENCE_WEB="${EVIDENCE_WEB:-http://garage-s3.garage.svc.cluster.local:3902}"
# evidence_bucket <repo> → the website bucket its CI publishes packs to ("" = none: artifact only)
evidence_bucket() { case "$1" in homelab) printf 'gateway-specs';; oracle-fleet) printf 'oracle-specs';; esac; }
# pack_roots <repo> → "<specs-root> <tests-root>": where that repo's rules and their tests live
pack_roots() { case "$1" in homelab) printf 'gateway/specs gateway/tests';; *) printf 'specs tests';; esac; }
# review_path_re <repo> → the file-list trigger for the LLM pass: a specs path, or the repo's
# rule-test root (a changed test label reaches a rule without touching specs — touched-rules
# decides inside the pass; zero touched rules = the mechanical approval after all)
review_path_re() { local _s t; read -r _s t <<< "$(pack_roots "$1")"; printf '%s|^%s/' "$SPECS_PATH_RE" "$t"; }
PR_LIST_LIMIT="${PR_LIST_LIMIT:-40}"                     # review-reflex.sh's ceiling: the rollup fragment is deep
LLM_TIMEOUT_S="${LLM_TIMEOUT_S:-600}"                    # the model's wall clock; < the 900 s pod deadline minus clone + submit

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
    ([ .statusCheckRollup[]? | {n: (.name // .context // ""), c: (.conclusion // .state // "")} ]) as $c
    # A CANCELLED run counts only when NO other run of the same check concluded: concurrency
    # cancels superseded runs (renovate-approve, 4× on #2636) and those rows stay in the rollup
    # beside the run that replaced them — read as red they wedge the PR forever.
    | ($c | length) > 0
      and ([ $c | group_by(.n)[] | [ .[].c | select(. != "CANCELLED") ] as $k
             | select(($k | length) == 0 or ([ $k[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) > 0) ] | length) == 0;
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
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"approve","conclusion":"CANCELLED"},{"name":"approve","conclusion":"SUCCESS"},{"name":"ci","conclusion":"SUCCESS"}]' <<< "$base"); check "superseded CANCELLED beside its SUCCESS → candidate (#2636)" candidate "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"approve","conclusion":"CANCELLED"},{"name":"ci","conclusion":"SUCCESS"}]' <<< "$base"); check "only-CANCELLED check → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .statusCheckRollup=[{"name":"ci","conclusion":"CANCELLED"},{"name":"ci","conclusion":"FAILURE"}]' <<< "$base"); check "CANCELLED beside a FAILURE → ci-not-green" ci-not-green "$(classify "$j")"
  j=$(jq -c --argjson r "[$code_ok]" '.reviews=$r | .labels=[{"name":"agent/error"}]' <<< "$base"); check "agent/error → error-label (touch nothing)" error-label "$(classify "$j")"
  check "content sha skips the merge commit" aaaa1111 "$(jq -r "$JQ_PRELUDE"'content_sha' <<< "$base")"
  check "specs path predicate: gateway/specs/access.md" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'gateway/specs/access.md' >/dev/null; echo $?)"
  check "specs path predicate: specs/x.md at root" 0 "$(grep -cE "$SPECS_PATH_RE" <<< 'specs/x.md' >/dev/null; echo $?)"
  check "trigger: homelab rule-test path → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'gateway/tests/test_access.py' >/dev/null; echo $?)"
  check "trigger: homelab specs path → LLM pass" 0 "$(grep -cE "$(review_path_re homelab)" <<< 'gateway/specs/access.md' >/dev/null; echo $?)"
  check "trigger: a non-gateway tests dir is NOT a homelab rule-test path" 1 "$(grep -cE "$(review_path_re homelab)" <<< 'scripts/tests/x.py' >/dev/null; echo $?)"
  check "pack roots: homelab" "gateway/specs gateway/tests" "$(pack_roots homelab)"
  check "pack roots: default island layout" "specs tests" "$(pack_roots some-island)"
  check "trigger: oracle-fleet root specs path → LLM pass" 0 "$(grep -cE "$(review_path_re oracle-fleet)" <<< 'specs/server/http.md' >/dev/null; echo $?)"
  check "trigger: oracle-fleet rule-test path → LLM pass" 0 "$(grep -cE "$(review_path_re oracle-fleet)" <<< 'tests/test_rt.py' >/dev/null; echo $?)"
  check "specs path predicate: docs/specs-reviewer.md is NOT a specs path" 1 "$(grep -cE "$SPECS_PATH_RE" <<< 'docs/agents/specs-reviewer.md' >/dev/null; echo $?)"
  check "verdict parse: APPROVE" APPROVE "$(parse_verdict "$(printf '## Specs review\nVerdict: APPROVE — no blocking check failed\nRows: …\n')")"
  check "verdict parse: CHANGES_REQUESTED" CHANGES_REQUESTED "$(parse_verdict "$(printf '## Specs review\nVerdict: CHANGES_REQUESTED — 1, 6\n')")"
  check "verdict parse: missing → empty" "" "$(parse_verdict "$(printf 'no verdict here\n')")"
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
read|run download 5 --repo o/r -n gateway-evidence -D /tmp/x
read|api --paginate repos/o/r/pulls/7/files --jq '.[].filename'
read|api repos/o/r/commits/abc --jq .sha
read|api -X GET repos/o/r/pulls -f state=closed
read|api graphql -f 'query=query($o:String!){repository(owner:$o,name:"r"){id}}' -f o=x -F p=7
write|pr review 7 --approve
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
  check "shadow: no gh bypass outside gh_real" 0 "$(declare -f build_pack shadow_main shadow_one shadow_release pr_body_as_of issue_intent ci_success_run evidence_fetch evidence_download evidence_baseline_download prior_review_pick llm_env_args harness_claude harness_opencode harness_goose | grep -cE 'command gh|/bin/gh|\\gh ')"
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
  rm -rf "$d"
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
# issue_intent <slug> <pr> → markdown: each closing issue's acceptance text (never fails the pass)
issue_intent() {
  local slug="$1" num="$2" refs r n body
  if ! refs="$(gh pr view "$num" --repo "$slug" --json closingIssuesReferences \
                --jq '.closingIssuesReferences[] | "\(.repository.owner.login)/\(.repository.name) \(.number)"' 2>/dev/null)"; then
    printf 'issue intent: the closing-issue lookup FAILED; pr-body.md names the reference, the acceptance text is not available\n'; return 0
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
# ci_success_run <slug> <commit> → the newest completed, successful `ci` run id at <commit> ("" = none)
ci_success_run() {
  gh run list --repo "$1" --commit "$2" --workflow ci.yaml --status completed --json databaseId,conclusion --limit 3 \
    --jq '[ .[] | select(.conclusion == "success") ] | .[0].databaseId // empty' 2>/dev/null || true
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
# evidence_download <slug> <head> <dir> <pr-number> → the head's evidence pack unpacked into <dir>:
# the bucket's evidence/pr-<N>/<head>, else the head run's LEGACY artifact (runs from before the
# move; drop the fallback once those have expired — 14-day retention).
# (rc 1 = none: no successful run, or the run uploaded no artifact — the pack states the absence)
evidence_download() {
  if evidence_fetch "${1#*/}" "pr-$4" "$2" "$3"; then
    log "evidence: bucket evidence/pr-$4/${2:0:8} → $(find "$3" -type f | wc -l) file(s)"; return 0
  fi
  local run_id; run_id="$(ci_success_run "$1" "$2")"
  [ -n "$run_id" ] || { log "evidence: no successful ci run at ${2:0:8}"; return 1; }
  gh run download "$run_id" --repo "$1" -n "$EVIDENCE_ARTIFACT" -D "$3" >/dev/null 2>&1 \
    || { log "evidence: ci run ${run_id} has no ${EVIDENCE_ARTIFACT} artifact"; return 1; }
  log "evidence: ci run ${run_id} artifact ${EVIDENCE_ARTIFACT} → $(find "$3" -type f | wc -l) file(s)"
}
# evidence_baseline_download <slug> <base> <dir> [<ancestor-of>] → "<evidence.json path> <commit sha>"
# from the bucket: the newest of the first 100 first-parent commits of <ancestor-of> (default
# origin/<base>) with a pack under evidence/<base>/ — ancestry by construction. Else (LEGACY, the
# artifact fallback) the newest successful ci PUSH run on <base> (of the newest 5) that uploaded the artifact;
# "" = none. The gateway step runs only on gateway changes, so a run without the artifact is
# skipped. <ancestor-of> (the shadow run's replay): only runs whose commit is an ancestor of it
# count — the baseline the live reviewer could have seen — and the window widens to 30 runs.
evidence_baseline_download() {
  local slug="$1" base="$2" dir="$3" anc="${4:-}" runs id sha lim=5
  if [ -n "$(evidence_bucket "${slug#*/}")" ]; then
    while read -r sha; do
      [ -n "$sha" ] || continue
      if evidence_fetch "${slug#*/}" "$base" "$sha" "$dir"; then printf '%s %s\n' "$dir/evidence.json" "$sha"; return 0; fi
    done <<< "$(git -C "$WORK/repo" rev-list --first-parent -n 100 "${anc:-origin/${base}}" 2>/dev/null || true)"
  fi
  [ -n "$anc" ] && lim=30
  runs="$(gh run list --repo "$slug" --branch "$base" --event push --workflow ci.yaml --status success --limit "$lim" \
            --json databaseId,headSha --jq '.[] | "\(.databaseId) \(.headSha)"' 2>/dev/null || true)"
  while read -r id sha; do
    [ -n "$id" ] || continue
    if [ -n "$anc" ] && ! git -C "$WORK/repo" merge-base --is-ancestor "$sha" "$anc" 2>/dev/null; then continue; fi
    rm -rf "$dir"; mkdir -p "$dir"
    gh run download "$id" --repo "$slug" -n "$EVIDENCE_ARTIFACT" -D "$dir" >/dev/null 2>&1 || continue
    [ -s "$dir/evidence.json" ] || continue
    printf '%s %s\n' "$dir/evidence.json" "$sha"; return 0
  done <<< "$runs"
  printf '\n'
}

# ── the context pack (ADR-156): ONE builder for the live pass and the shadow run ────────────────
# build_pack <repo> <num> <base-branch> <head> → builds $WORK/inputs (the model's cwd) and
# $WORK/lens.md (the system prompt). rc 0 built · 1 no review (logged; fail CLOSED) · 2 the head
# moved while fetching (logged; live only) · 4 touched-rules found no rule (the mechanical case).
# EVERY step is checked explicitly: the live caller runs under `|| LLM_RC=$?`, which suspends
# `set -e` (bot review, PR#2613 finding 2) — an unchecked failed fetch would hand the model an
# empty input set, and an empty diff reads as a clean APPROVE. A blocking lens fails CLOSED.
# SHADOW (set by shadow_main) changes four READS, never the pack's shape: the head is fetched by
# sha (a judged head may predate the PR's last push), the base rev is merge-base(origin/<base>,
# head), the PR body / prior review are as of $SHADOW_ASOF, and the baseline is an ancestor of
# that base.
build_pack() {
  local repo="$1" num="$2" base="$3" head="$4"
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
  # 2b) the pinned process: the wheel, verified by digest, extracted (never zip-imported)
  curl -fsSL --max-time 60 "$SNIPPETS_WHEEL" -o "$WORK/snippets.whl" \
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
    printf '%s\n' "${prior:-previous review: none, this is round 1}" > "$ctx/prior-review.md"
  else
    printf 'previous review: the reviews read FAILED; treat this as round 1 and say so\n' > "$ctx/prior-review.md"
  fi
  # 3b) evidence: the head's raw Allure results + the base branch's evidence.json (the baseline),
  #     both from the bucket (evidence_fetch; legacy ci artifacts as the fallback). Absent evidence is NOT a refusal: an empty results dir makes
  #     the pack say so, and the evidence brief turns that into E-STALE / NO_EVIDENCE findings.
  local results="$WORK/head-ev/allure-results" bl_json="" bl_commit=""
  mkdir -p "$WORK/head-ev"
  evidence_download "$slug" "$head" "$WORK/head-ev" "$num" || true
  mkdir -p "$results"
  if read -r bl_json bl_commit <<< "$(evidence_baseline_download "$slug" "$base" "$WORK/base-ev" ${SHADOW:+"$base_rev"})" && [ -n "$bl_json" ]; then
    log "[$repo#$num] baseline: ${base}@${bl_commit:0:8}"
  else
    bl_json=""; log "[$repo#$num] baseline: none (no pack under evidence/${base}/ on the last 100 first-parent commits, no legacy ${EVIDENCE_ARTIFACT} artifact)"
  fi
  # 3c) the context pack (allure-behavior-snippets evidence-pack): touched rules + sections + the
  #     spec diff + the specs tree + evidence + digest + attachments + baseline + process/ briefs.
  #     It IS the model's inputs dir. A pack failure is no review (fail closed).
  local specs_root tests_root; read -r specs_root tests_root <<< "$(pack_roots "$repo")"
  local -a packargs=("$base_rev" "pr-${num}" "$results" --repo "$WORK/repo" --specs-root "$specs_root"
    --tests-root "$tests_root" --prior-review "$ctx/prior-review.md" --issue-intent "$ctx/issue-intent.md"
    --pr-body "$ctx/pr-body.md" --out "$inputs")
  [ -n "$bl_json" ] && packargs+=(--baseline "$bl_json" --baseline-commit "$bl_commit")
  PYTHONPATH="$WORK/snippets" python3 -c 'import sys; sys.argv[0] = "evidence-pack"; from allure_behavior_snippets.pack import main; sys.exit(main())' \
      "${packargs[@]}" > "$WORK/pack.log" 2>&1 \
    || { log "[$repo#$num] evidence-pack FAILED — no review: $(tail -c 300 "$WORK/pack.log" | tr '\n' ' ')"; return 1; }
  local n_rules; n_rules="$(grep -c . "$inputs/touched-rules.txt" 2>/dev/null || true)"
  # the file list hit a specs/test path but no rule is touched (prose, a fixture, a helper):
  # nothing for either brief — the caller's mechanical approval, said so
  [ "${n_rules:-0}" -eq 0 ] && return 4
  log "[$repo#$num] pack: ${n_rules} touched rule(s): $(tr '\n' ' ' < "$inputs/touched-rules.txt" | head -c 300)"
  # the system prompt: homelab's wiring lens + the pinned briefs (finding contract first)
  local b
  for b in finding-contract rows evidence; do
    [ -s "$inputs/process/briefs/$b.md" ] || { log "[$repo#$num] pack has no process/briefs/$b.md — no review"; return 1; }
    printf '\n\n---\n\n' >> "$lens"; cat "$inputs/process/briefs/$b.md" >> "$lens"
  done
  return 0
}

# review_prompt <slug> <num> <head> → the user prompt every harness gets (the brief's entry point)
review_prompt() {
  printf '%s' "You are the specs reviewer for pull request ${1}#${2} (head ${3}). Your working directory is the context pack and holds your ONLY inputs; your Read and Glob tools are scoped to it. Start with manifest.json (what the pack holds and what was not provided), then intent: pr-body.md, issue-intent.md, spec-sections.md (each touched rule's section at the head + the spec diff), tree/ (the specs at the head, for neighbours), process/RULES.md and process/CONVENTIONS.md (the pinned process your briefs cite). Then evidence: digest.md first (its Stamp:, Baseline: and precomputed findings), the per-rule <RULE>.md tables, evidence/<RULE>.json for ONE rule's records (never the whole evidence.json: it holds every touched rule and can exceed your context), baseline-evidence.json, and attachments/ where a row's value is still unproven. prior-review.md is your previous review of this PR: on a later round, mark each of its findings resolved or still open FIRST. Apply BOTH briefs (rows, evidence) under the finding contract and write ONLY the review body in its Output shape, starting with the line '## Specs review' and then the line 'Verdict: APPROVE — …' or 'Verdict: CHANGES_REQUESTED — <blocking finding IDs>'. Do not run commands, do not fetch anything, do not submit the review yourself: the launcher submits what you return."
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
  local inputs="$1" lens="$2" prompt="$3" model="$4"
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  (cd "$inputs" && timeout "${LLM_TIMEOUT_S}" env -i "${envargs[@]}" claude -p "$prompt" --model "$model" --append-system-prompt-file "$lens" \
      --allowedTools "Read(//${inputs#/}/**)" "Glob" --permission-mode default --output-format json > "$WORK/result.json")
}
# harness_opencode <inputs> <lens> <prompt> → $WORK/result.txt (the final message, plain text)
#   SHADOW ONLY (no live consumer). System prompt = opencode's global rules file in the throwaway
#   HOME; tool scope = OPENCODE_PERMISSION (edit/bash/webfetch/external_directory denied — read,
#   glob, grep, list stay, inside the cwd). Model/provider come ONLY from the dispatch env (⚖
#   GW-SESSIONS-ENV verify rows: whatever opencode really reads is what the gateway must hand it).
harness_opencode() {
  local inputs="$1" lens="$2" prompt="$3" home
  home="$(sed -n 's/^HOME=//p' "$WORK/env.list" | head -1)"
  mkdir -p "$home/.config/opencode" && cp "$lens" "$home/.config/opencode/AGENTS.md" || return 1
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  envargs+=('OPENCODE_PERMISSION={"edit":"deny","bash":"deny","webfetch":"deny","external_directory":"deny"}'
            OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_DISABLE_SHARE=1)
  (cd "$inputs" && timeout "${LLM_TIMEOUT_S}" env -i "${envargs[@]}" opencode run "$prompt" > "$WORK/result.txt" 2> "$WORK/harness.err")
}
# harness_goose <inputs> <lens> <prompt> → $WORK/result.txt
#   SHADOW ONLY. System prompt = `--system`; tools = the `developer` builtin ONLY (--no-profile) —
#   goose has no path-scoped read, so this cell does NOT hold the allow-list half of the
#   confinement contract (its shell can read what the pod's uid can): recorded per run as
#   `confinement: "env-only"`, which is why shadow runs take merged, operator-authored PRs.
harness_goose() {
  local inputs="$1" lens="$2" prompt="$3"
  local -a envargs=(); mapfile -t envargs < "$WORK/env.list"
  envargs+=(GOOSE_MODE=auto GOOSE_DISABLE_KEYRING=1 GOOSE_MAX_TURNS=60)
  (cd "$inputs" && timeout "${LLM_TIMEOUT_S}" env -i "${envargs[@]}" goose run --no-session --no-profile --with-builtin developer -q \
      --system "$(cat "$lens")" -t "$prompt" > "$WORK/result.txt" 2> "$WORK/harness.err")
}

# ── shadow run (--shadow): the read-only gh, the as-of readers, the per-PR record ───────────────
# gh_shadow_allows <gh args…> → 0 for a READ, 1 for anything else (an ALLOW-list: an unknown
# verb is a write until proven otherwise). `gh api` is a read only as GET: an explicit -X/--method
# other than GET refuses, and a field flag without -X makes gh POST (gh api's own default), so it
# refuses too; `gh api graphql` (always POST) passes only a query with no `mutation` and no
# `@file` field (a hidden body).
gh_shadow_allows() {
  case "${1:-} ${2:-}" in
    "pr view"|"pr list"|"pr diff"|"issue view"|"issue list"|"run list"|"run view"|"run download") return 0;;
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
  local prc=0; build_pack "$repo" "$num" "$base" "$head" || prc=$?
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
  local prompt; prompt="$(review_prompt "$slug" "$num" "$head")"
  local t1; t1="$(date +%s)"
  case "$SHADOW_HARNESS" in
    claude)
      local model; model="$(jq -r '.env.ANTHROPIC_MODEL // ""' "$resp")"
      if [ -z "$model" ]; then log "[$repo#$num] shadow: dispatch env carries no ANTHROPIC_MODEL"; rc=1
      else harness_claude "$WORK/inputs" "$WORK/lens.md" "$prompt" "$model" || rc=$?; fi
      jq -r '.result // ""' "$WORK/result.json" > "$WORK/result.txt" 2>/dev/null || true
      shadow_record "$rec" "harness_usage=$(jq -c '{usage, num_turns, total_cost_usd, subtype}' "$WORK/result.json" 2>/dev/null || echo null)";;
    opencode) harness_opencode "$WORK/inputs" "$WORK/lens.md" "$prompt" || rc=$?;;
    goose)    harness_goose "$WORK/inputs" "$WORK/lens.md" "$prompt" || rc=$?;;
  esac
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
LLM_CANDIDATES=""  # "createdAt repo N base headSha" lines, oldest first after sort

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
    # 1)–3c) the lens + the context pack (build_pack — the shadow run builds the SAME one)
    local prc=0; build_pack "$repo" "$num" "$base" "$head" || prc=$?
    case "$prc" in
      0) ;;
      2) return 0;;   # head moved while fetching — logged; the next tick reads the new head
      4)
        printf '## Specs review\nVerdict: APPROVE — mechanical: touched-rules (allure-behavior-snippets %s) found no rule this diff touches. Head %s.\n' "$SNIPPETS_VERSION" "${head:0:12}" > "$WORK/mech-$num.md"
        local rs0=0; review_submit "$repo" "$num" approve "$WORK/mech-$num.md" "$head" || rs0=$?
        case "$rs0" in
          0) log "[$repo#$num] MECHANICAL approve at ${head:0:8} (no rule touched)"; N_MECH=$((N_MECH+1)); POSTED="$POSTED $repo#$num"; return 0;;
          3) return 0;;
          *) log "[$repo#$num] mechanical approve FAILED"; return 1;;
        esac;;
      *) return 1;;
    esac
    # 4) admission: POST /sessions (gateway/specs/endpoints/sessions.md, sessions.schema.json post.input)
    #    — in a loop over `attempt` (GW-SESSIONS-ADMIT §The retry contract): a strike on this pass
    #    re-admits at the SAME round with attempt + 1; the gateway's walk excludes the struck cell.
    local body http attempt=1
    while :; do
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
    local prompt
    prompt="$(review_prompt "$slug" "$num" "$head")"
    llm_env_args "$resp" "$WORK/home" > "$WORK/env.list" || { log "[$repo#$num] refusing the gateway's env map — no review"; return 1; }
    local rc=0
    # bounded INSIDE the workflow's 900 s activeDeadlineSeconds: a deadline kill skips the EXIT
    # trap, so the session would hold its rail slot until the gateway TTL (4 h) and the tick's
    # metrics push would never happen. 124 = timed out → no verdict, the next tick retries.
    rm -f "$WORK/result.json"
    harness_claude "$inputs" "$lens" "$prompt" "$model" || rc=$?
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
log "tick done: mechanical=$N_MECH approve=$N_APPROVE request_changes=$N_RC defer=$N_DEFER error=$N_ERR"
if [ "$TERMINAL_OK" -ne 1 ]; then exit 10; fi
exit "$LLM_RC"
