#!/usr/bin/env bash
# sitting.sh — the island intake sitting's launcher script (FU-320; islands/intake/README.md). Run by the
# `intake` template of agents/coordinator/island-intake-argo.yaml, whose bootstrap clones homelab master to
# /work/homelab and execs this file from there inside the island's devbox (`devbox run` in islands/intake/ —
# its devbox.json is this script's toolchain; claude, git and curl are the pod image's); the machinery
# inventory (predicate, key, capacity, belts, identity) is that manifest's header. Inputs are the container's environment — MODE, REVIEW (the workflow's
# parameters), ISLAND (ONE island: the workflow's walk starts this script once per island, homelab#3579), the INTAKE_* knobs, the transcripts-bucket keys, PUSHGATEWAY — never an Argo template tag.
# ISLAND is a platform island (a row of the selector's table: this repo, docs/intake/<island>.md) or a STACK island
# `<stack>/<repo>` (homelab#3580: declared by that stack's AgentStack claim, `repos[].intake.facts`) — step 0 below
# resolves either to a repo and a facts file, and no stack or stack repo is named in this file. Where a slash is
# invalid the name travels as ISLAND_KEY (`/` → `-`: the bucket prefix, the gateway task key) or base64 (the
# Pushgateway grouping key); the metric label and the receipt's `island` keep the name as the claim spells it.
# Harness: islands/intake/tests/island-intake-test.sh (run by `devbox run deep-dig-test`).
set -uo pipefail
DAY="$(date -u +%Y-%m-%d)"; TS_RUN="$(date -u +%Y%m%dT%H%M%SZ)"; RUN_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$MODE" in apply|dry-run) ;; *) echo "island-intake: mode must be apply|dry-run (got $MODE)"; exit 1;; esac
REVIEW="${REVIEW:-review-repair}"
case "$REVIEW" in off|review-repair) ;; *) echo "island-intake: review must be off|review-repair (got $REVIEW)"; exit 1;; esac
PGW="${PUSHGATEWAY:-}"
ND=0; NM=0; NRR=0; NG=0; NE=0   # this run's inputs per source: dig findings, pile members, pile re-reads, gap rows, escape PRs
NW=0; NST=0                     # …wait inputs (parking comments) and stale waits (re-read at once)
WC_H=0; WC_R=0; WC_O=0; WC_U=0; NFW=0; NFWI=0   # the wait read: intake-written records by class, R+O, ledger items
REVIEW_RAN=0
ISLAND_KEY="${ISLAND//\//-}"
# the Pushgateway grouping key: a path segment cannot hold a slash, so a stack island's name rides base64
# (`island@base64/<url-safe base64>` — the Pushgateway decodes it into the same `island` label)
case "$ISLAND" in
  */*) PGW_ISLAND="island@base64/$(printf '%s' "$ISLAND" | base64 | tr -d '\n=' | tr '+/' '-_')";;
  *) PGW_ISLAND="island/$ISLAND";;
esac
_push() { # <probe_ok> <inputs> <session_ran> <ruled> <queued>
  [ -n "$PGW" ] || return 0
  printf '%s\n' \
    "# TYPE island_intake_last_run_timestamp_seconds gauge" "island_intake_last_run_timestamp_seconds $(date -u +%s)" \
    "# TYPE island_intake_probe_ok gauge" "island_intake_probe_ok $1" \
    "# TYPE island_intake_inputs gauge" "island_intake_inputs $2" \
    "# TYPE island_intake_source_inputs gauge" "island_intake_source_inputs{source=\"dig\"} $ND" \
    "island_intake_source_inputs{source=\"member\"} $NM" "island_intake_source_inputs{source=\"reread\"} $NRR" \
    "island_intake_source_inputs{source=\"gap\"} $NG" "island_intake_source_inputs{source=\"escape\"} $NE" \
    "island_intake_source_inputs{source=\"wait\"} $NW" "island_intake_source_inputs{source=\"stale\"} $NST" \
    "# TYPE island_intake_session_ran gauge" "island_intake_session_ran $3" \
    "# TYPE island_intake_ruled gauge" "island_intake_ruled $4" \
    "# TYPE island_intake_queued gauge" "island_intake_queued $5" \
    "# TYPE island_intake_review_ran gauge" "island_intake_review_ran $REVIEW_RAN" \
    "# TYPE island_intake_wait_records gauge" "island_intake_wait_records{class=\"H\"} $WC_H" \
    "island_intake_wait_records{class=\"R\"} $WC_R" "island_intake_wait_records{class=\"O\"} $WC_O" \
    "island_intake_wait_records{class=\"U\"} $WC_U" \
    "# TYPE island_intake_false_waits gauge" "island_intake_false_waits $NFW" \
    "# TYPE island_intake_false_wait_items gauge" "island_intake_false_wait_items $NFWI" \
    | curl -fsS --max-time 5 --data-binary @- "$PGW/metrics/job/island_intake/$PGW_ISLAND" >/dev/null 2>&1 \
    || echo "island-intake: pushgateway unreachable — metrics stale, rulings unaffected"
}
TS_PREFIX="s3://${AGENT_TS_BUCKET}/homelab/intake-${ISLAND_KEY}-${DAY}/intake-r1-${TS_RUN}"
_ts_put() { # <local> <remote-basename>
  [ -s "$1" ] || return 0
  [ -n "${AGENT_TS_ACCESS_KEY_ID:-}" ] || { echo "transcripts: no S3 writer key — $2 not captured"; return 1; }
  command -v s5cmd >/dev/null 2>&1 || { echo "transcripts: s5cmd not in this image — $2 not captured"; return 1; }
  AWS_ACCESS_KEY_ID="$AGENT_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AGENT_TS_SECRET_ACCESS_KEY" \
    s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp "$1" "$TS_PREFIX/$2" >/dev/null 2>&1 \
    || { echo "transcripts: upload FAILED for $2"; return 1; }
  _ts_put_stack "$1" "$2" || true
}
# A stack island's own copy, same file under the same run path minus the homelab/ prefix (the bucket is
# already the island's): the Composition's intake-transcripts-<repo> bucket, readable from the stack's
# namespace. Copied only when the key's Secret names THIS island's stack (two claims listing one repo must
# not land one stack's sittings in the other's bucket); platform islands get no key at all. The copy is
# REDACTED first: every value of this pod's credential env (and the ServiceAccount token) is replaced by
# its name, so a session that printed its environment — the 2026-10-29 incident shape — does not carry a
# platform token into a stack-readable place. A literal scrub: it catches the accidental dump, not a
# deliberately encoded one. Beyond the env values: the git auth header form (base64 of
# `x-access-token:<token>`, which the island clone's .git/config carries), every gateway admission's
# session values (/tmp/redact-values, appended by _admit), and anything JWT-shaped (the projected tokens
# rotate during a sitting, so a file read at upload time would miss an earlier one). A failure is said
# and never fails the canonical upload above.
STACK_TS_PREFIX="s3://${STACK_TS_BUCKET:-}/intake-${DAY}/intake-r1-${TS_RUN}"
_ts_put_stack() { # <local> <remote-basename>
  case "$ISLAND" in */*) ;; *) return 0;; esac
  [ -n "${STACK_TS_BUCKET:-}" ] && [ -n "${STACK_TS_ACCESS_KEY_ID:-}" ] || return 0
  [ "${STACK_TS_STACK:-}" = "${ISLAND%%/*}" ] \
    || { echo "transcripts: stack copy SKIPPED for $2 — the bucket's stack '${STACK_TS_STACK:-}' is not the island's"; return 1; }
  local red; red="$(mktemp)" || return 1
  python3 -I - "$1" "$red" <<'PY' || { rm -f "$red"; echo "transcripts: stack copy SKIPPED for $2 — redaction failed"; return 1; }
import base64, os, re, sys
names = ("GH_TOKEN", "INTAKE_READ_GH_TOKEN", "AGENT_TS_ACCESS_KEY_ID", "AGENT_TS_SECRET_ACCESS_KEY",
         "AGENT_TS_READER_ID", "AGENT_TS_READER_SECRET", "STACK_TS_ACCESS_KEY_ID", "STACK_TS_SECRET_ACCESS_KEY",
         "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY")
vals = [(os.environ.get(n, ""), n) for n in names]
for f in ("/var/run/secrets/kubernetes.io/serviceaccount/token", "/var/run/secrets/agent-gateway/token"):
    try: vals.append((open(f).read().strip(), "SA_TOKEN:" + f.rsplit("/", 2)[-2]))
    except OSError: pass
for n in ("GH_TOKEN", "INTAKE_READ_GH_TOKEN"):
    v = os.environ.get(n, "")
    if v: vals.append((base64.b64encode(("x-access-token:" + v).encode()).decode(), n + ":basic"))
try:
    vals += [(l.strip(), "GATEWAY_SESSION") for l in open("/tmp/redact-values") if l.strip()]
except OSError: pass
data = open(sys.argv[1], "rb").read()
for v, n in sorted(vals, key=lambda x: -len(x[0])):
    if len(v) >= 8: data = data.replace(v.encode(), ("[redacted:" + n + "]").encode())
data = re.sub(rb"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", b"[redacted:JWT]", data)
open(sys.argv[2], "wb").write(data)
PY
  AWS_ACCESS_KEY_ID="$STACK_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$STACK_TS_SECRET_ACCESS_KEY" \
    s5cmd --endpoint-url "$AGENT_TS_ENDPOINT" cp "$red" "$STACK_TS_PREFIX/$2" >/dev/null 2>&1 \
    || { rm -f "$red"; echo "transcripts: stack copy FAILED for $2 (s3://$STACK_TS_BUCKET)"; return 1; }
  rm -f "$red"
}

