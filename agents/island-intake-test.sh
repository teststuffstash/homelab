#!/usr/bin/env bash
# island-intake-test — behavioural harness for the WIRED island intake (FU-320): the selector's
# `--source dig` and `--source pile` modes (gateway/scripts/intake-select.sh) and the CronWorkflow
# that runs them (agents/coordinator/island-intake-argo.yaml), plus the island table every selector
# mode reads (island_members / island_alert_rules / island_pattern — one island per item).
# agents/island-intake-fixtures/ holds REAL dig findings (full wire, bucket-shaped).
#
#   bash agents/island-intake-test.sh        (run by `devbox run deep-dig-test` — the dig's gate,
#                                              because intake is the dig's consumer)
#
# Hermetic: the selector reads a bucket-shaped directory (INTAKE_TS_DIR), the workflow's own script
# is extracted from the manifest and run with PATH stubs for claude / s5cmd / git / curl, the clock
# pinned. No network, no cluster.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEL="$REPO/gateway/scripts/intake-select.sh"
YAML="${YAML:-$REPO/agents/coordinator/island-intake-argo.yaml}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
command -v jq >/dev/null 2>&1 || { echo "island-intake-test: needs jq (devbox run -- bash $0)"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "island-intake-test: needs yq (devbox run -- bash $0)"; exit 2; }

PASS=0; FAIL=0; FAILED=()
# target states (the wait source, the pile's re-read ledger) come from a seam in EVERY row: a row that needs
# one sets its own file; this default answers nothing, so a lookup fails loud and never reaches gh
echo '{}' > "$TMP/refs-none.json"; export INTAKE_REFS_JSON="$TMP/refs-none.json"
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── the clock: 2026-10-27T05:00:00Z ─────────────────────────────────────────────────────────────
NOW=1793077200
TS="$TMP/ts"
finding() { # <day> <run> <n> <verdict> <recommendation> [alerts-json]
  mkdir -p "$TS/homelab/dig-$1/$2"
  jq -n --arg v "$4" --arg rec "$5" --argjson al "${6:-[\"GoCatalogParseFailed (alert:GoCatalogParseFailed)\"]}" --arg run "dig-$1/$2" \
    '{schema:"dig-finding/v1", group:"recurring|cluster", alerts:$al, verdict:$v, cause:"c", evidence:[],
      recommendation:$rec, pr:"", related:[], tool_gaps:[], ts:"x", run:$run, members:[]}' > "$TS/homelab/dig-$1/$2/finding-$3.json"
}
receipt() { # <day> <run> <mode> <ts> <ruled-json>
  mkdir -p "$TS/homelab/intake-gateway-$1/$2"
  jq -n --arg m "$3" --arg ts "$4" --argjson r "$5" \
    '{schema:"island-intake-receipt/v1", island:"gateway", mode:$m, ts:$ts, session_ran:true, inputs:[], ruled:$r}' \
    > "$TS/homelab/intake-gateway-$1/$2/receipt.json"
}
sel() { INTAKE_TS_DIR="$TS" INTAKE_NOW="$NOW" bash "$SEL" --source dig --island gateway --out "$TMP/sel.json" 2>"$TMP/sel.err"; }
ids() { jq -r '[.inputs[].id] | join(" ")' "$TMP/sel.json"; }

section "selector --source dig"
R1=dig-r1-20261025T033020Z; R2=dig-r1-20261026T033005Z
finding 2026-10-25 $R1 1 cause-found "make gateway/src/agent_gateway/catalog.py skip an unknown dialect"
finding 2026-10-25 $R1 2 cause-found "the docs leg of GW-CATALOG-GO"
finding 2026-10-25 $R1 3 cause-found "snore-recorder owner: delete the venv" '["SnoreVenvStale (alert:SnoreVenvStale)"]' # not the island's alert
finding 2026-10-26 $R2 1 explained   "fires by design after the canary — gateway/specs" # wrong verdict
finding 2026-10-26 $R2 2 cause-found "agent-gateway pod restarts on the parse"
finding 2026-10-10 dig-r1-20261010T033000Z 1 cause-found "gateway/ — too old for the lookback"
sel; rc=$?
[ "$rc" = 0 ] && ok "fires on unruled island findings (exit 0)" || bad "fire" "rc=$rc $(cat "$TMP/sel.err")"
[ "$(ids)" = "dig-2026-10-26/$R2/finding-2 dig-2026-10-25/$R1/finding-1 dig-2026-10-25/$R1/finding-2" ] \
  && ok "selects cause-found ∧ on one of the island's alerts ∧ inside the lookback" \
  || bad "membership" "got: $(ids)"
jq -e '.inputs[0] | has("recommendation") and has("evidence") and has("alerts")' "$TMP/sel.json" >/dev/null \
  && ok "each input carries the finding's text for the sitting" || bad "input shape" "$(jq -c '.inputs[0]' "$TMP/sel.json")"

receipt 2026-10-26 intake-r1-a dry-run 2026-10-26T05:00:00Z "[{\"input\":\"dig-2026-10-25/$R1/finding-1\",\"outcome\":\"queue\",\"refs\":[]}]"
sel; [ "$(jq '.counts.inputs' "$TMP/sel.json")" = 3 ] \
  && ok "a DRY-RUN receipt rules nothing" || bad "dry-run consumes" "$(jq -c .counts "$TMP/sel.json")"

receipt 2026-10-26 intake-r1-b apply 2026-10-26T05:10:00Z \
  "[{\"input\":\"dig-2026-10-25/$R1/finding-1\",\"outcome\":\"queue\",\"refs\":[\"teststuffstash/homelab#1\"]},
    {\"input\":\"dig-2026-10-25/$R1/finding-2\",\"outcome\":\"deferred\",\"refs\":[]}]"
sel
[ "$(ids)" = "dig-2026-10-26/$R2/finding-2 dig-2026-10-25/$R1/finding-2" ] \
  && ok "an APPLY receipt rules its inputs — except \`deferred\`, which re-presents" || bad "receipt key" "got: $(ids)"

receipt 2026-10-27 intake-r1-c apply 2026-10-27T05:00:00Z "[]"
receipt 2026-10-27 intake-r1-d apply 2026-10-27T05:30:00Z "[]"
sel; rc=$?
{ [ "$rc" = 1 ] && grep -q "daily cap" "$TMP/sel.err"; } \
  && ok "INTAKE_DAILY_MAX (2) apply sittings today → hold on the cap" || bad "daily cap" "rc=$rc $(cat "$TMP/sel.err")"
INTAKE_DAILY_MAX=3 INTAKE_TS_DIR="$TS" INTAKE_NOW="$NOW" bash "$SEL" --source dig --out "$TMP/sel.json" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "…and the cap is a knob (INTAKE_DAILY_MAX=3 fires)" || bad "cap knob" "rc=$rc"
rm -rf "$TS/homelab/intake-gateway-2026-10-27"

INTAKE_TS_DIR="$TMP/nowhere" INTAKE_NOW="$NOW" bash "$SEL" --source dig --out "$TMP/sel.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "an unreadable store is a probe failure (exit 2), never \"no inputs\"" || bad "rule #6" "rc=$rc"
( unset INTAKE_TS_DIR AGENT_TS_READER_ID; INTAKE_NOW="$NOW" bash "$SEL" --source dig --out "$TMP/sel.json" 2>/dev/null ); rc=$?
[ "$rc" = 2 ] && ok "no READER key → exit 2 (fail-closed: it could not see what was ruled)" || bad "reader key" "rc=$rc"
# The REAL S3 branch, through an s5cmd stub that answers the way Garage + s5cmd v2.3 do (observed
# in-cluster 2026-10-28): `ls <prefix>/*` rows are `<date> <time> <size> <key relative to prefix>`,
# and a prefix with NO objects is an ERROR + exit 1 — which killed the first live run under set -e.
S5BIN="$TMP/s5bin"; mkdir -p "$S5BIN"
cat > "$S5BIN/s5cmd" <<'EOF'
#!/bin/bash
[ "$1" = --endpoint-url ] && shift 2
url="$2"; rel="${url#s3://*/}"
case "$1" in
  ls) case "$rel" in
        homelab/) [ -d "$TS/homelab" ] || { echo "ERROR \"ls $url\": no object found" >&2; exit 1; }
                  echo "                                  DIR  dig-x/"; exit 0;;
        # a wildcard listing (the responder findings): keys relative to the prefix before the first `*`
        'homelab/alert-*/responder-*/finding.json')
               f="$(cd "$TS/homelab" 2>/dev/null && find . -path './alert-*/responder-*/finding.json' | sed 's#^\./##')"
               [ -n "$f" ] || { echo "ERROR \"ls $url\": no object found" >&2; exit 1; }
               printf '%s\n' "$f" | while read -r k; do echo "2026/11/18 00:31:51      456  $k"; done; exit 0;;
        *'/*') d="$TS/${rel%/\*}"
               [ -d "$d" ] || { echo "ERROR \"ls $url\": no object found" >&2; exit 1; }
               (cd "$d" && find . -type f | sed 's#^\./##' | while read -r f; do echo "2026/10/25 03:31:51      123  $f"; done); exit 0;;
      esac;;
  cat) cat "$TS/$rel" 2>/dev/null || { echo "ERROR cat" >&2; exit 1; }; exit 0;;
esac
exit 1
EOF
chmod +x "$S5BIN/s5cmd"
receipt 2026-10-27 intake-r1-s3 apply 2026-10-27T05:00:00Z "[{\"input\":\"dig-2026-10-26/$R2/finding-2\",\"outcome\":\"standing\",\"refs\":[]}]"
( unset INTAKE_TS_DIR; TS="$TS" PATH="$S5BIN:$PATH" AGENT_TS_READER_ID=r AGENT_TS_READER_SECRET=s INTAKE_NOW="$NOW" \
    bash "$SEL" --source dig --island gateway --out "$TMP/sel.json" 2>"$TMP/sel.err" ); rc=$?
{ [ "$rc" = 0 ] && [ "$(ids)" = "dig-2026-10-25/$R1/finding-2" ]; } \
  && ok "the S3 branch: Garage's row shape, missing prefixes tolerated, receipts read back" \
  || bad "S3 branch" "rc=$rc ids=$(ids 2>/dev/null) $(head -c 300 "$TMP/sel.err")"
rm -rf "$TS/homelab/intake-gateway-2026-10-27"
( unset INTAKE_TS_DIR; TS="$TMP/void" PATH="$S5BIN:$PATH" AGENT_TS_READER_ID=r AGENT_TS_READER_SECRET=s INTAKE_NOW="$NOW" \
    bash "$SEL" --source dig --out "$TMP/sel.json" 2>/dev/null ); rc=$?
[ "$rc" = 2 ] && ok "…and its positive control: an unlistable bucket is exit 2" || bad "S3 positive control" "rc=$rc"

INTAKE_TS_DIR="$TS" bash "$SEL" --source dig --island nosuch --out "$TMP/sel.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "an island with no pattern row is refused" || bad "island table" "rc=$rc"

# ── the island table: issue membership per island (INTAKE_ISSUES_JSON seam) ───────────────────
# Expected islands are derived from the selector's header contract: the FIRST ISLANDS row
# (gateway, router-pair, mgmt-box, dependency-upgrades, substrate, agent-loop) whose title regex
# matches or that owns EVERY Touches entry, each path going to its LONGEST matching prefix.
section "selector issues — the island table"
ISS="$TMP/issues.json"
iss() { # <n> <title> <touches|-> [labels-json] [first-comment-line] [author-json]
  local body="free text"
  [ "$3" != - ] && body="$(printf -- '---\nTouches: %s\n---\n\nfree text' "$3")"
  jq -nc --argjson n "$1" --arg t "$2" --arg b "$body" --argjson l "${4:-[]}" --arg c "${5:-}" \
    --argjson au "${6:-{\"login\":\"app/homelab-agents-1234\"\}}" \
    '{number:$n, title:$t, body:$b, labels:($l|map({name:.})), createdAt:"2026-10-20T00:00:00Z",
      author:$au, comments:(if $c == "" then [] else [{body:$c}] end)}' >> "$ISS.rows"
}
rm -f "$ISS.rows"
iss 1  "gateway: a title row"                 -                                             # gateway title
iss 2  "catalog drift on GW-CATALOG-GO"       -                                             # gateway GW- id
iss 3  "no title cue"                         "gateway/specs/a.md, gateway/tests/b.py"      # gateway Touches
iss 4  "scan: title says agent-loop"          "gateway/src/x.py"                            # gateway row is FIRST
iss 5  "no title cue"                         "gateway/a.md, agents/b.sh"                   # spans two → none
iss 6  "scan: a guard"                        -                                             # agent-loop title
iss 7  "no title cue"                         "agents/coordinator-scan.sh, docs/agents/x.md" # agent-loop Touches
iss 8  "no title cue"                         "tofu/opnsense-router.tf"                     # longest prefix beats tofu/
iss 9  "no title cue"                         "tofu/garage.tf, machines/machines.yaml"      # substrate Touches
iss 10 "opnsense: carp skew"                  -                                             # router-pair title
iss 11 "no title cue"                         "mgmt/scripts/mgmt-lease.sh"                  # mgmt-box Touches
iss 12 "renovate: a lane"                     -                                             # dependency-upgrades title
iss 13 "S9 original 2: lanes by class"        -                                             # dependency-upgrades title
iss 14 "garage-write-probe: cleanup"          "argocd/resources/garage-write-probe/"        # substrate title + Touches
iss 15 "no title cue"                         ".github/workflows/ci.yaml"                   # nobody's path → none
iss 16 "no title cue"                         "tofu/opnsense-router.tf, tofu/garage.tf"     # two islands → none
iss 17 "scan: labelled"                       - '["agent/queued"]'                          # lifecycle label → out
iss 18 "scan: ruled"                          - '[]' "intake: standing — not now"           # standing ruling → out
iss 19 "post-launch: scan bucket"             -                                             # container → out
iss 20 "garage: title wins over Touches"      "agents/x.sh"                                 # substrate row precedes agent-loop
iss 21 "mgmt: lease belt"                     "tofu/garage.tf"                              # mgmt-box row precedes substrate
# Attribution inputs (homelab#3094): claimed by no island ∧ bot-filed ∧ unlabelled ∧ unruled ∧ not a Goal/container
# → agent-loop's sitting, kind=attribution; by the header contract #5 #15 #16 (bot-filed, nobody's) join them.
HUMAN='{"login":"rsoot","is_bot":false}'
iss 22 "worker OOMKilled at 4Gi on the opencode 1M-context cell" - '["agent-fix"]' "" '{"login":"app/homelab-agents-1234","is_bot":true}'  # #3094 itself
iss 23 "no title cue, human-filed"            -                         '[]' "" "$HUMAN"     # human + nobody's → none
iss 24 "no title cue, human, mixed"           "gateway/a.md, agents/b.sh" '[]' "" "$HUMAN"   # human + spans two → none
iss 25 "no title cue, a [bot] login"          -                         '[]' "" '{"login":"homelab-agents-1234[bot]"}' # REST spelling
iss 26 "no title cue, bot, queued"            -                         '["agent/queued"]'   # lifecycle label → out
iss 27 "no title cue, bot, ruled"             -                         '[]' "intake: standing — not now" # ruled → out
iss 28 "no title cue, bot Goal"               -                         '["task/goal"]'      # a Goal → out
iss 29 "stint: bot container"                 -                                              # container → out
iss 30 "gateway: human-filed member"          -                         '[]' "" "$HUMAN"     # claimed: author is irrelevant
jq -s . "$ISS.rows" > "$ISS"
# members = the island TABLE's selection (kind member); attrs = the attribution inputs (kind attribution)
members() { INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island "$1" --json 2>/dev/null | jq -r '[.[] | select(.kind == "member") | .number] | sort | join(" ")'; }
attrs()   { INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island "$1" --json 2>/dev/null | jq -r '[.[] | select(.kind == "attribution") | .number] | sort | join(" ")'; }
for row in "gateway:1 2 3 4 30" "router-pair:8 10" "mgmt-box:11 21" "dependency-upgrades:12 13" "substrate:9 14 20" "agent-loop:6 7"; do
  isl="${row%%:*}"; want="${row#*:}"; got="$(members "$isl")"
  [ "$got" = "$want" ] && ok "--island $isl selects $want" || bad "members $isl" "want '$want' got '$got'"
done
all="$(for i in gateway router-pair mgmt-box dependency-upgrades substrate agent-loop; do members "$i"; echo; done | tr ' ' '\n' | grep -c .)"
[ "$all" = 16 ] && ok "no issue lands on two islands; #5 #15 #16 (mixed / unowned) and #17–#19 land on none" \
  || bad "exclusivity" "16 memberships expected, got $all"
got="$(attrs agent-loop)"
[ "$got" = "5 15 16 22 25" ] && ok "--island agent-loop takes the bot-filed unclaimed (#3094's shape, app/ and [bot] logins) as attribution inputs" \
  || bad "attribution agent-loop" "want '5 15 16 22 25' got '$got'"
other="$(for i in gateway router-pair mgmt-box dependency-upgrades substrate; do attrs "$i"; done | tr -d '\n')"
[ -z "$other" ] && ok "no other island receives an attribution input" || bad "attribution elsewhere" "got '$other'"
allsel="$(for i in gateway router-pair mgmt-box dependency-upgrades substrate agent-loop; do
  INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island "$i" --json 2>/dev/null | jq -r '.[].number'; done | sort -n | tr '\n' ' ')"
case " $allsel" in *" 23 "*|*" 24 "*|*" 26 "*|*" 27 "*|*" 28 "*|*" 29 "*) bad "attribution filters" "selected: $allsel";;
  *) ok "human-filed unclaimed (#23 #24) stay none; a labelled / ruled / Goal / container bot filing (#26–#29) is never an attribution input";; esac
line="$(INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island agent-loop 2>/dev/null | awk -F'\t' '$1 == 22')"
[ "$(printf '%s' "$line" | awk -F'\t' '{print $5}')" = attribution ] && ok "line output marks an attribution input (fifth column)" \
  || bad "attribution line" "got: $line"
line="$(INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island agent-loop 2>/dev/null | awk -F'\t' '$1 == 6')"
[ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" = 4 ] && ok "a member's line keeps the four columns" || bad "member line" "got: $line"
INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island nosuch 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "issues mode: an island with no membership row is refused (exit 2)" || bad "issues island table" "rc=$rc"
INTAKE_ISSUES_JSON="$TMP/nowhere.json" bash "$SEL" --island substrate 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "issues mode: an unreadable issue list is a probe failure (exit 2)" || bad "issues rule #6" "rc=$rc"

section "selector --source dig — island precedence"
TS2="$TMP/ts2"; mkdir -p "$TS2/homelab/dig-2026-10-26/r"
# Owner per the selector's header contract: (1) the first ISLANDS row whose alert-rule file defines one
# of the finding's alerts; (2) only when no row's rules do — a row WITH alert rules (the gateway) claims
# by an evidence/related path under its Touches prefixes at a path boundary, a row without by its text.
f2() { # <n> <alerts-json> <recommendation> [evidence-json]
  jq -n --argjson al "$2" --arg rec "$3" --argjson ev "${4:-[]}" '{schema:"dig-finding/v1", verdict:"cause-found", cause:"c",
    evidence:$ev, recommendation:$rec, pr:"", related:[], alerts:$al, members:[]}' > "$TS2/homelab/dig-2026-10-26/r/finding-$1.json"
}
f2 1 '[]' "MgmtOpnsenseDrillScoreRegressed: the drill's realism score fell"      # text: router-pair precedes mgmt-box
f2 2 '["GoCatalogStale (alert:GoCatalogStale)"]' "agents/agent-session.sh retries"  # the gateway's ALERT beats agent-loop's text
f2 3 '[]' "MgmtLeaseExpiredUnreverted: mgmt-lease left the pin"                   # text: mgmt-box
f2 4 '[]' "Longhorn volume degraded on wk-02"                                    # text: substrate
# the 2026-11-11 leak shape: prose names the gateway, a path merely CONTAINS "gateway/" — never the gateway's
f2 5 '["AgentRunPhaseSlow (alert:AgentRunPhaseSlow)"]' "the agent-gateway seat decides; see gateway/ and GW-SESSIONS-ADMIT" \
     '["argocd/resources/pushgateway/prometheusrule.yaml:288 (read) → for 30m", "agents/agent-session.sh:3266 (read) → the 600s wait"]'
# no row's rules define the alert, the EVIDENCE cites a path under gateway/ → the gateway's
f2 6 '["GithubWorkflowRunFailed (workflow:homelab/CI)"]' "fix the test" '["gateway/tests/test_catalog.py:12 (read) → the fixture is stale"]'
# argocd/resources/agent-gateway/ is deliberately nobody's Touches prefix, and no text row matches → nobody's
f2 7 '["GithubWorkflowRunFailed (workflow:homelab/CI)"]' "re-cut the snapshot" '["Repo: argocd/resources/agent-gateway/benchmarks.json → snapshot_at is old"]'
digsel() { INTAKE_TS_DIR="$TS2" INTAKE_NOW="$NOW" bash "$SEL" --source dig --island "$1" --out "$TMP/sel2.json" 2>/dev/null
           jq -r '[.inputs[].id | sub(".*finding-"; "")] | sort | join(" ")' "$TMP/sel2.json"; }
for row in "gateway:2 6" "router-pair:1" "mgmt-box:3" "substrate:4" "agent-loop:5" "dependency-upgrades:"; do
  isl="${row%%:*}"; want="${row#*:}"; got="$(digsel "$isl")"
  [ "$got" = "$want" ] && ok "dig --island $isl takes '${want:-nothing}' (an earlier row's finding is never re-ruled)" \
    || bad "dig precedence $isl" "want '$want' got '$got'"
done

# ── real findings (agents/island-intake-fixtures — the bucket's own objects, full wire) ─────────
# 2026-11-11: the text match put homelab#3162 (dig-2026-11-03 finding-1, AgentRunPhaseSlow — kata node
# memory) and homelab#3166 (dig-2026-11-04 finding-1, RetroReportOverdue) into the GATEWAY sitting: both
# cite argocd/resources/pushgateway/prometheusrule.yaml, which contains "gateway/". Neither alert is
# defined in the gateway's rule file and neither finding cites a gateway/ path, so by the header
# contract they are not the gateway's; the three on GoCatalogParseFailed / GoCatalogStale /
# TierEvidenceStale (all defined in argocd/resources/agent-gateway/prometheusrule.yaml) are.
section "selector --source dig — real findings"
FX="$REPO/agents/island-intake-fixtures"; FXNOW=1794286800   # 2026-11-10T05:00:00Z; lookback 14 d reaches 10-29
realsel() { INTAKE_TS_DIR="$FX" INTAKE_NOW="$FXNOW" INTAKE_DIG_LOOKBACK_D=14 bash "$SEL" --source dig --island "$1" --out "$TMP/sel3.json" 2>/dev/null
            jq -r '[.inputs[].id | sub("/dig-r1-[^/]*"; "")] | sort | join(" ")' "$TMP/sel3.json"; }
[ "$(find "$FX" -name 'finding-*.json' | wc -l)" = 5 ] && ok "five real findings on disk (a missing fixture is not a pass)" || bad "fixtures" "expected 5 under $FX"
got="$(realsel gateway)"
[ "$got" = "dig-2026-10-29/finding-4 dig-2026-11-08/finding-1 dig-2026-11-09/finding-2" ] \
  && ok "gateway takes the Go-catalog and tier-evidence findings (its own alerts)" || bad "real true positives" "got: $got"
case " $got " in *"dig-2026-11-03/finding-1"*|*"dig-2026-11-04/finding-1"*) bad "real leaks" "got: $got";;
  *) ok "…and neither leak: the kata-memory and retro-report findings are not the gateway's";; esac
got="$(realsel agent-loop)"
[ "$got" = "dig-2026-11-03/finding-1 dig-2026-11-04/finding-1" ] \
  && ok "…they stay selectable — by the loop's own island (text fallback), once" || bad "real leaks' owner" "got: $got"

# ── --source dig: recurring report-only RESPONDER findings (FU-320) ─────────────────────────────
# agents/island-intake-fixtures/homelab/alert-*/ holds the responder's REAL finding.json objects of
# 2026-11-12..17 (full wire); ride-issues.json the `gh issue view --json number,title,body` answers
# for the issues their ride subjects served (#3302 #3303 #3307 #3308 #3420 — all titled `gateway: …`).
# Expected values from the selector header's responder contract: finding = responder-finding/v1 ∧
# issue "" ∧ remediation_would non-empty ∧ run date inside the lookback; owner = the alert-rule island,
# else the island of the ride subject's issue (island_of_issue: title `gateway:` → gateway); class =
# alertname + namespace with ≥ INTAKE_RESPONDER_MIN (3) of the island's findings; id
# responder/<alertname>/<namespace>; ruled = the dig's receipt ledger. Of the nine real records:
#   six KubePodNotReady on workload:homelab/agent-homelab-issue-<gateway issue>-r<k>, each with a
#     remediation_would (the scratch-quota class: 1414…, 3c86…, 4123…×2, 7a7e…, cc93…) → ONE gateway input;
#   529d… KubePodNotReady on arc-runners with a remediation_would — a ONE-OFF in its class → nothing;
#   5647… (arc-runners) and a564… (AgentReviewLoop, repo:homelab) carry an EMPTY remediation_would → never.
section "selector --source dig — recurring responder findings"
RNOW=1795064400   # 2026-11-19T05:00:00Z; lookback 7 d reaches 2026-11-12, every real record
RISS="$FX/ride-issues.json"
[ "$(find "$FX/homelab" -path '*/alert-*/responder-*/finding.json' | wc -l)" = 9 ] \
  && ok "nine real responder findings on disk (a missing fixture is not a pass)" || bad "responder fixtures" "expected 9 under $FX/homelab/alert-*"
rsel() { # <ts-dir> <island> [env…] → $TMP/rsel.json, rc in $rc
  local d="$1" i="$2"; shift 2
  env INTAKE_TS_DIR="$d" INTAKE_ISSUES_JSON="${RISS_OVR:-$RISS}" INTAKE_NOW="$RNOW" "$@" \
    bash "$SEL" --source dig --island "$i" --out "$TMP/rsel.json" 2>"$TMP/rsel.err"; rc=$?
}
rids() { jq -r '[.inputs[] | select(.kind == "responder") | .id] | sort | join(" ")' "$TMP/rsel.json"; }
rsel "$FX" gateway
{ [ "$rc" = 0 ] && [ "$(rids)" = "responder/KubePodNotReady/homelab" ]; } \
  && ok "the scratch-quota class reaches the gateway sitting as ONE input (exit 0)" || bad "responder positive" "rc=$rc ids=$(rids) $(head -c 300 "$TMP/rsel.err")"
got="$(jq -r '[.inputs[] | select(.kind == "responder") | .members[].fingerprint] | sort | join(" ")' "$TMP/rsel.json")"
[ "$got" = "14149667f0ddd142 3c86aab4bb369c2d 41235cba59738cef 41235cba59738cef 7a7e458ae900e5e1 cc9346bfede93514" ] \
  && ok "…listing its six member findings (one fingerprint triaged twice counts twice)" || bad "responder members" "got: $got"
jq -e '.inputs[] | select(.kind == "responder") | .count == 6 and .namespace == "homelab"
       and all(.members[]; (.remediation_would | length) > 0 and (.finding | startswith("alert-")))' "$TMP/rsel.json" >/dev/null \
  && ok "…each member carries its remediation_would and its bucket path" || bad "responder member shape" "$(jq -c '.inputs[0]' "$TMP/rsel.json")"
case "$(jq -r '[.inputs[] | select(.kind == "responder") | .members[].subject] | join(" ")' "$TMP/rsel.json")" in
  *arc-runners*) bad "responder one-off" "an arc-runners finding joined the class";;
  *) ok "the arc-runners one-off and the empty-remediation records stay out";; esac
for i in agent-loop substrate; do
  rsel "$FX" "$i"; [ "$(rids)" = "" ] && ok "…and no other island is presented the class or the one-off ($i)" || bad "responder leak $i" "got: $(rids)"
done
rsel "$FX" gateway INTAKE_RESPONDER_MIN=7
{ [ "$rc" = 1 ] && [ "$(rids)" = "" ]; } && ok "INTAKE_RESPONDER_MIN is the floor: 6 < 7 presents nothing (hold)" || bad "responder floor" "rc=$rc ids=$(rids)"

# the ledger — the dig's, unchanged (a copy of the real tree, so receipts never land in the fixture dir)
TSR="$TMP/tsr"; mkdir -p "$TSR"; cp -r "$FX/homelab" "$TSR/"
rreceipt() { # <day> <run> <mode> <outcome>
  mkdir -p "$TSR/homelab/intake-gateway-$1/$2"
  jq -n --arg m "$3" --arg o "$4" --arg ts "$1T05:00:00Z" \
    '{schema:"island-intake-receipt/v1", island:"gateway", mode:$m, ts:$ts, session_ran:true, inputs:[],
      ruled:[{input:"responder/KubePodNotReady/homelab", outcome:$o, refs:[]}]}' > "$TSR/homelab/intake-gateway-$1/$2/receipt.json"
}
rreceipt 2026-11-17 intake-r1-dry dry-run standing
rsel "$TSR" gateway; [ "$(rids)" = "responder/KubePodNotReady/homelab" ] && ok "a DRY-RUN receipt rules no class" || bad "responder dry-run" "got: $(rids)"
rreceipt 2026-11-17 intake-r1-def apply deferred
rsel "$TSR" gateway; [ "$(rids)" = "responder/KubePodNotReady/homelab" ] && ok "a \`deferred\` class re-presents" || bad "responder deferred" "got: $(rids)"
rreceipt 2026-11-18 intake-r1-std apply standing
rsel "$TSR" gateway
{ [ "$rc" = 1 ] && [ "$(rids)" = "" ] && [ "$(jq '.counts.responder.ruled' "$TMP/rsel.json")" = 1 ]; } \
  && ok "an APPLY ruling keeps the class off the next day's sitting (counted as ruled)" || bad "responder ledger" "rc=$rc ids=$(rids) $(jq -c .counts "$TMP/rsel.json")"
rm -rf "$TSR/homelab/intake-gateway-"*

# negatives built from a REAL record (its full wire, only subject/fingerprint/issue/run changed)
REAL1="$FX/homelab/alert-3c86aab4bb369c2d/responder-r1-20261113T021803Z/finding.json"
rderive() { # <fp> <run-ts> <subject> [issue]
  mkdir -p "$TSR/homelab/alert-$1/responder-r1-$2"
  jq --arg fp "$1" --arg s "$3" --arg iss "${4:-}" '.fingerprint = $fp | .subject = $s | .issue = $iss' "$REAL1" \
    > "$TSR/homelab/alert-$1/responder-r1-$2/finding.json"
}
# (a) a recurring class whose rides serve an agent-loop issue (#9001 `coordinator: …`) is the loop's, not the gateway's
jq '. + [{number: 9001, title: "coordinator: a ride class the loop owns", body: "Touches: agents/coordinator-scan.sh\n"}]' "$RISS" > "$TMP/riss2.json"
for k in 1 2 3; do rderive "aa0000000000000$k" "2026111$((k + 3))T010000Z" "workload:homelab/agent-homelab-issue-9001-r$k"; done
# (b) a recurring class on non-ride subjects (arc-runners runner pods) — no island owns the subject
for k in 1 2 3; do rderive "bb0000000000000$k" "2026111$((k + 3))T020000Z" "workload:arc-runners/homelab-ephemeral-large-runner"; done
# (c) out of window / issue already filed / future-dated: never members (the gateway class stays at 6)
rderive cc00000000000001 20261101T010000Z "workload:homelab/agent-homelab-issue-3302-r9"
rderive cc00000000000002 20261115T010000Z "workload:homelab/agent-homelab-issue-3302-r8" "teststuffstash/homelab#1"
rderive cc00000000000003 20261120T010000Z "workload:homelab/agent-homelab-issue-3302-r7"
RISS_OVR="$TMP/riss2.json" rsel "$TSR" gateway
got="$(jq -r '[.inputs[] | select(.kind == "responder") | "\(.id)×\(.count)"] | join(" ")' "$TMP/rsel.json")"
[ "$got" = "responder/KubePodNotReady/homelab×6" ] \
  && ok "gateway: not the loop's class, not the runner class; stale, filed and future records are not members" || bad "responder negatives" "got: $got"
RISS_OVR="$TMP/riss2.json" rsel "$TSR" agent-loop
[ "$(jq -r '[.inputs[] | select(.kind == "responder") | "\(.id)×\(.count)"] | join(" ")' "$TMP/rsel.json")" = "responder/KubePodNotReady/homelab×3" ] \
  && ok "…the loop's ride class goes to the agent-loop sitting (the issue's island, by island_of_issue)" || bad "responder other island" "got: $(rids)"
echo '[]' > "$TMP/riss-empty.json"
RISS_OVR="$TMP/riss-empty.json" rsel "$TSR" gateway
[ "$rc" = 2 ] && ok "a ride issue that cannot be read is a probe failure (exit 2), never \"nobody's\"" || bad "responder issue probe" "rc=$rc"
RISS_OVR="$TMP/riss-empty.json" rsel "$TSR" gateway INTAKE_RESPONDER_MIN=99
[ "$rc" = 1 ] && ok "…and below the floor no issue is read at all" || bad "responder lazy read" "rc=$rc $(head -c 200 "$TMP/rsel.err")"
# a GONE ride issue (HTTP 404/410 — deleted, transferred) owns nothing: its findings join no class, one loud
# line, a counted skip — never exit 2 for the whole selection (the header's responder contract). #3302 rides
# ONE of the six class members (issue-3302-r2), so the class stays at 5 ≥ 3 and still presents.
jq 'map(if .number == 3302 then {number: 3302, _status: 404} else . end)' "$RISS" > "$TMP/riss-gone.json"
RISS_OVR="$TMP/riss-gone.json" rsel "$FX" gateway
{ [ "$rc" = 0 ] && [ "$(jq -r '[.inputs[] | select(.kind == "responder") | "\(.id)×\(.count)"] | join(" ")' "$TMP/rsel.json")" = "responder/KubePodNotReady/homelab×5" ] \
    && [ "$(jq '.counts.responder.skipped.ride_issue_gone' "$TMP/rsel.json")" = 1 ] && grep -q 'issue #3302 .*GONE (HTTP 404)' "$TMP/rsel.err"; } \
  && ok "a gone ride issue (404) skips its finding with a loud line and a counted reason; the rest of the class still presents" \
  || bad "responder gone issue" "rc=$rc $(jq -c '.counts.responder' "$TMP/rsel.json" 2>/dev/null) $(head -c 300 "$TMP/rsel.err")"
# the live read: `gh api repos/<repo>/issues/<n>` — 404/410 is gone, any other failure is still exit 2
GHB="$TMP/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<EOF
#!/bin/bash
[ "\$1" = api ] || exit 9
n="\${2##*/}"
case "\$n:\${GH_FAIL:-}" in
  3302:*) echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP \${GH_GONE:-404})" >&2; exit 1;;
  3303:502) echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1;;
esac
jq -c --argjson n "\$n" '.[] | select(.number == \$n)' "$RISS"
EOF
chmod +x "$GHB/gh"
( unset INTAKE_ISSUES_JSON; PATH="$GHB:$PATH" INTAKE_TS_DIR="$FX" INTAKE_NOW="$RNOW" GH_GONE=410 \
    bash "$SEL" --source dig --island gateway --out "$TMP/rsel.json" 2>"$TMP/rsel.err" ); rc=$?
{ [ "$rc" = 0 ] && [ "$(jq '.counts.responder.skipped.ride_issue_gone' "$TMP/rsel.json")" = 1 ]; } \
  && ok "…the live read: HTTP 410 from gh api is gone too (skipped, counted)" || bad "responder gone live" "rc=$rc $(head -c 300 "$TMP/rsel.err")"
( unset INTAKE_ISSUES_JSON; PATH="$GHB:$PATH" INTAKE_TS_DIR="$FX" INTAKE_NOW="$RNOW" GH_FAIL=502 \
    bash "$SEL" --source dig --island gateway --out "$TMP/rsel.json" 2>"$TMP/rsel.err" ); rc=$?