# the clone is the bootstrap's (the manifest): this file is read from it, so it cannot make it
cd /work/homelab || exit 1

# ── 0. THE ISLAND'S REPO AND FACTS FILE (homelab#3580) ──────────────────────────────────────────
# The selector resolves the name (`--resolve`): a platform island is this repo and docs/intake/<island>.md,
# with no claims read; a stack island is the repo and the facts path its claim declares, read live
# (scripts/claims-read.sh). A stack island's repo is cloned beside this clone — default branch, depth 1,
# its push URL disabled (the sitting writes to GitHub through `gh` only) — and the model sessions run
# there, so the facts file's repo-relative reads resolve. Every failure here is THIS island's step
# failing (exit 1), before any selection or session: the walk's other islands are other pods.
_fail0() { _push 0 0 0 0 0; echo "island-intake: $1"; exit 1; }
WORK=/work/homelab   # where the model sessions run and the lenses read the base
HL=""                # the prefix a homelab path needs from there ("" = the homelab clone itself)
SEL_ARGS=(); CLAIMS_ARGS=()
case "$ISLAND" in */*)
  bash islands/intake/scripts/claims-read.sh /tmp/claims.json || _fail0 "$ISLAND — a stack island cannot be resolved without the claims — exit 1, Argo retries"
  CLAIMS_ARGS=(--claims /tmp/claims.json);;
esac
RESOLVED="$(bash islands/intake/scripts/intake-select.sh --resolve --repo "${ORG:-teststuffstash}/homelab" --island "$ISLAND" "${CLAIMS_ARGS[@]}" 2>/tmp/resolve.log)" \
  || { cat /tmp/resolve.log; _fail0 "$ISLAND resolves to no island — this island's step fails"; }
REPO_SLUG="$(jq -r '.repo' <<< "$RESOLVED")"; FACTS="$(jq -r '.facts' <<< "$RESOLVED")"; ISLAND_KIND="$(jq -r '.kind' <<< "$RESOLVED")"
if [ "$ISLAND_KIND" = stack ]; then
  WORK=/work/island-repo; HL="/work/homelab/"
  rm -rf "$WORK"
  _ah="http.extraHeader="; [ -n "${GH_TOKEN:-}" ] && _ah="http.extraHeader=Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  git clone -c "$_ah" --depth 1 "https://github.com/$REPO_SLUG.git" "$WORK" || _fail0 "$ISLAND — clone failed ($REPO_SLUG) — exit 1, Argo retries"
  git -C "$WORK" remote set-url --push origin "no-push://the-intake-sitting-reads-only" || echo "island-intake: could not disable the push URL of $WORK — continuing"
  # claude's workdir trust for this clone too (the bootstrap seeds the homelab clone's)
  { jq --arg d "$WORK" '.projects[$d] = {hasTrustDialogAccepted: true}' "$HOME/.claude.json" > /tmp/claude.json.next && mv /tmp/claude.json.next "$HOME/.claude.json"; } 2>/dev/null \
    || echo "island-intake: could not add $WORK to $HOME/.claude.json (the workdir trust seed) — continuing"
  SEL_ARGS=(--claims /tmp/claims.json --facts "$WORK/$FACTS")
fi
# the facts file can carry a sitting (scripts/facts-check.sh — the ONE predicate, the harness's too)
FACTS_MISS="$(bash islands/intake/scripts/facts-check.sh "$WORK/$FACTS" | paste -sd';' -)" || true
[ -z "$FACTS_MISS" ] || _fail0 "$ISLAND — the facts file $FACTS ($REPO_SLUG) cannot carry a sitting: $FACTS_MISS"

# ── 1. SELECT, per source (deterministic; exit 1 = hold, 2 = a probe failed) ──────
# A hold is a hold only when the selector WROTE a selection saying so: an unexpected death
# (set -e) also exits 1, and reading that as "nothing to do" is the fail-open the first
# in-cluster dry-run hit (2026-10-28 — inputs 0 while four findings were waiting).
_select() { # <source> → 0 fire, 1 hold, 2 failed; the selection lands in /tmp/sel-<source>.json
  local _rc=0
  bash islands/intake/scripts/intake-select.sh --source "$1" --island "$ISLAND" "${SEL_ARGS[@]}" --out "/tmp/sel-$1.json" 2>"/tmp/select-$1.log" || _rc=$?
  cat "/tmp/select-$1.log"
  if [ "$_rc" -eq 2 ] || ! jq -e '.schema == "island-intake-select/v1"' "/tmp/sel-$1.json" >/dev/null 2>&1; then
    echo "island-intake: selection failed (source $1, rc=$_rc, no valid selection)"; return 2
  fi
  return "$_rc"
}
rc_dig=0; _select dig || rc_dig=$?
rc_pile=0; _select pile || rc_pile=$?
rc_gaps=0; _select gaps || rc_gaps=$?
rc_esc=0; _select escape || rc_esc=$?
rc_wait=0; _select wait || rc_wait=$?
if [ "$rc_dig" -eq 2 ] || [ "$rc_pile" -eq 2 ] || [ "$rc_gaps" -eq 2 ] || [ "$rc_esc" -eq 2 ] || [ "$rc_wait" -eq 2 ]; then
  _push 0 0 0 0 0; echo "island-intake: selection failed — exit 1, Argo retries"; exit 1
fi
# ONE input set for ONE sitting: the dig's text inputs, the pile's issues and waits, the gap rows,
# the escape PRs, the wait inputs. A stale wait (the wait source's `reread` row) merges into the
# pile's row of the same id — the PILE row wins (its `wait`: seat | agent/blocked | pr-hold), only
# `stale` is added (the pile's own `stale` kept when it has one) — or joins as a re-read of its own.
jq -n --slurpfile d /tmp/sel-dig.json --slurpfile p /tmp/sel-pile.json --slurpfile g /tmp/sel-gaps.json --slurpfile e /tmp/sel-escape.json \
      --slurpfile w /tmp/sel-wait.json \
  'def by_id: reduce .[] as $x ({}; if .[$x.id] == null then .[$x.id] = $x
                                   else .[$x.id].stale = (.[$x.id].stale // $x.stale) end) | [.[]];
   ($p[0].inputs + [$w[0].inputs[] | select(.kind == "reread")] | by_id) as $pile
   | [$w[0].inputs[] | select(.kind == "wait")] as $waits
   | {schema: "island-intake-select/v1", island: $d[0].island, source: "dig+pile+gaps+escape+wait", ts: $p[0].ts,
    specs_root: $g[0].specs_root,
    counts: {dig: $d[0].counts.inputs, members: $p[0].counts.members,
             rereads: ([$pile[] | select(.kind == "reread" and .stale == null)] | length),
             gaps: $g[0].counts.inputs, escapes: $e[0].counts.inputs,
             waits: ($waits | length), stale: ([$pile[] | select(.stale != null)] | length),
             inputs: ($d[0].counts.inputs + ($pile | length) + $g[0].counts.inputs + $e[0].counts.inputs + ($waits | length))},
    inputs: ($d[0].inputs + $pile + $g[0].inputs + $e[0].inputs + $waits), escape_prior: ($e[0].prior // [])}' > /tmp/sel.json \
  || { _push 0 0 0 0 0; echo "island-intake: selection failed (the merge) — exit 1, Argo retries"; exit 1; }
# the earlier sittings' wait records — the ledger's input (islands/intake/scripts/intake-wait-ledger.py)
mkdir -p /tmp/wait; jq '.prior // []' /tmp/sel-wait.json > /tmp/wait/prior.json 2>/dev/null || echo '[]' > /tmp/wait/prior.json
NIN="$(jq -r '.counts.inputs' /tmp/sel.json)"; ND="$(jq -r '.counts.dig' /tmp/sel.json)"
NM="$(jq -r '.counts.members' /tmp/sel.json)"; NRR="$(jq -r '.counts.rereads' /tmp/sel.json)"
NG="$(jq -r '.counts.gaps' /tmp/sel.json)"; NE="$(jq -r '.counts.escapes' /tmp/sel.json)"
NW="$(jq -r '.counts.waits' /tmp/sel.json)"; NST="$(jq -r '.counts.stale' /tmp/sel.json)"
# An empty selection starts no session (homelab#3579): the island is quiet, and its metrics say it ran —
# the per-island IslandIntakeStale reads this push, so a quiet island stays fresh.
if [ "$NIN" -eq 0 ]; then
  _push 1 0 0 0 0; echo "island-intake: $ISLAND — no inputs"; exit 0
fi
if [ "$rc_dig" -ne 0 ] && [ "$rc_pile" -ne 0 ] && [ "$rc_gaps" -ne 0 ] && [ "$rc_esc" -ne 0 ] && [ "$rc_wait" -ne 0 ]; then
  _push 1 "$NIN" 0 0 0; echo "island-intake: hold — no sitting today"; exit 0
fi

# ── 2. ADMISSION — every session of this run (the author, each lens, the repair) is admitted
# separately by the agent-gateway (FU-270) as the platform's coordinator (the islands are platform
# islands; the bell below rings platform), tier heavy, the STRONGEST model of that tier (`prefer`,
# GW-SESSIONS-ADMIT: an authoring sitting rules a whole pile once a day — a wrong ruling costs
# rides). agents/gateway-admit.sh's UNBOUND lane shape: the dispatch env rides `env` onto the claude
# call. rc 4 = the old path (knob off, or the FU-270 transition fallback, logged by the helper): the
# subscription rail. Nothing of this run is served on the Go rail (the goal-decompose class is not
# on Go): a gateway answer there is released unused. The helper keeps ONE session in its globals,
# so a session is released before the next admission (gw_release; the EXIT trap is the backstop).
. agents/gateway-admit.sh
ADMIT_WHY=""
_admit() { # <task suffix> → rc 0 (rail + TS_MODEL + GW_LLM_ENV set) | 1 (not admitted: ADMIT_WHY says why)
  local _gw=0 _rm
  gw_admit_lane /tmp/gw-llm.env --stack platform --role coordinator --task "intake-${ISLAND_KEY}-$DAY$1" --tier heavy --prefer strongest || _gw=$?
  case "$_gw" in
    0) trap gw_release EXIT
       case "$GW_RAIL $GW_MODEL" in
         opencode\ *|*opencode-go/*) ADMIT_WHY="the gateway answered on the Go rail ($GW_RAIL $GW_MODEL) — released unused"; gw_release; GW_LLM_ENV=(); return 1;;
       esac
       # every admission's session values, kept for the stack copy's redaction (_ts_put_stack)
       local _kv; for _kv in "${GW_LLM_ENV[@]}"; do
         case "${_kv%%=*}" in *TOKEN*|*KEY*|*SECRET*) printf '%s\n' "${_kv#*=}" >> /tmp/redact-values;; esac
       done
       rail="gateway:$GW_RAIL"; TS_MODEL="$GW_WIRE_MODEL"; return 0;;
    1) ADMIT_WHY="the gateway deferred [$GW_DEFER_REASON]"; return 1;;
  esac
  rail="$(SUBSCRIPTION_TIER=heavy bash agents/subscription-latch.sh --pick-rail)" || rail=""
  case "$rail" in
    ''|opencode-go/*) ADMIT_WHY="subscription rail not clear (rail='$rail')"; return 1;;
  esac
  _rm="$(bash agents/resolve-model.sh --role coordinator --class goal-decompose --fallback opus)"
  eval "$(python3 agents/model_id.py --shell "$_rm")"; TS_MODEL="${MODEL_MODEL:-$_rm}"; return 0
}
# The author and the repair sessions read stack-authored input with the pod's environment: their read set
# (GH_TOKEN and INTAKE_READ_GH_TOKEN — their job is GitHub writes and reads —, the transcripts READER key, the
# kube ServiceAccount) minus every key ONLY this shell uses: the transcripts WRITER keys (_ts_put,
# _ts_put_stack). A session steered by an issue body cannot overwrite a sitting's record or write into a
# stack's bucket. Every Secret-sourced env of the intake leaf is classified here or in the harness's
# read-set list (islands/intake/tests/island-intake-test.sh); a new one fails the harness until it is.
SESSION_UNSET=(-u AGENT_TS_ACCESS_KEY_ID -u AGENT_TS_SECRET_ACCESS_KEY -u STACK_TS_ACCESS_KEY_ID -u STACK_TS_SECRET_ACCESS_KEY)
if ! _admit ""; then
  _push 1 "$NIN" 0 0 0; echo "island-intake: $ADMIT_WHY — exit 1, Argo retries with backoff"; exit 1
fi
A_RAIL="$rail"; A_MODEL="$TS_MODEL"

# FACTS = step 0's: docs/intake/<island>.md for every platform island, the gateway's included (ADR-160; intake.md
# §Island facts); the claim's path, in the stack's clone, for a stack island
rm -rf /tmp/review; mkdir -p /tmp/review/issues
{
if [ "$ISLAND_KIND" = stack ]; then
cat <<BRIEF
You are the ISLAND INTAKE sitting for the \`$ISLAND\` island, running unattended in-cluster
(agents/coordinator/island-intake-argo.yaml). \`$ISLAND\` is a STACK island: the repo $REPO_SLUG,
declared in its stack's AgentStack claim. Your working directory is a fresh clone of that repo's
default branch at $WORK (cwd) — its open issues are your inputs, and every issue, label and comment
you write goes to $REPO_SLUG. The platform's files are in a second clone, homelab master at
/work/homelab: every \`islands/…\`, \`agents/…\` or \`docs/…\` path the brief names is under it.
Read ${HL}islands/intake/rules/intake.md IN FULL first and follow it exactly —
it is your brief; this prompt only adds the inputs, the mode and the receipt protocol.
Your island's facts file (intake.md §Island facts): $FACTS — in this repo (cwd); read it IN FULL after
the brief. A stack island has no dig findings, no gap rows and no wait read: those lists are empty.
BRIEF
else
cat <<BRIEF
You are the ISLAND INTAKE sitting for the \`$ISLAND\` island, running unattended in-cluster
(agents/coordinator/island-intake-argo.yaml). Your working tree is a fresh clone of homelab
master at /work/homelab (cwd). Read islands/intake/rules/intake.md IN FULL first and follow it exactly —
it is your brief; this prompt only adds the inputs, the mode and the receipt protocol.
Your island's facts file (intake.md §Island facts): $FACTS — read it IN FULL after the brief.
BRIEF
fi
cat <<BRIEF

mode: $MODE
review: $REVIEW

The inputs come as the brief's lists (intake.md §Inputs); a list may be empty.

\`text:\` inputs with \`source: dig\` — findings of the grouped deep dig
(docs/agents/roles.md §deep dig), each a diagnosis of standing alerts with the reads it
made. Treat each as a CLAIM (intake.md procedure step 1): live-verify it within the brief's
read set — the spec row it names, the alert's live state, the log lines
the alert's annotation names, and the issues/PRs filed or merged since the finding's
timestamp. Several findings are
often ONE cause (the dig groups by onset + host, and re-digs a renamed tail alert):
rule them together — one issue for one change. When you \`file\`, the issue's prose names
the finding id(s) as its origin (\`Origin=\` is prose for a non-issue source).

\`text:\` inputs with \`source: responder\` — one per recurring class of report-only
responder triages (same alert, same namespace, on the island's subjects), listing every
member finding (intake.md §Inputs). Rule the class on its cause, never by applying a
member's \`remediation_would\`; name the class id as the origin.

\`issues:\` — the island's open issues nobody has ruled (no lifecycle label, no
\`intake:\` comment). Rule each one.

\`reread:\` — the island's waits: issues an earlier ruling parked on a human, with the
label or ruling that parks them (\`wait\`), since when (\`since\`) and the parking line
(\`parked_by\`). A \`wait: pr-hold\` row is parked by \`blocked-on: human\` on its open PR
(\`pr\`), not by a label. A row carrying \`stale\` names a target (\`issue=\`/\`pr=\` marker, or a
\`#<n>\` its parking comment named) that closed or merged since: re-read it now, whatever its age.
Procedure step R: test the ONE fact, then change the ruling or write nothing.

\`gap:\` — \`⚑ gap\` / \`🚧 WIP\` rows of the island's own specs index that no open issue names,
id \`<specs page>#<REQ>\` (the index row verbatim in \`row\`). Rule each one (intake.md §Inputs).

\`escape:\` — PRs of issues this island queued that drew CHANGES_REQUESTED: step E
(${HL}islands/intake/rules/intake-escape.md), one record per blocking finding under \`## Escape records\`.
\`escape-prior:\` — earlier sittings' records, from their receipts: read, never re-classified.

\`wait:\` — parking comments on the island's items, released since or standing: step W
(${HL}islands/intake/rules/intake-wait.md), one record per input under \`## Wait records\`; the ledger's earlier
records are in /tmp/wait/prior.json.

LIVE READS (the brief's read set; every one is a GET, from this pod):
- Alertmanager: curl -s http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/api/v2/alerts
- Prometheus: curl -sG http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query --data-urlencode 'query=<promql>'
- Loki (logs; MULTI-TENANT — the tenant is the NAMESPACE and the header is required, docs/loki-tenancy.md):
  control first: curl -sG -H 'X-Scope-OrgID: <namespace>' http://loki.loki.svc:3100/loki/api/v1/labels
  (\`"status":"success"\` with a non-empty \`data\` = that tenant has streams; an empty \`data\` is a wrong tenant or a quiet namespace, not "no such log line")
  curl -sG -H 'X-Scope-OrgID: <namespace>' http://loki.loki.svc:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="<ns>",pod=~"<pod>.*"}' --data-urlencode 'start=<unix-ns>' --data-urlencode 'limit=500'
  Node kernel logs are {container="kmsg-reader", node="<node>"} under tenant \`loki\`.
- the kube API, READ-ONLY (this pod's own ServiceAccount; no Secret, no ConfigMap, no write verb):
  control first: kubectl auth can-i get <kind> -n <ns>
  kubectl get <kind> -n <ns> -o json
  A \`Forbidden\` (or a \`no\` from the control) is a FACT to report — name the kind and the namespace — never an empty answer.
- ride records (the transcripts bucket, READER key):
  AWS_ACCESS_KEY_ID="\$AGENT_TS_READER_ID" AWS_SECRET_ACCESS_KEY="\$AGENT_TS_READER_SECRET" s5cmd --endpoint-url "\$AGENT_TS_ENDPOINT" ls "s3://\$AGENT_TS_BUCKET/homelab/issue-<n>/*"
  (then the same with \`cat\` on a run's run.log / manifest.json)
- the gateway's views: curl -s -H "Authorization: Bearer \$(cat /var/run/secrets/agent-gateway/token)" http://agent-gateway.agent-egress.svc.cluster.local:8080/<healthz | catalog/opencode | catalog/openrouter | sessions?task=<task>>
  This pod's caller lists only the sessions it admitted itself: an EMPTY \`sessions\` list for
  a worker's task is not absence — read the ride record instead.

RECEIPT PROTOCOL (the shell parses this; the receipt is the ONLY record that an input was
ruled — an input without a line re-presents tomorrow). For EVERY input id below (a dig
finding id, a \`responder/<alert>/<namespace>\` class id, \`<owner/repo>#<n>\` for an issue or an escape PR, \`<specs page>#<REQ>\` for a
gap row, \`<owner/repo>#<n>@<parked_at>/<state>\` for a wait) print exactly one line, at the end, outside any code fence:
  INTAKE-RULED: <input id> <outcome> <refs>
<outcome> is one of queue|goal|seat|fold|close|requeue|standing|split|file|forward|unchanged|deferred|read
(the brief's outcomes; \`forward\` = another island's, retitled and passed on — its <refs> is
\`island:<name>\`; \`unchanged\` = a \`reread:\` input whose wait still holds — you wrote
nothing; \`deferred\` = left for a later sitting, e.g. past the 3-queue cap; \`read\` = an
\`escape:\` PR or a \`wait:\` you read); <refs> is a comma-separated list of the issue/PR refs you wrote or
relied on (owner/repo#n), or \`-\`. An issue you FILED this sitting (a \`file\`, a parity issue, a
split part) is listed in the \`<refs>\` of the input it came from AND gets its own line with its own
ruling — \`INTAKE-RULED: <owner/repo>#<n> queue|goal|seat|standing|close <refs>\` (dry-run: \`#new-<k>\`);
a filed queue/goal issue is reviewed and labelled like any other. For every \`## Escape records\` record also print
  INTAKE-ESCAPE: <pr id> <finding id> <class A|B|C|D|E|X> <the intake check it names, one line>
For every \`## Wait records\` record its INTAKE-WAIT line, and for a key the ledger puts at the bar its
INTAKE-WAIT-PROPOSAL line — both one JSON object on one line (${HL}islands/intake/rules/intake-wait.md).
In dry-run mode print the lines you WOULD print.
BRIEF
if [ "$REVIEW" = review-repair ]; then
cat <<BRIEF

REVIEW: review-repair — intake.md §Review and repair runs IN THIS RUN: you are its first pass
(step 1: bodies, no label, no \`intake:\` comment on a \`queue\`/\`goal\` ruling; the
\`## Review units\` lines). The launcher runs the lenses and then ONE repair session, which posts
the review comment, the labels and your ruling. So that the launcher can label even when the repair
does not run, add for every issue of a \`queue\`/\`goal\` ruling that must carry labels (a
Goal's children, never the Goal) one line beside the INTAKE-RULED lines:
  INTAKE-HOLD: <owner/repo>#<n> add=<label,label,…>
and write every body of those rulings (final text, the Goal's included) to /tmp/review/issues/<n>.md
— in dry-run an issue you would create is \`new-<k>\` (its refs read \`<owner/repo>#new-<k>\`).
BRIEF
else
printf '\nREVIEW: off — label and rule as you go; intake.md §Review and repair does not run in this run.\n'
fi
printf '\nINPUTS (island-intake-select/v1, built %s):\n' "$(jq -r .ts /tmp/sel.json)"
printf '\ntext: (source: dig)\n'; jq '[.inputs[] | select(.kind == "dig")]' /tmp/sel.json
printf '\ntext: (source: responder)\n'; jq '[.inputs[] | select(.kind == "responder")]' /tmp/sel.json
printf '\nissues:\n'; jq '[.inputs[] | select(.kind == "member" or .kind == "attribution")]' /tmp/sel.json
printf '\nreread:\n'; jq '[.inputs[] | select(.kind == "reread")]' /tmp/sel.json
printf '\ngap:\n'; jq '[.inputs[] | select(.kind == "gap")]' /tmp/sel.json
printf '\nescape:\n'; jq '[.inputs[] | select(.kind == "escape")]' /tmp/sel.json
printf '\nescape-prior:\n'; jq '.escape_prior // []' /tmp/sel.json
printf '\nwait:\n'; jq '[.inputs[] | select(.kind == "wait")]' /tmp/sel.json
} > /tmp/brief.md
_ts_put /tmp/brief.md brief.md || true
_ts_put /tmp/sel.json inputs.json || true

: > /tmp/ts-mark; : > /tmp/intake.log
( cd "$WORK" && timeout "${AUTHOR_TIMEOUT_S:-3600}" env "${SESSION_UNSET[@]}" "${GW_LLM_ENV[@]}" claude -p "$(cat /tmp/brief.md)" --model "$TS_MODEL" --permission-mode bypassPermissions --max-turns 120 </dev/null 2>&1 ) \
  | tee /tmp/intake.log \
  || echo "WARN: the intake session failed — whatever it printed is still harvested" | tee -a /tmp/intake.log
gw_release

# ── 3. RULINGS (shell-owned: only ids of THIS run's inputs, only known outcomes) ────
grep -oE '^ *INTAKE-RULED: [^ ]+ [a-z-]+( [^ ]+)?' /tmp/intake.log | sed 's/^ *INTAKE-RULED: //' \
  | jq -R -s --slurpfile sel /tmp/sel.json '
      ($sel[0].inputs | map(.id)) as $ids
      | [ split("\n")[] | select(length > 0) | split(" ")
          | {input: .[0], outcome: .[1], refs: ((.[2] // "-") | if . == "-" then [] else split(",") end)}
          | select(.input as $i | $ids | index($i))
          | select(.outcome | IN("queue","goal","seat","fold","close","requeue","standing","split","file","forward","unchanged","deferred","read")) ]
      | unique_by(.input)' > /tmp/ruled.json 2>/dev/null || echo '[]' > /tmp/ruled.json
NR="$(jq '[.[] | select(.outcome != "deferred")] | length' /tmp/ruled.json)"
# an issue this sitting FILED and ruled in the same pass (a `file`, a parity issue, a split part — its id is a
# ref of an input's ruling) carries its own ruling line: not a ledger entry (only inputs re-present), but a
# queue/goal ruling the review stage, the labels and the bell must see
grep -oE '^ *INTAKE-RULED: [^ ]+ [a-z-]+( [^ ]+)?' /tmp/intake.log | sed 's/^ *INTAKE-RULED: //' \
  | jq -R -s --slurpfile r /tmp/ruled.json '
      ([$r[0][] | .refs[]] | unique) as $filed | ([$r[0][] | .input]) as $ins
      | [ split("\n")[] | select(length > 0) | split(" ")
          | {input: .[0], outcome: .[1], refs: ((.[2] // "-") | if . == "-" then [] else split(",") end)}
          | select(.input as $i | ($filed | index($i)) and ($ins | index($i) | not))
          | select(.outcome | IN("queue","goal","seat","standing","close")) ] | unique_by(.input)' > /tmp/ruled-filed.json 2>/dev/null || echo '[]' > /tmp/ruled-filed.json
jq -s '.[0] + .[1]' /tmp/ruled.json /tmp/ruled-filed.json > /tmp/ruled-q.json 2>/dev/null || cp /tmp/ruled.json /tmp/ruled-q.json
# queued = queue-class rulings of inputs + of filed issues no input's queue-class ruling already names (no double count)
NQ="$(jq -n --slurpfile r /tmp/ruled.json --slurpfile f /tmp/ruled-filed.json '
      def q: select(.outcome == "queue" or .outcome == "goal" or .outcome == "requeue");
      ([$r[0][] | q]) as $rq | ([$rq[] | .refs[]]) as $named
      | ($rq | length) + ([$f[0][] | q | select(.input as $i | $named | index($i) | not)] | length)')"
# the escape read's records: one per blocking finding of an escape input of THIS run
grep -oE '^ *INTAKE-ESCAPE: [^ ]+ [^ ]+ [A-EX]( .*)?$' /tmp/intake.log | sed 's/^ *INTAKE-ESCAPE: //' \
  | jq -R -s --slurpfile sel /tmp/sel.json '
      ([$sel[0].inputs[] | select(.kind == "escape") | .id]) as $ids
      | [ split("\n")[] | select(length > 0) | capture("^(?<pr>[^ ]+) (?<finding>[^ ]+) (?<class>[A-EX]) ?(?<check>.*)$")
          | select(.pr as $p | $ids | index($p)) ] | unique_by([.pr, .finding])' > /tmp/escapes.json 2>/dev/null || echo '[]' > /tmp/escapes.json
# the wait read's records: one per wait input of THIS run, the model's class + rule keys joined to the
# selector's row (item, writer, parking and release facts are the selector's, never the model's)
# A line that is not a JSON object, or names no wait of this run, or carries an unknown class or a bad
# rule entry, is model output gone wrong: skipped and counted (`wait_lines_dropped`, with samples),
# never a reason to lose the valid lines beside it.
{ grep -E '^ *INTAKE-WAIT: ' /tmp/intake.log || true; } | sed 's/^ *INTAKE-WAIT: //' \
  | jq -R -s --slurpfile sel /tmp/sel.json --arg run "intake-${ISLAND_KEY}-${DAY}/intake-r1-${TS_RUN}" '
      ([$sel[0].inputs[] | select(.kind == "wait") | {key: .id, value: .}] | from_entries) as $rows
      | def ok: (.wait | type) == "string" and $rows[.wait] != null and (.class | IN("H","R","O","U"))
          and ((.rules // []) | type == "array" and all(.[]; type == "object" and (.mark | IN("caused","missing")) and ((.file // "") | type == "string" and . != "")));
        [ split("\n")[] | select(length > 0) | . as $line | (try fromjson catch null) as $o
          | if ($o | type) != "object" then {drop: "unparseable", sample: $line[0:120]}
            elif ($o | try ok catch false) | not then {drop: "invalid", sample: $line[0:120]}
            else ($o | $rows[.wait] as $w
              | {keep: {wait, class, rules: (.rules // []), direction: ((.direction // "") | tostring), widens: (.widens == true),
                        fact: ((.fact // "") | tostring), item: ($w.id | sub("@.*$"; "")), number: $w.number, state: $w.wait,
                        parked_at: $w.parked_at, parked_by: $w.parked_by, writer: $w.writer,
                        released_at: ($w.released_at // null), release: ($w.release // null), run: $run}}) end ]
      | {kept: ([.[] | .keep // empty] | unique_by(.wait)),
         dropped: {count: ([.[] | select(.drop)] | length), samples: ([.[] | select(.drop) | {reason: .drop, sample}] | .[0:5])}}' \
  > /tmp/wait-lines.json 2>/dev/null || echo '{"kept": [], "dropped": {"count": -1, "samples": [{"reason": "the harvest itself failed"}]}}' > /tmp/wait-lines.json
jq '.kept' /tmp/wait-lines.json > /tmp/waits.json; jq '.dropped' /tmp/wait-lines.json > /tmp/waits-dropped.json
# every proposal line goes to the ledger as written: it skips and counts a malformed one, keeps the rest
{ grep -E '^ *INTAKE-WAIT-PROPOSAL: ' /tmp/intake.log || true; } | sed 's/^ *INTAKE-WAIT-PROPOSAL: //' > /tmp/wait/proposals.jsonl
# the ledger over the receipts' prior records + this run's: keeps a proposal only for a key at the bar
python3 islands/intake/scripts/intake-wait-ledger.py --records /tmp/wait/prior.json --records /tmp/waits.json \
    --proposals /tmp/wait/proposals.jsonl --json > /tmp/wait-ledger.json 2>/tmp/wait-ledger.err \
  || { echo "⚠ island-intake: the wait ledger failed — $(head -c 300 /tmp/wait-ledger.err)"; echo '{}' > /tmp/wait-ledger.json; }
jq -e 'type == "object"' /tmp/wait-ledger.json >/dev/null 2>&1 || echo '{}' > /tmp/wait-ledger.json
eval "$(jq -r '[.[] | select(.writer == "intake")] as $m
    | "WC_H=\([$m[] | select(.class == "H")] | length); WC_R=\([$m[] | select(.class == "R")] | length); "
    + "WC_O=\([$m[] | select(.class == "O")] | length); WC_U=\([$m[] | select(.class == "U")] | length); "
    + "NFW=\([$m[] | select(.class == "R" or .class == "O")] | length)"' /tmp/waits.json 2>/dev/null)" || true
NFWI="$(jq -r '.false_waits.items // 0' /tmp/wait-ledger.json 2>/dev/null)" || NFWI=0

# ── 4. REVIEW AND REPAIR (REVIEW=review-repair; islands/intake/rules/intake.md §Review and repair) ─────────
# The author's `## Review units` lines (`unit: <owner/repo>#<n> [#<child> …] base=<sha>`,
# `rows: <owner/repo>#<n> base=<sha>`) of THIS repo whose issues a queue/goal ruling of this run
# names: one unit-lens session per `unit:` line, one rows-lens session per `rows:` line (the author
# writes one for a `spec` body only: an `edit` body has no `rows:` line, so no rows lens) — each admitted
# on its own (_admit) and CONFINED (env -i, no token; Read scoped to its case directory, Write to its
# one output file, `git show` / `git grep` for the base — the lens briefs' frozen-case form). The rows
# lens is the specs reviewer's staged read (agents/specs-reviewer-session.sh review_run): pass 1 sees
# ONLY masked/ (the pinned wheel's mask_page over the body's spec section) + process/ and freezes its
# `## Pass 1 (frozen)`; pass 2 completes the same file. A failed run (no file, or an empty Pass 1) is
# re-run once, then skipped. Then ONE repair session (an author session: steps 3–4 — post, label,
# rule). The launcher is the belt: an INTAKE-HOLD issue still unlabelled after the repair is labelled
# here (and, when the repair did not run, gets the review comment + the ruling first/last). Nothing
# here loops; a lens that fails or defers never holds the queue.
# REPO_SLUG = step 0's: this repo for a platform island, the claim's repo for a stack island
_re_repo="$(printf '%s' "$REPO_SLUG" | sed 's/\./\\./g')"
grep -oE '^ *INTAKE-HOLD: [^ ]+ add=[^ ]+' /tmp/intake.log | sed 's/^ *INTAKE-HOLD: //' \
  | jq -R -s --arg re "^${_re_repo}#([0-9]+|new-[0-9]+)\$" --slurpfile ruled /tmp/ruled-q.json '
      ([ $ruled[0][] | select(.outcome | IN("queue","goal")) | . as $r | ([.input] + .refs)[] | {ref: ., outcome: $r.outcome} ]) as $refs
      | [ split("\n")[] | select(length > 0) | capture("^(?<ref>[^ ]+) add=(?<add>[^ ]+)$")
          | select(.ref | test($re)) | . as $h
          | ([ $refs[] | select(.ref == $h.ref) | .outcome ] | first) as $o | select($o != null)
          | .add |= (split(",") | map(select(IN("agent-fix","task/fix","task/build","agent/queued","experiment/open"))))
          | select(.add | length > 0) | . + {key: (.ref | sub(".*#"; "")), outcome: $o} ] | unique_by(.ref)' \
  > /tmp/holds.json 2>/dev/null || echo '[]' > /tmp/holds.json
# the review units: kind, issue keys (the first is the unit's head — a Goal, or the one issue), base
grep -oE '^[ >*`-]*(unit|rows): [^ `]+( +#[^ `]+)* +base=[0-9a-f]{7,40}' /tmp/intake.log | sed -E 's/^[ >*`-]*//' \
  | jq -R -s --arg re "^${_re_repo}#([0-9]+|new-[0-9]+)\$" --slurpfile ruled /tmp/ruled-q.json '
      ([ $ruled[0][] | select(.outcome | IN("queue","goal")) | ([.input] + .refs)[] | select(test($re)) | sub(".*#"; "") ]) as $keys
      | [ split("\n")[] | select(length > 0)
          | capture("^(?<kind>unit|rows): (?<head>[^ ]+)(?<rest>( +#[^ ]+)*) +base=(?<base>[0-9a-f]+)$")
          | select(.head | test($re))
          | {kind, base, issues: ([.head | sub(".*#"; "")] + [.rest | scan("#([^ ]+)") | .[0]])}
          | select(.issues | all(. as $i | $keys | index($i))) ]
      | reduce .[] as $u ([]; if index([$u]) then . else . + [$u] end)' \
  > /tmp/units.json 2>/dev/null || echo '[]' > /tmp/units.json