[ "$rc" = 2 ] && ok "…while a 502 (the GitHub read failing as such) is still a probe failure, exit 2" || bad "responder 502" "rc=$rc"
# the S3 branch: one wildcard listing for every fingerprint (the stub answers Garage's row shape)
( unset INTAKE_TS_DIR; TS="$TSR" PATH="$S5BIN:$PATH" AGENT_TS_READER_ID=r AGENT_TS_READER_SECRET=s INTAKE_NOW="$RNOW" \
    INTAKE_ISSUES_JSON="$TMP/riss2.json" bash "$SEL" --source dig --island gateway --out "$TMP/rsel.json" 2>"$TMP/rsel.err" ); rc=$?
{ [ "$rc" = 0 ] && [ "$(rids)" = "responder/KubePodNotReady/homelab" ] \
  && [ "$(jq '[.inputs[] | select(.kind == "responder") | .count] | add' "$TMP/rsel.json")" = 6 ]; } \
  && ok "the S3 branch lists alert-*/responder-*/finding.json once and reads the same class" || bad "responder S3" "rc=$rc ids=$(rids) $(head -c 300 "$TMP/rsel.err")"

# ── --source pile: the issue pile as ONE selection, waits included ──────────────────────────────
# Expected values from the selector's header contract. member = unruled ∧ unlabelled (the default
# selection); reread = OPEN island member ∧ (`agent/blocked` ∨ the LATEST intake ruling is `seat`) ∧ the
# wait ≥ INTAKE_REREAD_AGE_D (3) days old — dated by the latest `intake:` / `blocked-on:` comment, else
# updatedAt — ∧ not listed (outcome ≠ deferred) by an APPLY receipt of the last INTAKE_REREAD_EVERY_D
# (7) days. Never a Goal/container; any OTHER agent/* label = the loop's. Clock: 2026-10-27T05:00Z.
section "selector --source pile"
PISS="$TMP/pile.json"; rm -f "$PISS.rows"; TSP="$TMP/tsp"; mkdir -p "$TSP/homelab"
piss() { # <n> <title> <labels-json> <comments-json> [updatedAt] [author-json]
  jq -nc --argjson n "$1" --arg t "$2" --argjson l "$3" --argjson c "$4" --arg u "${5:-2026-10-01T00:00:00Z}" \
    --argjson au "${6:-{\"login\":\"rsoot\",\"is_bot\":false\}}" \
    '{number:$n, title:$t, body:"free text", labels:($l|map({name:.})), createdAt:"2026-10-01T00:00:00Z", updatedAt:$u, author:$au, comments:$c}' >> "$PISS.rows"
}
cm() { jq -nc --arg b "$1" --arg d "$2" '{body:$b, createdAt:$d}'; }   # <body> <createdAt>
SEAT=$'intake: seat — needs a ruling\nblocked-on: human'
piss 101 "gateway: unruled"                     '[]' '[]'                                                    # member
piss 102 "gateway: blocked 7 d"                 '["agent-fix","agent/blocked"]' "[$(cm "$SEAT" 2026-10-20T05:00:00Z)]"   # reread (7 d)
piss 103 "gateway: seat, comment only, 5 d"     '[]' "[$(cm "$SEAT" 2026-10-22T04:00:00Z)]"                   # reread (5 d)
piss 104 "gateway: seat, 1 d"                   '[]' "[$(cm "$SEAT" 2026-10-26T04:00:00Z)]"                   # 1 d < 3 → out
piss 105 "gateway: standing"                    '[]' "[$(cm 'intake: standing — not now' 2026-10-02T00:00:00Z)]" # not a wait → out
piss 106 "gateway: seat, then standing"         '[]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z),$(cm 'intake: standing — ruled' 2026-10-10T00:00:00Z)]" # LATEST ruling is standing → out
piss 107 "gateway: blocked by a worker"         '["agent/blocked"]' "[$(cm $'the ride stopped\nblocked-on: human' 2026-10-15T00:00:00Z)]" # reread, no intake ruling (12 d)
piss 108 "gateway: blocked, touched yesterday"  '["agent/blocked"]' '[]' 2026-10-26T05:00:00Z                 # no marker comment → updatedAt, 1 d → out
piss 109 "gateway: blocked, quiet 17 d"         '["agent/blocked"]' '[]' 2026-10-10T00:00:00Z                 # updatedAt, 17 d → reread
piss 110 "gateway: a blocked Goal"              '["agent/blocked","task/goal"]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z)]" # a Goal → out
piss 111 "post-launch: gateway bucket"          '["agent/blocked"]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z)]"     # a container → out
piss 112 "gateway: queued after a seat ruling"  '["agent/queued"]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z)]"      # another agent/* label → the loop's
piss 113 "scan: blocked, another island"        '["agent/blocked"]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z)]"     # agent-loop's wait, not the gateway's
piss 114 "no title cue, bot-filed, blocked"     '["agent/blocked"]' "[$(cm "$SEAT" 2026-10-02T00:00:00Z)]" 2026-10-02T00:00:00Z '{"login":"app/homelab-agents-1234","is_bot":true}' # nobody's member → nobody's wait
piss 115 "gateway: blocked and errored"         '["agent/blocked","agent/error"]' "[$(cm "$SEAT" 2026-10-12T00:00:00Z)]" # agent/blocked is the wait → reread (15 d)
jq -s . "$PISS.rows" > "$PISS"
pile() { INTAKE_ISSUES_JSON="$PISS" INTAKE_TS_DIR="$TSP" INTAKE_NOW="$NOW" bash "$SEL" --source pile --island "${1:-gateway}" --out "$TMP/pile-sel.json" 2>"$TMP/pile.err"; }
pk() { jq -r --arg k "$1" '[.inputs[] | select(.kind == $k) | .number] | sort | join(" ")' "$TMP/pile-sel.json"; }
preceipt() { # <day> <run> <mode> <ts> <ruled-json>
  mkdir -p "$TSP/homelab/intake-gateway-$1/$2"
  jq -n --arg m "$3" --arg ts "$4" --argjson r "$5" \
    '{schema:"island-intake-receipt/v1", island:"gateway", mode:$m, ts:$ts, session_ran:true, inputs:[], ruled:$r}' \
    > "$TSP/homelab/intake-gateway-$1/$2/receipt.json"
}
H=teststuffstash/homelab
pile; rc=$?
[ "$rc" = 0 ] && jq -e '.schema == "island-intake-select/v1" and .source == "pile" and .island == "gateway"' "$TMP/pile-sel.json" >/dev/null \
  && ok "fires (exit 0) with ONE selection in the dig's shape" || bad "pile fire" "rc=$rc $(cat "$TMP/pile.err")"
[ "$(pk member)" = 101 ] && ok "member = the default selection (unruled, unlabelled): #101" || bad "pile members" "got '$(pk member)'"
[ "$(pk reread)" = "102 103 107 109 115" ] \
  && ok "reread = agent/blocked ∨ latest ruling seat, ≥ 3 d old: #102 #103 #107 #109 #115 (not the 1-day waits, standing, Goal, container, queued, other islands')" \
  || bad "pile rereads" "got '$(pk reread)'"
[ "$(jq -c '[.inputs[] | select(.number == 102 or .number == 103 or .number == 109) | [.id, .wait, .wait_d]]' "$TMP/pile-sel.json")" = "[[\"$H#102\",\"agent/blocked\",7],[\"$H#103\",\"seat\",5],[\"$H#109\",\"agent/blocked\",17]]" ] \
  && ok "each reread carries its id (<owner/repo>#<n>), the wait and its age in days" || bad "reread shape" "$(jq -c '.inputs[] | select(.kind == "reread") | [.id, .wait, .wait_d]' "$TMP/pile-sel.json" | tr '\n' ' ')"
[ "$(jq -c .counts "$TMP/pile-sel.json")" = '{"members":1,"rereads":5,"reread_recent":0,"inputs":6}' ] && ok "counts: 1 member + 5 rereads = 6 inputs" || bad "pile counts" "$(jq -c .counts "$TMP/pile-sel.json")"
pile agent-loop; [ "$(pk reread)" = 113 ] && ok "another island's wait is that island's (#113 → agent-loop); a bot-filed unclaimed wait (#114) is nobody's" \
  || bad "pile agent-loop" "got '$(pk reread)'"
got="$(INTAKE_ISSUES_JSON="$PISS" INTAKE_NOW="$NOW" bash "$SEL" --island gateway --json 2>/dev/null | jq -r '[.[].number] | join(" ")')"
[ "$got" = 101 ] && ok "the default (issues) mode still selects only the unruled: #101" || bad "issues mode regressed" "got '$got'"

preceipt 2026-10-24 a apply   2026-10-24T05:00:00Z "[{\"input\":\"$H#102\",\"outcome\":\"unchanged\",\"refs\":[]},{\"input\":\"$H#107\",\"outcome\":\"deferred\",\"refs\":[]}]"
preceipt 2026-10-25 b dry-run 2026-10-25T05:00:00Z "[{\"input\":\"$H#103\",\"outcome\":\"unchanged\",\"refs\":[]}]"
pile
[ "$(pk reread)" = "103 107 109 115" ] && [ "$(jq '.counts.reread_recent' "$TMP/pile-sel.json")" = 1 ] \
  && ok "an APPLY receipt 3 d ago that lists #102 (unchanged) keeps it out; \`deferred\` (#107) and a dry-run receipt (#103) do not" \
  || bad "reread ledger" "got '$(pk reread)' $(jq -c .counts "$TMP/pile-sel.json")"
INTAKE_REREAD_EVERY_D=2 pile
[ "$(pk reread)" = "102 103 107 109 115" ] && ok "…for INTAKE_REREAD_EVERY_D days only (=2: the 3-day-old receipt has aged out)" || bad "reread every knob" "got '$(pk reread)'"
INTAKE_REREAD_AGE_D=6 pile
[ "$(pk reread)" = "107 109 115" ] && ok "INTAKE_REREAD_AGE_D is a knob (=6: the 5-day wait #103 is too young; #102 still ledgered)" || bad "reread age knob" "got '$(pk reread)'"
preceipt 2026-10-27 c apply 2026-10-27T03:00:00Z "[]"; preceipt 2026-10-27 d apply 2026-10-27T04:00:00Z "[]"
pile; rc=$?
{ [ "$rc" = 1 ] && grep -q "daily cap" "$TMP/pile.err" && [ "$(jq '.counts.inputs' "$TMP/pile-sel.json")" = 5 ]; } \
  && ok "the same INTAKE_DAILY_MAX cap: 2 apply sittings today → hold, the selection still written" || bad "pile cap" "rc=$rc $(cat "$TMP/pile.err")"
rm -rf "$TSP/homelab/intake-gateway-2026-10-27"
pile mgmt-box; rc=$?
{ [ "$rc" = 1 ] && [ "$(jq '.counts.inputs' "$TMP/pile-sel.json")" = 0 ]; } && ok "an island with nothing to rule or re-read holds (exit 1, a valid empty selection)" || bad "pile hold" "rc=$rc"
INTAKE_ISSUES_JSON="$PISS" INTAKE_TS_DIR="$TMP/nowhere" INTAKE_NOW="$NOW" bash "$SEL" --source pile --out "$TMP/x.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "an unreadable receipt store is a probe failure (exit 2) — it could not see what was re-read" || bad "pile rule #6 (bucket)" "rc=$rc"
INTAKE_ISSUES_JSON="$TMP/nowhere.json" INTAKE_TS_DIR="$TSP" INTAKE_NOW="$NOW" bash "$SEL" --source pile --out "$TMP/x.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "…and so is an unreadable issue list" || bad "pile rule #6 (issues)" "rc=$rc"
# PR-level waits (INTAKE_PR_HOLDS=1): an issue the loop still holds (another `agent/*` label) whose
# OPEN PR's newest `blocked-on:` marker is `human` is a reread, `wait: pr-hold`, dated by the marker.
piss 116 "gateway: in review, its PR parked on a human" '["agent-fix","agent/review"]' "[$(cm 'intake: queue — one ride' 2026-10-02T00:00:00Z)]" 2026-10-26T00:00:00Z
piss 117 "gateway: in review, the hold superseded"      '["agent/review"]' '[]' 2026-10-26T00:00:00Z
piss 118 "gateway: in review, parked yesterday"         '["agent/review"]' '[]' 2026-10-26T00:00:00Z
jq -s . "$PISS.rows" > "$PISS"
PPRS="$TMP/pile-prs.json"
jq -n '[
  {number:900, state:"OPEN", headRefName:"fix/issue-116-x", body:"", closingIssuesReferences:[], comments:[
     {body:"ruling\nblocked-on: issue=5", createdAt:"2026-10-18T00:00:00Z"},
     {body:"ci-red ruling: designed wait\n\nblocked-on: human\n\nNext mover: a rerun", createdAt:"2026-10-20T00:00:00Z"},
     {body:"state-fp:ci-red:abc — a marker comment that talks about `blocked-on: human` mid-line", createdAt:"2026-10-21T00:00:00Z"}]},
  {number:901, state:"OPEN", headRefName:"fix/other", body:"Fixes #117", closingIssuesReferences:[], comments:[
     {body:"blocked-on: human", createdAt:"2026-10-10T00:00:00Z"}, {body:"blocked-on: issue=5", createdAt:"2026-10-12T00:00:00Z"}]},
  {number:902, state:"OPEN", headRefName:"fix/y", body:"", closingIssuesReferences:[{number:118}], comments:[
     {body:"blocked-on: human", createdAt:"2026-10-26T04:00:00Z"}]},
  {number:903, state:"OPEN", headRefName:"fix/issue-112-z", body:"", closingIssuesReferences:[], comments:[]}]' > "$PPRS"
INTAKE_PR_HOLDS=1 INTAKE_PRS_JSON="$PPRS" INTAKE_REREAD_EVERY_D=2 pile
[ "$(pk reread)" = "102 103 107 109 115 116" ] \
  && [ "$(jq -c '.inputs[] | select(.number == 116) | [.wait, .pr, .wait_d, .since, .parked_by]' "$TMP/pile-sel.json")" = '["pr-hold",900,7,"2026-10-20T00:00:00Z","blocked-on: human (PR #900)"]' ] \
  && ok "INTAKE_PR_HOLDS=1: an agent/review issue whose open PR's NEWEST marker is blocked-on: human is a reread (pr-hold, the PR, the marker's date); a superseded (#117), a 1-day (#118) and a marker-less (#112) one are not" \
  || bad "pile pr-hold" "got '$(pk reread)' $(jq -c '.inputs[] | select(.number == 116)' "$TMP/pile-sel.json") $(cat "$TMP/pile.err")"
[ "$(jq -c '[.inputs[] | select(.kind == "reread" and .number != 116) | has("pr")] | any' "$TMP/pile-sel.json")" = false ] \
  && ok "…and a label/ruling wait carries no pr field" || bad "pile pr field" "$(jq -c '.inputs[] | select(.kind == "reread")' "$TMP/pile-sel.json")"
INTAKE_PRS_JSON="$PPRS" INTAKE_REREAD_EVERY_D=2 pile
[ "$(pk reread)" = "102 103 107 109 115" ] && ok "without INTAKE_PR_HOLDS the pile is the label/ruling waits only (the default)" || bad "pile pr-hold default" "got '$(pk reread)'"
INTAKE_PR_HOLDS=1 INTAKE_PRS_JSON="$TMP/nowhere.json" pile; rc=$?
[ "$rc" = 2 ] && ok "INTAKE_PR_HOLDS=1 with an unreadable PR list is a probe failure (exit 2), never \"no holds\"" || bad "pile rule #6 (prs)" "rc=$rc"
# forward (gateway/intake.md step 0): an issue whose LATEST intake ruling is `forward` is unruled —
# a member of whichever island its (retitled) title names now, its row carrying the hop count.
FISS="$TMP/fwd.json"
fiss() { jq -nc --argjson n "$1" --arg t "$2" --argjson c "$3" \
  '{number:$n, title:$t, body:"free text", labels:[], createdAt:"2026-10-01T00:00:00Z", updatedAt:"2026-10-20T00:00:00Z", author:{login:"rsoot",is_bot:false}, comments:$c}'; }
{ fiss 201 "gateway: passed here by another island" "[$(cm 'intake: forward → gateway — the catalog view is the gateway'"'"'s' 2026-10-20T00:00:00Z)]"
  fiss 202 "gateway: passed here twice" "[$(cm 'intake: forward → retro — x' 2026-10-18T00:00:00Z),$(cm 'intake: forward → gateway — y' 2026-10-20T00:00:00Z)]"
  fiss 203 "gateway: forwarded, then ruled seat" "[$(cm 'intake: forward → gateway — x' 2026-10-10T00:00:00Z),$(cm "$SEAT" 2026-10-20T00:00:00Z)]"
  fiss 204 "dependency: passed on to another island" "[$(cm 'intake: forward → dependency-upgrades — the lint is theirs' 2026-10-20T00:00:00Z)]"
  fiss 205 "gateway: never forwarded" '[]'
  fiss 206 "gateway: forwarded with a missed space" "[$(cm 'intake: forward→gateway — z' 2026-10-20T00:00:00Z)]"
  fiss 207 "gateway: forwarded with a colon" "[$(cm 'intake: forward: gateway — z' 2026-10-20T00:00:00Z)]"
  fiss 208 "gateway: a ruling that only starts like it" "[$(cm 'intake: forwarded-looking standing note' 2026-10-20T00:00:00Z)]"
} | jq -s . > "$FISS"
fwd() { INTAKE_ISSUES_JSON="$FISS" INTAKE_TS_DIR="$TSP" INTAKE_NOW="$NOW" bash "$SEL" --source pile --island "$1" --out "$TMP/fwd-sel.json" 2>"$TMP/fwd.err"; }
fwd gateway
[ "$(jq -c '[.inputs[] | select(.kind == "member") | [.number, (.forwards // 0)]] | sort' "$TMP/fwd-sel.json")" = '[[201,1],[202,2],[205,0],[206,1],[207,1]]' ] \
  && [ "$(jq -c '[.inputs[] | select(.kind == "reread") | .number]' "$TMP/fwd-sel.json")" = '[203]' ] \
  && ok "a latest ruling of forward is unruled: a member again, with forwards = its hop count (#201 ×1, #202 ×2; #205 carries none); a later seat is a wait again (#203); the count and the unruled check read the comment the same way (\`forward→gateway\` #206, \`forward:\` #207 are members ×1; \`forwarded…\` #208 is neither)" \
  || bad "forward members" "$(jq -c '.inputs' "$TMP/fwd-sel.json") $(cat "$TMP/fwd.err")"
fwd dependency-upgrades
[ "$(jq -c '[.inputs[] | [.number, .kind, .forwards]]' "$TMP/fwd-sel.json")" = '[[204,"member",1]]' ] \
  && ok "…and it is the member of the island its title names now (#204 → dependency-upgrades)" || bad "forward target" "$(jq -c '.inputs' "$TMP/fwd-sel.json")"

# ── the CronWorkflow, structurally (the dig's FU-198 pins) ──────────────────────────────────────
section "island-intake-argo.yaml — shape"
CW='select(.kind == "CronWorkflow")'
yqw() { yq -r "$CW | $1" "$YAML" | grep -v -e '^---$' -e '^$'; }
[ "$(yqw '.spec.workflowSpec.synchronization // "none"')" = none ] && ok "no workflow-level semaphore" || bad "FU-198" "workflowSpec.synchronization set"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.synchronization != null) | .name')" = intake ] \
  && ok "the semaphore sits on the intake LEAF" || bad "FU-198" "semaphore not on the leaf"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .retryStrategy // "none"')" = none ] \
  && ok "the leaf carries no retryStrategy" || bad "FU-198" "leaf retries"
[ "$(yqw '.spec.workflowSpec.entrypoint')" = intake-retry ] && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-retry") | .steps[][] | .template')" = intake ] \
  && ok "entrypoint = the retry wrapper, which calls the leaf" || bad "caller edge" "entrypoint/steps"
[ "$(yqw '.spec.workflowSpec.arguments.parameters[] | select(.name == "mode") | .value')" = apply ] \
  && ok "mode defaults to apply (submit -p mode=dry-run for a no-write sitting)" || bad "mode param" "missing"
grep -qx '  - island-intake-argo.yaml' "$REPO/agents/coordinator/kustomization.yaml" \
  && ok "kustomization ships it" || bad "kustomization" "island-intake-argo.yaml not listed"

# ── the workflow's own script, end to end, stubbed ──────────────────────────────────────────────
section "island-intake-argo.yaml — the script, run"
yq -r "$CW | .spec.workflowSpec.templates[] | select(.name == \"intake\") | .container.args[0]" "$YAML" \
  | sed -e "s#/tmp/#$TMP/run/#g" -e "s#/work/homelab#$TMP/work/homelab#g" > "$TMP/script.sh"   # /tmp/ FIRST: $TMP is under /tmp
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/run" "$TMP/up"
cat > "$BIN/git" <<EOF
#!/bin/bash
# clone stub: the checkout under test, minus .git (untracked/ignored excluded; a re-entry guard makes a PATH loop fail, never fork-bomb)
[ -n "\${STUB_GIT_ACTIVE:-}" ] && { echo "git stub re-entered" >&2; exit 97; }; export STUB_GIT_ACTIVE=1
dest="\${@: -1}"; mkdir -p "\$dest"; (cd "$REPO" && $(command -v git) ls-files -z | tar --null -T - -cf -) | (cd "\$dest" && tar -xf -)
# the rail + model resolution are the proxy's — served flat here
printf '#!/bin/bash\necho anthropic\n' > "\$dest/agents/subscription-latch.sh"
printf '#!/bin/bash\necho opus\n' > "\$dest/agents/resolve-model.sh"
# the island's specs index: a row's fixture (\$H/specs-index.md), else one with no gap row — the gap
# source then holds and the dig/pile rows below see exactly the sittings they always saw
if [ -f "\$H/specs-index.md" ]; then cp "\$H/specs-index.md" "\$dest/gateway/specs/README.md"; else printf '# specs\n' > "\$dest/gateway/specs/README.md"; fi
EOF
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
echo "claude $*" | cut -c1-80 >> "$H/claude.calls"
cat "$H/claude.out"
EOF
cat > "$BIN/s5cmd" <<'EOF'
#!/bin/bash
# writer stub: `s5cmd --endpoint-url E cp <local> s3://…/<key>` → $H/up/<basename>
[ "$3" = cp ] && cp "$4" "$H/up/$(basename "$5")"
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$H/curl.calls"
# a pushgateway write (`--data-binary @-`): keep the exposition text the launcher piped in
case " $* " in *" --data-binary @- "*) cat >> "$H/pgw.body";; esac
EOF
chmod +x "$BIN"/*
echo '[]' > "$TMP/pile-empty.json"   # the pile source's seam: an empty pile unless a row sets PILE_JSON
echo '{}' > "$TMP/refs-empty.json"   # the target-state seam: a row that needs a target sets REFS_JSON (a lookup here fails loud, never reaches gh)
# the wait source reads the same pile seam; its cap is 0 unless a row sets WAIT_MAX, so the dig/pile/review rows
# below see exactly the sittings they always saw (the gap source's specs-index default, the same move)
run_script() { # <mode>
  rm -rf "$TMP/work" "$TMP/up"/* "$TMP/run"/*; : > "$TMP/claude.calls"; : > "$TMP/curl.calls"; mkdir -p "$TMP/work"
  ( cd "$TMP" && H="$TMP" PATH="${RUN_PATH:-$BIN}:$PATH" HOME="$TMP/home" MODE="$1" ISLAND=gateway \
      INTAKE_WAIT_MAX="${WAIT_MAX:-0}" INTAKE_REFS_JSON="${REFS_JSON:-$TMP/refs-empty.json}" \
      INTAKE_ISSUES_JSON="${PILE_JSON:-$TMP/pile-empty.json}" INTAKE_PRS_JSON="${PRS_JSON:-$TMP/pile-empty.json}" \
      INTAKE_TS_DIR="$TS" INTAKE_NOW="$NOW" GH_TOKEN=x AGENT_TS_BUCKET=b AGENT_TS_ENDPOINT=e \
      AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s PUSHGATEWAY="" env ${RUN_ENV:-} bash "$TMP/script.sh" ) > "$TMP/run.log" 2>&1
}
cat > "$TMP/claude.out" <<EOF
… the sitting's report …
INTAKE-RULED: dig-2026-10-26/$R2/finding-2 approve -
INTAKE-RULED: dig-2026-10-26/$R2/finding-2 fold teststuffstash/homelab#9
INTAKE-RULED: dig-2026-10-25/$R1/finding-2 queue teststuffstash/homelab#9
INTAKE-RULED: dig-2099-01-01/forged/finding-1 queue -
INTAKE-RULED: dig-2026-10-25/$R1/finding-2 close -
EOF
run_script apply; rc=$?
[ "$rc" = 0 ] && ok "apply run exits 0" || bad "apply run" "rc=$rc; $(tail -5 "$TMP/run.log")"
[ -s "$TMP/claude.calls" ] && grep -q -- "--model opus" "$TMP/claude.calls" && ok "one sitting, on the resolved model" || bad "session" "$(cat "$TMP/claude.calls")"
grep -q "Read gateway/intake.md IN FULL" "$TMP/up/brief.md" 2>/dev/null && grep -q "mode: apply" "$TMP/up/brief.md" \
  && jq -e '.inputs | length == 2' "$TMP/up/inputs.json" >/dev/null 2>&1 \
  && ok "brief names the island brief + mode; the inputs ride beside it" || bad "brief" "$(head -3 "$TMP/up/brief.md" 2>/dev/null)"
[ "$(jq -c '[.ruled[] | [.input, .outcome]]' "$TMP/up/receipt.json" 2>/dev/null)" = "[[\"dig-2026-10-25/$R1/finding-2\",\"queue\"],[\"dig-2026-10-26/$R2/finding-2\",\"fold\"]]" ] \
  && ok "receipt keeps only THIS run's ids, known outcomes, first line per id" || bad "receipt" "$(jq -c .ruled "$TMP/up/receipt.json" 2>/dev/null)"
jq -e '.schema == "island-intake-receipt/v1" and .mode == "apply" and .session_ran == true' "$TMP/up/receipt.json" >/dev/null 2>&1 \
  && ok "receipt schema/mode/session_ran — what the selector's ledger reads" || bad "receipt shape" "$(cat "$TMP/up/receipt.json" 2>/dev/null)"
grep -q '/coordinate' "$TMP/curl.calls" && ok "a queue outcome rings /coordinate once" || bad "ring" "$(cat "$TMP/curl.calls")"
mkdir -p "$TS/homelab/intake-gateway-2026-10-27/r"; cp "$TMP/up/receipt.json" "$TS/homelab/intake-gateway-2026-10-27/r/"
sel; rc=$?
[ "$rc" = 1 ] && ok "…and the next selection reads that receipt back: nothing left to rule" || bad "round trip" "rc=$rc $(ids)"
rm -rf "$TS/homelab/intake-gateway-2026-10-27"

run_script dry-run
grep -q "mode: dry-run" "$TMP/up/brief.md" && jq -e '.mode == "dry-run"' "$TMP/up/receipt.json" >/dev/null 2>&1 \
  && ok "dry-run: the brief and receipt say dry-run" || bad "dry-run" "$(jq -c . "$TMP/up/receipt.json" 2>/dev/null)"
grep -q '/coordinate' "$TMP/curl.calls" && bad "dry-run ring" "rang /coordinate" || ok "dry-run never rings"

RUN_ENV="INTAKE_NOW=garbage" run_script apply; rc=$?   # `date -d @garbage` in an assignment → set -e exit 1, nothing written
{ [ "$rc" = 1 ] && [ ! -s "$TMP/claude.calls" ] && grep -q "selection failed" "$TMP/run.log"; } \
  && ok "a selector that dies (exit 1, no selection written) is a failure for Argo to retry — never read as a hold" \
  || bad "fail-open hold" "rc=$rc $(tail -2 "$TMP/run.log")"

receipt 2026-10-26 intake-r1-e apply 2026-10-26T06:00:00Z \
  "[{\"input\":\"dig-2026-10-25/$R1/finding-2\",\"outcome\":\"close\",\"refs\":[]},{\"input\":\"dig-2026-10-26/$R2/finding-2\",\"outcome\":\"fold\",\"refs\":[]}]"
run_script apply
[ ! -s "$TMP/claude.calls" ] && grep -q "hold" "$TMP/run.log" && ok "hold: no session, exit 0" || bad "hold" "$(tail -3 "$TMP/run.log")"

# a recurring responder class rides the dig source into the SAME sitting (selector header: an alert
# the island's rule file defines owns the finding — no ride issue is read); three real-wire records
# re-stamped onto GoCatalogStale (defined in argocd/resources/agent-gateway/prometheusrule.yaml)
for k in 4 5 6; do
  d="$TS/homelab/alert-dd0000000000000$k/responder-r1-2026102${k}T010000Z"; mkdir -p "$d"
  jq --arg fp "dd0000000000000$k" '.alertname = "GoCatalogStale" | .fingerprint = $fp | .subject = "workload:agent-egress/agent-gateway"' \
    "$REPO/agents/island-intake-fixtures/homelab/alert-3c86aab4bb369c2d/responder-r1-20261113T021803Z/finding.json" > "$d/finding.json"
done
printf 'INTAKE-RULED: responder/GoCatalogStale/agent-egress standing -\n' > "$TMP/claude.out"
run_script apply; rc=$?
{ [ "$rc" = 0 ] && grep -q '^text: (source: responder)$' "$TMP/up/brief.md" && grep -qF '"id": "responder/GoCatalogStale/agent-egress"' "$TMP/up/brief.md"; } \
  && ok "the brief lists the class under \`text: (source: responder)\`" || bad "responder brief" "rc=$rc $(tail -3 "$TMP/run.log")"
[ "$(jq -c '[.ruled[] | [.input, .outcome]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["responder/GoCatalogStale/agent-egress","standing"]]' ] \
  && ok "…and its ruling lands in the receipt under the class id (the ledger the selector reads)" || bad "responder receipt" "$(jq -c .ruled "$TMP/up/receipt.json" 2>/dev/null)"
rm -rf "$TS/homelab/alert-dd"*

# ── the pile source in the same sitting ─────────────────────────────────────────────────────────
# State here: the dig HOLDS (receipt intake-r1-e ruled both findings); the pile fixture above serves
# 1 member + 5 rereads. Per the header's machinery inventory either source firing starts the ONE
# sitting over both input sets, and the receipt's ruled lines carry issue ids with the brief's
# outcomes, `requeue` and `unchanged` included (`requeue` queues work, so it rings).
section "island-intake-argo.yaml — the pile source rides the same sitting"
cat > "$TMP/claude.out" <<EOF
INTAKE-RULED: $H#101 seat $H#101
INTAKE-RULED: $H#102 requeue $H#102
INTAKE-RULED: $H#103 unchanged -
INTAKE-RULED: $H#107 split $H#7,$H#8
INTAKE-RULED: $H#109 reopened -
INTAKE-RULED: $H#115 forward island:retro
INTAKE-RULED: $H#999 requeue -
EOF
PILE_JSON="$PISS" run_script apply; rc=$?
{ [ "$rc" = 0 ] && [ -s "$TMP/claude.calls" ] && [ "$(grep -c '^claude' "$TMP/claude.calls")" = 1 ]; } \
  && ok "the dig holds, the pile fires → ONE sitting" || bad "pile sitting" "rc=$rc $(tail -4 "$TMP/run.log")"
[ "$(jq -c '[.counts.dig, .counts.members, .counts.rereads, .counts.inputs]' "$TMP/up/inputs.json" 2>/dev/null)" = "[0,1,5,6]" ] \
  && ok "inputs.json = both selections merged (0 dig + 1 member + 5 rereads)" || bad "merged inputs" "$(jq -c .counts "$TMP/up/inputs.json" 2>/dev/null)"
{ grep -q '^issues:$' "$TMP/up/brief.md" && grep -q '^reread:$' "$TMP/up/brief.md" && grep -qF "\"id\": \"$H#102\"" "$TMP/up/brief.md" \
    && grep -qF '"parked_by": "intake: seat — needs a ruling"' "$TMP/up/brief.md"; } \
  && ok "the brief lists \`issues:\` and \`reread:\` (id, the parking line)" || bad "brief lists" "$(grep -n -e '^issues' -e '^reread' "$TMP/up/brief.md")"
{ grep -qF 'http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/query' "$TMP/up/brief.md" \
    && grep -qF 'http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/api/v2/alerts' "$TMP/up/brief.md" \
    && grep -qF 'http://agent-gateway.agent-egress.svc.cluster.local:8080/' "$TMP/up/brief.md" \
    && grep -qF '/var/run/secrets/agent-gateway/token' "$TMP/up/brief.md"; } \
  && ok "…and the in-cluster addresses of the live reads (Prometheus, Alertmanager, the gateway + its caller token)" || bad "brief live reads" "missing an address"
grep -qF 'AWS_ACCESS_KEY_ID="$AGENT_TS_READER_ID"' "$TMP/up/brief.md" \
  && ok "…the bucket read names the READER key by VARIABLE — no key value is rendered into the uploaded brief" || bad "brief reader key" "$(grep -n AWS_ACCESS "$TMP/up/brief.md")"
[ "$(jq -c '[.ruled[] | [.input, .outcome]]' "$TMP/up/receipt.json" 2>/dev/null)" = "[[\"$H#101\",\"seat\"],[\"$H#102\",\"requeue\"],[\"$H#103\",\"unchanged\"],[\"$H#107\",\"split\"],[\"$H#115\",\"forward\"]]" ] \
  && [ "$(jq -c '.ruled[] | select(.outcome == "forward") | .refs' "$TMP/up/receipt.json" 2>/dev/null)" = '["island:retro"]' ] \
  && ok "receipt: issue ids with seat / requeue / unchanged / split / forward (its ref = the island it went to); an unknown outcome and a forged id dropped" || bad "pile receipt" "$(jq -c .ruled "$TMP/up/receipt.json" 2>/dev/null)"
grep -q '/coordinate' "$TMP/curl.calls" && ok "a \`requeue\` rings /coordinate (it queued work)" || bad "requeue ring" "$(cat "$TMP/curl.calls")"
mkdir -p "$TSP/homelab/intake-gateway-2026-10-27/r"; cp "$TMP/up/receipt.json" "$TSP/homelab/intake-gateway-2026-10-27/r/"
rm -rf "$TSP/homelab/intake-gateway-2026-10-24"
pile
[ "$(pk reread)" = "109" ] && ok "…and the next pile selection reads that receipt back: #102 #103 #107 #115 are not re-read tomorrow, #109 (no line) is" \
  || bad "pile round trip" "got '$(pk reread)'"
rm -rf "$TSP/homelab/intake-gateway-2026-10-27"
cat > "$TMP/claude.out" <<EOF
INTAKE-RULED: $H#103 unchanged -
INTAKE-RULED: $H#115 forward island:retro
EOF
PILE_JSON="$PISS" run_script apply
grep -q '/coordinate' "$TMP/curl.calls" && bad "unchanged ring" "rang /coordinate" || ok "\`unchanged\` and \`forward\` ring nothing (a forward queues no work)"
echo 'not json' > "$TMP/pile-bad.json"
PILE_JSON="$TMP/pile-bad.json" run_script apply; rc=$?
{ [ "$rc" = 1 ] && [ ! -s "$TMP/claude.calls" ] && grep -q "selection failed (source pile" "$TMP/run.log"; } \
  && ok "a pile selection that fails is a failure for Argo to retry — the dig's hold does not mask it" || bad "pile fail-open" "rc=$rc $(tail -2 "$TMP/run.log")"

# ── FU-270: the sitting is admitted by the agent-gateway (gateway rollout, #1640/#1769) ──────────
section "island-intake-argo.yaml — the gateway admits the sitting (FU-270)"
# Rulings 2026-11-01: intake acts for the platform (platform islands; the bell rings platform), so
# its ONE sitting admits as stack platform, role coordinator, tier heavy (the goal-decompose sitting
# the old path runs on opus), through agents/gateway-admit.sh's unbound lane shape — the dispatch env
# overrides the pod's old-proxy pair on the claude call. Refusal-before-request / fail-closed = the
# FU-270 transition fallback (one loud line, the old path); defer = exit 1 like a rail not clear.
# Same extracted script and stubs as above, with `curl` answering POST /sessions and `claude`
# recording the env it was handed (GBIN shadows BIN).
GBIN="$TMP/gbin"; mkdir -p "$GBIN"
cat > "$GBIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$H/curl.calls"
case "$*" in
  *"-X DELETE"*/sessions/*) exit 0 ;;
  *"-X POST"*/sessions*)
    [ -f "$H/gw-reply.json" ] || { printf '000'; exit 7; }
    _o=""; _p=""; for _a in "$@"; do [ "$_p" = "-o" ] && _o="$_a"; _p="$_a"; done
    [ -z "$_o" ] || cat "$H/gw-reply.json" > "$_o"
    cat "$H/gw-http" 2>/dev/null || printf '200'; exit 0 ;;