NH="$(jq 'length' /tmp/holds.json)"; NU="$(jq 'length' /tmp/units.json)"
P_STATUS="skipped: review off"; P_RAIL=""; P_MODEL=""; LENS_N=0
echo '[]' > /tmp/lenses.json; echo '[]' > /tmp/findings.json; mkdir -p /tmp/review/out
LENS_TIMEOUT_S="${LENS_TIMEOUT_S:-1200}"; PASS1_TIMEOUT_S="${PASS1_TIMEOUT_S:-240}"; REPAIR_TIMEOUT_S="${REPAIR_TIMEOUT_S:-1200}"
LENS_MAX="${INTAKE_REVIEW_LENS_MAX:-3}"   # lens sessions per run: a budget, not a loop
# the pod's wall clock (activeDeadlineSeconds): a lens starts only when its worst case (two runs) plus the
# repair still fits, the repair only when it fits — Argo killing the pod mid-review would leave the held
# issues unlabelled and no receipt
RUN_DEADLINE_S="${RUN_DEADLINE_S:-14400}"
_fits() { [ $(( SECONDS + $1 + REPAIR_TIMEOUT_S + 600 )) -le "$RUN_DEADLINE_S" ]; }
_lens_env() { # <home> → KEY=VALUE lines for `env -i`: PATH, a throwaway HOME, the pod's LLM pair + OTEL, then the gateway's env over them
  printf '%s\n' "PATH=$PATH" "HOME=$1" "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}" "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-}" \
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "CLAUDE_CODE_ENABLE_TELEMETRY=${CLAUDE_CODE_ENABLE_TELEMETRY:-}" \
    "OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER:-}" "OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER:-}" \
    "OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_EXPORTER_OTLP_PROTOCOL:-}" "OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT:-}" \
    "OTEL_TRACES_EXPORTER=none" "OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES:-}"
  [ "${#GW_LLM_ENV[@]}" -eq 0 ] || printf '%s\n' "${GW_LLM_ENV[@]}"
}
_lens_run() { # <cwd> <brief> <prompt> <timeout_s> <name> <tool…> → /tmp/review/<name>.json; rc = the harness's
  local dir="$1" sys="$2" prompt="$3" lim="$4" name="$5" home="/tmp/review/home-$5" rc=0; shift 5
  local -a envargs=(); mkdir -p "$home"; mapfile -t envargs < <(_lens_env "$home")
  (cd "$dir" && timeout "$lim" env -i "${envargs[@]}" claude -p "$prompt" --model "$TS_MODEL" --append-system-prompt-file "/work/homelab/$sys" \
      --allowedTools "$@" --permission-mode default --output-format json </dev/null \
      > "/tmp/review/$name.json" 2> "/tmp/review/$name.err") || rc=$?
  return "$rc"
}
_pass1_lines() { # <rows output file> → the `## Pass 1 (frozen)` section's non-blank lines (a `- none` line counts)
  awk '/^## Pass 1 \(frozen\)/{on=1; next} on && /^## /{exit} on && NF' "$1" 2>/dev/null
}
_case_issue() { # <key> <dest dir> [comments] → <dest>/issues/<key>.md (+ .comments.md): apply = GitHub's body; dry-run (or no issue yet) = the author's file
  local k="$1" d="$2"; mkdir -p "$d/issues"
  case "$k" in
    *[!0-9]*) cp "/tmp/review/issues/$k.md" "$d/issues/$k.md" 2>/dev/null || echo "(the author wrote no body file for $k)" > "$d/issues/$k.md";;
    *) if [ "$MODE" != apply ] && [ -s "/tmp/review/issues/$k.md" ]; then cp "/tmp/review/issues/$k.md" "$d/issues/$k.md"   # dry-run: what apply WOULD post
       else gh issue view "$k" --repo "$REPO_SLUG" --json title,body --jq '"# " + .title + "\n\n" + .body' > "$d/issues/$k.md" 2>/dev/null \
         || cp "/tmp/review/issues/$k.md" "$d/issues/$k.md" 2>/dev/null || echo "(body unreadable for #$k)" > "$d/issues/$k.md"; fi;;
  esac
  [ "${3:-}" = comments ] || return 0
  case "$k" in
    *[!0-9]*) : > "$d/issues/$k.comments.md";;
    *) gh issue view "$k" --repo "$REPO_SLUG" --json comments \
         --jq '.comments[] | select((.body | startswith("intake:")) | not) | "### \(.author.login) — \(.createdAt)\n\n\(.body)\n"' \
         > "$d/issues/$k.comments.md" 2>/dev/null || echo "(comments unreadable — the read failed)" > "$d/issues/$k.comments.md";;
  esac
  # the loader's answer on the body (intake.md §Experiment): the unit lens runs no python, so it reads this — the loader's one line, then its exit
  python3 -I islands/intake/scripts/experiment.py load "$d/issues/$k.md" > /dev/null 2> "$d/issues/$k.experiment.txt"; echo "exit $?" >> "$d/issues/$k.experiment.txt"
}
_lens_record() { # <kind> <unit index> <status> <output file|""> <runs> — the rail/model of an ADMITTED lens only
  local _r="" _m=""; [ "$5" -gt 0 ] && { _r="${rail:-}"; _m="${TS_MODEL:-}"; }
  jq --arg k "$1" --argjson u "$2" --arg s "$3" --arg o "$4" --argjson n "$5" --arg rail "$_r" --arg m "$_m" \
    '. + [{lens: $k, unit: $u, status: $s, output: $o, runs: $n, rail: $rail, model: $m}]' /tmp/lenses.json > /tmp/lenses.next \
    && mv /tmp/lenses.next /tmp/lenses.json
}
_findings() { # <kind> <output file> <run key> → its finding rows (ids U… / R…/…) appended to /tmp/findings.json, keyed <run key>:<id>
                 # (every unit lens numbers from U1: the run key keeps two units' U1 apart, in the receipt and in the repair's answers)
  awk -v k="$1" -F'|' '
    /^\|/ { id=$2; gsub(/^[ `]+|[ `]+$/, "", id)
            if ((k == "unit" && id ~ /^U[0-9]+$/) || (k == "rows" && id ~ /^R[0-9]+\//)) {
              p="advisory"; f=""
              for (i = 3; i <= NF; i++) { c=$i; gsub(/^ +| +$/, "", c)
                if (c ~ /^(BLOCKING|blocking)/) { p="blocking"; f=$(i+1); break }
                if (c ~ /^(advisory|Advisory)/) { p="advisory"; f=$(i+1); break } }
              gsub(/^ +| +$/, "", f); print id "\t" p "\t" f } }' "$2" \
    | jq -R -s --arg k "$1" --arg rk "$3" --slurpfile have /tmp/findings.json '
        $have[0] + [ split("\n")[] | select(length > 0) | split("\t") | {id: ($rk + ":" + .[0]), lens: $k, posture: .[1], finding: .[2]} ] | unique_by(.id)' \
    > /tmp/findings.next 2>/dev/null && mv /tmp/findings.next /tmp/findings.json
}
SNIP=""; PIN_NOTE=""
_snippets_process() { # → SNIP = an extracted wheel of the release the island's specs/README.md pins, or PIN_NOTE says why not
  [ -n "$SNIP" ] && return 0; [ -n "$PIN_NOTE" ] && return 1
  local root pin have
  root="$(jq -r '.specs_root // ""' /tmp/sel.json)"
  pin="$( { [ -n "$root" ] && grep -oE 'RULES\.md @ v[0-9]+\.[0-9]+\.[0-9]+' "$root/README.md" 2>/dev/null | head -1 | sed 's/.*@ v//'; } || true)"
  have="$(sed -n 's#^SNIPPETS_WHEEL=.*/download/v\([0-9.]*\)/.*#\1#p' gateway/scripts/lib/snippets.sh)"
  if [ -n "${INTAKE_SNIPPETS_DIR:-}" ]; then SNIP="$INTAKE_SNIPPETS_DIR"; return 0; fi
  if [ -z "$pin" ]; then PIN_NOTE="no snippets pin in ${root:-<no specs root>}/README.md"; return 1; fi
  if [ "$pin" != "$have" ]; then PIN_NOTE="the island pins snippets v$pin; only v$have has a verified digest here (gateway/scripts/lib/snippets.sh)"; return 1; fi
  # shellcheck source=/dev/null
  if . gateway/scripts/lib/snippets.sh && _snippets_fetch && rm -rf /tmp/review/snippets \
     && python3 -m zipfile -e "${SNIPPETS_WHEEL_LOCAL#file://}" /tmp/review/snippets; then SNIP=/tmp/review/snippets; return 0; fi
  PIN_NOTE="the pinned snippets wheel v$pin could not be fetched/verified"; return 1
}
_mask() { # <body file> → stdout: its `## Spec changes` section, every description cell keyed (the pinned mask_page); rc 3 = nothing to mask (an `edit` body)
  python3 -c '
import re, sys
sys.path.insert(0, sys.argv[1])
from allure_behavior_snippets.evidence import mask_page
body = open(sys.argv[2], encoding="utf-8").read().split("\n")
start = next((i for i, l in enumerate(body) if re.match(r"##\s+Spec changes\b", l)), None)
if start is None:
    sys.exit(3)
end = next((i for i in range(start + 1, len(body)) if re.match(r"##\s+\S", body[i])), len(body))
masked, keys = mask_page("\n".join(body[start:end]))
if not keys:
    sys.exit(3)
print(masked)' "$SNIP" "$1"
}
_base_ready() { # <sha> → the island's clone ($WORK) holds it (a depth-1 clone has only the tip; fetch the author's base when it differs)
  git -C "$WORK" cat-file -e "$1^{commit}" 2>/dev/null && return 0
  # the clone's own config already carries the auth header (`git clone -c` persists it): a second -c doubles it (HTTP 400)
  git -C "$WORK" fetch -q --depth 1 origin "$1" 2>&1 | tail -2 | sed 's/^/island-intake: base fetch: /'
  git -C "$WORK" cat-file -e "$1^{commit}" 2>/dev/null
}

if [ "$REVIEW" = review-repair ] && [ "$NH" -gt 0 ]; then
  REVIEW_RAN=1
  for ui in $(seq 0 $((NU - 1))); do
    kind="$(jq -r ".[$ui].kind" /tmp/units.json)"; base="$(jq -r ".[$ui].base" /tmp/units.json)"
    mapfile -t keys < <(jq -r ".[$ui].issues[]" /tmp/units.json)
    head="${keys[0]}"; out="/tmp/review/out/$kind-$ui.md"; runs=0; st=""
    if [ "$LENS_N" -ge "$LENS_MAX" ]; then _lens_record "$kind" "$ui" "skipped: INTAKE_REVIEW_LENS_MAX=$LENS_MAX lens sessions this run" "" 0; continue; fi
    if ! _fits $(( 2 * (PASS1_TIMEOUT_S + LENS_TIMEOUT_S) )); then _lens_record "$kind" "$ui" "skipped: the run's deadline (RUN_DEADLINE_S=$RUN_DEADLINE_S) leaves no room" "" 0; continue; fi
    if ! _base_ready "$base"; then _lens_record "$kind" "$ui" "skipped: base $base not readable in the clone" "" 0; continue; fi
    case="/tmp/review/case-$kind-$ui"; rm -rf "$case"; mkdir -p "$case"; printf '%s\n' "$base" > "$case/BASE_SHA"
    if [ "$kind" = unit ]; then
      for k in "${keys[@]}"; do _case_issue "$k" "$case" comments; done
      { for k in "${keys[@]}"; do case "$k" in *[!0-9]*) ;; *)
          gh api "repos/$REPO_SLUG/issues/$k/dependencies/blocked_by" --jq ".[] | \"#\(.number) before #$k\"" 2>/dev/null || true;; esac; done
        cat /tmp/review/edges.md 2>/dev/null || true; } | sort -u > "$case/edges.md"
      [ -s "$case/edges.md" ] || echo "(no edges)" > "$case/edges.md"
      LENS_N=$((LENS_N + 1))
      if ! _admit "-lens-unit-$ui"; then _lens_record unit "$ui" "deferred: $ADMIT_WHY" "" 0; continue; fi
      while [ "$runs" -lt 2 ]; do
        runs=$((runs + 1)); rm -f "$out"
        _lens_run "$case" islands/intake/rules/intake-review-unit.md "Unit review (islands/intake/rules/intake-review-unit.md, your system prompt) of the unit ${REPO_SLUG}#${keys[*]} at base ${base}, island \`$ISLAND\`. Use the frozen case directory $case (issues/<n>.md, issues/<n>.comments.md, issues/<n>.experiment.txt, edges.md, BASE_SHA) in place of the gh reads; the repository at the base is the clone at $WORK, read ONLY as \`git -C $WORK show ${base}:<path>\` / \`git -C $WORK grep -n <pattern> ${base} -- <path>\`. Write your ONE file to the absolute path $out. Your wall clock is ${LENS_TIMEOUT_S} s: write the file well before it with what you can support — an unwritten file is a failed run." \
          "$LENS_TIMEOUT_S" "unit-$ui" "Read(/${case}/**)" "Glob" "Bash(git -C $WORK show:*)" "Bash(git -C $WORK grep:*)" "Edit(/${out})" || true
        [ -s "$out" ] && break
      done
      if [ -s "$out" ]; then st="ran"; _findings unit "$out" "unit#$ui"; else st="skipped: failed twice (no findings file)"; fi
      _lens_record unit "$ui" "$st" "$out" "$runs"; gw_release
    else
      if ! _snippets_process; then _lens_record rows "$ui" "skipped: $PIN_NOTE" "" 0; continue; fi
      mkdir -p "$case/masked"; cp -r "$SNIP/allure_behavior_snippets/process" "$case/process"
      for k in "${keys[@]}"; do _case_issue "$k" "$case"; done
      # a Goal child's rows read the Goal's body too: the unit line that names this issue carries its head
      gk="$(jq -r --arg k "$head" '[.[] | select(.kind == "unit" and (.issues | index($k)) and .issues[0] != $k) | .issues[0]] | first // empty' /tmp/units.json)"
      [ -n "$gk" ] && _case_issue "$gk" "$case"
      if ! _mask "$case/issues/$head.md" > "$case/masked/$head.md" 2>/dev/null; then
        _lens_record rows "$ui" "skipped: #$head carries no description-keyed spec table (nothing to mask)" "" 0; continue
      fi
      p1="/tmp/review/rows-pass1-$ui"; rm -rf "$p1"; mkdir -p "$p1"; cp -r "$case/masked" "$case/process" "$p1/"
      LENS_N=$((LENS_N + 1))
      if ! _admit "-lens-rows-$ui"; then _lens_record rows "$ui" "deferred: $ADMIT_WHY" "" 0; continue; fi
      while [ "$runs" -lt 2 ]; do
        runs=$((runs + 1)); rm -f "$out"
        # pass 1: the masked surface only — its own Read scope, the full case out of reach
        _lens_run "$p1" islands/intake/rules/intake-review-rows.md "Rows review (islands/intake/rules/intake-review-rows.md, your system prompt) of ${REPO_SLUG}#${head}, island \`$ISLAND\` — PASS 1 of a staged read. Your cwd holds ONLY process/ and masked/${head}.md: do the brief's order steps 1 (process/ only) and 2. Write the file $out (that absolute path) now with the output's first line and its '## Pass 1 (frozen)' section (one line per finding, or '- none'), nothing else; pass 2 continues the same file." \
          "$PASS1_TIMEOUT_S" "rows-$ui-p1" "Read(/${p1}/**)" "Glob" "Edit(/${out})" || true
        if [ -n "$(_pass1_lines "$out")" ]; then
          cp "$out" "/tmp/review/out/rows-$ui.pass1.md"
          _lens_run "$case" islands/intake/rules/intake-review-rows.md "Rows review (islands/intake/rules/intake-review-rows.md, your system prompt) of ${REPO_SLUG}#${head} at base ${base}, island \`$ISLAND\` — PASS 2 of a staged read. $out already holds your FROZEN '## Pass 1 (frozen)': keep it verbatim and complete the file (order step 3, '## Findings', '## Cannot run pre-queue'). Use the frozen case directory $case (process/, masked/, issues/<n>.md — a Goal child's Goal body beside it —, BASE_SHA) in place of the gh reads; the repository at the base is the clone at $WORK, read ONLY as \`git -C $WORK show ${base}:<path>\` / \`git -C $WORK grep -n <pattern> ${base} -- <path>\`. Your wall clock is ${LENS_TIMEOUT_S} s: complete the file well before it." \
            "$LENS_TIMEOUT_S" "rows-$ui" "Read(/${case}/**)" "Read(/${out})" "Glob" "Bash(git -C $WORK show:*)" "Bash(git -C $WORK grep:*)" "Edit(/${out})" || true
          # the frozen pass 1 survives pass 2 whatever pass 2 did to the file
          [ -n "$(_pass1_lines "$out")" ] || cp "/tmp/review/out/rows-$ui.pass1.md" "$out"
        fi
        [ -s "$out" ] && [ -n "$(_pass1_lines "$out")" ] && break
      done
      if [ -s "$out" ] && [ -n "$(_pass1_lines "$out")" ]; then st="ran"; _findings rows "$out" "rows#$ui"; else st="skipped: failed twice (no file, or an empty Pass 1)"; rm -f "$out"; fi
      _lens_record rows "$ui" "$st" "$out" "$runs"; gw_release
    fi
  done

  # 4c. ONE repair pass (an author session): every finding answered by id, then post, label, rule
  if [ ! -s islands/intake/rules/intake.md ]; then P_STATUS="skipped: islands/intake/rules/intake.md missing"
  elif ! _fits 0; then P_STATUS="skipped: the run's deadline leaves no room for the repair"
  elif ! _admit "-repair"; then P_STATUS="deferred: $ADMIT_WHY"
  else
    P_RAIL="$rail"; P_MODEL="$TS_MODEL"
    {
    cat <<REPAIR
You are the REPAIR PASS of the ISLAND INTAKE sitting for the \`$ISLAND\` island (mode: $MODE), running
unattended in-cluster; cwd = $WORK, a fresh clone of $REPO_SLUG. Follow ${HL}islands/intake/rules/intake.md §Review and repair,
steps 3 and 4, exactly (and §A queue-ready body for any edit). Below: the first pass's report, then every
lens's findings file; the bodies under review are also at /tmp/review/issues/<n>.md (GitHub's copy wins in apply). Answer EVERY finding by its id, once (\`changed: …\` / \`declined: …\`), then on each
issue of each unit: the ONE \`intake: review — …\` comment, then the labels (the INTAKE-HOLD lines of the
first pass name them), then the ruling comment LAST. A lens that did not run adds its skipped line under the
review comment's first line. In dry-run write nothing to GitHub: print every comment, label and edit you
WOULD make. No lens re-runs. At the end, outside any code fence, one line per finding:
  INTAKE-REPAIR: <keyed finding id> changed|declined <one-line reason>
The KEYED id is \`<lens>#<unit line>:<the lens's id>\` (every unit lens numbers from U1): use it in
the INTAKE-REPAIR lines; the comment may show the lens's own id.

LENS RUNS (status per unit line):
$(jq -r '.[] | "- \(.lens)#\(.unit): \(.status) (its findings file: \(.lens)-\(.unit).md)"' /tmp/lenses.json)

FINDINGS (keyed id · posture · finding):
$(jq -r '.[] | "- \(.id) · \(.posture) · \(.finding)"' /tmp/findings.json)

=== FIRST PASS REPORT ===
REPAIR
    cat /tmp/intake.log
    for f in /tmp/review/out/unit-*.md /tmp/review/out/rows-[0-9]*.md; do
      case "$f" in *.pass1.md) continue;; esac
      [ -s "$f" ] && { printf '\n=== LENS FINDINGS FILE: %s ===\n' "$(basename "$f")"; cat "$f"; }
    done
    } > /tmp/review/repair-brief.md
    # on stdin: the first-pass report + every findings file can exceed one argv string (MAX_ARG_STRLEN, 128 KiB)
    ( cd "$WORK" && timeout "$REPAIR_TIMEOUT_S" env "${SESSION_UNSET[@]}" "${GW_LLM_ENV[@]}" claude -p --model "$TS_MODEL" \
        --permission-mode bypassPermissions --max-turns 80 < /tmp/review/repair-brief.md > /tmp/review/repair.log 2>&1 ) \
      && P_STATUS="ran" || P_STATUS="failed: the repair session ended rc≠0 (its lines are still read)"
    gw_release
  fi
elif [ "$REVIEW" = review-repair ]; then
  P_STATUS="skipped: nothing held for labels"
fi
# the repair's answers, joined onto the findings: changed | declined | unanswered
if grep -oE '^ *INTAKE-REPAIR: [^ ]+ (changed|declined)( .*)?$' /tmp/review/repair.log 2>/dev/null | sed 's/^ *INTAKE-REPAIR: //' \
  | jq -R -s --slurpfile f /tmp/findings.json '
      ([ split("\n")[] | select(length > 0) | capture("^(?<id>[^ ]+) (?<fate>changed|declined) ?(?<reason>.*)$") ]
       | map({(.id): .}) | add // {}) as $a
      | [ $f[0][] | . + {fate: ($a[.id].fate // "unanswered"), reason: ($a[.id].reason // "")} ]' > /tmp/findings.next 2>/dev/null; then
  mv /tmp/findings.next /tmp/findings.json
else   # no repair line at all (no repair, or it printed none): every finding is unanswered
  jq '[.[] | . + {fate: "unanswered", reason: ""}]' /tmp/findings.json > /tmp/findings.next && mv /tmp/findings.next /tmp/findings.json
fi

# ── 5. THE BELT: every held issue ends labelled (apply). After a repair that ran, only the labels it
# missed; when the repair did not run, the whole step 4 here — review comment, labels, ruling LAST. ──
_belt_review_comment() { # → stdout: §Review and repair step 4's comment, for a repair that did not run
  jq -r --arg ps "$P_STATUS" --slurpfile l /tmp/lenses.json '
      "intake: review — \(length) findings: 0 changed, 0 declined",
      ($l[0][] | select(.status | startswith("ran") | not) | "\(.lens) review skipped — \(.status)"),
      "the repair pass did not finish (\($ps)) — every finding below is unanswered",
      (.[] | "\(.id) — \(.finding) — unanswered")' /tmp/findings.json
}
NL=0
# shellcheck source=/dev/null
. agents/machine-comment.sh   # gh_label_add — the ONE REST label write (FU-290); sourcing defines functions only
while IFS=$'\t' read -r ref key add outcome; do
  [ -n "$ref" ] || continue
  if [ "$MODE" != apply ]; then echo "island-intake (dry-run): $ref would carry +$add (the repair pass prints the comments)"; continue; fi
  case "$key" in *[!0-9]*) echo "island-intake: $ref is not an issue number — not labelled"; continue;; esac
  # what THIS run already put on the issue (a repair that posted, then died, must not get a second copy)
  st="$(gh issue view "$key" --repo "$REPO_SLUG" --json labels,comments | jq -c --arg t "$RUN_START" \
        '{labels: [.labels[].name], review: any(.comments[]; .createdAt >= $t and (.body | startswith("intake: review"))),
          ruling: any(.comments[]; .createdAt >= $t and (.body | startswith("intake:")) and ((.body | startswith("intake: review")) | not))}' 2>/dev/null)" \
    || { echo "⚠ island-intake: cannot read $ref back — not touched by the belt"; continue; }
  # labelled = queued AND every held label is on it (a repair that queued but left `experiment/open` off is finished here)
  if printf '%s' "$st" | jq -e --arg add "$add" '.labels as $l | ($l | index("agent/queued")) and (($add | split(",")) - $l == [])' >/dev/null; then NL=$((NL + 1)); continue; fi
  if [ "$REVIEW" = review-repair ] && ! printf '%s' "$st" | jq -e '.review' >/dev/null; then
    _belt_review_comment > "/tmp/review/belt-$key.md"
    gh issue comment "$key" --repo "$REPO_SLUG" --body-file "/tmp/review/belt-$key.md" >/dev/null || echo "⚠ island-intake: the review comment on $ref FAILED"
  fi
  IFS=, read -ra _ls <<< "$add"
  if gh_label_add "$REPO_SLUG" "$key" "${_ls[@]}"; then
    NL=$((NL + 1)); echo "island-intake: belt labelled $ref (+$add; repair: $P_STATUS)"
  else echo "⚠ island-intake: labelling $ref FAILED — it is not queued"; fi
  if [ "$REVIEW" = review-repair ] && ! printf '%s' "$st" | jq -e '.ruling' >/dev/null; then
    printf 'intake: %s — queued as authored; the review'"'"'s repair pass did not finish (%s)\n' "$outcome" "$P_STATUS" > "/tmp/review/rule-$key.md"
    gh issue comment "$key" --repo "$REPO_SLUG" --body-file "/tmp/review/rule-$key.md" >/dev/null || echo "⚠ island-intake: the ruling comment on $ref FAILED"
  fi
done < <(jq -r '.[] | [.ref, .key, (.add | join(",")), .outcome] | @tsv' /tmp/holds.json)
# a queue/goal ruling none of whose refs is held: nothing labels it (review-repair only)
UNHELD="$(jq -c --slurpfile h /tmp/holds.json '[ .[] | select(.outcome | IN("queue","goal"))
    | select(([.input] + .refs) as $r | [$h[0][].ref] | any(. as $x | $r | index($x)) | not) | .input ]' /tmp/ruled-q.json 2>/dev/null)" || UNHELD='[]'
[ -n "$UNHELD" ] || UNHELD='[]'
[ "$REVIEW" = review-repair ] && [ "$UNHELD" != "[]" ] && echo "⚠ island-intake: queue/goal ruling(s) with no INTAKE-HOLD line — the launcher cannot label them: $UNHELD"
# the report's `## Escape records` section, verbatim (the receipt carries it beside the parsed lines)
awk '/^## Escape records/{on=1} on && /^## / && !/^## Escape records/{exit} on' /tmp/intake.log > /tmp/escape-records.md 2>/dev/null || :
awk '/^## Wait records/{on=1} on && /^## / && !/^## Wait (records|proposals)/{exit} on' /tmp/intake.log > /tmp/wait-records.md 2>/dev/null || :

# ── 6. RECEIPT ────────────────────────────────────────────────────────────────────────────────
jq -n --arg island "$ISLAND" --arg mode "$MODE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg model "$A_MODEL" --arg rail "$A_RAIL" --arg run "intake-${ISLAND_KEY}-${DAY}/intake-r1-${TS_RUN}" \
      --arg repo "$REPO_SLUG" --arg kind "$ISLAND_KIND" --arg facts "$FACTS" \
      --arg review "$REVIEW" --arg ps "$P_STATUS" --arg pr "$P_RAIL" --arg pm "$P_MODEL" \
      --argjson labelled "$NL" --argjson unheld "$UNHELD" --rawfile escmd /tmp/escape-records.md \
      --rawfile waitmd /tmp/wait-records.md --slurpfile waits /tmp/waits.json --slurpfile wl /tmp/wait-ledger.json \
      --slurpfile wdrop /tmp/waits-dropped.json \
      --slurpfile sel /tmp/sel.json --slurpfile ruled /tmp/ruled.json --slurpfile filed /tmp/ruled-filed.json --slurpfile holds /tmp/holds.json \
      --slurpfile units /tmp/units.json --slurpfile lenses /tmp/lenses.json \
      --slurpfile findings /tmp/findings.json --slurpfile escapes /tmp/escapes.json \
      '{schema: "island-intake-receipt/v1", island: $island, island_kind: $kind, repo: $repo, facts: $facts, mode: $mode, ts: $ts, run: $run,
        session_ran: true, model: $model, rail: $rail,
        inputs: ($sel[0].inputs | map(.id)), counts: $sel[0].counts, ruled: $ruled[0], ruled_filed: $filed[0],
        review: {mode: $review, held: [$holds[0][].ref], units: $units[0], labelled: $labelled, unheld: $unheld,
                 lenses: [$lenses[0][] | del(.output)],
                 ran: ([$lenses[0][] | select(.status == "ran")] | length > 0),
                 repair: {status: $ps, rail: $pr, model: $pm}},
        findings: [$findings[0][] | {id, lens, posture, finding, fate, reason}],
        escapes: $escapes[0], escape_records: $escmd,
        waits: $waits[0], wait_records: $waitmd, wait_lines_dropped: $wdrop[0],
        wait_ledger: ($wl[0] | {bar, records, classes, false_waits, other_writers, at_bar, invalid, unparseable}),
        wait_proposals: ($wl[0].proposals // []), wait_proposals_dropped: ($wl[0].dropped // [])}' > /tmp/receipt.json
echo "island-intake: $NR of $NIN input(s) ruled ($NQ queued) — review: $(jq -r '[.review.lenses[] | "\(.lens)#\(.unit) \(.status)"] | join(" · ") | if . == "" then "no lens" else . end' /tmp/receipt.json) · repair $P_STATUS — receipt:"
jq -c '.ruled[]' /tmp/receipt.json; jq -c '.findings[]' /tmp/receipt.json
_ts_put /tmp/receipt.json receipt.json \
  || echo "⚠ island-intake: the RECEIPT did not upload — tomorrow's sitting re-reads these inputs (its own step 2 finds what this one filed)"
jq -n --arg role coordinator --arg lane intake --arg project homelab --arg task "intake-${ISLAND_KEY}-$DAY" \
      --arg model "$A_MODEL" --arg rail "$A_RAIL" --arg pod "${HOSTNAME:-}" --arg ts "$TS_RUN" \
      '{role:$role, lane:$lane, project:$project, task:$task, round:1, model:$model, rail:$rail,
        session_key:"coordinator-claude", pod:$pod, timestamp:$ts,
        files:["inputs.json","brief.md","intake.log","receipt.json","review-<lens>-<unit>.md","review-repair.log","wait-ledger.json"],
        grafana_query:("{pod=\""+$pod+"\"}")}' > /tmp/ts-manifest.json
_ts_put /tmp/intake.log intake.log || true
for f in /tmp/review/out/*.md; do [ -f "$f" ] && { _ts_put "$f" "review-$(basename "$f")" || true; }; done
_ts_put /tmp/review/repair.log review-repair.log || true
_ts_put /tmp/wait-ledger.json wait-ledger.json || true
_ts_put /tmp/ts-manifest.json manifest.json || true
{ find "$HOME/.claude/projects" /tmp/review -name '*.jsonl' -newer /tmp/ts-mark 2>/dev/null || true; } | while read -r f; do _ts_put "$f" "$(basename "$f")" || true; done

# ── 7. RING once, so queued work dispatches now rather than on the scan's cron ──────
if [ "$MODE" = apply ] && [ "$NQ" -gt 0 ] && [ "$ISLAND_KIND" = stack ]; then
  # the queued issues are in the stack's repo: its own loop's scan finds them on its cron. The bell's
  # payload names a stack's loop namespace, which no claim field this script reads carries.
  echo "island-intake: $NQ queued in $REPO_SLUG — no /coordinate ring for a stack island (its loop's scan dispatches)"
elif [ "$MODE" = apply ] && [ "$NQ" -gt 0 ]; then
  curl -m 5 -fsS -X POST -H "Content-Type: application/json" \
    -d '{"stack":"platform","loop_ns":"platform-agents","unit":"-"}' \
    http://agent-loop-eventsource-svc.agent-coordinator.svc.cluster.local:12000/coordinate >/dev/null 2>&1 \
    && echo "island-intake: rang /coordinate for platform" \
    || echo "island-intake: coordinate bell failed (non-fatal — the scan's cron catches it)"
fi
_push 1 "$NIN" 1 "$NR" "$NQ"
exit 0