esac
exit 0
EOF
cat > "$GBIN/claude" <<'EOF'
#!/bin/bash
echo "claude $*" | cut -c1-80 >> "$H/claude.calls"
for a in "$@"; do case "$a" in --model) m=1;; *) [ -n "${m:-}" ] && { echo "model $a" >> "$H/claude.calls"; m=""; };; esac; done
echo "env ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-} ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-}" >> "$H/claude.calls"
cat "$H/claude.out"
EOF
chmod +x "$GBIN"/*
printf 'fake-caller-token-projected' > "$TMP/gw-caller-token"
I_OLD_BASE="http://openrouter-proxy.agent-egress.svc.cluster.local:8080/anthropic"
I_GW_BASE="http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic"
gw_intake_run() { # <reply-kind> [knob]
  rm -rf "$TMP/work" "$TMP/up"/* "$TMP/run"/* "$TMP/gw-reply.json" "$TMP/gw-http"
  : > "$TMP/claude.calls"; : > "$TMP/curl.calls"; mkdir -p "$TMP/work"
  case "$1" in
    dispatch) printf '%s' '{"decision":"dispatch","session":{"id":"s-int-1","token":"gws_INTAKETOKEN","expires_at":"2026-10-27T09:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/gw-intake-model","env":{"ANTHROPIC_BASE_URL":"'"$I_GW_BASE"'","ANTHROPIC_AUTH_TOKEN":"gws_INTAKETOKEN","ANTHROPIC_MODEL":"gw-intake-model"},"context_tokens":200000}' > "$TMP/gw-reply.json";;
    go)       printf '%s' '{"decision":"dispatch","session":{"id":"s-int-go","token":"gws_GO","expires_at":"2026-10-27T09:00:00Z"},"rail":"opencode","harness":"claude","model":"opencode-go/claude-haiku-5-5","env":{"ANTHROPIC_BASE_URL":"'"$I_GW_BASE"'","ANTHROPIC_AUTH_TOKEN":"gws_GO","ANTHROPIC_MODEL":"claude-haiku-5-5"},"context_tokens":200000}' > "$TMP/gw-reply.json";;
    defer)    printf '%s' '{"decision":"defer","reason":"subscription-sessions-full","retry_after_s":600}' > "$TMP/gw-reply.json";;
    fallback) printf '{"error":"down"}' > "$TMP/gw-reply.json"; printf '503' > "$TMP/gw-http";;
  esac
  ( cd "$TMP" && H="$TMP" PATH="$GBIN:$BIN:$PATH" HOME="$TMP/home" MODE=apply ISLAND=gateway \
      INTAKE_ISSUES_JSON="$TMP/pile-empty.json" INTAKE_PRS_JSON="$TMP/pile-empty.json" \
      INTAKE_TS_DIR="$TS" INTAKE_NOW="$NOW" GH_TOKEN=x AGENT_TS_BUCKET=b AGENT_TS_ENDPOINT=e \
      AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s PUSHGATEWAY="" \
      AGENT_GATEWAY="${2-sessions}" AGENT_GATEWAY_CALLER_TOKEN_FILE="$TMP/gw-caller-token" \
      ANTHROPIC_BASE_URL="$I_OLD_BASE" ANTHROPIC_AUTH_TOKEN="ref:agent-coordinator/coordinator-claude" \
      bash "$TMP/script.sh" ) > "$TMP/run.log" 2>&1
}
rm -rf "$TS/homelab/intake-gateway-2026-10-26/intake-r1-e"   # un-rule the hold row's inputs: these rows need a sitting
gw_intake_run dispatch; rc=$?
grep -qF '"stack":"platform","role":"coordinator","task":"intake-gateway-' "$TMP/curl.calls" && grep -qF '"tier":"heavy"' "$TMP/curl.calls" && grep -qF '"prefer":"strongest"' "$TMP/curl.calls" \
  && ok "dispatch → POST /sessions as stack platform, role coordinator, tier heavy, prefer strongest, task intake-<island>-<day>" \
  || bad "gw admit body" "$(grep sessions "$TMP/curl.calls" | head -2) | $(tail -3 "$TMP/run.log")"
grep -qx "model gw-intake-model" "$TMP/claude.calls" && ok "…the sitting runs on the GATEWAY's model (rail prefix stripped)" || bad "gw model" "$(cat "$TMP/claude.calls")"
grep -qxF "env ANTHROPIC_BASE_URL=$I_GW_BASE ANTHROPIC_AUTH_TOKEN=gws_INTAKETOKEN" "$TMP/claude.calls" \
  && ok "…and its dispatch env overrides the pod's old-proxy pair" || bad "gw env" "$(grep '^env' "$TMP/claude.calls")"
grep -qF -- "-X DELETE http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/s-int-1" "$TMP/curl.calls" \
  && ok "…and the EXIT trap releases the session" || bad "gw release" "$(grep sessions "$TMP/curl.calls")"
[ "$rc" = 0 ] && jq -e '.rail == "gateway:anthropic" and .model == "gw-intake-model"' "$TMP/up/receipt.json" >/dev/null 2>&1 \
  && ok "…and the receipt records the gateway's rail and model" || bad "gw receipt" "rc=$rc $(jq -c '{rail,model}' "$TMP/up/receipt.json" 2>/dev/null)"

gw_intake_run defer; rc=$?
{ [ "$rc" = 1 ] && ! grep -q '^claude' "$TMP/claude.calls" && grep -qF "the gateway deferred [subscription-sessions-full]" "$TMP/run.log"; } \
  && ok "defer → no sitting, exit 1 → the retry wrapper (as a rail not clear does)" || bad "gw defer" "rc=$rc $(tail -3 "$TMP/run.log")"

gw_intake_run go; rc=$?
{ [ "$rc" = 1 ] && ! grep -q '^claude' "$TMP/claude.calls" && grep -qF -- "-X DELETE http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/s-int-go" "$TMP/curl.calls" \
    && grep -qF "answered on the Go rail" "$TMP/run.log"; } \
  && ok "a dispatch on the Go rail (opencode / opencode-go/*) is released unused → no sitting, exit 1 (nothing of this run rides Go)" \
  || bad "gw go rail" "rc=$rc $(tail -3 "$TMP/run.log")"

gw_intake_run fallback; rc=$?
grep -qF "gateway admission refused rc=3 — old-proxy fallback" "$TMP/run.log" \
  && ok "gateway 503 (fail-closed) → the ONE loud transition-fallback line" || bad "gw fallback line" "$(tail -5 "$TMP/run.log")"
{ [ "$rc" = 0 ] && grep -qx "model opus" "$TMP/claude.calls" && grep -qxF "env ANTHROPIC_BASE_URL=$I_OLD_BASE ANTHROPIC_AUTH_TOKEN=ref:agent-coordinator/coordinator-claude" "$TMP/claude.calls"; } \
  && ok "…and the sitting runs on the old path (resolved model, old-proxy pair)" || bad "gw fallback path" "rc=$rc $(cat "$TMP/claude.calls")"

gw_intake_run dispatch ""; rc=$?
{ ! grep -q '/sessions' "$TMP/curl.calls" && grep -qx "model opus" "$TMP/claude.calls"; } \
  && ok "AGENT_GATEWAY unset → no /sessions call, the old path byte-for-byte" || bad "gw knob off" "$(grep sessions "$TMP/curl.calls")"

# ── night run 2026-11-14: scan / launch / retro rows (the selector's island table) ──────────────
# Expected from the header contract: a title `<island> island:` or every Touches entry under
# islands/<island>/; the three rows sit after gateway and before agent-loop, so "scan island: …"
# is scan's though agent-loop's title row matches `^scan`; spanning two islands is nobody's.
section "selector issues — scan / launch / retro rows"
rm -f "$ISS.rows"
iss 41 "scan island: the doorbell row"           -                                              # scan title (not agent-loop's ^scan)
iss 42 "no title cue"                            "islands/scan/specs/scan-decision.md, islands/scan/README.md" # scan Touches
iss 43 "no title cue"                            "islands/launch/specs/x.md"                    # launch Touches
iss 44 "retro island: a gap"                     -                                              # retro title
iss 45 "no title cue, human"                     "islands/scan/a.md, islands/retro/b.md" '[]' "" "$HUMAN" # spans two → none
iss 46 "scan: a guard"                           -                                              # agent-loop title, as before
iss 47 "no title cue, human"                     "agents/x.sh, islands/scan/y.md" '[]' "" "$HUMAN"   # spans two → none
iss 48 "launch: no island suffix"                -              '[]' "" "$HUMAN"                 # `launch:` alone is no row → none
jq -s . "$ISS.rows" > "$ISS"
for row in "scan:41 42" "launch:43" "retro:44" "agent-loop:46" "gateway:"; do
  isl="${row%%:*}"; want="${row#*:}"; got="$(members "$isl")"
  [ "$got" = "$want" ] && ok "--island $isl selects '${want:-nothing}'" || bad "members $isl (new rows)" "want '$want' got '$got'"
done
allsel="$(for i in gateway scan launch retro router-pair mgmt-box dependency-upgrades substrate agent-loop; do
  INTAKE_ISSUES_JSON="$ISS" bash "$SEL" --island "$i" --json 2>/dev/null | jq -r '.[].number'; done | sort -n | tr '\n' ' ')"
[ "$allsel" = "41 42 43 44 46 " ] && ok "each issue on at most one island; #45 #47 (span two) and #48 (no row) on none" || bad "new-row exclusivity" "selected: $allsel"
TS3="$TMP/ts3"; mkdir -p "$TS3/homelab/dig-2026-10-26/r"
jq -n '{schema:"dig-finding/v1", verdict:"cause-found", cause:"c", evidence:["islands/scan/specs/scan-decision.md:12 (read)", "agents/coordinator-scan.sh:40 (read)"],
  recommendation:"r", pr:"", related:[], alerts:[], members:[]}' > "$TS3/homelab/dig-2026-10-26/r/finding-1.json"
got="$(for i in scan agent-loop; do INTAKE_TS_DIR="$TS3" INTAKE_NOW="$NOW" bash "$SEL" --source dig --island "$i" --out "$TMP/sel4.json" 2>/dev/null; printf '%s:%s ' "$i" "$(jq '.counts.inputs' "$TMP/sel4.json")"; done)"
[ "$got" = "scan:1 agent-loop:0 " ] && ok "dig: a finding citing islands/scan/ is scan's (text row before agent-loop's), once" || bad "dig scan row" "got $got"

# ── --source gaps ────────────────────────────────────────────────────────────────────────────────
# A private tree (the selector + the body parser + a fixture index) so the expectation never reads
# the live gateway index. Expected from the header contract: rows with `⚑ gap` or `🚧` whose first
# cell is `[REQ](page#…)`, minus APPLY-ruled ids and rows an open issue names (REQ in its
# title/body at a word boundary, or the row's own `#<n>` open), first INTAKE_GAP_MAX in index order.
section "selector --source gaps"
GT="$TMP/gtree"; mkdir -p "$GT/gateway/scripts" "$GT/gateway/specs" "$GT/agents"
cp "$SEL" "$GT/gateway/scripts/"; cp "$REPO/agents/issue_body.py" "$GT/agents/"
cat > "$GT/gateway/specs/README.md" <<'EOF'
# specs — fixture index
A prose line naming `⚑ gap` rows is not a row.
| Requirement | Page | What it pins | Status |
|---|---|---|---|
| [GW-A](endpoints/a.md#gw-a) | a | the a row · `⚑ gap`: one thing | ok |
| [GW-B](endpoints/b.md#gw-b) | b | the b row | 🚧 WIP — no evidence pipeline yet |
| [GW-C](endpoints/c.md#gw-c) | c | complete | ok |
| [GW-D](endpoints/d.md#gw-d) | d | `⚑ gap (2026-10-01, PR #5 → work #77)` | ok |
| [GW-E](endpoints/e.md#gw-e) | e | `⚑ gap`: named by an open issue | ok |
| [GW-EF](endpoints/ef.md#gw-ef) | ef | `⚑ gap`: "GW-E" and "GW-EFX" do not name it | ok |
| [GW-F](endpoints/f.md#gw-f) | f | `⚑ gap`: ruled by an apply receipt | ok |
| [GW-G](endpoints/g.md#gw-g) | g | `⚑ gap`: a dry-run receipt rules nothing | ok |
EOF
GISS="$TMP/gaps-issues.json"
jq -n '[{number:77, title:"work on d", body:"x", labels:[], comments:[]},
        {number:78, title:"an issue", body:"touches GW-E and GW-EFX", labels:[], comments:[]}]' > "$GISS"
TSG="$TMP/tsg"; mkdir -p "$TSG/homelab/intake-gateway-2026-10-20/a" "$TSG/homelab/intake-gateway-2026-10-21/b"
jq -n '{schema:"island-intake-receipt/v1", island:"gateway", mode:"apply", ts:"2026-10-20T05:00:00Z", session_ran:true,
  ruled:[{input:"gateway/specs/endpoints/f.md#GW-F", outcome:"standing", refs:[]}]}' > "$TSG/homelab/intake-gateway-2026-10-20/a/receipt.json"
jq -n '{schema:"island-intake-receipt/v1", island:"gateway", mode:"dry-run", ts:"2026-10-21T05:00:00Z", session_ran:true,
  ruled:[{input:"gateway/specs/endpoints/g.md#GW-G", outcome:"standing", refs:[]}]}' > "$TSG/homelab/intake-gateway-2026-10-21/b/receipt.json"
gaps() { INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" env "$@" bash "$GT/gateway/scripts/intake-select.sh" --source gaps --island gateway --out "$TMP/gsel.json" 2>"$TMP/gsel.err"; }
gaps; rc=$?
got="$(jq -r '[.inputs[].requirement] | join(" ")' "$TMP/gsel.json" 2>/dev/null)"
{ [ "$rc" = 0 ] && [ "$got" = "GW-A GW-B GW-EF GW-G" ]; } && ok "fires on GW-A (⚑) GW-B (🚧) GW-EF GW-G; not C (no mark), D (#77 open), E (named), F (apply-ruled)" \
  || bad "gaps selection" "rc=$rc got '$got' $(cat "$TMP/gsel.err")"
[ "$(jq -c '.counts' "$TMP/gsel.json")" = '{"rows":7,"ruled":1,"named":2,"over_cap":0,"inputs":4}' ] && ok "counts: 7 rows, 1 ruled, 2 named, 4 inputs" || bad "gaps counts" "$(jq -c .counts "$TMP/gsel.json")"
[ "$(jq -r '.inputs[0] | [.id, .kind, (.marks | join("+")), (.row | startswith("| [GW-A]"))] | @tsv' "$TMP/gsel.json")" = "$(printf 'gateway/specs/endpoints/a.md#GW-A\tgap\t⚑ gap\ttrue')" ] \
  && ok "an input is <specs page>#<REQ>, kind gap, its marks and the row verbatim" || bad "gap input shape" "$(jq -c '.inputs[0]' "$TMP/gsel.json")"
gaps INTAKE_GAP_MAX=2; [ "$(jq -r '[.inputs[].requirement] | join(" ")' "$TMP/gsel.json"):$(jq '.counts.over_cap' "$TMP/gsel.json")" = "GW-A GW-B:2" ] \
  && ok "INTAKE_GAP_MAX=2 → the first two in index order, over_cap 2 (they re-present tomorrow)" || bad "gap cap" "$(jq -c .counts "$TMP/gsel.json")"
INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" bash "$GT/gateway/scripts/intake-select.sh" --source gaps --island router-pair --out "$TMP/gsel.json" 2>/dev/null; rc=$?
{ [ "$rc" = 1 ] && jq -e '.specs_root == null and .counts.inputs == 0' "$TMP/gsel.json" >/dev/null; } && ok "an island with no specs root: a valid empty selection (exit 1)" || bad "gaps no root" "rc=$rc"
INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" bash "$GT/gateway/scripts/intake-select.sh" --source gaps --island scan --out "$TMP/gsel.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "a declared specs root whose index is missing (islands/scan/specs here) is a probe failure (exit 2)" || bad "gaps missing index" "rc=$rc"
gaps INTAKE_ISSUES_JSON="$TMP/nowhere.json"; rc=$?
[ "$rc" = 2 ] && ok "an unreadable issue list is exit 2 (it could not see which rows are named)" || bad "gaps issues rule #6" "rc=$rc"
gaps INTAKE_TS_DIR="$TMP/nowhere"; rc=$?
[ "$rc" = 2 ] && ok "an unreadable receipt store is exit 2" || bad "gaps bucket rule #6" "rc=$rc"

# ── --source escape ──────────────────────────────────────────────────────────────────────────────
# Expected from the header contract: issues of queue/goal/requeue lines (input or ref) in APPLY receipts
# of the last 30 d; PRs OPEN|MERGED, linked (closing ref / head `issue-<n>` / `Fixes|Closes #<n>` in the
# body), ≥ 1 CHANGES_REQUESTED, not already read by an APPLY receipt.
section "selector --source escape"
TSE="$TMP/tse"; mkdir -p "$TSE/homelab/intake-gateway-2026-10-20/a" "$TSE/homelab/intake-gateway-2026-10-21/b"
jq -n --arg h "$H" '{schema:"island-intake-receipt/v1", island:"gateway", mode:"apply", ts:"2026-10-20T05:00:00Z", run:"intake-gateway-2026-10-20/a", session_ran:true,
  ruled:[{input:($h+"#201"), outcome:"queue", refs:[($h+"#201")]}, {input:"dig-x/finding-1", outcome:"goal", refs:[($h+"#300"), ($h+"#301")]},
         {input:($h+"#202"), outcome:"requeue", refs:[]}, {input:($h+"#203"), outcome:"seat", refs:[($h+"#203")]}],
  escapes:[{pr:($h+"#400"), finding:"F1", class:"B", check:"the read set"}]}' > "$TSE/homelab/intake-gateway-2026-10-20/a/receipt.json"
jq -n --arg h "$H" '{schema:"island-intake-receipt/v1", island:"gateway", mode:"dry-run", ts:"2026-10-21T05:00:00Z", session_ran:true,
  ruled:[{input:($h+"#204"), outcome:"queue", refs:[($h+"#204")]}]}' > "$TSE/homelab/intake-gateway-2026-10-21/b/receipt.json"
pr() { # <n> <state> <head> <body> <closing-json> <review-states-json>
  jq -nc --argjson n "$1" --arg s "$2" --arg hd "$3" --arg b "$4" --argjson c "$5" --argjson r "$6" \
    '{number:$n, title:"t", state:$s, url:"u", headRefName:$hd, body:$b, closingIssuesReferences:($c | map({number:.})), reviews:($r | map({state:.}))}'
}
{ pr 501 OPEN   fix/a              "x"                     '[201]' '["COMMENTED","CHANGES_REQUESTED"]'   # in: closing ref
  pr 502 MERGED fix/issue-301-x    "x"                     '[]'    '["CHANGES_REQUESTED","APPROVED"]'    # in: a goal child by head
  pr 503 MERGED fix/b              "Fixes #202"            '[]'    '["APPROVED"]'                        # out: no CR
  pr 504 CLOSED fix/c              "Fixes #201"            '[]'    '["CHANGES_REQUESTED"]'               # out: closed unmerged
  pr 505 OPEN   fix/d              "Fixes #203"            '[]'    '["CHANGES_REQUESTED"]'               # out: #203 was seat
  pr 506 OPEN   fix/e              "Fixes #204"            '[]'    '["CHANGES_REQUESTED"]'               # out: a dry-run queued it
  pr 507 MERGED fix/issue-2010-y   "relates to #2010"      '[]'    '["CHANGES_REQUESTED"]'               # out: 2010 is not 201
  pr 508 MERGED fix/f              "Closes $H#202"         '[]'    '["CHANGES_REQUESTED"]'               # in: a requeue, full ref
} | jq -s . > "$TMP/prs.json"
esc() { INTAKE_PRS_JSON="${1:-$TMP/prs.json}" INTAKE_TS_DIR="$TSE" INTAKE_NOW="$NOW" bash "$SEL" --source escape --island gateway --out "$TMP/esel.json" 2>"$TMP/esel.err"; }
esc; rc=$?
got="$(jq -r '[.inputs[].number] | join(" ")' "$TMP/esel.json" 2>/dev/null)"
{ [ "$rc" = 0 ] && [ "$got" = "501 502 508" ]; } && ok "fires on #501 (closing ref) #502 (head issue-301, a Goal child) #508 (Closes, a requeue)" \
  || bad "escape selection" "rc=$rc got '$got' $(cat "$TMP/esel.err")"
[ "$(jq -c '[.inputs[] | select(.number == 502) | .id, .issue, .changes_requested][]' "$TMP/esel.json" | tr '\n' ' ')" = "\"$H#502\" \"$H#301\" 1 " ] \
  && ok "an input carries its id <owner/repo>#<pr>, the queued issue and the CR count" || bad "escape shape" "$(jq -c '.inputs[1]' "$TMP/esel.json")"
[ "$(jq -c '[.prior[].finding]' "$TMP/esel.json")" = '["F1"]' ] && ok "the receipts' escape records ride as prior (the prompt's escape-prior:)" || bad "escape prior" "$(jq -c .prior "$TMP/esel.json")"
mkdir -p "$TSE/homelab/intake-gateway-2026-10-26/c"
jq -n --arg h "$H" '{schema:"island-intake-receipt/v1", island:"gateway", mode:"apply", ts:"2026-10-26T05:00:00Z", session_ran:true,
  ruled:[{input:($h+"#501"), outcome:"read", refs:[]}, {input:($h+"#502"), outcome:"deferred", refs:[]}]}' > "$TSE/homelab/intake-gateway-2026-10-26/c/receipt.json"
esc; [ "$(jq -r '[.inputs[].number] | join(" ")' "$TMP/esel.json")" = "502 508" ] && ok "a PR an APPLY receipt read is not re-read; \`deferred\` re-presents" || bad "escape ledger" "got $(jq -c '[.inputs[].number]' "$TMP/esel.json")"
# an issue the sitting FILED from a gap:/text: input and ruled in the same pass (the launcher's
# ruled_filed, island-intake-argo.yaml §3): the input's line is `file`/`seat` naming it, its own line
# `queue` — queued by this island all the same, so its PR is read; a filed issue ruled `seat` is not
mkdir -p "$TSE/homelab/intake-gateway-2026-10-22/d"
jq -n --arg h "$H" '{schema:"island-intake-receipt/v1", island:"gateway", mode:"apply", ts:"2026-10-22T05:00:00Z", run:"intake-gateway-2026-10-22/d", session_ran:true,
  ruled:[{input:"gateway/specs/x.md#GW-X", outcome:"file", refs:[($h+"#210")]}, {input:"dig-y/finding-2", outcome:"seat", refs:[($h+"#211")]}],
  ruled_filed:[{input:($h+"#210"), outcome:"queue", refs:[($h+"#210")]}, {input:($h+"#211"), outcome:"seat", refs:[]}]}' > "$TSE/homelab/intake-gateway-2026-10-22/d/receipt.json"
{ pr 509 MERGED fix/g "Fixes #210" '[]' '["CHANGES_REQUESTED"]'   # in: filed + ruled queue in one sitting
  pr 510 OPEN   fix/h "Fixes #211" '[]' '["CHANGES_REQUESTED"]'   # out: filed, ruled seat
} | jq -s . > "$TMP/prs-filed.json"
esc "$TMP/prs-filed.json"
{ [ "$(jq -r '[.inputs[].number] | join(" ")' "$TMP/esel.json")" = "509" ] && [ "$(jq -r '.inputs[0].queued_by' "$TMP/esel.json")" = "intake-gateway-2026-10-22/d" ]; } \
  && ok "an issue filed and ruled queue in one sitting (receipt ruled_filed) is queued: its PR #509 is read; a filed seat (#510) is not" \
  || bad "escape filed queue" "got $(jq -c '[.inputs[] | {number, queued_by}]' "$TMP/esel.json") $(cat "$TMP/esel.err")"
esc "$TMP/nowhere.json"; rc=$?
[ "$rc" = 2 ] && ok "queued issues + an unreadable PR list → exit 2" || bad "escape rule #6" "rc=$rc"
TSE0="$TMP/tse0"; mkdir -p "$TSE0/homelab"
INTAKE_PRS_JSON="$TMP/nowhere.json" INTAKE_TS_DIR="$TSE0" INTAKE_NOW="$NOW" bash "$SEL" --source escape --island gateway --out "$TMP/esel.json" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "nothing queued → a valid empty selection and NO PR read (an unreadable list is never touched)" || bad "escape nothing queued" "rc=$rc"

# ── --source wait ────────────────────────────────────────────────────────────────────────────────
# Expected from the header contract (clock 2026-10-27T05:00Z, lookback 30 d → releases from 2026-09-27):
# parking = a comment whose marker is `blocked-on: human` (or a marker-less `intake: seat`); writer = intake
# (`intake:` first line, any login) | lane (a bot) | human; release = the first later non-seat `intake:`
# outcome or marker off human, an `agent/blocked` removal by a non-bot, or a close — `operator` for a non-bot
# login, `reread` for the bot's own `intake:`, `lane` for another bot. released = every parking released in
# the lookback (oldest release first); standing = an OPEN item's newest unreleased parking ≥ 3 d old that an
# APPLY receipt after it ruled `unchanged`, or an agent/blocked item with no parking comment; minus ids a
# receipt read; cap INTAKE_WAIT_MAX (6). stale = an OPEN item's marker target closed, or a `#<n>` its
# unreleased parking names closed AFTER it, minus a receipt that listed the item after the close.
section "selector --source wait"
WISS="$TMP/wait-items.json"; rm -f "$WISS.rows"; TSW2="$TMP/tsw2"; mkdir -p "$TSW2/homelab"
wc_() { jq -nc --arg b "$1" --arg d "$2" --arg l "$3" --argjson bot "$4" '{id: 1, createdAt: $d, body: $b, author: {login: $l, is_bot: $bot}}'; }
we_() { jq -nc --arg t "$1" --arg d "$2" --arg lab "$3" --arg l "$4" --argjson bot "$5" '{type: $t, createdAt: $d, label: (if $lab == "" then null else $lab end), actor: {login: $l, is_bot: $bot}}'; }
witem() { # <n> <title> <state> <labels-json> <comments-json> [events-json]
  jq -nc --argjson n "$1" --arg t "$2" --arg s "$3" --argjson l "$4" --argjson c "$5" --argjson e "${6:-[]}" \
    '{number: $n, title: $t, body: "free text", state: $s, createdAt: "2026-09-01T00:00:00Z", updatedAt: "2026-10-20T00:00:00Z",
      closedAt: null, author: {login: "app/homelab-agents-1234", is_bot: true}, labels: ($l | map({name: .})), comments: $c, events: $e}' >> "$WISS.rows"
}
B=homelab-agents-1234; OP=RasmusSoot
SEATH=$'intake: seat — needs the operator\nblocked-on: human'
witem 301 "gateway: released by the operator" OPEN '["agent-fix"]' "[$(wc_ "$SEATH" 2026-10-10T00:00:00Z $B true),$(wc_ 'intake: requeue — the fact moved' 2026-10-20T00:00:00Z $OP false)]"
witem 302 "gateway: parked twice, released by the re-read" OPEN '["agent-fix"]' \
  "[$(wc_ "$SEATH" 2026-10-05T00:00:00Z $B true),$(wc_ "$SEATH" 2026-10-08T00:00:00Z $B true),$(wc_ 'intake: queue — ruled afresh' 2026-10-15T00:00:00Z $B true)]"
witem 303 "gateway: standing, re-read unchanged" OPEN '["agent-fix","agent/blocked"]' "[$(wc_ "$SEATH" 2026-10-12T00:00:00Z $B true)]"
witem 304 "gateway: standing, never re-read" OPEN '["agent-fix","agent/blocked"]' "[$(wc_ "$SEATH" 2026-10-12T00:00:00Z $B true)]"
witem 305 "gateway: parked by a ride, label removed" OPEN '["agent-fix"]' "[$(wc_ $'the ride stopped\nblocked-on: human' 2026-10-10T00:00:00Z $B true)]" \
  "[$(we_ UnlabeledEvent 2026-10-21T00:00:00Z agent/blocked $OP false)]"
witem 306 "scan: another island's released wait" OPEN '[]' "[$(wc_ "$SEATH" 2026-10-10T00:00:00Z $B true),$(wc_ 'intake: requeue — x' 2026-10-20T00:00:00Z $OP false)]"
witem 307 "gateway: a wait already read" OPEN '[]' "[$(wc_ "$SEATH" 2026-10-09T00:00:00Z $B true),$(wc_ 'intake: close — done' 2026-10-19T00:00:00Z $B true)]"
witem 308 "gateway: stale marker" OPEN '["agent/blocked"]' "[$(wc_ $'intake: seat — waits on the view\nblocked-on: issue=900' 2026-10-15T00:00:00Z $B true)]"
witem 309 "gateway: names a PR that merged after" OPEN '[]' "[$(wc_ $'intake: seat — after #901 merges this is one ride\nblocked-on: human' 2026-10-10T00:00:00Z $B true)]"
witem 310 "gateway: names a PR that merged before" OPEN '[]' "[$(wc_ $'intake: seat — #902 shipped the rows; the ruling is open\nblocked-on: human' 2026-10-10T00:00:00Z $B true)]"
witem 311 "gateway: blocked, no comment" OPEN '["agent/blocked"]' '[]' "[$(we_ LabeledEvent 2026-10-15T00:00:00Z agent/blocked $B true)]"
witem 312 "gateway: closed by the operator" CLOSED '[]' "[$(wc_ "$SEATH" 2026-10-10T00:00:00Z $B true)]" "[$(we_ ClosedEvent 2026-10-12T00:00:00Z '' $OP false)]"
witem 313 "gateway: released before the lookback" OPEN '[]' "[$(wc_ "$SEATH" 2026-09-01T00:00:00Z $B true),$(wc_ 'intake: requeue — y' 2026-09-10T00:00:00Z $OP false)]"
witem 314 "gateway: a seat on an open issue" OPEN '["agent/blocked"]' "[$(wc_ $'intake: seat — waits on #950\nblocked-on: issue=950' 2026-10-10T00:00:00Z $B true)]"
# the FULL self-repo form names a target (#903) exactly as the short form does; another repo's ref (#904) is
# nobody's target here — the refs seam lacks 904, so reading it would be a loud exit 2
witem 315 "gateway: names the full form" OPEN '[]' "[$(wc_ $'intake: seat — after teststuffstash/homelab#903 merges (not other/repo#904)\nblocked-on: human' 2026-10-10T00:00:00Z $B true)]"
# a pile pr-hold (agent/review, its open PR parked on a human) whose issue's marker target closed: stale too
witem 316 "gateway: in review, PR parked, its marker target closed" OPEN '["agent-fix","agent/review"]' "[$(wc_ $'waiting on the catalog\nblocked-on: issue=905' 2026-10-15T00:00:00Z $B true)]"
jq -s . "$WISS.rows" > "$WISS"
WREFS="$TMP/wait-refs.json"
jq -n '{"900": {state: "CLOSED", closed_at: "2026-10-25T00:00:00Z"}, "901": {state: "MERGED", closed_at: "2026-10-25T00:00:00Z"},
        "902": {state: "MERGED", closed_at: "2026-10-05T00:00:00Z"}, "950": {state: "OPEN", closed_at: null},
        "903": {state: "MERGED", closed_at: "2026-10-25T00:00:00Z"}, "905": {state: "CLOSED", closed_at: "2026-10-25T00:00:00Z"}}' > "$WREFS"
wreceipt() { # <day> <run> <mode> <ts> <ruled-json>
  mkdir -p "$TSW2/homelab/intake-gateway-$1/$2"
  jq -n --arg m "$3" --arg ts "$4" --argjson r "$5" '{schema:"island-intake-receipt/v1", island:"gateway", mode:$m, ts:$ts, session_ran:true, inputs:[], ruled:$r,
    waits: [{wait: "prior", item: "x#1", class: "H", rules: [], writer: "intake"}]}' > "$TSW2/homelab/intake-gateway-$1/$2/receipt.json"
}
wreceipt 2026-10-22 a apply 2026-10-22T05:00:00Z "[{\"input\":\"$H#303\",\"outcome\":\"unchanged\",\"refs\":[]},{\"input\":\"$H#309\",\"outcome\":\"unchanged\",\"refs\":[]},
  {\"input\":\"$H#310\",\"outcome\":\"unchanged\",\"refs\":[]},{\"input\":\"$H#315\",\"outcome\":\"unchanged\",\"refs\":[]},{\"input\":\"$H#307@2026-10-09T00:00:00Z/released\",\"outcome\":\"read\",\"refs\":[]}]"
wreceipt 2026-10-23 b dry-run 2026-10-23T05:00:00Z "[{\"input\":\"$H#304\",\"outcome\":\"unchanged\",\"refs\":[]}]"
wsel() { INTAKE_ISSUES_JSON="$WISS" INTAKE_REFS_JSON="${WREFS_OVR:-$WREFS}" INTAKE_TS_DIR="$TSW2" INTAKE_NOW="$NOW" "$@" \
           bash "$SEL" --source wait --island "${WISL:-gateway}" --out "$TMP/wsel.json" 2>"$TMP/wsel.err"; }
wids() { jq -r '[.inputs[] | select(.kind == "wait") | (.id | sub("^[^#]*#"; "") | sub("T00:00:00Z"; ""))] | join(" ")' "$TMP/wsel.json"; }
wsel env INTAKE_WAIT_MAX=20; rc=$?
[ "$rc" = 0 ] && jq -e '.schema == "island-intake-select/v1" and .source == "wait"' "$TMP/wsel.json" >/dev/null \
  && ok "fires (exit 0) with one selection in the shared shape" || bad "wait fire" "rc=$rc $(cat "$TMP/wsel.err")"
# released by release time: #312 (close 10-12), #302 ×2 (10-15), #301 (10-20), #305 (10-21); standing by parking:
# #309 #310 #315 (10-10, re-read unchanged on 10-22), #303 (10-12, the same), #311 (10-15, label-only)
[ "$(wids)" = "312@2026-10-10/released 302@2026-10-05/released 302@2026-10-08/released 301@2026-10-10/released 305@2026-10-10/released 309@2026-10-10/standing 310@2026-10-10/standing 315@2026-10-10/standing 303@2026-10-12/standing 311@2026-10-15/standing" ] \
  && ok "released (oldest release first, one row per parking comment: #302 twice) then standing (#309 #310 #315 #303 re-read unchanged, #311 label-only)" \
  || bad "wait selection" "got: $(wids)"
case " $(wids) " in *" 304@"*|*" 306@"*|*" 307@"*|*" 313@"*|*" 314@"*)
    bad "wait negatives" "got: $(wids)";;
  *) ok "not: a standing wait no APPLY receipt re-read (#304, its receipt a dry-run), another island's (#306), one a receipt already read (#307), a release outside the lookback (#313), a seat whose marker is off human (#314)";;
esac
[ "$(jq -c '[.inputs[] | select(.kind == "wait" and (.number == 301 or .number == 302 or .number == 305 or .number == 312)) | [.number, .writer, .release, .release_via]] | unique' "$TMP/wsel.json")" \
  = '[[301,"intake","operator","comment"],[302,"intake","reread","comment"],[305,"lane","operator","label"],[312,"intake","operator","close"]]' ] \
  && ok "writer and release: the operator's login is \`operator\` whatever it wrote, the bot's own ruling is \`reread\`; a ride's stop is \`lane\`; a label removal and a close release too" \
  || bad "wait release kinds" "$(jq -c '[.inputs[] | select(.kind == "wait") | [.number, .writer, .release, .release_via]]' "$TMP/wsel.json")"
[ "$(jq -c '.inputs[] | select(.number == 311) | [.writer, .parked_at, .unchanged_reads]' "$TMP/wsel.json")" = '["lane","2026-10-15T00:00:00Z",0]' ] \
  && [ "$(jq -c '.inputs[] | select(.number == 303) | [.parked_at, .unchanged_reads, has("days_parked")]' "$TMP/wsel.json")" = '["2026-10-12T00:00:00Z",1,false]' ] \
  && ok "a row carries the parking TIMESTAMP (never days parked); a label-only wait is dated and authored by its label event" \
  || bad "wait row shape" "$(jq -c '.inputs[] | select(.number == 311 or .number == 303)' "$TMP/wsel.json")"
[ "$(jq -r '[.inputs[] | select(.kind == "reread") | "\(.number):\(.stale.target):\(.stale.target_state)"] | join(" ")' "$TMP/wsel.json")" = "308:900:CLOSED 309:901:MERGED 315:903:MERGED 316:905:CLOSED" ] \
  && ok "stale: a marker target closed (#308 → issue=900, #316 → issue=905), a #<n> the parking named merged AFTER it (#309 → #901, though a receipt ruled it unchanged before the merge; #315 → the full form teststuffstash/homelab#903, never other/repo#904); not #310 (#902 merged before), not #314 (#950 open)" \
  || bad "wait stale" "$(jq -c '[.inputs[] | select(.kind == "reread")]' "$TMP/wsel.json")"
jq -e '[.inputs[] | select(.kind == "reread") | .id] == ["'"$H"'#308", "'"$H"'#309", "'"$H"'#315", "'"$H"'#316"]' "$TMP/wsel.json" >/dev/null \
  && ok "…a stale row carries the pile's id (<owner/repo>#<n>) so its ruling is the re-read's receipt line" || bad "stale id" "$(jq -c '[.inputs[] | select(.kind == "reread") | .id]' "$TMP/wsel.json")"
[ "$(jq -c '[(.prior | length), .counts.read]' "$TMP/wsel.json")" = '[1,1]' ] \
  && ok "the APPLY receipts' wait records ride as prior (the ledger's input); the read wait counts as read" || bad "wait prior" "$(jq -c '{p: .prior, c: .counts}' "$TMP/wsel.json")"
wsel; [ "$(jq -c '[.counts.waits, .counts.over_cap, .counts.stale, .counts.inputs]' "$TMP/wsel.json")" = '[6,4,4,10]' ] \
  && [ "$(wids)" = "312@2026-10-10/released 302@2026-10-05/released 302@2026-10-08/released 301@2026-10-10/released 305@2026-10-10/released 309@2026-10-10/standing" ] \
  && ok "INTAKE_WAIT_MAX (default 6) caps the waits, released first; stale rows are not capped" || bad "wait cap" "$(jq -c .counts "$TMP/wsel.json") $(wids)"
wreceipt 2026-10-26 c apply 2026-10-26T05:00:00Z "[{\"input\":\"$H#308\",\"outcome\":\"unchanged\",\"refs\":[]}]"
wsel; [ "$(jq -r '[.inputs[] | select(.kind == "reread") | .number] | join(" ")' "$TMP/wsel.json")" = "309 315 316" ] \
  && ok "a receipt that listed the item AFTER its target closed ends the stale re-read (#308)" || bad "stale ledger" "$(jq -c '[.inputs[] | select(.kind == "reread")]' "$TMP/wsel.json")"
rm -rf "$TSW2/homelab/intake-gateway-2026-10-26"
WISL=agent-loop wsel; [ "$(wids)" = "306@2026-10-10/released" ] && ok "another island's wait is that island's (#306 → agent-loop)" || bad "wait island" "got: $(wids)"
jq '{"900": .["900"], "901": .["901"]}' "$WREFS" > "$TMP/wrefs-short.json"
WREFS_OVR="$TMP/wrefs-short.json" wsel; rc=$?
[ "$rc" = 2 ] && ok "a target state that cannot be read is a probe failure (exit 2), never \"still open\"" || bad "wait refs probe" "rc=$rc"
INTAKE_ISSUES_JSON="$TMP/nowhere.json" INTAKE_TS_DIR="$TSW2" INTAKE_NOW="$NOW" bash "$SEL" --source wait --out "$TMP/x.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "…and so is an unreadable item list" || bad "wait items probe" "rc=$rc"
INTAKE_ISSUES_JSON="$WISS" INTAKE_TS_DIR="$TMP/nowhere" INTAKE_NOW="$NOW" bash "$SEL" --source wait --out "$TMP/x.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "…and an unreadable receipt store" || bad "wait bucket probe" "rc=$rc"
# the pile's re-read ledger, same fixture: #309 (latest ruling seat) was ruled `unchanged` 5 d ago (hidden for
# INTAKE_REREAD_EVERY_D = 7) — but #901, named in its parking comment, merged AFTER that receipt, so the receipt
# no longer hides it; #310's #902 merged BEFORE its receipt, so #310 stays hidden
INTAKE_ISSUES_JSON="$WISS" INTAKE_REFS_JSON="$WREFS" INTAKE_TS_DIR="$TSW2" INTAKE_NOW="$NOW" bash "$SEL" --source pile --island gateway --out "$TMP/wpile.json" 2>"$TMP/wpile.err"
{ jq -e '[.inputs[] | select(.number == 309) | .stale.target] == [901]' "$TMP/wpile.json" >/dev/null \
    && jq -e '[.inputs[] | select(.number == 315) | .stale.target] == [903]' "$TMP/wpile.json" >/dev/null \
    && ! jq -e '.inputs[] | select(.number == 310)' "$TMP/wpile.json" >/dev/null && ! jq -e '.inputs[] | select(.number == 303)' "$TMP/wpile.json" >/dev/null; } \
  && ok "pile: a receipt that ruled a wait unchanged BEFORE its named target merged does not hide it (#309 → #901; #315 → the full form teststuffstash/homelab#903, the wait source's reader); #310 and #303 stay hidden" \
  || bad "pile stale ledger" "$(jq -c '[.inputs[] | select(.kind == "reread") | {number, stale}]' "$TMP/wpile.json") $(head -c 300 "$TMP/wpile.err")"

# the workflow: the wait source rides the SAME sitting — wait inputs in the brief, INTAKE-WAIT lines joined
# to their rows in the receipt, the ledger's bar decides which proposal is kept, and the gauges
section "island-intake-argo.yaml — the wait read rides the same sitting"
KEY_WORDS="3. **Does it need a human fact?** The body"
cat > "$TMP/claude.out" <<EOF
## Wait records
### wait $H#301 @ 2026-10-10T00:00:00Z  writer: intake
class: R
INTAKE-WAIT: {"wait": "$H#301@2026-10-10T00:00:00Z/released", "class": "R", "rules": [{"file": "gateway/intake.md", "mark": "caused", "words": "$KEY_WORDS"}], "direction": "narrow-stall", "widens": true, "fact": "on the page"}
INTAKE-WAIT: {"wait": "$H#302@2026-10-05T00:00:00Z/released", "class": "R", "rules": [{"file": "gateway/intake.md", "mark": "caused", "words": "3. Does it need a human fact? The body"}], "direction": "narrow-stall", "widens": false}
INTAKE-WAIT: {"wait": "$H#305@2026-10-10T00:00:00Z/released", "class": "R", "rules": [{"file": "gateway/intake.md", "mark": "caused", "words": "$KEY_WORDS"}], "direction": "none", "widens": false}
INTAKE-WAIT: {"wait": "$H#312@2026-10-10T00:00:00Z/released", "class": "H", "rules": [{"file": "gateway/intake.md", "mark": "caused", "words": "- Operator-only, not yours to reason around:"}], "direction": "none", "widens": false}
INTAKE-WAIT: {"wait": "$H#999@2026-10-10T00:00:00Z/released", "class": "R", "rules": []}
INTAKE-WAIT: {"wait": "$H#309@2026-10-10T00:00:00Z/standing", "class": "Q", "rules": []}
INTAKE-WAIT: {"wait": "$H#310@2026-10-10T00:00:00Z/standing", "class": "R" BROKEN
INTAKE-WAIT: not json at all
INTAKE-WAIT: {"wait": "$H#311@2026-10-15T00:00:00Z/standing", "class": "U", "rules": ["a string, not an object"]}
## Wait proposals
INTAKE-WAIT-PROPOSAL: {"file": "gateway/intake.md", "mark": "caused", "words": "$KEY_WORDS", "diff": "-old\n+new", "widens_authority": false}
INTAKE-WAIT-PROPOSAL: {"file": "gateway/intake.md", "mark": "missing", "words": "## Hard limits", "diff": "+x"}
INTAKE-WAIT-PROPOSAL: {"file": "gateway/intake.md", "diff": "+y" BROKEN
## Facts I lacked
INTAKE-RULED: $H#301@2026-10-10T00:00:00Z/released read -
INTAKE-RULED: $H#302@2026-10-05T00:00:00Z/released read -
INTAKE-RULED: $H#308 unchanged -
EOF
# #316 is a pile pr-hold (agent/review; its open PR #920's newest marker is blocked-on: human) AND stale
jq -n '[{number: 920, state: "OPEN", headRefName: "fix/issue-316-x", body: "", closingIssuesReferences: [],
         comments: [{body: "blocked-on: human", createdAt: "2026-10-20T00:00:00Z"}]}]' > "$TMP/wait-prs.json"
WAIT_MAX=6 PILE_JSON="$WISS" PRS_JSON="$TMP/wait-prs.json" REFS_JSON="$WREFS" TS="$TSW2" RUN_ENV="PUSHGATEWAY=http://pgw INTAKE_PR_HOLDS=1" run_script apply; rc=$?
{ [ "$rc" = 0 ] && grep -q '^wait:$' "$TMP/up/brief.md" && grep -qF "\"id\": \"$H#302@2026-10-08T00:00:00Z/released\"" "$TMP/up/brief.md" \
    && grep -qF 'step W' "$TMP/up/brief.md" && grep -qF '"stale": {' "$TMP/up/brief.md"; } \
  && ok "the brief lists \`wait:\` (one row per parking comment) and the stale re-reads under \`reread:\`" || bad "wait brief" "rc=$rc $(tail -3 "$TMP/run.log")"
# the merge keeps the PILE row (its `wait` and `pr`) and adds only `stale`: #309 stays `seat`, #316 `pr-hold` (PR #920);
# #315 is the pile's seat too; #308 (agent/blocked + an issue marker) is the pile's `agent/blocked`
[ "$(jq -c '[.counts.waits, .counts.stale]' "$TMP/up/inputs.json" 2>/dev/null)" = '[6,4]' ] \
  && [ "$(jq '[.inputs[] | select(.id == "'"$H"'#309" or .id == "'"$H"'#316")] | length' "$TMP/up/inputs.json")" = 2 ] \
  && [ "$(jq -c '[.inputs[] | select(.kind == "reread" and .stale != null) | [.number, .wait, .stale.target, (.pr // null)]] | sort' "$TMP/up/inputs.json")" \
       = '[[308,"agent/blocked",900,null],[309,"seat",901,null],[315,"seat",903,null],[316,"pr-hold",905,920]]' ] \
  && ok "inputs.json: 6 waits + 4 stale; a stale wait the pile also re-reads is ONE input — the pile's \`wait\` kept (seat, agent/blocked, pr-hold with its PR), only \`stale\` added" \
  || bad "wait merge" "$(jq -c '[.counts, [.inputs[] | select(.kind == "reread") | [.number, .wait, .stale.target, .pr]]]' "$TMP/up/inputs.json" 2>/dev/null)"
[ "$(jq '.counts.inputs as $n | [.counts.dig, .counts.members, .counts.rereads, .counts.gaps, .counts.escapes, .counts.waits, .counts.stale] | add == $n' "$TMP/up/inputs.json")" = true ] \
  && ok "the source split is disjoint: dig + member + reread + gap + escape + wait + stale = inputs" || bad "split sum" "$(jq -c .counts "$TMP/up/inputs.json")"
{ jq -e '.wait_lines_dropped.count == 5 and ([.wait_lines_dropped.samples[].reason] | sort) == ["invalid","invalid","invalid","unparseable","unparseable"]' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.wait_ledger.unparseable.proposals.count == 1' "$TMP/up/receipt.json" >/dev/null; } \
  && ok "malformed model lines are skipped and counted with samples (5 INTAKE-WAIT: two unparseable, an unknown wait id, an unknown class, a bad rule entry; 1 proposal) — the valid lines beside them survive (next rows)" \
  || bad "wait malformed lines" "$(jq -c '{wait_lines_dropped, u: .wait_ledger.unparseable}' "$TMP/up/receipt.json" 2>/dev/null)"
[ "$(jq -c '[.waits[] | [.number, .class, .writer, .release]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[[301,"R","intake","operator"],[302,"R","intake","reread"],[305,"R","lane","operator"],[312,"H","intake","operator"]]' ] \
  && ok "receipt.waits: each INTAKE-WAIT joined to its selector row (writer, release from the selector); an unknown wait id and an unknown class dropped" \
  || bad "wait receipt" "$(jq -c '.waits' "$TMP/up/receipt.json" 2>/dev/null)"
# the bar: #301 and #302 (intake, R) name the same line → 2 distinct items; #305 is a ride's wait (not tallied)
# (the key: file|mark|first eight words, markdown and punctuation stripped — intake-wait-ledger.py's norm_words)
{ jq -e '.wait_ledger.at_bar == ["gateway/intake.md|caused|3 does it need a human fact the"] and .wait_ledger.false_waits == {records: 2, items: 2}' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.wait_proposals | length == 1 and .[0].items == ["'"$H"'#301", "'"$H"'#302"] and .[0].widens_authority == true' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.wait_proposals_dropped[0] == {key: "gateway/intake.md|missing|hard limits", reason: "not at the bar"} and .wait_proposals_dropped[1].reason == "unparseable"' "$TMP/up/receipt.json" >/dev/null; } \
  && ok "the ledger: the key at the bar (two intake items; the ride's #305 not counted), its proposal kept with the ledger's items and widens; one below the bar dropped" \
  || bad "wait ledger in receipt" "$(jq -c '{wait_ledger, wait_proposals, wait_proposals_dropped}' "$TMP/up/receipt.json" 2>/dev/null)"
grep -q '^## Wait records' <(jq -r '.wait_records' "$TMP/up/receipt.json" 2>/dev/null) && [ -s "$TMP/up/wait-ledger.json" ] \
  && ok "the report's \`## Wait records\` section rides the receipt verbatim; wait-ledger.json is uploaded beside it" || bad "wait records md" "$(jq -c .wait_records "$TMP/up/receipt.json" 2>/dev/null | head -c 200)"
{ grep -qx 'island_intake_source_inputs{source="wait"} 6' "$TMP/pgw.body" && grep -qx 'island_intake_source_inputs{source="stale"} 4' "$TMP/pgw.body" \
    && grep -qx 'island_intake_wait_records{class="R"} 2' "$TMP/pgw.body" && grep -qx 'island_intake_wait_records{class="H"} 1' "$TMP/pgw.body" \
    && grep -qx 'island_intake_false_waits 2' "$TMP/pgw.body" && grep -qx 'island_intake_false_wait_items 2' "$TMP/pgw.body"; } 2>/dev/null \
  && ok "gauges: wait/stale inputs, records by class (intake-written: R=2 H=1), the false-wait KPI (2) and its distinct items" \
  || bad "wait gauges" "$(grep -e wait -e stale "$TMP/pgw.body" 2>/dev/null | tr '\n' ' ')"
rm -f "$TMP/pgw.body"
mkdir -p "$TSW2/homelab/intake-gateway-2026-10-27/r"; cp "$TMP/up/receipt.json" "$TSW2/homelab/intake-gateway-2026-10-27/r/"
wsel env INTAKE_WAIT_MAX=20
case " $(wids) " in *" 301@"*|*" 302@2026-10-05"*) bad "wait round trip" "got: $(wids)";;
  *) [ "$(jq -c '.prior | length' "$TMP/wsel.json")" = 5 ] && ok "…and the next selection reads that receipt back: the read waits are not offered again; its records join prior" \
       || bad "wait round trip prior" "$(jq -c '.prior | length' "$TMP/wsel.json")";;
esac
rm -rf "$TSW2/homelab/intake-gateway-2026-10-27"

# the ledger and the recorded wait cases: each script's own self-test (planted defects through its real
# functions), then the committed cases validated strictly, rules commits included
section "the wait ledger and the recorded wait cases"
python3 -I "$REPO/gateway/scripts/intake-wait-ledger.py" --self-test > "$TMP/ledger-st.log" 2>&1 \
  && ok "intake-wait-ledger.py --self-test" || bad "ledger self-test" "$(grep -e FAIL "$TMP/ledger-st.log" | head -5)"
python3 -I "$REPO/gateway/scripts/intake-wait-cases.py" --self-test > "$TMP/cases-st.log" 2>&1 \
  && ok "intake-wait-cases.py --self-test" || bad "cases self-test" "$(grep -e FAIL "$TMP/cases-st.log" | head -5)"
python3 -I "$REPO/gateway/scripts/intake-wait-cases.py" --git validate > "$TMP/cases.log" 2>&1 \
  && grep -q '10 case(s) valid (train 7, heldout 3), 0 error' "$TMP/cases.log" \
  && ok "the ten recorded wait cases validate (train 7, held out 3; rules commits checked unless the checkout is shallow)" || bad "wait cases" "$(tail -5 "$TMP/cases.log")"

# ── the workflow's review stage, run (gateway/intake.md §Review and repair) ─────────────────────
# Stubs: `claude` answers per session (author / unit lens / rows pass 1 / rows pass 2 / repair, told
# apart by the prompt) and writes each lens's ONE file where its prompt says; `gh` records. The
# expectations come from the launcher's contract in the manifest header + §Review and repair:
# lenses run confined (env -i, Read scoped to the case dir, Write to one file), the rows lens sees
# only masked/ + process/ on pass 1, an empty Pass 1 is re-run once, the repair answers by id, the
# launcher's belt labels what the repair left unlabelled, a failed lens never holds the queue.
section "island-intake-argo.yaml — review and repair"
RBIN="$TMP/rbin"; mkdir -p "$RBIN"
cat > "$RBIN/claude" <<EOF
#!/bin/bash
T="$TMP"
p=""; prev=""; allow=""; inallow=0; for a in "\$@"; do
  [ "\$prev" = -p ] && case "\$a" in --*) ;; *) p="\$a";; esac
  case "\$a" in --allowedTools) inallow=1;; --*) inallow=0;; *) [ "\$inallow" = 1 ] && allow="\$allow \$a";; esac
  prev="\$a"; done
[ -n "\$p" ] || p="\$(cat)"   # \`claude -p\` with no prompt argument reads it from stdin (the repair's brief)
case "\$p" in
  *"REPAIR PASS"*) s=repair;; *"ISLAND INTAKE sitting"*) s=author;; *"Unit review"*) s=unit;;
  *"PASS 1 of a staged read"*) s=pass1;; *"PASS 2 of a staged read"*) s=pass2;; *) s=other;;
esac
echo "\$s cwd=\$PWD gh_token=\${GH_TOKEN:+set} allow=\$allow" >> "\$T/r.calls"
printf '%s' "\$p" > "\$T/prompt-\$s.txt"
out="\$(printf '%s' "\$p" | grep -oE '/[^ ]*/review/out/[a-z]+-[0-9]+\.md' | head -1)"
case "\$s" in
  author) mkdir -p "\$T/run/review/issues"; cp "\$T/body-9.md" "\$T/run/review/issues/9.md"; cat "\$T/r-author.out";;
  unit)   [ -f "\$T/unit-fail" ] || cp "\$T/r-unit.md" "\$out"; echo '{"result":"done"}';;
  pass1)  if [ -f "\$T/pass1-empty-once" ]; then rm -f "\$T/pass1-empty-once"; printf 'specs review\n## Pass 1 (frozen)\n\n' > "\$out"
          else printf 'specs review, pre-queue: CHANGES_REQUESTED — #9\n## Pass 1 (frozen)\n- 9/r1.1 — check 10 — the cells do not place it\n' > "\$out"; fi
          ls -R "\$PWD" > "\$T/pass1-world.txt"; echo '{"result":"p1"}';;
  pass2)  printf '\n## Findings\n| id | posture | finding | evidence | fate | by |\n|---|---|---|---|---|---|\n| R10/9/r1.1 | BLOCKING | the row cannot be placed | q | survives | x |\n' >> "\$out"; echo '{"result":"p2"}';;
  repair) cat "\$T/r-repair.out"; if [ -f "\$T/repair-fail" ]; then exit 1; fi;;
esac
EOF
cat > "$RBIN/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$TMP/gh.calls"
case "\$1 \$2" in
  "issue view") case "\$*" in *labels,comments*) cat "$TMP/gh-view.json" 2>/dev/null;; *title,body*) cat "$TMP/body-9.md";; esac;;
  "issue comment") prev=""; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" >> "$TMP/gh.comments"; prev="\$a"; done;;
esac
exit 0
EOF
chmod +x "$RBIN"/*
SN="$TMP/snip/allure_behavior_snippets"; mkdir -p "$SN/process/briefs"; : > "$SN/__init__.py"; echo "# RULES" > "$SN/process/RULES.md"
cat > "$SN/evidence.py" <<'EOF'
# a stand-in for the pinned mask_page: description column → r<t>.<r>, header → row
def mask_page(text):
    out, keys, t, lines, i = [], [], 0, text.split("\n"), 0
    while i < len(lines):
        cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
        if lines[i].lstrip().startswith("|") and cells and cells[0] == "description":
            t += 1; out += ["| row |" + lines[i].split("|", 2)[2], lines[i + 1]]; i += 2; r = 0
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                r += 1; c = [x.strip() for x in lines[i].strip().strip("|").split("|")]
                keys.append((f"r{t}.{r}", c[0])); out.append(f"| r{t}.{r} |" + lines[i].split("|", 2)[2]); i += 1
            continue
        out.append(lines[i]); i += 1
    return "\n".join(out), keys
EOF
cat > "$TMP/body-9.md" <<'EOF'
---
Touches: gateway/specs/endpoints/sessions.md
---
## Deliverable
the thing
## Acceptance
1. GW-X row 1
## Spec changes
| description | world | input || expected? |
|---|---|---||---|
| "SECRET-DESCRIPTION the happy path" | w | a || b |
## Out of scope
none
EOF
cat > "$TMP/r-unit.md" <<'EOF'
unit review: CHANGES_REQUESTED — #9
| id | issue(s) | BLOCKING / advisory | finding (one sentence) | evidence | what would clear it |
|---|---|---|---|---|---|
| U1 | #9 | BLOCKING | the acceptance cannot pass | a ↔ b | c |
| U2 | #9 | advisory | a wording nit | a ↔ b | c |
EOF
cat > "$TMP/r-author.out" <<EOF
… the first pass …
## Review units
- unit: $H#9 base=$(git -C "$REPO" rev-parse HEAD)
- rows: $H#9 base=$(git -C "$REPO" rev-parse HEAD)
- unit: $H#999 base=$(git -C "$REPO" rev-parse HEAD)
INTAKE-RULED: dig-2026-10-26/$R2/finding-2 queue $H#9
INTAKE-RULED: dig-2026-10-25/$R1/finding-2 standing -
INTAKE-HOLD: $H#9 add=agent-fix,task/fix,agent/queued,agent/approved
INTAKE-HOLD: $H#999 add=agent/queued
EOF
cat > "$TMP/r-repair.out" <<'EOF'
INTAKE-REPAIR: unit#0:U1 changed fixed the acceptance
INTAKE-REPAIR: rows#1:R10/9/r1.1 declined the row is right
EOF
review_run() { # <mode> [env…]
  rm -f "$TMP/r.calls" "$TMP/gh.calls" "$TMP/gh.comments" "$TMP"/prompt-*.txt
  RUN_PATH="$RBIN:$BIN" RUN_ENV="INTAKE_SNIPPETS_DIR=$TMP/snip ${*:2}" run_script "$1"
}
rm -rf "$TS/homelab/intake-gateway-2026-10-27"
gview() { # <labels-json> <comment bodies…> — the issue as the belt reads it back; comments dated inside this run
  local l="$1"; shift; jq -n --argjson l "$l" '{labels: ($l | map({name: .})), comments: [$ARGS.positional[] | {body: ., createdAt: "2099-01-01T00:00:00Z"}]}' --args "$@" > "$TMP/gh-view.json"; }
touch "$TMP/pass1-empty-once"; gview '[]' "intake: review — 3 findings: 1 changed, 1 declined" "intake: queue — one ride"   # the repair posted, but did not label
review_run apply; rc=$?
[ "$rc" = 0 ] && ok "apply run with review-repair exits 0" || bad "review run" "rc=$rc $(tail -5 "$TMP/run.log")"
[ "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')" = "author unit pass1 pass1 pass2 repair " ] \
  && ok "sessions: author → unit lens → rows pass 1 (empty → re-run once) → pass 2 → ONE repair" || bad "session order" "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')"
grep -q "INTAKE-HOLD" "$TMP/prompt-author.txt" && grep -q "review: review-repair" "$TMP/prompt-author.txt" && grep -qF '`## Review units`' "$TMP/prompt-author.txt" \
    && grep -q 'An issue you FILED this sitting' "$TMP/prompt-author.txt" \
  && ok "the author is told: review-repair, Review units, INTAKE-HOLD, a filed issue's own ruling line" || bad "author prompt" "$(grep -n REVIEW "$TMP/prompt-author.txt")"
line="$(grep '^unit ' "$TMP/r.calls")"
case "$line" in *"cwd=$TMP/run/review/case-unit-0 gh_token= "*"Read(/$TMP/run/review/case-unit-0/**)"*"Bash(git -C $TMP/work/homelab show:*)"*"Edit(/$TMP/run/review/out/unit-0.md)"*) ok "unit lens: cwd = its case dir, no token, Read scoped to it, git show on the clone at the base, Edit = its one file";;
  *) bad "unit confinement" "$line";; esac
[ "$(grep -c '^unit ' "$TMP/r.calls")" = 1 ] && ok "a unit line whose issue no queue/goal ruling names (#999) gets no lens" || bad "forged unit" "$(grep -c '^unit ' "$TMP/r.calls")"
{ grep -q 'r1.1' "$TMP/pass1-world.txt" 2>/dev/null || grep -q '9.md' "$TMP/pass1-world.txt"; } && ! grep -q 'issues' "$TMP/pass1-world.txt" \
  && ! grep -rq SECRET-DESCRIPTION "$TMP/run/review/rows-pass1-1/" && grep -q '| r1.1 |' "$TMP/run/review/rows-pass1-1/masked/9.md" \
  && ok "rows pass 1 sees masked/ + process/ only: the description is keyed (r1.1), the body is out of reach" || bad "pass 1 world" "$(cat "$TMP/pass1-world.txt" | head -12)"
grep -q "^pass2 cwd=$TMP/run/review/case-rows-1 gh_token= .*Bash(git -C $TMP/work/homelab show:\*)" "$TMP/r.calls" && ok "rows pass 2 runs in its case dir, the base through git -C, no token" || bad "pass 2" "$(grep pass2 "$TMP/r.calls")"
grep -q -- '- 9/r1.1' "$TMP/run/review/out/rows-1.md" && grep -q 'R10/9/r1.1' "$TMP/run/review/out/rows-1.md" \
  && ok "the rows file keeps its frozen Pass 1 and gains pass 2's findings" || bad "rows file" "$(cat "$TMP/run/review/out/rows-1.md")"
grep -q 'LENS FINDINGS FILE: unit-0.md' "$TMP/prompt-repair.txt" && grep -q 'LENS FINDINGS FILE: rows-1.md' "$TMP/prompt-repair.txt" && grep -q 'Review units' "$TMP/prompt-repair.txt" \
    && grep -q 'unit#0:U1' "$TMP/prompt-repair.txt" \
  && ok "the repair prompt (on stdin) carries the first-pass report, every lens's findings file and the keyed ids" || bad "repair prompt" "$(grep -c FINDINGS "$TMP/prompt-repair.txt")"
[ "$(jq -c '[.findings[] | [.id, .lens, .posture, .fate]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["rows#1:R10/9/r1.1","rows","blocking","declined"],["unit#0:U1","unit","blocking","changed"],["unit#0:U2","unit","advisory","unanswered"]]' ] \
  && ok "receipt: one record per finding, keyed <lens>#<unit>:<id> (two units' U1 never collide) — lens, posture, changed/declined/unanswered" || bad "receipt findings" "$(jq -c .findings "$TMP/up/receipt.json" 2>/dev/null)"
[ "$(jq -c '[.review.lenses[] | [.lens, .status, .runs]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["unit","ran",1],["rows","ran",2]]' ] && jq -e '.review.repair.status == "ran" and .review.held == ["'"$H"'#9"]' "$TMP/up/receipt.json" >/dev/null \
  && ok "receipt: each lens's status and runs, the repair, the held set (#999 forged → dropped)" || bad "receipt review" "$(jq -c .review "$TMP/up/receipt.json" 2>/dev/null)"
grep -qF "gh api -X POST repos/$H/issues/9/labels -f labels[]=agent-fix -f labels[]=task/fix -f labels[]=agent/queued" "$TMP/gh.calls" && ! grep -q 'agent/approved' "$TMP/gh.calls" && ! grep -q 'issues/999' "$TMP/gh.calls" \
  && ok "the belt labels #9 the repair left unlabelled — brief labels only (agent/approved dropped), no forged ref" || bad "belt labels" "$(grep labels "$TMP/gh.calls")"
[ ! -s "$TMP/gh.comments" ] && ok "…and posts no comment the repair already posted in this run" || bad "belt comments" "$(cat "$TMP/gh.comments")"
grep -q '/coordinate' "$TMP/curl.calls" && ok "the queue rings /coordinate after the labels" || bad "review ring" "$(cat "$TMP/curl.calls")"

gview '["agent-fix","task/fix","agent/queued"]' "intake: review — x" "intake: queue — y"
review_run apply
! grep -q '/labels' "$TMP/gh.calls" && ok "an issue the repair already labelled is left alone" || bad "belt idempotent" "$(grep labels "$TMP/gh.calls")"

gview '[]'; touch "$TMP/unit-fail" "$TMP/repair-fail"
review_run apply
{ jq -e '[.review.lenses[] | select(.lens == "unit")][0] | .status == "skipped: failed twice (no findings file)" and .runs == 2' "$TMP/up/receipt.json" >/dev/null \
  && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls" && head -1 "$TMP/gh.comments" | grep -q '^intake: review — 1 findings: 0 changed, 0 declined' \
  && grep -q '^unit review skipped' "$TMP/gh.comments" && tail -1 "$TMP/gh.comments" | grep -q '^intake: queue — queued as authored'; } \
  && ok "a unit lens that writes no file twice + a repair that fails: still labelled; review comment (skipped line) first, ruling LAST" \
  || bad "lens failure" "$(jq -c .review "$TMP/up/receipt.json" 2>/dev/null) | $(cat "$TMP/gh.comments" 2>/dev/null)"
rm -f "$TMP/unit-fail" "$TMP/repair-fail"

gview '[]' "intake: review — 3 findings: 1 changed, 1 declined"; touch "$TMP/repair-fail"   # the repair posted its review comment, then died
review_run apply
{ [ "$(grep -c '^intake: review' "$TMP/gh.comments" 2>/dev/null || true)" = 0 ] && grep -q '^intake: queue — queued as authored' "$TMP/gh.comments" \
    && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls"; } \
  && ok "a repair that posted its review comment and died: the belt adds labels + the ruling, never a second review comment" \
  || bad "belt partial" "$(cat "$TMP/gh.comments" 2>/dev/null)"
rm -f "$TMP/repair-fail"

# a queue ruling in place (refs \`-\`): its INPUT is the held issue (the contract allows refs \`-\`)
sed -i "s|^INTAKE-RULED: dig-2026-10-26/$R2/finding-2 queue $H#9\$|INTAKE-RULED: $H#9 queue -|" "$TMP/r-author.out"
PILE9="$TMP/pile9.json"; jq -n '[{number:9, title:"gateway: in place", body:"x", labels:[], createdAt:"2026-10-20T00:00:00Z", updatedAt:"2026-10-20T00:00:00Z", author:{login:"rsoot"}, comments:[]}]' > "$PILE9"
gview '[]'; PILE_JSON="$PILE9" review_run apply
{ jq -e '.review.held == ["'"$H"'#9"] and (.review.units | length == 2)' "$TMP/up/receipt.json" >/dev/null 2>&1 && grep -q '^unit ' "$TMP/r.calls"; } \
  && ok "a queue ruled in place (refs -) is held and reviewed through its input id" || bad "hold by input" "$(jq -c .review "$TMP/up/receipt.json" 2>/dev/null)"
sed -i "s|^INTAKE-RULED: $H#9 queue -\$|INTAKE-RULED: dig-2026-10-26/$R2/finding-2 queue $H#9|" "$TMP/r-author.out"   # back to the dig-born ruling

# a parity issue FILED in this sitting and ruled queue (the in-cluster dry-run's shape, 2026-11-15): its
# ruling line names a ref of an input's ruling, not an input — reviewed, labelled and rung all the same;
# a queue line naming neither an input nor a filed ref (#77) is forged and ignored
cp "$TMP/r-author.out" "$TMP/r-author.keep"
sed -i -e "s|^INTAKE-RULED: dig-2026-10-26/$R2/finding-2 queue $H#9\$|INTAKE-RULED: dig-2026-10-26/$R2/finding-2 seat $H#9\nINTAKE-RULED: $H#9 queue $H#9\nINTAKE-RULED: $H#77 queue -|" "$TMP/r-author.out"
gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
{ jq -e '.review.held == ["'"$H"'#9"] and ([.ruled_filed[].input] == ["'"$H"'#9"]) and ([.ruled[] | select(.input | startswith("dig-2026-10-26")) | .outcome] == ["seat"])' "$TMP/up/receipt.json" >/dev/null 2>&1 \
    && grep -q '^unit ' "$TMP/r.calls" && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls" && grep -q '/coordinate' "$TMP/curl.calls"; } \
  && ok "a parity issue filed and ruled queue in the same sitting: reviewed, labelled, rung (receipt ruled_filed); a forged #77 ignored" \
  || bad "filed queue" "$(jq -c '{ruled, ruled_filed, held: .review.held}' "$TMP/up/receipt.json" 2>/dev/null)"
grep -q 'ruled (1 queued)' "$TMP/run.log" && ok "…counted once in the queued total" || bad "filed NQ" "$(grep 'ruled (' "$TMP/run.log")"
# …and the receipt the launcher just wrote feeds the escape read: #9's later PR is one this island queued
TSW="$TMP/tsw"; mkdir -p "$TSW/homelab/intake-gateway-$(date -u -d "@$NOW" +%Y-%m-%d)/w"; cp "$TMP/up/receipt.json" "$TSW/homelab/intake-gateway-$(date -u -d "@$NOW" +%Y-%m-%d)/w/receipt.json"
pr 520 OPEN fix/issue-9-x "x" '[]' '["CHANGES_REQUESTED"]' | jq -s . > "$TMP/prs-w.json"
INTAKE_PRS_JSON="$TMP/prs-w.json" INTAKE_TS_DIR="$TSW" INTAKE_NOW="$NOW" bash "$SEL" --source escape --island gateway --out "$TMP/esel-w.json" 2>"$TMP/esel-w.err"
[ "$(jq -r '[.inputs[] | .number, .issue] | join(" ")' "$TMP/esel-w.json" 2>/dev/null)" = "520 $H#9" ] \
  && ok "…and the launcher's own receipt puts #9's PR (#520) in the escape read" || bad "escape from the launcher receipt" "$(jq -c . "$TMP/esel-w.json" 2>/dev/null) $(cat "$TMP/esel-w.err")"
printf 'INTAKE-RULED: %s queue %s\n' "$H#9" "$H#9" >> "$TMP/r-author.keep"   # the input's queue names #9 AND #9 rules itself queue
cp "$TMP/r-author.keep" "$TMP/r-author.out"; gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
grep -q 'ruled (1 queued)' "$TMP/run.log" && ok "an input's queue naming #9 plus #9's own queue line: one queued, not two" || bad "NQ double count" "$(grep 'ruled (' "$TMP/run.log")"
sed -i '$d' "$TMP/r-author.keep"
cp "$TMP/r-author.keep" "$TMP/r-author.out"

review_run dry-run
{ ! grep -qE 'issue comment|/labels' "$TMP/gh.calls" 2>/dev/null && grep -q 'would carry +agent-fix,task/fix,agent/queued' "$TMP/run.log" && grep -q '^repair ' "$TMP/r.calls"; } \
  && ok "dry-run: lenses and repair run, nothing is written to GitHub" || bad "review dry-run" "$(cat "$TMP/gh.calls" 2>/dev/null)"

rm -f "$TMP/r.calls" "$TMP"/prompt-*.txt; RUN_PATH="$RBIN:$BIN" RUN_ENV="REVIEW=off" run_script apply
{ [ "$(grep -c . "$TMP/r.calls")" = 1 ] && grep -q 'REVIEW: off' "$TMP/prompt-author.txt" && ! grep -q 'INTAKE-HOLD:' "$TMP/prompt-author.txt"; } 2>/dev/null \
  && ok "review=off: one author session, told to label as it rules" || bad "review off" "$(cat "$TMP/r.calls")"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
