#!/usr/bin/env bash
# island-intake-test — behavioural harness for the WIRED island intake (FU-320): the selector's
# `--source dig` and `--source pile` modes (islands/intake/scripts/intake-select.sh) and the CronWorkflow
# that runs them (agents/coordinator/island-intake-argo.yaml), plus the island table every selector
# mode reads (island_members / island_alert_rules / island_pattern — one island per item).
# islands/intake/tests/fixtures/ holds REAL dig findings (full wire, bucket-shaped).
#
#   bash islands/intake/tests/island-intake-test.sh        (run by `devbox run deep-dig-test` — the dig's gate,
#                                              because intake is the dig's consumer)
#
# Hermetic: the selector reads a bucket-shaped directory (INTAKE_TS_DIR); the workflow's bootstrap is
# extracted from the manifest and the launcher script read from its file (islands/intake/scripts/sitting.sh),
# and the two run as the pod runs them — the bootstrap clones, then execs the script — with PATH stubs
# for claude / s5cmd / git / curl, the clock pinned. No network, no cluster.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SEL="$REPO/islands/intake/scripts/intake-select.sh"
YAML="${YAML:-$REPO/agents/coordinator/island-intake-argo.yaml}"
SITTING="${SITTING:-$REPO/islands/intake/scripts/sitting.sh}"
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

# ── real findings (islands/intake/tests/fixtures — the bucket's own objects, full wire) ─────────
# 2026-11-11: the text match put homelab#3162 (dig-2026-11-03 finding-1, AgentRunPhaseSlow — kata node
# memory) and homelab#3166 (dig-2026-11-04 finding-1, RetroReportOverdue) into the GATEWAY sitting: both
# cite argocd/resources/pushgateway/prometheusrule.yaml, which contains "gateway/". Neither alert is
# defined in the gateway's rule file and neither finding cites a gateway/ path, so by the header
# contract they are not the gateway's; the three on GoCatalogParseFailed / GoCatalogStale /
# TierEvidenceStale (all defined in argocd/resources/agent-gateway/prometheusrule.yaml) are.
section "selector --source dig — real findings"
FX="$REPO/islands/intake/tests/fixtures"; FXNOW=1794286800   # 2026-11-10T05:00:00Z; lookback 14 d reaches 10-29
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
# islands/intake/tests/fixtures/homelab/alert-*/ holds the responder's REAL finding.json objects of
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
# forward (islands/intake/rules/intake.md step 0): an issue whose LATEST intake ruling is `forward` is unruled —
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
# homelab#3579: the entrypoint is the WALK (the island list, then the retry wrapper once per name); the retry
# wrapper still calls the leaf, once per invocation. homelab#3604 (a deliberate change of this pinned shape, stated
# in its PR): the experiment read is the walk's first step and a closing `experiments-failed` group ends the
# workflow Failed when it failed — the pinned list below gained exactly those two names, nothing else moved.
[ "$(yqw '.spec.workflowSpec.entrypoint')" = intake-islands ] \
  && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-islands") | [.steps[][] | .name + "=" + .template] | join(" ")')" = "experiments=experiments islands=list-islands sitting=intake-retry experiments-failed=experiments-failed" ] \
  && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-retry") | .steps[][] | .template')" = intake ] \
  && ok "entrypoint = the walk (the island list, then the retry wrapper per island), and the retry wrapper calls the leaf" || bad "caller edge" "entrypoint/steps"
WALK='.spec.workflowSpec.templates[] | select(.name == "intake-islands") | .steps[][] | select(.name == "sitting")'
{ [ "$(yqw "$WALK | .withParam")" = '{{steps.islands.outputs.parameters.islands}}' ] \
    && [ "$(yqw "$WALK | .arguments.parameters[] | select(.name == \"island\") | .value")" = '{{item}}' ] \
    && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-retry") | .steps[][] | .arguments.parameters[] | select(.name == "island") | .value')" = '{{inputs.parameters.island}}' ] \
    && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .container.env[] | select(.name == "ISLAND") | .value')" = '{{inputs.parameters.island}}' ]; } \
  && ok "the walk fans out over the list step's output; each name reaches the leaf's ISLAND env as an input parameter" || bad "fan-out" "$(yqw "$WALK")"
[ "$(yqw '.spec.workflowSpec.arguments.parameters[] | select(.name == "island") | .value')" = all ] \
  && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "list-islands") | .container.env[] | select(.name == "ISLAND") | .value')" = '{{workflow.parameters.island}}' ] \
  && ok "island defaults to all, read by the list step (submit -p island=<name> for one island)" || bad "island param" "$(yqw '.spec.workflowSpec.arguments.parameters')"
[ "$(yqw '.spec.workflowSpec.parallelism')" = 1 ] && ok "one pod of the workflow at a time: the sittings run in sequence" || bad "sequence" "workflowSpec.parallelism = $(yqw '.spec.workflowSpec.parallelism')"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-retry") | .retryStrategy.limit')" = 3 ] \
  && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake-islands") | .retryStrategy // "none"')" = none ] \
  && ok "the retry stays on the retry wrapper (per island); the walk itself does not retry" || bad "retry home" "moved"
# deadlines: ONE sitting's is the leaf's and equals the script's RUN_DEADLINE_S default (its _fits arithmetic is
# against the pod's deadline); the walk's holds more than one sitting and ends before the next daily run (86400 s)
RDS="$(sed -n 's/^RUN_DEADLINE_S="${RUN_DEADLINE_S:-\([0-9]*\)}"$/\1/p' "$SITTING")"
LEAF_DL="$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .activeDeadlineSeconds')"; WF_DL="$(yqw '.spec.workflowSpec.activeDeadlineSeconds')"
{ [ -n "$RDS" ] && [ "$LEAF_DL" = "$RDS" ] && [ "$WF_DL" -gt "$LEAF_DL" ] && [ "$WF_DL" -lt 86400 ]; } 2>/dev/null \
  && ok "the leaf's deadline is the script's RUN_DEADLINE_S ($RDS s); the walk's ($WF_DL s) is longer and under a day" || bad "deadlines" "script=$RDS leaf=$LEAF_DL workflow=$WF_DL"
[ "$(yqw '.spec.workflowSpec.arguments.parameters[] | select(.name == "mode") | .value')" = apply ] \
  && ok "mode defaults to apply (submit -p mode=dry-run for a no-write sitting)" || bad "mode param" "missing"
grep -qx '  - island-intake-argo.yaml' "$REPO/agents/coordinator/kustomization.yaml" \
  && ok "kustomization ships it" || bad "kustomization" "island-intake-argo.yaml not listed"

# ── its identity, its image, its toolchain (homelab#3577) ───────────────────────────────────────
section "island-intake-argo.yaml — identity, image, toolchain"
CDIR="$REPO/agents/coordinator"; KZ="$CDIR/kustomization.yaml"; SA=island-intake
nb() { grep -v -e '^---$' -e '^$' || true; }
[ "$(yqw '.spec.workflowSpec.serviceAccountName')" = "$SA" ] && ok "the workflow runs as ServiceAccount $SA" || bad "service account" "$(yqw '.spec.workflowSpec.serviceAccountName')"
# every binding in the app that names the SA, as "<Kind>/<name> → <roleRef kind>/<roleRef name>". Expected, from the
# issue's acceptance 1: the two read roles, the one new read role, the Argo executor's Role — and nothing else
got="$(for f in "$CDIR"/*.yaml; do yq -r 'select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
        | select([.subjects[]? | select(.kind == "ServiceAccount" and .name == "'"$SA"'" and .namespace == "agent-coordinator")] | length > 0)
        | .kind + "/" + .metadata.name + " → " + .roleRef.kind + "/" + .roleRef.name' "$f"; done | nb | sort | tr '\n' ';')"
want="ClusterRoleBinding/island-intake-read → ClusterRole/island-intake-read;ClusterRoleBinding/island-intake-read-app → ClusterRole/agent-read-app;ClusterRoleBinding/island-intake-read-infra → ClusterRole/agent-read-infra;RoleBinding/argo-workflows-workflow-island-intake → Role/argo-workflows-workflow;"
[ "$got" = "$want" ] && ok "$SA is bound to the two read roles, island-intake-read and the Argo executor's Role — to nothing else (not ClusterRole agent-coordinator)" \
  || bad "bindings" "$got"
[ "$(yq -r 'select(.kind == "ServiceAccount" and .metadata.name == "'"$SA"'") | .metadata.namespace' "$CDIR/rbac.yaml" | nb)" = agent-coordinator ] \
  && ok "…and the ServiceAccount is declared in agent-coordinator" || bad "service account object" "not in rbac.yaml"
# island-intake-read: get/list only, on exactly five kinds — homelab#3577's four, plus the AgentStack claims
# (homelab#3580 acceptance 2: the stack islands' declaration; a rule on the existing role, no new object)
got="$(yq -r 'select(.kind == "ClusterRole" and .metadata.name == "island-intake-read") | .rules[]
        | (.apiGroups | join(",")) + ":" + (.resources | sort | join(",")) + ":" + (.verbs | sort | join(","))' "$CDIR/rbac.yaml" | nb | sort | tr '\n' ';')"
[ "$got" = ":resourcequotas:get,list;argoproj.io:cronworkflows,workflowtemplates:get,list;monitoring.coreos.com:prometheusrules:get,list;platform.teststuff.net:agentstacks:get,list;" ] \
  && ok "island-intake-read = get, list on resourcequotas, prometheusrules, cronworkflows, workflowtemplates, agentstacks" || bad "island-intake-read" "$got"
# no ClusterRole the SA holds carries a write verb (the executor's task-result Role is the chart's, not this app's)
got="$(for f in "$CDIR"/*.yaml; do yq -r 'select(.kind == "ClusterRole" and (.metadata.name == "island-intake-read" or .metadata.name == "agent-read-infra" or .metadata.name == "agent-read-app"))
        | .metadata.name as $n | .rules[] | .verbs[] | select(. != "get" and . != "list" and . != "watch") | $n + ":" + .' "$f"; done | nb | sort -u | tr '\n' ' ')"
n="$(for f in "$CDIR"/*.yaml; do yq -r 'select(.kind == "ClusterRole" and (.metadata.name == "island-intake-read" or .metadata.name == "agent-read-infra" or .metadata.name == "agent-read-app")) | .metadata.name' "$f"; done | nb | grep -c .)"
{ [ -z "$got" ] && [ "$n" = 3 ]; } && ok "the three ClusterRoles it holds carry get/list/watch only" || bad "a write verb" "roles read: $n; $got"
# the image: agent-base, untagged in the manifest; ONE kustomization entry carries the tag, as a one-line flow
# mapping — a line that STARTS with `newTag:` is rewritten by the agent-coordinator deploy-pin with a coordinator tag
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .container.image')" = registry.teststuff.net/agent-base ] \
  && ok "the sitting's image is agent-base, with no tag in the manifest" || bad "image" "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .container.image')"
BASE_TAG="$(yq -r '.images[] | select(.name == "registry.teststuff.net/agent-base") | .newTag' "$KZ")"
{ grep -qE '^[0-9]{4}\.[0-9]+\.[0-9]+-g[0-9a-f]{12}(\.[0-9]+)?$' <<< "$BASE_TAG" \
    && grep -qxF "  - { name: registry.teststuff.net/agent-base, newTag: $BASE_TAG }" "$KZ" \
    && [ "$(grep -cE '^[[:space:]]+newTag:' "$KZ")" = 1 ] \
    && [ "$(yq -r '.images[] | select(.name == "registry.teststuff.net/agent-coordinator") | .newTag' "$KZ")" != "$BASE_TAG" ]; } \
  && ok "kustomization pins agent-base on ONE flow-style line ($BASE_TAG); the only \`newTag:\`-led line stays the coordinator's" \
  || bad "agent-base pin" "newTag='$BASE_TAG'; newTag-led lines: $(grep -cE '^[[:space:]]+newTag:' "$KZ")"
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .container.env[] | select(.name == "HOME") | .value')" = /home/devbox ] \
  && ok "HOME is the base image's user's (/home/devbox)" || bad "HOME" "not /home/devbox"
# the island's devbox: the two tools the pod image does not pre-bake, each locked for the pod's platform
DJ="$REPO/islands/intake/devbox.json"; DL="$REPO/islands/intake/devbox.lock"
{ [ "$(jq -r '.packages | keys | sort | join(" ")' "$DJ" 2>/dev/null)" = "prometheus yq-go" ] \
    && [ "$(jq -r '.packages.prometheus.outputs | join(",")' "$DJ" 2>/dev/null)" = cli ]; } \
  && ok "islands/intake/devbox.json: only what the image lacks — prometheus (its cli output = promtool), yq-go" || bad "devbox.json" "$(jq -c '.packages' "$DJ" 2>/dev/null)"
got="$(jq -rn --slurpfile d "$DJ" --slurpfile l "$DL" '[$d[0].packages | keys[] | select(($l[0].packages[. + "@latest"].systems["x86_64-linux"].outputs // []) | length == 0)] | join(" ")' 2>/dev/null)" || got="unreadable"
[ -z "$got" ] && ok "…and devbox.lock resolves every one for x86_64-linux" || bad "devbox.lock" "unlocked: $got"
# versions: the repo-root lock's entry, whole, wherever the root carries the package (acceptance 3)
got="$(jq -rn --slurpfile i "$DL" --slurpfile r "$REPO/devbox.lock" '[$i[0].packages | to_entries[] | select($r[0].packages[.key] != null and $r[0].packages[.key] != .value) | .key] | join(" ")' 2>/dev/null)" || got="unreadable"
n="$(jq -rn --slurpfile i "$DL" --slurpfile r "$REPO/devbox.lock" '[$i[0].packages | keys[] | select($r[0].packages[.] != null)] | length' 2>/dev/null)" || n=0
{ [ -z "$got" ] && [ "$n" -ge 3 ]; } && ok "the lock's entries are the repo-root devbox.lock's wherever the root has the package ($n of them)" || bad "lock vs root" "differs: $got (shared: $n)"

# ── the workflow's own script, end to end, stubbed ──────────────────────────────────────────────
section "island-intake-argo.yaml — the script, run"
# the launcher script, from its FILE; the manifest's bootstrap (clone → exec the script) runs it, its exec
# pointed at this redirected copy (the clone stub's tree holds the unredirected one)
sed -e "s#/tmp/#$TMP/run/#g" -e "s#/work/homelab#$TMP/work/homelab#g" -e "s#/work/island-repo#$TMP/work/island-repo#g" "$SITTING" > "$TMP/sitting.sh"   # /tmp/ FIRST: $TMP is under /tmp
yq -r "$CW | .spec.workflowSpec.templates[] | select(.name == \"intake\") | .container.args[0]" "$YAML" \
  | sed -e "s#/tmp/#$TMP/run/#g" -e "s#/work/homelab#$TMP/work/homelab#g" \
        -e "s#exec bash islands/intake/scripts/sitting.sh#exec bash $TMP/sitting.sh#" > "$TMP/script.sh"
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
[ "$3" = cp ] && { echo "$5" >> "$H/s5.dest"; cp "$4" "$H/up/$(basename "$5")"; }
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$H/curl.calls"
# a pushgateway write (`--data-binary @-`): keep the exposition text the launcher piped in
case " $* " in *" --data-binary @- "*) cat >> "$H/pgw.body";; esac
EOF
cat > "$BIN/devbox" <<'EOF'
#!/bin/bash
# devbox stub: the bootstrap's two calls, recorded with the directory they were made from.
# `install` answers STUB_DEVBOX_INSTALL_RC; `run … -- <command>` starts the command where the real one does —
# in the devbox's own directory (--config), NOT the caller's — so a launch that leans on the caller's cwd fails here too
echo "devbox $* (cwd $PWD)" >> "$H/devbox.calls"
cfg=""; args=("$@"); for i in "${!args[@]}"; do [ "${args[$i]}" = --config ] && cfg="${args[$((i + 1))]}"; done
case "$1" in
  install) exit "${STUB_DEVBOX_INSTALL_RC:-0}";;
  run) while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
       [ -n "$cfg" ] && { cd "$cfg" || exit 96; }
       exec "$@";;
esac
exit 95
EOF
cat > "$BIN/kubectl" <<'EOF'
#!/bin/bash
# no cluster in the platform rows: the claims read (the list step's, homelab#3580) fails here, as it does when the
# API is unreachable — the stack-island rows put their own kubectl in front
echo "Unable to connect to the server (stub: no cluster)" >&2; exit 1
EOF
chmod +x "$BIN"/*
echo '[]' > "$TMP/pile-empty.json"   # the pile source's seam: an empty pile unless a row sets PILE_JSON
echo '{}' > "$TMP/refs-empty.json"   # the target-state seam: a row that needs a target sets REFS_JSON (a lookup here fails loud, never reaches gh)
# the wait source reads the same pile seam; its cap is 0 unless a row sets WAIT_MAX, so the dig/pile/review rows
# below see exactly the sittings they always saw (the gap source's specs-index default, the same move)
run_script() { # <mode>
  rm -rf "$TMP/work" "$TMP/up"/* "$TMP/run"/*; : > "$TMP/claude.calls"; : > "$TMP/curl.calls"; : > "$TMP/devbox.calls"; mkdir -p "$TMP/work"
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
# the bootstrap's two devbox calls: install, then the launcher THROUGH `devbox run` in islands/intake/ — the stub
# starts the command in that directory, as devbox does, so the sitting ran only because the launch returns to the clone root
{ [ "$(sed -n 1p "$TMP/devbox.calls")" = "devbox install --config islands/intake (cwd $TMP/work/homelab)" ] \
    && [ "$(sed -n 2p "$TMP/devbox.calls")" = "devbox run --config islands/intake -- bash $TMP/run/island-intake-launch.sh (cwd $TMP/work/homelab)" ] \
    && [ "$(grep -c . "$TMP/devbox.calls")" = 2 ]; } \
  && ok "the bootstrap installs the island's devbox and runs the launcher through \`devbox run\` in islands/intake/" || bad "devbox run" "$(cat "$TMP/devbox.calls")"
[ "$(jq -c '.projects | to_entries | map([.key, .value.hasTrustDialogAccepted])' "$TMP/home/.claude.json" 2>/dev/null)" = "[[\"$TMP/work/homelab\",true]]" ] \
  && ok "…and seeds claude's workdir trust for the clone (the base image seeds a worker's /work/repo only)" || bad "trust seed" "$(cat "$TMP/home/.claude.json" 2>&1 | head -2)"
[ -s "$TMP/claude.calls" ] && grep -q -- "--model opus" "$TMP/claude.calls" && ok "one sitting, on the resolved model" || bad "session" "$(cat "$TMP/claude.calls")"
grep -q "Read islands/intake/rules/intake.md IN FULL" "$TMP/up/brief.md" 2>/dev/null && grep -q "mode: apply" "$TMP/up/brief.md" \
  && jq -e '.inputs | length == 2' "$TMP/up/inputs.json" >/dev/null 2>&1 \
  && ok "brief names the island brief + mode; the inputs ride beside it" || bad "brief" "$(head -3 "$TMP/up/brief.md" 2>/dev/null)"
# the facts file: the launcher names docs/intake/<island>.md for EVERY island — the gateway's is a file like the
# others (intake.md §Island facts is a pointer, it holds no island's facts), and no branch on the island's name picks it
{ grep -qF "Your island's facts file (intake.md §Island facts): docs/intake/gateway.md" "$TMP/up/brief.md" \
    && [ -s "$TMP/work/homelab/docs/intake/gateway.md" ] && ! grep -q 'Island facts at the end' "$TMP/up/brief.md" \
    && ! grep -qE '"?\$\{?ISLAND\}?"? *(=|==|!=) *"?gateway' "$REPO/islands/intake/scripts/sitting.sh" \
    && ! grep -q '^## Island facts — ' "$REPO/islands/intake/rules/intake.md"; } \
  && ok "the gateway sitting is handed docs/intake/gateway.md like every island its file — no \`if gateway\` branch, no facts block in the brief" \
  || bad "facts hand-over" "$(grep -n 'facts' "$TMP/up/brief.md" 2>/dev/null | head -3)"
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

rm -f "$TMP/pgw.body"; RUN_ENV="STUB_DEVBOX_INSTALL_RC=1 PUSHGATEWAY=http://pgw" run_script apply; rc=$?
{ [ "$rc" = 1 ] && [ ! -s "$TMP/claude.calls" ] && [ "$(grep -c . "$TMP/devbox.calls")" = 1 ] && grep -q "the island's devbox did not install" "$TMP/run.log" \
    && grep -qx 'island_intake_probe_ok 0' "$TMP/pgw.body" && grep -qx 'island_intake_session_ran 0' "$TMP/pgw.body" \
    && grep -q '/metrics/job/island_intake/island/gateway' "$TMP/curl.calls"; } 2>/dev/null \
  && ok "the island's devbox does not install → exit 1 for Argo to retry, no session, no \`devbox run\`, the gauges say probe_ok 0" \
  || bad "devbox install failed" "rc=$rc calls=$(grep -c . "$TMP/devbox.calls") $(tail -2 "$TMP/run.log")"
# the "did not start" push carries every series the script's own _push does (a gauge added to one and not the other goes stale silently)
RUN_ENV="PUSHGATEWAY=http://pgw" run_script apply
sed -n 's/^\(island_intake_[a-z_]*\({[^}]*}\)\{0,1\}\) .*/\1/p' "$TMP/pgw.body" | sort | uniq -c | awk '{print $1}' | sort -u > "$TMP/pgw.counts"
[ "$(cat "$TMP/pgw.counts")" = 2 ] && ok "…and its series are exactly the script's own \`_push\` series" \
  || bad "did-not-start series" "$(sed -n 's/^\(island_intake_[a-z_]*\({[^}]*}\)\{0,1\}\) .*/\1/p' "$TMP/pgw.body" | sort | uniq -c | awk '$1 != 2' | tr '\n' ' ')"
rm -f "$TMP/pgw.body"

receipt 2026-10-26 intake-r1-e apply 2026-10-26T06:00:00Z \
  "[{\"input\":\"dig-2026-10-25/$R1/finding-2\",\"outcome\":\"close\",\"refs\":[]},{\"input\":\"dig-2026-10-26/$R2/finding-2\",\"outcome\":\"fold\",\"refs\":[]}]"
run_script apply
[ ! -s "$TMP/claude.calls" ] && grep -q "hold" "$TMP/run.log" && ok "hold: no session, exit 0" || bad "hold" "$(tail -3 "$TMP/run.log")"

# ── every island (homelab#3579) ─────────────────────────────────────────────────────────────────
# State here: the gateway's two dig findings are ruled (receipt intake-r1-e), the pile seam is empty → the
# gateway's selection is EMPTY (counts.inputs == 0). Acceptance 3: no session, the line below, metrics, exit 0.
rm -f "$TMP/pgw.body"; RUN_ENV="PUSHGATEWAY=http://pgw" run_script apply; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/claude.calls" ] && grep -qx 'island-intake: gateway — no inputs' "$TMP/run.log"; } \
  && ok "an empty selection: no claude call, \`island-intake: gateway — no inputs\`, exit 0" || bad "no inputs" "rc=$rc $(tail -3 "$TMP/run.log")"
{ grep -qE '^island_intake_last_run_timestamp_seconds [0-9]+$' "$TMP/pgw.body" && grep -qx 'island_intake_probe_ok 1' "$TMP/pgw.body" \
    && grep -qx 'island_intake_inputs 0' "$TMP/pgw.body" && grep -qx 'island_intake_session_ran 0' "$TMP/pgw.body" \
    && [ "$(grep -c -- '--data-binary @-' "$TMP/curl.calls")" = 1 ] && grep -q '/metrics/job/island_intake/island/gateway$' "$TMP/curl.calls"; } 2>/dev/null \
  && ok "…and it pushes its metrics once (last-run timestamp, probe_ok 1, inputs 0) — a quiet island stays fresh" || bad "no-inputs metrics" "$(cat "$TMP/curl.calls" 2>/dev/null | tail -2)"
# another island, empty: the same step under its own name and its own `island` grouping label
rm -f "$TMP/pgw.body"; RUN_ENV="ISLAND=mgmt-box PUSHGATEWAY=http://pgw" run_script apply; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/claude.calls" ] && grep -qx 'island-intake: mgmt-box — no inputs' "$TMP/run.log" \
    && grep -q '/metrics/job/island_intake/island/mgmt-box$' "$TMP/curl.calls" && ! grep -q '/island/gateway' "$TMP/curl.calls" \
    && [ "$(grep -c . "$TMP/devbox.calls")" = 2 ]; } \
  && ok "an empty selection on another island (mgmt-box): its own line, its own \`island\` label, no session" || bad "no inputs, mgmt-box" "rc=$rc $(tail -3 "$TMP/run.log")"
# inputs waiting behind the daily cap are NOT an empty selection: the hold line, never "no inputs"
receipt 2026-10-27 intake-r1-cap1 apply 2026-10-27T01:00:00Z '[]'; receipt 2026-10-27 intake-r1-cap2 apply 2026-10-27T02:00:00Z '[]'
echo '[{"number":301,"title":"gateway: unruled, behind the cap","body":"free text","labels":[],"createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z","author":{"login":"rsoot","is_bot":false},"comments":[]}]' > "$TMP/pile-cap.json"
PILE_JSON="$TMP/pile-cap.json" run_script apply; rc=$?
{ [ "$rc" = 0 ] && [ ! -s "$TMP/claude.calls" ] && grep -q 'hold: daily cap' "$TMP/run.log" && grep -qx 'island-intake: hold — no sitting today' "$TMP/run.log" \
    && ! grep -q 'no inputs$' "$TMP/run.log"; } \
  && ok "inputs held by the daily cap stay a hold (\`hold — no sitting today\`), not \`no inputs\`" || bad "cap hold" "rc=$rc $(tail -3 "$TMP/run.log")"
rm -rf "$TS/homelab/intake-gateway-2026-10-27"
# another island WITH an input: its own sitting — facts file, receipt prefix, receipt island, metrics label (acceptance 4).
# The cap is per island: two gateway sittings today (the receipts above, re-made) do not hold the router pair's.
receipt 2026-10-27 intake-r1-cap1 apply 2026-10-27T01:00:00Z '[]'; receipt 2026-10-27 intake-r1-cap2 apply 2026-10-27T02:00:00Z '[]'
echo '[{"number":302,"title":"opnsense: unruled","body":"free text","labels":[],"createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z","author":{"login":"rsoot","is_bot":false},"comments":[]}]' > "$TMP/pile-rp.json"
cp "$TMP/claude.out" "$TMP/claude.out.keep"; printf 'INTAKE-RULED: teststuffstash/homelab#302 standing -\n' > "$TMP/claude.out"
rm -f "$TMP/pgw.body" "$TMP/s5.dest"; PILE_JSON="$TMP/pile-rp.json" RUN_ENV="ISLAND=router-pair PUSHGATEWAY=http://pgw" run_script apply; rc=$?
{ [ "$rc" = 0 ] && [ "$(grep -c '^claude' "$TMP/claude.calls")" = 1 ] \
    && grep -qF "Your island's facts file (intake.md §Island facts): docs/intake/router-pair.md" "$TMP/up/brief.md" \
    && [ "$(jq -c '[.island, (.ruled | map([.input, .outcome]))]' "$TMP/up/receipt.json" 2>/dev/null)" = '["router-pair",[["teststuffstash/homelab#302","standing"]]]' ]; } \
  && ok "a named island with an input (router-pair) holds its own sitting — its facts file, its receipt — while the gateway is at its daily cap" \
  || bad "router-pair sitting" "rc=$rc $(tail -3 "$TMP/run.log") $(jq -c '[.island, .ruled]' "$TMP/up/receipt.json" 2>/dev/null)"
{ [ -s "$TMP/s5.dest" ] && grep -q '/receipt\.json$' "$TMP/s5.dest" \
    && [ -z "$(grep -vE '^s3://b/homelab/intake-router-pair-[0-9]{4}-[0-9]{2}-[0-9]{2}/intake-r1-[0-9TZ]+/' "$TMP/s5.dest")" ]; } \
  && ok "…every record of it lands under s3://<bucket>/homelab/intake-router-pair-<day>/" || bad "receipt prefix" "$(sort -u "$TMP/s5.dest" 2>/dev/null | head -3)"
{ grep -q '/metrics/job/island_intake/island/router-pair$' "$TMP/curl.calls" && ! grep -q '/island/gateway' "$TMP/curl.calls" \
    && grep -qx 'island_intake_session_ran 1' "$TMP/pgw.body" && grep -qx 'island_intake_inputs 1' "$TMP/pgw.body"; } 2>/dev/null \
  && ok "…and its metrics carry \`island=router-pair\` (session_ran 1, inputs 1)" || bad "router-pair metrics" "$(grep metrics "$TMP/curl.calls" 2>/dev/null)"
cp "$TMP/claude.out.keep" "$TMP/claude.out"; rm -rf "$TS/homelab/intake-gateway-2026-10-27" "$TMP/s5.dest"; rm -f "$TMP/pgw.body"

# the island LIST: the selector's --list-islands, and the workflow's list step that turns it into the walk's withParam
section "island-intake-argo.yaml — the island list (homelab#3579)"
# expected = the selector's ISLANDS row (gateway first) — every one of the nine has a membership row and docs/intake/<island>.md
ALL_ISLANDS='gateway scan launch retro router-pair mgmt-box dependency-upgrades substrate agent-loop'
got="$(env -u GH_TOKEN -u INTAKE_TS_DIR -u INTAKE_ISSUES_JSON bash "$SEL" --list-islands 2>"$TMP/list.err")"; rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$got" | tr '\n' ' ')" = "$ALL_ISLANDS" ] && [ ! -s "$TMP/list.err" ]; } \
  && ok "--list-islands: one name per line, the table's order, gateway first — no gh, bucket or issue read" || bad "--list-islands" "rc=$rc got '$(printf '%s' "$got" | tr '\n' ' ')' $(cat "$TMP/list.err")"
# membership row AND facts file: a tree where only gateway and retro have a facts file, plus a facts file no row names
LT="$TMP/ltree"; mkdir -p "$LT/islands/intake/scripts" "$LT/docs/intake"; cp "$SEL" "$LT/islands/intake/scripts/"
: > "$LT/docs/intake/retro.md"; : > "$LT/docs/intake/gateway.md"; : > "$LT/docs/intake/commons.md"
got="$(bash "$LT/islands/intake/scripts/intake-select.sh" --list-islands 2>"$TMP/list.err")"; rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$got" | tr '\n' ' ')" = "gateway retro" ] && grep -q "'scan' has no facts file (docs/intake/scan.md)" "$TMP/list.err"; } \
  && ok "…an island without a facts file is left out (named on stderr); a facts file without a membership row lists nothing" || bad "--list-islands facts" "got '$(printf '%s' "$got" | tr '\n' ' ')'"
# the list step's script, from the manifest, with the clone stubbed (the same redirects as the bootstrap's)
yq -r "$CW | .spec.workflowSpec.templates[] | select(.name == \"list-islands\") | .container.args[0]" "$YAML" \
  | sed -e "s#/tmp/#$TMP/run/#g" -e "s#/work/homelab#$TMP/work/homelab#g" > "$TMP/list.sh"
LIST_OUT="$(yqw '.spec.workflowSpec.templates[] | select(.name == "list-islands") | .outputs.parameters[] | select(.name == "islands") | .valueFrom.path' | sed -e "s#/tmp/#$TMP/run/#")"
run_list() { # <island> [PATH prefix]
  rm -rf "$TMP/work" "$TMP/run"/*; : > "$TMP/devbox.calls"; mkdir -p "$TMP/work"
  ( cd "$TMP" && H="$TMP" PATH="${2:-$BIN}:$PATH" HOME="$TMP/home" ISLAND="$1" GH_TOKEN=x bash "$TMP/list.sh" ) > "$TMP/list.log" 2>&1
}
run_list all; rc=$?
{ [ "$rc" = 0 ] && [ -n "$LIST_OUT" ] && [ "$(jq -c . "$LIST_OUT" 2>/dev/null)" = '["gateway","scan","launch","retro","router-pair","mgmt-box","dependency-upgrades","substrate","agent-loop"]' ]; } \
  && ok "island=all: the list step clones and writes the selector's list as a JSON array to its output parameter's path" || bad "list step, all" "rc=$rc out=$LIST_OUT $(tail -2 "$TMP/list.log")"
[ ! -s "$TMP/devbox.calls" ] && [ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "list-islands") | .synchronization // "none"')" = none ] \
  && ok "…with no devbox and no semaphore slot (it starts no session)" || bad "list step cost" "$(cat "$TMP/devbox.calls")"
run_list scan; rc=$?
{ [ "$rc" = 0 ] && [ "$(jq -c . "$LIST_OUT" 2>/dev/null)" = '["scan"]' ] && [ ! -e "$TMP/work/homelab" ]; } \
  && ok "island=scan: that one name, no clone (\`-p island=scan\` keeps working)" || bad "list step, named" "rc=$rc $(cat "$LIST_OUT" 2>/dev/null) $(tail -2 "$TMP/list.log")"
run_list 'a"b'; rc=$?
{ [ "$rc" = 0 ] && jq -e '. == ["a\"b"]' "$LIST_OUT" >/dev/null 2>&1; } \
  && ok "…a name is written as JSON data, never spliced into the array" || bad "list step, quoting" "rc=$rc $(cat "$LIST_OUT" 2>/dev/null)"
mkdir -p "$TMP/badbin"; printf '#!/bin/bash\nexit 1\n' > "$TMP/badbin/git"; chmod +x "$TMP/badbin/git"
run_list all "$TMP/badbin:$BIN"; rc=$?
{ [ "$rc" = 1 ] && [ ! -s "$LIST_OUT" ] && grep -q 'clone failed (the island list)' "$TMP/list.log"; } \
  && ok "island=all with a failed clone: exit 1 and no list — never an empty walk that passes" || bad "list step, clone failed" "rc=$rc $(tail -2 "$TMP/list.log")"
# a selector that lists nothing (no facts file in the clone): exit 1
cat > "$TMP/badbin/git" <<EOF
#!/bin/bash
dest="\${@: -1}"; mkdir -p "\$dest/islands/intake/scripts"; cp "$SEL" "\$dest/islands/intake/scripts/"
EOF
run_list all "$TMP/badbin:$BIN"; rc=$?
{ [ "$rc" = 1 ] && grep -q 'the island list is empty' "$TMP/list.log"; } \
  && ok "…and an empty list fails the step (zero sittings is never a pass)" || bad "list step, empty" "rc=$rc $(tail -2 "$TMP/list.log")"

# a recurring responder class rides the dig source into the SAME sitting (selector header: an alert
# the island's rule file defines owns the finding — no ride issue is read); three real-wire records
# re-stamped onto GoCatalogStale (defined in argocd/resources/agent-gateway/prometheusrule.yaml)
for k in 4 5 6; do
  d="$TS/homelab/alert-dd0000000000000$k/responder-r1-2026102${k}T010000Z"; mkdir -p "$d"
  jq --arg fp "dd0000000000000$k" '.alertname = "GoCatalogStale" | .fingerprint = $fp | .subject = "workload:agent-egress/agent-gateway"' \
    "$REPO/islands/intake/tests/fixtures/homelab/alert-3c86aab4bb369c2d/responder-r1-20261113T021803Z/finding.json" > "$d/finding.json"
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
# the two reads of homelab#3577, each with its control line, for EVERY island (the launcher holds no island branch)
{ grep -qF "curl -sG -H 'X-Scope-OrgID: <namespace>' http://loki.loki.svc:3100/loki/api/v1/query_range" "$TMP/up/brief.md" \
    && grep -qF "control first: curl -sG -H 'X-Scope-OrgID: <namespace>' http://loki.loki.svc:3100/loki/api/v1/labels" "$TMP/up/brief.md" \
    && grep -qF 'kubectl get <kind> -n <ns> -o json' "$TMP/up/brief.md" \
    && grep -qF 'control first: kubectl auth can-i get <kind> -n <ns>' "$TMP/up/brief.md" \
    && grep -q 'A `Forbidden` .* is a FACT to report .* never an empty answer' "$TMP/up/brief.md"; } \
  && ok "…plus Loki (tenant header = the namespace) and the read-only kube API, each with a control line; a Forbidden is a fact, never an empty answer" \
  || bad "brief live reads (loki, kube)" "$(grep -n -e loki -e kubectl "$TMP/up/brief.md" | head -4)"
# the Loki query is the deep dig's own line (one home is a later cleanup): same host, path, tenant header and parameters
LOKI_Q="curl -sG -H 'X-Scope-OrgID: <namespace>' http://loki.loki.svc:3100/loki/api/v1/query_range --data-urlencode 'query={namespace=\"<ns>\",pod=~\"<pod>.*\"}' --data-urlencode 'start=<unix-ns>' --data-urlencode 'limit=500'"
{ grep -qF "$LOKI_Q" "$REPO/agents/coordinator/deep-dig-argo.yaml" && grep -qF "$LOKI_Q" "$TMP/up/brief.md"; } \
  && ok "…the Loki query is the deep dig's line, verbatim" || bad "loki line" "the brief's and deep-dig-argo.yaml's differ"
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
GT="$TMP/gtree"; mkdir -p "$GT/islands/intake/scripts" "$GT/gateway/specs" "$GT/agents"
cp "$SEL" "$GT/islands/intake/scripts/"; cp "$REPO/agents/issue_body.py" "$GT/agents/"
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
gaps() { INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" env "$@" bash "$GT/islands/intake/scripts/intake-select.sh" --source gaps --island gateway --out "$TMP/gsel.json" 2>"$TMP/gsel.err"; }
gaps; rc=$?
got="$(jq -r '[.inputs[].requirement] | join(" ")' "$TMP/gsel.json" 2>/dev/null)"
{ [ "$rc" = 0 ] && [ "$got" = "GW-A GW-B GW-EF GW-G" ]; } && ok "fires on GW-A (⚑) GW-B (🚧) GW-EF GW-G; not C (no mark), D (#77 open), E (named), F (apply-ruled)" \
  || bad "gaps selection" "rc=$rc got '$got' $(cat "$TMP/gsel.err")"
[ "$(jq -c '.counts' "$TMP/gsel.json")" = '{"rows":7,"ruled":1,"named":2,"over_cap":0,"inputs":4}' ] && ok "counts: 7 rows, 1 ruled, 2 named, 4 inputs" || bad "gaps counts" "$(jq -c .counts "$TMP/gsel.json")"
[ "$(jq -r '.inputs[0] | [.id, .kind, (.marks | join("+")), (.row | startswith("| [GW-A]"))] | @tsv' "$TMP/gsel.json")" = "$(printf 'gateway/specs/endpoints/a.md#GW-A\tgap\t⚑ gap\ttrue')" ] \
  && ok "an input is <specs page>#<REQ>, kind gap, its marks and the row verbatim" || bad "gap input shape" "$(jq -c '.inputs[0]' "$TMP/gsel.json")"
gaps INTAKE_GAP_MAX=2; [ "$(jq -r '[.inputs[].requirement] | join(" ")' "$TMP/gsel.json"):$(jq '.counts.over_cap' "$TMP/gsel.json")" = "GW-A GW-B:2" ] \
  && ok "INTAKE_GAP_MAX=2 → the first two in index order, over_cap 2 (they re-present tomorrow)" || bad "gap cap" "$(jq -c .counts "$TMP/gsel.json")"
INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" bash "$GT/islands/intake/scripts/intake-select.sh" --source gaps --island router-pair --out "$TMP/gsel.json" 2>/dev/null; rc=$?
{ [ "$rc" = 1 ] && jq -e '.specs_root == null and .counts.inputs == 0' "$TMP/gsel.json" >/dev/null; } && ok "an island with no specs root: a valid empty selection (exit 1)" || bad "gaps no root" "rc=$rc"
INTAKE_ISSUES_JSON="$GISS" INTAKE_TS_DIR="$TSG" INTAKE_NOW="$NOW" bash "$GT/islands/intake/scripts/intake-select.sh" --source gaps --island scan --out "$TMP/gsel.json" 2>/dev/null; rc=$?
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
INTAKE-WAIT: {"wait": "$H#301@2026-10-10T00:00:00Z/released", "class": "R", "rules": [{"file": "islands/intake/rules/intake.md", "mark": "caused", "words": "$KEY_WORDS"}], "direction": "narrow-stall", "widens": true, "fact": "on the page"}
INTAKE-WAIT: {"wait": "$H#302@2026-10-05T00:00:00Z/released", "class": "R", "rules": [{"file": "islands/intake/rules/intake.md", "mark": "caused", "words": "3. Does it need a human fact? The body"}], "direction": "narrow-stall", "widens": false}
INTAKE-WAIT: {"wait": "$H#305@2026-10-10T00:00:00Z/released", "class": "R", "rules": [{"file": "islands/intake/rules/intake.md", "mark": "caused", "words": "$KEY_WORDS"}], "direction": "none", "widens": false}
INTAKE-WAIT: {"wait": "$H#312@2026-10-10T00:00:00Z/released", "class": "H", "rules": [{"file": "islands/intake/rules/intake.md", "mark": "caused", "words": "- Operator-only, not yours to reason around:"}], "direction": "none", "widens": false}
INTAKE-WAIT: {"wait": "$H#999@2026-10-10T00:00:00Z/released", "class": "R", "rules": []}
INTAKE-WAIT: {"wait": "$H#309@2026-10-10T00:00:00Z/standing", "class": "Q", "rules": []}
INTAKE-WAIT: {"wait": "$H#310@2026-10-10T00:00:00Z/standing", "class": "R" BROKEN
INTAKE-WAIT: not json at all
INTAKE-WAIT: {"wait": "$H#311@2026-10-15T00:00:00Z/standing", "class": "U", "rules": ["a string, not an object"]}
## Wait proposals
INTAKE-WAIT-PROPOSAL: {"file": "islands/intake/rules/intake.md", "mark": "caused", "words": "$KEY_WORDS", "diff": "-old\n+new", "widens_authority": false}
INTAKE-WAIT-PROPOSAL: {"file": "islands/intake/rules/intake.md", "mark": "missing", "words": "## Hard limits", "diff": "+x"}
INTAKE-WAIT-PROPOSAL: {"file": "islands/intake/rules/intake.md", "diff": "+y" BROKEN
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
{ jq -e '.wait_ledger.at_bar == ["islands/intake/rules/intake.md|caused|3 does it need a human fact the"] and .wait_ledger.false_waits == {records: 2, items: 2}' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.wait_proposals | length == 1 and .[0].items == ["'"$H"'#301", "'"$H"'#302"] and .[0].widens_authority == true' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.wait_proposals_dropped[0] == {key: "islands/intake/rules/intake.md|missing|hard limits", reason: "not at the bar"} and .wait_proposals_dropped[1].reason == "unparseable"' "$TMP/up/receipt.json" >/dev/null; } \
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
python3 -I "$REPO/islands/intake/scripts/intake-wait-ledger.py" --self-test > "$TMP/ledger-st.log" 2>&1 \
  && ok "intake-wait-ledger.py --self-test" || bad "ledger self-test" "$(grep -e FAIL "$TMP/ledger-st.log" | head -5)"
python3 -I "$REPO/islands/intake/scripts/intake-wait-cases.py" --self-test > "$TMP/cases-st.log" 2>&1 \
  && ok "intake-wait-cases.py --self-test" || bad "cases self-test" "$(grep -e FAIL "$TMP/cases-st.log" | head -5)"
python3 -I "$REPO/islands/intake/scripts/intake-wait-cases.py" --git validate > "$TMP/cases.log" 2>&1 \
  && grep -q '10 case(s) valid (train 7, heldout 3), 0 error' "$TMP/cases.log" \
  && ok "the ten recorded wait cases validate (train 7, held out 3; rules commits checked unless the checkout is shallow)" || bad "wait cases" "$(tail -5 "$TMP/cases.log")"

# the experiment block's loader (homelab#3602): its own self-test — the real command over the fixture bodies
# in fixtures/experiment/, every expected exit, object and fault written by hand in expected.json
section "the experiment block's loader"
python3 -I "$REPO/islands/intake/scripts/experiment.py" --self-test > "$TMP/experiment-st.log" 2>&1 \
  && ok "experiment.py --self-test" || bad "experiment self-test" "$(grep -e FAIL "$TMP/experiment-st.log" | head -5)"

# the verdict and the Prometheus read (homelab#3603): the two commands as a shell caller runs them, against a
# stub HTTP server (tests/prom_stub.py) answering from fixtures/experiment-read/prom.json — one scenario per
# URL path prefix. The decision table itself (fixtures/experiment-read/decide.json) and every refused answer
# are rows of the self-test above. Expected values, from the fixture and the rule (issue #3603 acceptance 2):
# body.md has min_window 1h, max_window 7d, min_samples 20, pass "<= 3", guard errors "< 1"; t0 is
# 2026-11-01T00:00:05Z = 1793491205; the stub's sample count is 3 before t0 + 2000m and 20 from it on, so the
# deciding window is 2000m = 120000 s and the deciding instant 1793491205 + 120000 = 1793611205.
section "the experiment's verdict and its Prometheus read (experiment.py read, at)"
EXP="$REPO/islands/intake/scripts/experiment.py"; EXPFX="$REPO/islands/intake/tests/fixtures/experiment-read"
python3 -I "$REPO/islands/intake/tests/prom_stub.py" "$EXPFX/prom.json" "$TMP/prom.port" "$TMP/prom.log" > "$TMP/prom-stub.log" 2>&1 &
PROM_PID=$!
for _ in $(seq 1 100); do [ -s "$TMP/prom.port" ] && break; sleep 0.1; done
PROM="http://127.0.0.1:$(cat "$TMP/prom.port" 2>/dev/null)"; : >> "$TMP/prom.log"
expread() { # <scenario> <now> [body]  → $TMP/exp.out, $TMP/exp.err; the exit is the command's own
  python3 -I "$EXP" read --prometheus "$PROM/$1" --since 2026-11-01T00:00:05Z --now "$2" "${3:-$EXPFX/body.md}" > "$TMP/exp.out" 2> "$TMP/exp.err"
}
asked() { grep -c "\"scenario\": \"$1\"" "$TMP/prom.log"; }
expread pass 2026-11-03T02:00:05Z; rc=$?
{ [ "$rc" = 0 ] && [ "$(wc -l < "$TMP/exp.out")" = 1 ] && [ ! -s "$TMP/exp.err" ] \
    && jq -e '.verdict == "pass" and .window_s == 120000 and .at == "2026-11-02T09:20:05Z" and .value == 2 and .samples == 20
              and .bound == "2026-11-08T00:00:05Z" and .id == "press-waits-down" and .t0 == "2026-11-01T00:00:05Z" and .error == null
              and .guards == [{id: "errors", value: 0, ok: true}] and (keys | length) == 11' "$TMP/exp.out" > /dev/null; } \
  && ok "read: a claim that holds exits 0 — one JSON line: verdict pass, the 2000m window, the instant it ends, the value, the samples, the guard" \
  || bad "read pass" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
{ jq -e -s 'any(.[]; .scenario == "pass" and .time == "1793611205" and .query == "max_over_time(fx_value[2000m]) and on() (avg_over_time(fx_up[2000m]) > 0.95)")' "$TMP/prom.log" > /dev/null \
    && [ "$(asked pass)" -le 16 ] && ! grep -qF '$window' "$TMP/prom.log"; } \
  && ok "…the stub was asked query over [2000m] at t0 + 2000m, \$window never left in a question, and the bisection took at most 16 questions for a seven-day bound" \
  || bad "read pass questions" "$(asked pass) asked: $(tail -3 "$TMP/prom.log")"
cp "$TMP/exp.out" "$TMP/exp.first"
expread pass 2026-11-09T00:00:05Z; rc=$?
{ [ "$rc" = 0 ] && cmp -s "$TMP/exp.out" "$TMP/exp.first"; } \
  && ok "…and the same read a day after the bound prints the same line (the verdict is of t0 and the series, not of when it is read)" \
  || bad "read pass twice" "rc=$rc $(cat "$TMP/exp.out")"
expread fail 2026-11-03T02:00:05Z; rc=$?
{ [ "$rc" = 1 ] && jq -e '.verdict == "fail" and .value == 7 and .reason == "7 <= 3 does not hold" and .error == null' "$TMP/exp.out" > /dev/null; } \
  && ok "read: a value over the threshold (7 against <= 3) exits 1, verdict fail" || bad "read fail" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
expread pending 2026-11-03T02:00:05Z; rc=$?
{ [ "$rc" = 2 ] && jq -e '.verdict == "pending" and .window_s == null and .samples == 3 and .error == null' "$TMP/exp.out" > /dev/null; } \
  && ok "read: three samples of twenty before the bound exit 2, verdict pending and no error" || bad "read pending" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
expread two-samples 2026-11-03T02:00:05Z; rc=$?
{ [ "$rc" = 2 ] && [ "$(jq -c '[.verdict, .error, .id, .bound]' "$TMP/exp.out")" = '[null,"one sample expected, the answer holds 2","press-waits-down","2026-11-08T00:00:05Z"]' ]; } \
  && ok "read: an answer of two samples exits 2 with no verdict — the error says one sample expected" || bad "read two samples" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
expread down 2026-11-03T02:00:05Z; rc=$?
{ [ "$rc" = 2 ] && [ "$(jq -c '[.verdict, .error]' "$TMP/exp.out")" = '[null,"HTTP 500 (asked twice)"]' ] && [ "$(asked down)" = 2 ]; } \
  && ok "read: HTTP 500 exits 2 with no verdict, after exactly one retry (two requests)" || bad "read HTTP 500" "rc=$rc asked=$(asked down) $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
before="$(wc -l < "$TMP/prom.log")"; codes=""
for b in none.md neither.md malformed-no-block.md no-such-body.md; do
  expread pass 2026-11-03T02:00:05Z "$REPO/islands/intake/tests/fixtures/experiment/$b"; codes="$codes $?:$(wc -c < "$TMP/exp.out"):$(wc -l < "$TMP/exp.err")"
done
{ [ "$codes" = " 3:0:1 4:0:1 5:0:1 6:0:1" ] && [ "$(wc -l < "$TMP/prom.log")" = "$before" ]; } \
  && ok "read: a body that does not load never shares an exit with a verdict — none 3, absent 4, malformed 5, unreadable 6; nothing on stdout, nothing asked" \
  || bad "read body exits" "got:$codes"
python3 -I "$EXP" at --prometheus "$PROM/baseline" --window 10d --at 2026-11-02T09:20:05Z \
  --query 'max_over_time(fx_value[$window]) and on() (avg_over_time(fx_up[$window]) > 0.95)' > "$TMP/exp.out" 2> "$TMP/exp.err"; rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$TMP/exp.out")" = 5 ] && [ ! -s "$TMP/exp.err" ]; } \
  && ok "at: the baseline replay prints the one number (10d asked as [14400m], at the instant given — the stub answers no other question)" \
  || bad "at" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
python3 -I "$EXP" at --prometheus "$PROM/baseline" --window 1h --at 2026-11-02T09:20:05Z --query 'fx_gone[$window]' > "$TMP/exp.out" 2> "$TMP/exp.err"; rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$TMP/exp.out")" = "no sample" ]; } \
  && ok "at: an answer with no sample prints \`no sample\`, exit 0" || bad "at no sample" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
python3 -I "$EXP" at --prometheus "$PROM/down" --window 1h --at 2026-11-02T09:20:05Z --query 'fx_value[$window]' > "$TMP/exp.out" 2> "$TMP/exp.err"; rc=$?
{ [ "$rc" = 2 ] && [ ! -s "$TMP/exp.out" ] && grep -q '^experiment: read failed — HTTP 500 (asked twice)$' "$TMP/exp.err"; } \
  && ok "at: HTTP 500 exits 2 — nothing on stdout, the reason on stderr" || bad "at HTTP 500" "rc=$rc $(cat "$TMP/exp.out" "$TMP/exp.err" | head -3)"
kill "$PROM_PID" 2>/dev/null; wait "$PROM_PID" 2>/dev/null

# ── the rules write the experiment (homelab#3605; intake.md §Experiment) ─────────────────────────────────
# Expected, from the issue's acceptance 2, 4 and 6: BOTH body templates of intake.md show `## Experiment` in
# place — after the part that decides the means (`## Spec changes` / `## Decision`), before `## Out of scope` —
# each with the one line telling the ride the section is not its to change; the `spec` template's example is a
# section the loader accepts (exit 0, experiment.py's header). The `edit` template points at it and holds no block.
section "intake.md — both body templates carry \`## Experiment\`"
EXPY="$REPO/islands/intake/scripts/experiment.py"; RULES="$REPO/islands/intake/rules/intake.md"
tpl() { # <shape> → stdout: that shape's template (the fenced block under its `### The `<shape>` shape` heading)
  awk -v h="### The \`$1\` shape" 'index($0, h) == 1 {on = 1; next} on && /^### / {exit} on && /^````markdown$/ {inb = 1; next} inb && /^````$/ {exit} inb' "$RULES"; }
for shp in "spec:## Spec changes" "edit:## Decision"; do
  shape="${shp%%:*}"; means="${shp#*:}"; tpl "$shape" > "$TMP/tpl-$shape.md"
  order="$(grep -nxE "$means|## Experiment|## Out of scope" "$TMP/tpl-$shape.md" | cut -d: -f2 | tr '\n' '|')"
  [ "$order" = "$means|## Experiment|## Out of scope|" ] \
    && ok "the \`$shape\` template: \`## Experiment\` after \`$means\`, before \`## Out of scope\`" || bad "template $shape" "headings: '$order'"
  [ "$(awk '/^## Experiment$/{on=1; next} on && /^## /{exit} on' "$TMP/tpl-$shape.md" | grep -c "Not the ride's to change")" = 1 ] \
    && ok "…and its section says, in one line, that it is not the ride's to change" || bad "template $shape worker line" "$(grep -c "Not the ride's to change" "$TMP/tpl-$shape.md")"
done
python3 -I "$EXPY" load --check "$TMP/tpl-spec.md"; rc=$?
[ "$rc" = 0 ] && ok "the \`spec\` template's example section passes experiment.py load --check (exit 0)" || bad "template example" "exit $rc: $(python3 -I "$EXPY" load "$TMP/tpl-spec.md" 2>&1 >/dev/null)"
# the fixture bodies of the body-shape rows (the `edit` one here; the `spec` one is built in the review section
# below and checked there). The check can fail: the same body without its section is `absent` (exit 4).
python3 -I "$EXPY" load --check "$REPO/islands/intake/tests/fixtures/edit-body-3563.md"; rc=$?
[ "$rc" = 0 ] && ok "the \`edit\` fixture body passes experiment.py load --check" || bad "edit fixture experiment" "exit $rc"
awk '/^## Experiment$/{skip=1; next} skip && /^## /{skip=0} !skip' "$REPO/islands/intake/tests/fixtures/edit-body-3563.md" > "$TMP/edit-no-exp.md"
python3 -I "$EXPY" load --check "$TMP/edit-no-exp.md"; rc=$?
[ "$rc" = 4 ] && ok "…and the same body without its section is absent (exit 4): the check can fail" || bad "edit fixture without a section" "exit $rc"

# ── the facts files name their island's body shape (intake.md §A queue-ready body) ────────────────────────
# Expected from homelab#3576 acceptance 5: `spec` for gateway, scan, launch, retro; `edit` for agent-loop,
# substrate, mgmt-box, router-pair, dependency-upgrades — and every docs/intake/*.md carries exactly ONE
# such line, so a new facts file without it fails here.
section "facts files — one \`Body shape:\` line each"
shape_of() { grep -E '^Body shape: ' "$REPO/docs/intake/$1.md" 2>/dev/null | sed 's/^Body shape: //' | tr '\n' ' '; }
for row in "gateway:spec" "scan:spec" "launch:spec" "retro:spec" "agent-loop:edit" "substrate:edit" "mgmt-box:edit" "router-pair:edit" "dependency-upgrades:edit"; do
  isl="${row%%:*}"; want="${row#*:}"; got="$(shape_of "$isl")"
  [ "$got" = "$want " ] && ok "docs/intake/$isl.md: Body shape: $want" || bad "body shape $isl" "want '$want' got '$got'"
done
nofile=""; for f in "$REPO"/docs/intake/*.md; do
  { [ "$(grep -cE '^Body shape: (spec|edit)$' "$f")" = 1 ] && [ "$(grep -c '^Body shape:' "$f")" = 1 ]; } || nofile="$nofile $(basename "$f")"; done
[ -z "$nofile" ] && ok "every docs/intake/*.md carries exactly one \`Body shape: spec|edit\` line" || bad "body shape line" "missing or malformed in:$nofile"

# ── every facts file names its sources and what a ride can do (homelab#3578, Goal #3574 pin 4) ─────────
# The shape, from the issue's acceptance 1 + intake.md §What you read: `## Sources` holds a table whose
# header is `| question | read | note |` with at least one data row (question and read both filled);
# `## What a ride can do` holds at least one line. The files checked are the ones the SELECTOR lists
# (--list-islands), so an island gaining a facts file is checked without an edit here.
# facts_sections <file> → one line per shortfall on stdout; nothing = the file has both sections.
facts_sections() { bash "$REPO/islands/intake/scripts/facts-check.sh" --sections "$1"; }   # the ONE predicate — the launcher's too (homelab#3580)
section "facts files — \`## Sources\` and \`## What a ride can do\` (homelab#3578)"
FACTS_ISLANDS="$(env -u GH_TOKEN -u INTAKE_TS_DIR -u INTAKE_ISSUES_JSON bash "$SEL" --list-islands 2>/dev/null)"
# expected = ALL_ISLANDS above (the selector's ISLANDS row): the check walks what the selector knows, all nine
[ "$(printf '%s' "$FACTS_ISLANDS" | tr '\n' ' ')" = "$ALL_ISLANDS" ] \
  && ok "the facts files checked are the selector's list (--list-islands), all nine" || bad "facts list" "got '$(printf '%s' "$FACTS_ISLANDS" | tr '\n' ' ')'"
for isl in $FACTS_ISLANDS; do
  miss="$(facts_sections "$REPO/docs/intake/$isl.md" | tr '\n' ';')"
  [ -z "$miss" ] && ok "docs/intake/$isl.md: both sections, a Sources row" || bad "facts sections $isl" "$miss"
done
# the series an experiment may read (homelab#3605 acceptance 5): a `## Sources` row is marked by the word
# `experiment` in its note cell. Expected: an island whose Sources has a row reading Prometheus marks at least
# one, and a marked row's read is a Prometheus one; an island with no Prometheus row says so in one line under
# the table and marks none. Which islands have no Prometheus row, read from the files at the issue's base:
# launch, retro, scan (their one live-value row points at the agent loop's).
src_rows() { # <facts file> → the Sources table's data rows as `read<TAB>note`
  awk -F'|' '/^## /{sec=$0} sec=="## Sources" && /^\|/ && NF >= 5 && $2 !~ /^ *(question|-+) *$/ {print $3 "\t" $4}' "$1"; }
exp_none=""
for isl in $FACTS_ISLANDS; do
  f="$REPO/docs/intake/$isl.md"
  prom="$(src_rows "$f" | cut -f1 | grep -c 'Prometheus' || true)"; marked="$(src_rows "$f" | cut -f2 | grep -c '\*\*experiment\*\*' || true)"
  stray="$(src_rows "$f" | awk -F'\t' '$2 ~ /\*\*experiment\*\*/ && $1 !~ /Prometheus/' | grep -c . || true)"
  line="$(awk '/^## /{sec=$0} sec=="## Sources"' "$f" | grep -c '^No row here is a series an experiment may read' || true)"
  if [ "$prom" -gt 0 ]; then
    { [ "$marked" -ge 1 ] && [ "$stray" = 0 ] && [ "$line" = 0 ]; } && ok "docs/intake/$isl.md: $marked of its $prom Prometheus row(s) marked \`experiment\`, no other row" \
      || bad "experiment marks $isl" "prometheus rows=$prom marked=$marked marked-non-prometheus=$stray none-line=$line"
  else
    exp_none="$exp_none$isl "
    { [ "$marked" = 0 ] && [ "$line" = 1 ]; } && ok "docs/intake/$isl.md: no Prometheus row — says so in one line under the table, marks none" \
      || bad "experiment none-line $isl" "marked=$marked none-line=$line"
  fi
done
[ "$(printf '%s' "$exp_none" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')" = "launch retro scan " ] && ok "the islands with no series to read are launch, retro, scan" || bad "experiment none islands" "got '$exp_none'"
# the check can fail: one file per shortfall, built here (never a copy of a real facts file)
FX="$TMP/facts-fx"; mkdir -p "$FX"
printf '# x\n\nBody shape: edit\n\n- a fact\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n| where is the cap | `a.yaml`, `storage:` | — |\n\n## What a ride can do\n\n- **Recipe**: x\n' > "$FX/good.md"
printf '# x\n\n- a fact\n\n## What a ride can do\n\n- **Recipe**: x\n' > "$FX/no-sources.md"
printf '# x\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n| q | `r` | n |\n' > "$FX/no-ride.md"
printf '# x\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n\n## What a ride can do\n\n- x\n' > "$FX/no-row.md"
printf '# x\n\n## Sources\n\n| Read | Why |\n|---|---|\n| `r` | w |\n\n## What a ride can do\n\n- x\n' > "$FX/old-table.md"
printf '# x\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n| q |  | n |\n\n## What a ride can do\n\n- x\n' > "$FX/empty-read.md"
printf '# x\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n| q | `r` | n |\n\n## What a ride can do\n\n## Next\n\n- x\n' > "$FX/empty-ride.md"
printf '# x\n\nthe island rows live under `## Sources` and `## What a ride can do` below\n' > "$FX/mention-only.md"
fx() { # <file> <expected shortfall lines, ;-joined> <label>
  got="$(facts_sections "$FX/$1" | tr '\n' ';')"
  [ "$got" = "$2" ] && ok "$3" || bad "$3" "want '$2' got '$got'"
}
fx good.md          ''                                                   "a file with both sections and one row passes"
fx no-sources.md    'no `## Sources` heading;'                           "…without \`## Sources\`: fails"
fx no-ride.md       'no `## What a ride can do` heading;'                "…without \`## What a ride can do\`: fails"
fx no-row.md        '`## Sources` table has no row;'                     "…a \`## Sources\` table with a header and no row: fails"
fx old-table.md     '`## Sources` has no `| question | read | note |` table;' "…a \`## Sources\` table in another shape (\`Read | Why\`): fails"
fx empty-read.md    '`## Sources` table has no row;'                     "…a row whose read cell is empty is not a row"
fx empty-ride.md    '`## What a ride can do` is empty;'                  "…an empty \`## What a ride can do\`: fails"
fx mention-only.md  'no `## Sources` heading;no `## What a ride can do` heading;' "…a prose mention of the headings is not the headings"

# ── the workflow's review stage, run (islands/intake/rules/intake.md §Review and repair) ─────────────────────
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
## Experiment
No widget job fails in the 7 d after the merge, while the widget exporter was scraped — series `widget_job_failures_total`; baseline: 6 failed jobs over the 14 d to 2026-01-15T00:00:00Z.
Written at intake, before the result. Not the ride's to change: no PR and no comment edits this section.

```experiment
{"id": "gateway-widget-jobs-not-failing", "requirement": "GW-X", "cases": [], "kpi": {"query": "(sum(increase(widget_job_failures_total[$window])) or vector(0)) and on() (min(avg_over_time(up{job=\"widget-exporter\"}[$window])) > 0.95)", "pass": "<= 0", "baseline": 6, "min_window": "7d", "max_window": "7d", "min_samples_query": "sum(increase(widget_jobs_total[$window]))", "min_samples": 20}}
```
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
# the `spec` fixture body carries a valid `## Experiment` (homelab#3605 acceptance 6): the loader accepts it, and the
# launcher hands the unit lens — which runs no python — the loader's answer beside the body (`exit 0`, nothing else)
python3 -I "$REPO/islands/intake/scripts/experiment.py" load --check "$TMP/body-9.md"; rc=$?
[ "$rc" = 0 ] && ok "the \`spec\` fixture body passes experiment.py load --check" || bad "spec fixture experiment" "exit $rc"
[ "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>/dev/null)" = "exit 0" ] \
  && ok "the unit lens's case carries the loader's answer on the body (issues/9.experiment.txt: exit 0)" || bad "case experiment.txt" "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>&1)"
[ -z "$(find "$TMP/run/review" -path '*rows*' -name '*.experiment.txt')" ] && ok "…the rows lens's worlds get none (pass 1 sees masked/ + process/ only)" || bad "rows experiment.txt" "$(find "$TMP/run/review" -name '*.experiment.txt')"
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

# an `edit` body (intake.md §A queue-ready body: exact replacements + check commands, `## Decision`, no rows
# table) goes through the unit lens ONLY. The fixture is homelab#3563's queued body with its `## Key rows`
# section rewritten as `## Decision` (homelab#3576 acceptance 6). §Review and repair step 1: the author writes
# a `rows:` line for a `spec` body only — so the units are one `unit:` line, and the launcher, which runs the
# rows lens per `rows:` line, starts no rows session (no pass 1, no pass 2).
cp "$TMP/body-9.md" "$TMP/body-9.spec"; cp "$TMP/r-author.out" "$TMP/r-author.spec"
cp "$REPO/islands/intake/tests/fixtures/edit-body-3563.md" "$TMP/body-9.md"
{ grep -q '^## Decision' "$TMP/body-9.md" && ! grep -qE '^## (Spec changes|Key rows)' "$TMP/body-9.md" && ! grep -q '^| *description *|' "$TMP/body-9.md"; } \
  && ok "the edit fixture: \`## Decision\`, no \`## Spec changes\` / \`## Key rows\`, no rows table" || bad "edit fixture shape" "$(grep -n '^## ' "$TMP/body-9.md" | tr '\n' ' ')"
cat > "$TMP/r-author.out" <<EOF
… the first pass, an edit body …
## Review units
- unit: $H#9 base=$(git -C "$REPO" rev-parse HEAD)
INTAKE-RULED: dig-2026-10-26/$R2/finding-2 queue $H#9
INTAKE-HOLD: $H#9 add=agent-fix,task/fix,agent/queued
EOF
gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
{ [ "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')" = "author unit repair " ] \
    && [ "$(jq -c '[.review.lenses[] | [.lens, .status, .runs]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["unit","ran",1]]' ] \
    && [ "$(jq -c '[.review.units[].kind]' "$TMP/up/receipt.json" 2>/dev/null)" = '["unit"]' ] \
    && grep -q '^## Decision' "$TMP/run/review/case-unit-0/issues/9.md" && [ -z "$(find "$TMP/run/review" -maxdepth 1 -name 'rows-pass1*' -o -maxdepth 1 -name 'case-rows*')" ] \
    && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls"; } \
  && ok "an \`edit\` body: sessions author → unit lens → repair; the unit lens read the body, NO rows lens ran (no pass 1, no pass 2), still labelled" \
  || bad "edit body review" "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ') | $(jq -c .review "$TMP/up/receipt.json" 2>/dev/null)"
# …and a `rows:` line an author wrote for it by mistake starts no rows session either: the body has no
# `## Spec changes` section to mask, so the launcher records the lens as skipped and the queue is not held
printf -- '- rows: %s base=%s\n' "$H#9" "$(git -C "$REPO" rev-parse HEAD)" >> "$TMP/r-author.out"
gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
{ [ "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')" = "author unit repair " ] \
    && [ "$(jq -c '[.review.lenses[] | [.lens, .status, .runs]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["unit","ran",1],["rows","skipped: #9 carries no description-keyed spec table (nothing to mask)",0]]' ] \
    && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls"; } \
  && ok "…a mistaken \`rows:\` line on an \`edit\` body: recorded skipped (nothing to mask), no rows session, still labelled" \
  || bad "edit body, stray rows line" "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ') | $(jq -c .review.lenses "$TMP/up/receipt.json" 2>/dev/null)"
# `experiment/open` (intake.md §Experiment: set with the queue labels) is a label the belt applies — and a repair
# that queued the issue but left it off is finished by the belt: the POST carries it, no comment is repeated
cp "$TMP/r-author.out" "$TMP/r-author.noexp"
sed -i "s|^INTAKE-HOLD: $H#9 add=agent-fix,task/fix,agent/queued\$|INTAKE-HOLD: $H#9 add=agent-fix,task/fix,agent/queued,experiment/open|" "$TMP/r-author.out"
gview '["agent-fix","task/fix","agent/queued"]' "intake: review — x" "intake: queue — y"; review_run apply
{ grep -qF "gh api -X POST repos/$H/issues/9/labels -f labels[]=agent-fix -f labels[]=task/fix -f labels[]=agent/queued -f labels[]=experiment/open" "$TMP/gh.calls" && [ ! -s "$TMP/gh.comments" ]; } \
  && ok "a held \`experiment/open\` the repair left off a queued issue: the belt adds it, no second comment" || bad "belt experiment/open" "$(grep labels "$TMP/gh.calls"; cat "$TMP/gh.comments" 2>/dev/null)"
gview '["agent-fix","task/fix","agent/queued","experiment/open"]' "intake: review — x" "intake: queue — y"; review_run apply
! grep -q '/labels' "$TMP/gh.calls" && ok "…and an issue that already carries it is left alone" || bad "belt experiment/open idempotent" "$(grep labels "$TMP/gh.calls")"
[ "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>/dev/null)" = "exit 0" ] && ok "the \`edit\` body's case carries the loader's answer too (exit 0)" || bad "edit case experiment.txt" "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>&1)"
# a body whose section is malformed: the lens reads the loader's own line and exit 2. The body is the loader's
# fixture malformed-no-block.md; the expected line is its hand-written `fault` in fixtures/experiment/expected.json
cp "$TMP/body-9.md" "$TMP/body-9.edit"; cp "$REPO/islands/intake/tests/fixtures/experiment/malformed-no-block.md" "$TMP/body-9.md"
gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
want="experiment: malformed — $(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["malformed-no-block.md"]["fault"])' "$REPO/islands/intake/tests/fixtures/experiment/expected.json")
exit 2"
{ [ "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>/dev/null)" = "$want" ] && grep -qF "gh api -X POST repos/$H/issues/9/labels" "$TMP/gh.calls"; } \
  && ok "a malformed section: the case carries the loader's fault line and exit 2 — and the queue is not held" || bad "malformed experiment.txt" "$(cat "$TMP/run/review/case-unit-0/issues/9.experiment.txt" 2>&1)"
cp "$TMP/body-9.edit" "$TMP/body-9.md"; cp "$TMP/r-author.noexp" "$TMP/r-author.out"
# a body that still says `## Key rows` over a description table is not a `spec` body: nothing is masked
printf '## Deliverable\nx\n## Key rows\n| description | a || b |\n|---|---||---|\n| "old heading" | 1 || 2 |\n' > "$TMP/body-9.md"
gview '[]' "intake: review — x" "intake: queue — y"; review_run apply
[ "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')" = "author unit repair " ] \
  && ok "\`## Key rows\` is no longer a rows-lens heading: only \`## Spec changes\` is masked and read" || bad "key rows heading" "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')"
cp "$TMP/body-9.spec" "$TMP/body-9.md"; cp "$TMP/r-author.spec" "$TMP/r-author.out"

rm -f "$TMP/r.calls" "$TMP"/prompt-*.txt; RUN_PATH="$RBIN:$BIN" RUN_ENV="REVIEW=off" run_script apply
{ [ "$(grep -c . "$TMP/r.calls")" = 1 ] && grep -q 'REVIEW: off' "$TMP/prompt-author.txt" && ! grep -q 'INTAKE-HOLD:' "$TMP/prompt-author.txt"; } 2>/dev/null \
  && ok "review=off: one author session, told to label as it rules" || bad "review off" "$(cat "$TMP/r.calls")"

# ── stack islands: declared in the AgentStack claim (homelab#3580) ─────────────────────────────────
# No real stack: fixtures/stack-claims.json is an invented claims list in the live answer's STRUCTURE
# (a v1 List of AgentStack items: metadata.name, spec.repos[].name/.specs/.intake) — stack `beta` first
# so the order below is the selector's sort, not the file's — and fixtures/stack-repos/<repo>/ are the
# repos the `git clone` stub serves. Expected values, from the issue's acceptance:
#   alpha: alpha-iac (no `intake`) → no island; alpha-app (intake.facts docs/intake.md, complete) → `alpha/alpha-app`
#   beta:  beta-svc (facts path absent from its repo) → listed, its step fails; beta-web (facts file with no
#          `Body shape:` line and no `## What a ride can do`) → listed, its step fails
section "stack islands — the claim declares them (homelab#3580)"
SFX="$REPO/islands/intake/tests/fixtures"; CLAIMS_FX="$SFX/stack-claims.json"
got="$(bash "$SEL" --list-islands --claims "$CLAIMS_FX" 2>"$TMP/slist.err")"; rc=$?
{ [ "$rc" = 0 ] && [ "$(printf '%s' "$got" | tr '\n' ' ')" = "$ALL_ISLANDS alpha/alpha-app beta/beta-svc beta/beta-web" ] && [ ! -s "$TMP/slist.err" ]; } \
  && ok "--list-islands --claims: the platform islands as today, then one <stack>/<repo> per declaring repo, by stack then repo; a repo without the field is absent" \
  || bad "--list-islands --claims" "rc=$rc got '$(printf '%s' "$got" | tr '\n' ' ')' $(cat "$TMP/slist.err")"
echo 'not json' > "$TMP/claims-bad.json"
bash "$SEL" --list-islands --claims "$TMP/claims-bad.json" >/dev/null 2>"$TMP/slist.err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'not a claims list' "$TMP/slist.err"; } && ok "…an unreadable claims file is exit 2, never a list without the stack islands" || bad "--claims unreadable" "rc=$rc $(cat "$TMP/slist.err")"
# a claim is a stack's own text: a name or a path that is not a plain name / repo-relative path is dropped, loudly
jq '.items[0].spec.repos += [{"name": "beta-x", "intake": {"facts": "../../etc/passwd"}}, {"name": "b;x", "intake": {"facts": "f.md"}}]' "$CLAIMS_FX" > "$TMP/claims-odd.json"
got="$(bash "$SEL" --list-islands --claims "$TMP/claims-odd.json" 2>"$TMP/slist.err" | tr '\n' ' ')"
{ [ "$got" = "$ALL_ISLANDS alpha/alpha-app beta/beta-svc beta/beta-web " ] && [ "$(grep -c 'left out' "$TMP/slist.err")" = 2 ]; } \
  && ok "…a facts path with \`..\` or a repo name with a shell character is left out and named on stderr" || bad "--claims odd names" "got '$got' $(cat "$TMP/slist.err")"
# resolution: a platform name → this repo + docs/intake/<island>.md, no claims; a stack name → the claim's repo + path
[ "$(bash "$SEL" --resolve --island router-pair 2>/dev/null)" = '{"island":"router-pair","kind":"platform","repo":"teststuffstash/homelab","facts":"docs/intake/router-pair.md"}' ] \
  && ok "--resolve: a platform island is homelab and its docs/intake/ file, with no claims file" || bad "--resolve platform" "$(bash "$SEL" --resolve --island router-pair 2>&1)"
[ "$(bash "$SEL" --resolve --island alpha/alpha-app --claims "$CLAIMS_FX" 2>/dev/null)" = '{"island":"alpha/alpha-app","kind":"stack","repo":"teststuffstash/alpha-app","facts":"docs/intake.md"}' ] \
  && ok "--resolve: a stack island is <org>/<repo> and the claim's facts path" || bad "--resolve stack" "$(bash "$SEL" --resolve --island alpha/alpha-app --claims "$CLAIMS_FX" 2>&1)"
[ "$(ORG=otherorg bash "$SEL" --resolve --island beta/beta-svc --claims "$CLAIMS_FX" 2>/dev/null | jq -r '.repo + " " + .facts')" = "otherorg/beta-svc docs/intake/facts.md" ] \
  && ok "…the org is the environment's (ORG), the repo and the path are the claim's" || bad "--resolve org" "$(ORG=otherorg bash "$SEL" --resolve --island beta/beta-svc --claims "$CLAIMS_FX" 2>&1)"
for row in "alpha/alpha-iac:--claims:$CLAIMS_FX:a repo that declares no intake" "alpha/nope:--claims:$CLAIMS_FX:a repo no claim has" "nostack/alpha-app:--claims:$CLAIMS_FX:a stack no claim has" "nope:::a name with no table row"; do
  IFS=: read -r isl flag file what <<< "$row"
  # shellcheck disable=SC2086  # flag + file are one optional pair
  out="$(bash "$SEL" --resolve --island "$isl" $flag $file 2>"$TMP/sres.err")"; rc=$?
  { [ "$rc" = 2 ] && [ -z "$out" ] && grep -q 'resolves to nothing' "$TMP/sres.err"; } && ok "--resolve $isl ($what): exit 2, \`resolves to nothing\`" || bad "--resolve $isl" "rc=$rc out=$out $(cat "$TMP/sres.err")"
done
bash "$SEL" --resolve --island alpha/alpha-app >/dev/null 2>"$TMP/sres.err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'needs --claims' "$TMP/sres.err"; } && ok "…a stack name without a claims file is exit 2 (never the default repo)" || bad "--resolve no claims" "rc=$rc $(cat "$TMP/sres.err")"

# membership (fixtures/stack-issues.json, seven open issues of the repo). Undecided by the pile's own filters:
# #5 carries agent/queued and #6 a standing `intake:` ruling → out; #1 #2 #3 #4 #7 remain. The facts file's
# `## Membership` lines (fixtures/stack-repos/alpha-app/docs/intake.md): `exclude label: epic` → #2;
# `exclude title: ^(release|chore\(deps\)):` → #1 (`release: 1.4.0`) and #7 (`chore(deps): …`), NOT #3 (its
# `release:` is mid-title). #4 has a title and a Touches the gateway's row would claim: here it is a member.
SISS="$SFX/stack-issues.json"; AFACTS="$SFX/stack-repos/alpha-app/docs/intake.md"
smem() { INTAKE_ISSUES_JSON="$SISS" bash "$SEL" --island alpha/alpha-app --claims "$CLAIMS_FX" "$@" --json 2>"$TMP/smem.err" | jq -r '[.[] | select(.kind == "member") | .number] | sort | map(tostring) | join(" ")'; }
[ "$(smem)" = "1 2 3 4 7" ] && ok "a stack island's members with no --facts: every undecided open issue of the repo, whatever its title or Touches" || bad "stack members" "$(smem) $(cat "$TMP/smem.err")"
[ "$(smem --facts "$AFACTS")" = "3 4" ] && ok "…with the facts file: minus \`exclude label:\` and \`exclude title:\` (an anchored ERE: a mid-title match stays)" || bad "stack exclusions" "$(smem --facts "$AFACTS") $(cat "$TMP/smem.err")"
sed '/^## Membership$/,/^## Sources$/{/^## Sources$/!d}' "$AFACTS" > "$TMP/facts-nomem.md"
[ "$(smem --facts "$TMP/facts-nomem.md")" = "1 2 3 4 7" ] && ok "…a facts file with no \`## Membership\` section excludes nothing" || bad "no membership section" "$(smem --facts "$TMP/facts-nomem.md")"
printf '# x\n\n## Membership\n\n- exclude labels: epic\n' > "$TMP/facts-typo.md"
INTAKE_ISSUES_JSON="$SISS" bash "$SEL" --island alpha/alpha-app --claims "$CLAIMS_FX" --facts "$TMP/facts-typo.md" --json >/dev/null 2>"$TMP/smem.err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'unknown membership line' "$TMP/smem.err"; } && ok "…a mistyped \`exclude\` line is exit 2, never a wider membership" || bad "membership typo" "rc=$rc $(cat "$TMP/smem.err")"
printf '# x\n\n## Membership\n\nexclude title: ^(release\n' > "$TMP/facts-ere.md"
INTAKE_ISSUES_JSON="$SISS" bash "$SEL" --island alpha/alpha-app --claims "$CLAIMS_FX" --facts "$TMP/facts-ere.md" --json >/dev/null 2>"$TMP/smem.err"; rc=$?
{ [ "$rc" = 2 ] && grep -q 'not a usable ERE' "$TMP/smem.err"; } && ok "…an ERE grep refuses is exit 2" || bad "membership ERE" "rc=$rc $(cat "$TMP/smem.err")"
INTAKE_ISSUES_JSON="$SISS" bash "$SEL" --island alpha/alpha-app --claims "$CLAIMS_FX" --facts "$TMP/no-such-facts.md" --json >/dev/null 2>"$TMP/smem.err"; rc=$?
[ "$rc" = 2 ] && ok "…an unreadable --facts file is exit 2" || bad "membership facts unreadable" "rc=$rc"
# the pile for a stack island: ids carry the stack's repo; the receipts are read from intake-<stack>-<repo>-<day>/
TSS="$TMP/ts-stack"; mkdir -p "$TSS/homelab"
spile() { INTAKE_ISSUES_JSON="$SISS" INTAKE_TS_DIR="$TSS" INTAKE_NOW="$NOW" bash "$SEL" --source pile --island alpha/alpha-app --claims "$CLAIMS_FX" --facts "$AFACTS" --out "$TMP/spile.json" 2>"$TMP/spile.err"; }
spile; rc=$?
{ [ "$rc" = 0 ] && [ "$(jq -c '[.island, [.inputs[].id]]' "$TMP/spile.json")" = '["alpha/alpha-app",["teststuffstash/alpha-app#3","teststuffstash/alpha-app#4"]]' ]; } \
  && ok "--source pile: the stack island's inputs are ids of ITS repo (<org>/<repo>#<n>)" || bad "stack pile" "rc=$rc $(jq -c '[.island, [.inputs[].id]]' "$TMP/spile.json" 2>&1) $(tail -1 "$TMP/spile.err")"
# two apply receipts today under the slash-less prefix reach the daily cap (INTAKE_DAILY_MAX default 2); the same
# two under another island's prefix do not
for r in a b; do mkdir -p "$TSS/homelab/intake-gateway-2026-10-27/$r"; echo '{"schema":"island-intake-receipt/v1","mode":"apply","session_ran":true,"ts":"2026-10-27T01:00:00Z","ruled":[]}' > "$TSS/homelab/intake-gateway-2026-10-27/$r/receipt.json"; done
spile; rc1=$?
mv "$TSS/homelab/intake-gateway-2026-10-27" "$TSS/homelab/intake-alpha-alpha-app-2026-10-27"
spile; rc2=$?
{ [ "$rc1" = 0 ] && [ "$rc2" = 1 ] && grep -q 'hold: daily cap' "$TMP/spile.err"; } \
  && ok "…its receipts are read from homelab/intake-<stack>-<repo>-<day>/ (the name with / replaced by -): two there reach its daily cap" || bad "stack receipts prefix" "rc1=$rc1 rc2=$rc2 $(tail -1 "$TMP/spile.err")"
rm -rf "$TSS/homelab/intake-alpha-alpha-app-2026-10-27"
for src in dig wait; do
  INTAKE_TS_DIR="$TSS" INTAKE_NOW="$NOW" bash "$SEL" --source "$src" --island alpha/alpha-app --claims "$CLAIMS_FX" --out "$TMP/snone.json" 2>"$TMP/snone.err"; rc=$?
  { [ "$rc" = 1 ] && grep -q 'no dig source for a stack island' "$TMP/snone.err" \
      && jq -e --arg s "$src" '.schema == "island-intake-select/v1" and .source == $s and .counts.inputs == 0 and .inputs == []' "$TMP/snone.json" >/dev/null; } \
    && ok "--source $src for a stack island selects nothing and says \`no dig source for a stack island\` (a valid empty selection, exit 1)" || bad "stack $src" "rc=$rc $(cat "$TMP/snone.err")"
done
INTAKE_ISSUES_JSON="$SISS" INTAKE_TS_DIR="$TSS" INTAKE_NOW="$NOW" bash "$SEL" --source gaps --island alpha/alpha-app --claims "$CLAIMS_FX" --out "$TMP/snone.json" 2>/dev/null; rc=$?
{ [ "$rc" = 1 ] && jq -e '.counts.inputs == 0 and .specs_root == null' "$TMP/snone.json" >/dev/null; } && ok "--source gaps for a stack island: no specs root, nothing selected" || bad "stack gaps" "rc=$rc"

# the facts check is ONE script (scripts/facts-check.sh): the launcher runs it before any session, facts_sections
# above is its --sections mode. In full it also wants the `Body shape:` line — and every platform facts file passes it.
FC="$REPO/islands/intake/scripts/facts-check.sh"
miss=""; for isl in $FACTS_ISLANDS; do bash "$FC" "$REPO/docs/intake/$isl.md" >/dev/null || miss="$miss $isl"; done
[ -z "$miss" ] && ok "facts-check.sh passes every platform island's docs/intake/<island>.md (the launcher runs it for them too)" || bad "facts-check platform" "fails:$miss"
out="$(bash "$FC" "$AFACTS")"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && ok "facts-check.sh: the complete stack facts file passes (exit 0, nothing printed)" || bad "facts-check good" "rc=$rc $out"
out="$(bash "$FC" "$SFX/stack-repos/beta-web/docs/intake.md" | tr '\n' ';')"
[ "$out" = 'no single `Body shape: spec|edit` line;no `## What a ride can do` heading;' ] && ok "…a file without a \`Body shape:\` line and \`## What a ride can do\`: both named, exit 1" || bad "facts-check incomplete" "$out"
out="$(bash "$FC" "$SFX/stack-repos/beta-svc/docs/intake/facts.md" | tr '\n' ';')"
[ "$out" = 'the facts file does not exist (or is empty);' ] && ok "…a missing file: named" || bad "facts-check missing" "$out"
printf '# x\n\nBody shape: spec\nBody shape: edit\n\n## Sources\n\n| question | read | note |\n|---|---|---|\n| q | `r` | n |\n\n## What a ride can do\n\n- x\n' > "$TMP/facts-two-shapes.md"
[ "$(bash "$FC" "$TMP/facts-two-shapes.md" | tr '\n' ';')" = 'no single `Body shape: spec|edit` line;' ] && ok "…two \`Body shape:\` lines are not one" || bad "facts-check two shapes" "$(bash "$FC" "$TMP/facts-two-shapes.md")"

# the sitting, run for a stack island. Stubs in front of the platform rows': kubectl serves the fixture claims
# (STUB_KUBECTL=fail|empty for the failures), git serves homelab from the checkout (the bootstrap's clone) and a
# stack repo from fixtures/stack-repos/<repo> by the URL's name, claude and gh record where they ran / what they wrote.
SB="$TMP/sbin"; mkdir -p "$SB"
cat > "$SB/kubectl" <<EOF
#!/bin/bash
echo "kubectl \$*" >> "$TMP/skubectl.calls"
case "\${STUB_KUBECTL:-ok}" in
  fail) echo 'Error from server (Forbidden): agentstacks.platform.teststuff.net is forbidden' >&2; exit 1;;
  empty) echo '{"apiVersion":"v1","kind":"List","items":[]}';;
  *) case "\$*" in "get agentstacks.platform.teststuff.net "*"-o json") cat "$CLAIMS_FX";; *) exit 1;; esac;;
esac
EOF
cat > "$SB/git" <<EOF
#!/bin/bash
echo "git \$* (cwd \$PWD)" >> "$TMP/sgit.calls"
case " \$* " in
  *" clone "*)
    url=""; for a in "\$@"; do case "\$a" in https://*) url="\$a";; esac; done
    case "\$url" in */homelab.git) exec "$BIN/git" "\$@";; esac
    src="$SFX/stack-repos/\$(basename "\$url" .git)"; dest="\${@: -1}"
    [ -d "\$src" ] || { echo "fatal: repository '\$url' not found" >&2; exit 128; }
    mkdir -p "\$dest" && cp -R "\$src/." "\$dest/";;
esac
exit 0
EOF
cat > "$SB/claude" <<EOF
#!/bin/bash
echo "claude cwd=\$PWD" >> "$TMP/sclaude.calls"
cat "$TMP/sclaude.out"
EOF
cat > "$SB/gh" <<EOF
#!/bin/bash
echo "gh \$*" >> "$TMP/sgh.calls"
case "\$1 \$2" in "issue view") echo '{"labels":[],"comments":[]}';; esac
exit 0
EOF
chmod +x "$SB"/*
stack_run() { # <island> <mode> [env…]
  rm -f "$TMP/skubectl.calls" "$TMP/sgit.calls" "$TMP/sclaude.calls" "$TMP/sgh.calls" "$TMP/pgw.body" "$TMP/s5.dest"
  TS="$TSS" PILE_JSON="$SISS" RUN_PATH="$SB:$BIN" RUN_ENV="ISLAND=$1 PUSHGATEWAY=http://pgw REVIEW=off ${*:3}" run_script "$2"
}
# the island label a Pushgateway URL carries: `island/<name>`, or `island@base64/<url-safe base64>` decoded back
pgw_island() { # <curl.calls> → the island each metrics push names, one per line
  sed -n 's#.*/metrics/job/island_intake/##p' "$1" | while read -r seg; do
    case "$seg" in island@base64/*) b="${seg#island@base64/}"; b="$(printf '%s' "$b" | tr -- '-_' '+/')"; while [ $(( ${#b} % 4 )) -ne 0 ]; do b="$b="; done; printf '%s' "$b" | base64 -d; echo;;
                   island/*) echo "${seg#island/}";; *) echo "?$seg";; esac
  done
}
# #3 ruled standing, #4 queued with its hold line (review off: the belt labels it); a forged id of another repo is dropped
printf 'INTAKE-RULED: teststuffstash/alpha-app#3 standing -\nINTAKE-RULED: teststuffstash/alpha-app#4 queue -\nINTAKE-HOLD: teststuffstash/alpha-app#4 add=agent-fix,task/fix,agent/queued\nINTAKE-RULED: teststuffstash/homelab#4 queue -\n' > "$TMP/sclaude.out"
stack_run alpha/alpha-app apply; rc=$?
[ "$rc" = 0 ] && ok "a stack island's sitting (alpha/alpha-app) exits 0" || bad "stack sitting" "rc=$rc $(tail -4 "$TMP/run.log")"
{ [ "$(grep -c . "$TMP/skubectl.calls")" = 1 ] && grep -q '^kubectl get agentstacks.platform.teststuff.net .*-o json$' "$TMP/skubectl.calls"; } 2>/dev/null \
  && ok "…the leaf reads the live claims once (kubectl get agentstacks.platform.teststuff.net -o json)" || bad "leaf claims read" "$(cat "$TMP/skubectl.calls" 2>&1)"
{ grep -qE "^git clone -c http\.extraHeader=Authorization: Basic [A-Za-z0-9+/=]+ --depth 1 https://github\.com/teststuffstash/alpha-app\.git $TMP/work/island-repo \(cwd $TMP/work/homelab\)\$" "$TMP/sgit.calls" \
    && [ "$(grep -c ' clone ' "$TMP/sgit.calls")" = 2 ] && [ -s "$TMP/work/island-repo/docs/intake.md" ] && [ -s "$TMP/work/homelab/islands/intake/rules/intake.md" ] \
    && grep -q "^git -C $TMP/work/island-repo remote set-url --push origin " "$TMP/sgit.calls"; } \
  && ok "…and clones the declared repo beside the homelab clone: default branch (no -b), --depth 1, the sitting's token, push URL disabled" || bad "stack clone" "$(cat "$TMP/sgit.calls")"
[ "$(cat "$TMP/sclaude.calls")" = "claude cwd=$TMP/work/island-repo" ] && ok "…the author session runs with that clone as its working directory" || bad "stack cwd" "$(cat "$TMP/sclaude.calls" 2>&1)"
{ grep -qF "Your island's facts file (intake.md §Island facts): docs/intake.md — in this repo (cwd)" "$TMP/up/brief.md" \
    && grep -qF "Read $TMP/work/homelab/islands/intake/rules/intake.md IN FULL" "$TMP/up/brief.md" \
    && grep -qF 'the repo teststuffstash/alpha-app' "$TMP/up/brief.md" && ! grep -q 'docs/intake/alpha' "$TMP/up/brief.md"; } \
  && ok "…its brief hands it the rules from the homelab clone and the facts file from its own repo, at the claim's path" || bad "stack brief" "$(head -12 "$TMP/up/brief.md" 2>&1)"
[ "$(jq -c '[.inputs[] | select(.kind == "member") | .id]' "$TMP/up/inputs.json" 2>/dev/null)" = '["teststuffstash/alpha-app#3","teststuffstash/alpha-app#4"]' ] \
  && [ "$(jq -c '.counts | [.dig, .gaps, .waits]' "$TMP/up/inputs.json")" = '[0,0,0]' ] \
  && ok "…its inputs are the repo's undecided issues minus the facts file's exclusions (the selector got --facts from the clone); no dig, gap or wait input" || bad "stack inputs" "$(jq -c '[.counts, [.inputs[].id]]' "$TMP/up/inputs.json" 2>&1)"
grep -c 'no dig source for a stack island' "$TMP/run.log" | grep -qx 2 && ok "…the dig and wait sources say \`no dig source for a stack island\` in the run's log" || bad "stack dig/wait line" "$(grep -c 'no dig source' "$TMP/run.log")"
[ "$(jq -c '[.island, .island_kind, .repo, .facts, (.ruled | map([.input, .outcome]))]' "$TMP/up/receipt.json" 2>/dev/null)" = '["alpha/alpha-app","stack","teststuffstash/alpha-app","docs/intake.md",[["teststuffstash/alpha-app#3","standing"],["teststuffstash/alpha-app#4","queue"]]]' ] \
  && ok "receipt: island \`alpha/alpha-app\`, its repo and facts path, rulings by the repo's ids (another repo's forged id dropped)" || bad "stack receipt" "$(jq -c '[.island, .repo, .ruled]' "$TMP/up/receipt.json" 2>&1)"
{ [ -s "$TMP/s5.dest" ] && grep -q '/receipt\.json$' "$TMP/s5.dest" \
    && [ -z "$(grep -vE '^s3://b/homelab/intake-alpha-alpha-app-[0-9]{4}-[0-9]{2}-[0-9]{2}/intake-r1-[0-9TZ]+/[^/]+$' "$TMP/s5.dest")" ] \
    && jq -e '(.run | test("^intake-alpha-alpha-app-[0-9-]+/intake-r1-")) ' "$TMP/up/receipt.json" >/dev/null \
    && jq -e '.task | test("^intake-alpha-alpha-app-[0-9]{4}-[0-9]{2}-[0-9]{2}$")' "$TMP/up/manifest.json" >/dev/null; } \
  && ok "…every record lands under s3://<bucket>/homelab/intake-alpha-alpha-app-<day>/ — no slash from the name in the prefix, the run id or the task key" || bad "stack receipt prefix" "$(sort -u "$TMP/s5.dest" 2>/dev/null | head -3)"
{ [ "$(pgw_island "$TMP/curl.calls" | sort -u)" = "alpha/alpha-app" ] && grep -q '/metrics/job/island_intake/island@base64/[A-Za-z0-9_-]*$' "$TMP/curl.calls" \
    && grep -qx 'island_intake_session_ran 1' "$TMP/pgw.body" && grep -qx 'island_intake_inputs 2' "$TMP/pgw.body" && grep -qx 'island_intake_queued 1' "$TMP/pgw.body"; } 2>/dev/null \
  && ok "…its metrics carry island=\"alpha/alpha-app\": the grouping key is \`island@base64/<url-safe base64>\` (no slash in a path segment) and decodes to the name" || bad "stack metrics" "$(grep metrics "$TMP/curl.calls" 2>/dev/null)"
{ grep -q '^gh api -X POST repos/teststuffstash/alpha-app/issues/4/labels ' "$TMP/sgh.calls" && grep -q -- '--repo teststuffstash/alpha-app' "$TMP/sgh.calls" \
    && ! grep -q 'homelab' "$TMP/sgh.calls" && [ "$(jq -c '.review.labelled' "$TMP/up/receipt.json")" = 1 ]; } 2>/dev/null \
  && ok "writes go to the stack's repo: the belt reads and labels teststuffstash/alpha-app#4 — no gh call names homelab" || bad "stack writes" "$(cat "$TMP/sgh.calls" 2>&1)"
{ ! grep -q '/coordinate' "$TMP/curl.calls" && grep -q 'no /coordinate ring for a stack island' "$TMP/run.log"; } \
  && ok "…and a stack island's queue rings no platform /coordinate (said in the log)" || bad "stack ring" "$(grep coordinate "$TMP/curl.calls" "$TMP/run.log")"
stack_run alpha/alpha-app dry-run; rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$TMP/sclaude.calls")" = "claude cwd=$TMP/work/island-repo" ] && jq -e '.mode == "dry-run" and .facts == "docs/intake.md"' "$TMP/up/receipt.json" >/dev/null \
    && ! grep -q ' -X POST ' "$TMP/sgh.calls" 2>/dev/null; } \
  && ok "dry-run for a stack island: the facts file read from the stack's clone at the claim's path, nothing written to GitHub" || bad "stack dry-run" "rc=$rc $(tail -3 "$TMP/run.log")"
# the "did not start" push (the manifest's _dead) names the island the script's own _push names
stack_run alpha/alpha-app apply STUB_DEVBOX_INSTALL_RC=1; rc=$?
{ [ "$rc" = 1 ] && [ "$(pgw_island "$TMP/curl.calls")" = "alpha/alpha-app" ] && grep -qx 'island_intake_probe_ok 0' "$TMP/pgw.body"; } 2>/dev/null \
  && ok "the bootstrap's \"did not start\" push uses the same base64 grouping key for a stack island" || bad "stack _dead key" "rc=$rc $(grep metrics "$TMP/curl.calls" 2>/dev/null)"
# a platform island still resolves with no claims read, no second clone
stack_run mgmt-box apply; rc=$?
{ [ "$rc" = 0 ] && [ ! -e "$TMP/skubectl.calls" ] && [ "$(grep -c ' clone ' "$TMP/sgit.calls")" = 1 ] && [ ! -e "$TMP/work/island-repo" ] && [ "$(pgw_island "$TMP/curl.calls")" = "mgmt-box" ]; } \
  && ok "a platform island resolves to homelab with NO claims read and no second clone (unchanged)" || bad "platform resolution" "rc=$rc kubectl=$(cat "$TMP/skubectl.calls" 2>/dev/null) $(tail -2 "$TMP/run.log")"

# failures of ONE island's step, each before any model session, each pushing probe_ok 0 under its own island label
sfail() { # <island> <log pattern> <label> [env…]
  stack_run "$1" apply "${@:4}"; rc=$?
  { [ "$rc" = 1 ] && [ ! -s "$TMP/sclaude.calls" ] && grep -qE -- "$2" "$TMP/run.log" && [ "$(pgw_island "$TMP/curl.calls")" = "$1" ] && grep -qx 'island_intake_probe_ok 0' "$TMP/pgw.body"; } 2>/dev/null \
    && ok "$3" || bad "$3" "rc=$rc claude=$(cat "$TMP/sclaude.calls" 2>/dev/null) $(tail -3 "$TMP/run.log")"
}
sfail beta/beta-svc 'the facts file docs/intake/facts\.md \(teststuffstash/beta-svc\) cannot carry a sitting: the facts file does not exist' \
  "a claim whose facts path is not in the repo: the step fails naming the path, no session"
sfail beta/beta-web 'cannot carry a sitting: no single `Body shape: spec\|edit` line;no `## What a ride can do` heading' \
  "a facts file without a \`Body shape:\` line and \`## What a ride can do\`: the step fails naming both, no session"
sed '/^## Sources$/,$d' "$AFACTS" > "$TMP/facts-nosrc.md"; printf '\n## What a ride can do\n\n- x\n' >> "$TMP/facts-nosrc.md"
mkdir -p "$TMP/altrepos/alpha-app/docs"; cp "$TMP/facts-nosrc.md" "$TMP/altrepos/alpha-app/docs/intake.md"
sed "s#$SFX/stack-repos#$TMP/altrepos#" "$SB/git" > "$TMP/git.alt"; cp "$SB/git" "$TMP/git.keep"; cp "$TMP/git.alt" "$SB/git"
sfail alpha/alpha-app 'cannot carry a sitting: no `## Sources` heading' "a facts file without \`## Sources\`: the step fails naming it, no session"
cp "$TMP/git.keep" "$SB/git"
sfail alpha/alpha-iac "alpha/alpha-iac resolves to no island" "a name no claim declares (alpha/alpha-iac): that island's step fails — nothing cloned for it, no session"
[ "$(grep -c ' clone ' "$TMP/sgit.calls")" = 1 ] && ok "…with only the bootstrap's homelab clone made" || bad "unresolved clone" "$(cat "$TMP/sgit.calls")"
sfail alpha/alpha-app 'claims read FAILED — stack islands not walked' "a stack island whose claims read fails: the step fails (exit 1 for Argo to retry), no session" STUB_KUBECTL=fail
mkdir -p "$TMP/altrepos2"; sed "s#$SFX/stack-repos#$TMP/altrepos2#" "$TMP/git.keep" > "$SB/git"
sfail alpha/alpha-app 'clone failed \(teststuffstash/alpha-app\)' "a stack repo that does not clone: the step fails, no session"
cp "$TMP/git.keep" "$SB/git"

# the list step with the claims (acceptance 2 + 3): the read, the selector's --claims, the gauge
slist() { # [env…]
  rm -rf "$TMP/work" "$TMP/run"/*; rm -f "$TMP/skubectl.calls" "$TMP/pgw.body"; : > "$TMP/curl.calls"; mkdir -p "$TMP/work"
  ( cd "$TMP" && H="$TMP" PATH="$SB:$BIN:$PATH" HOME="$TMP/home" ISLAND=all GH_TOKEN=x PUSHGATEWAY=http://pgw env "$@" bash "$TMP/list.sh" ) > "$TMP/list.log" 2>&1
}
NINE='"gateway","scan","launch","retro","router-pair","mgmt-box","dependency-upgrades","substrate","agent-loop"'
slist; rc=$?
{ [ "$rc" = 0 ] && [ "$(jq -c . "$LIST_OUT" 2>/dev/null)" = "[$NINE,\"alpha/alpha-app\",\"beta/beta-svc\",\"beta/beta-web\"]" ]; } \
  && ok "the list step reads the live claims and emits the platform islands, then the stack islands" || bad "list step, claims" "rc=$rc $(cat "$LIST_OUT" 2>&1) $(tail -2 "$TMP/list.log")"
{ grep -qx 'island_intake_claims_read_ok 1' "$TMP/pgw.body" && [ "$(grep -c -- '--data-binary @-' "$TMP/curl.calls")" = 1 ] && grep -q '/metrics/job/island_intake_claims$' "$TMP/curl.calls" \
    && ! grep -q 'claims read FAILED' "$TMP/list.log"; } 2>/dev/null \
  && ok "…and pushes island_intake_claims_read_ok 1 from the list step (its own Pushgateway group — no island's gauges replaced)" || bad "claims gauge ok" "$(cat "$TMP/pgw.body" "$TMP/curl.calls" 2>&1)"
for mode in fail empty; do
  slist STUB_KUBECTL=$mode; rc=$?
  { [ "$rc" = 0 ] && [ "$(jq -c . "$LIST_OUT" 2>/dev/null)" = "[$NINE]" ] && grep -qx 'island-intake: claims read FAILED — stack islands not walked' "$TMP/list.log" \
      && grep -qx 'island_intake_claims_read_ok 0' "$TMP/pgw.body" && grep -q '/metrics/job/island_intake_claims$' "$TMP/curl.calls"; } 2>/dev/null \
    && ok "a claims read that $( [ $mode = fail ] && echo fails || echo 'answers no items' ): the platform islands are still emitted, the FAILED line printed, island_intake_claims_read_ok 0 pushed" \
    || bad "list step, claims $mode" "rc=$rc $(cat "$LIST_OUT" 2>&1) $(tail -3 "$TMP/list.log")"
done
[ "$(yqw '.spec.workflowSpec.templates[] | select(.name == "list-islands") | .container.env[] | select(.name == "PUSHGATEWAY") | .value')" = "$(yqw '.spec.workflowSpec.templates[] | select(.name == "intake") | .container.env[] | select(.name == "PUSHGATEWAY") | .value')" ] \
  && ok "the list step's container has the leaf's PUSHGATEWAY" || bad "list step PUSHGATEWAY" "differs or missing"

# the claim field (acceptance 1) and the mirror (acceptance 12)
XRD="$REPO/argocd/resources/agentstack/xrd.yaml"
XI='.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.repos.items.properties.intake'
{ [ "$(yq -r "$XI | .type" "$XRD")" = object ] && [ "$(yq -r "$XI | .required | join(\",\")" "$XRD")" = facts ] \
    && [ "$(yq -r "$XI | .properties | keys | join(\",\")" "$XRD")" = facts ] && [ "$(yq -r "$XI | .properties.facts.type" "$XRD")" = string ] \
    && [ "$(yq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.repos.items.required | join(",")' "$XRD")" = name ]; } \
  && ok "XRD: repos[].intake is an object with ONE required string, facts — and stays optional on a repo" || bad "xrd intake" "$(yq -r "$XI" "$XRD" | head -5)"
XPAT="$(yq -r "$XI | .properties.facts.pattern" "$XRD")"
{ grep -qE -- "$XPAT" <<< "docs/intake.md" && ! grep -qE -- "$XPAT" <<< "../x.md" && ! grep -qE -- "$XPAT" <<< "/abs.md" && ! grep -qE -- "$XPAT" <<< "a/.hidden/x.md"; } \
  && ok "…its facts pattern takes a repo-relative path and refuses \`..\`, a leading slash and a dot-led segment" || bad "xrd facts pattern" "$XPAT"
[ "$(jq '[.. | objects | select(has("intake"))] | length' "$REPO/agents/stacks.json")" = 0 ] \
  && ok "agents/stacks.json (the mirror) carries no \`intake\` key: no stack has declared one, and the launcher never reads the mirror for it" || bad "mirror" "an intake key in agents/stacks.json"
{ ! grep -qE '^[^#]*stacks\.json' "$REPO/islands/intake/scripts/claims-read.sh" "$REPO/islands/intake/scripts/sitting.sh" "$SEL"; } \
  && ok "…no intake script reads agents/stacks.json (the claims are read live)" || bad "mirror read" "$(grep -nE '^[^#]*stacks\.json' "$REPO/islands/intake/scripts/"*.sh | head -3)"

# the point of the child: no stack and no stack repo is named in the scripts, the selector or the manifest. The
# names searched are (a) every non-platform stack and its repos in agents/stacks.json — the names homelab already
# carries — and (b) the fixture's invented ones; whole-word, fixed-string, over code and comments alike.
NAMES="$( { jq -r '.stacks[] | select(.name != "platform") | .name, (.repos[] | if type == "object" then .name else . end)' "$REPO/agents/stacks.json"
            jq -r '.items[] | .metadata.name, (.spec.repos[].name)' "$CLAIMS_FX"; } | sort -u)"
hits=""; for n in $NAMES; do
  h="$(grep -rnwF -- "$n" "$REPO/islands/intake/scripts" "$YAML" | head -2)"; [ -z "$h" ] || hits="$hits [$n] $h"
done
{ [ "$(printf '%s\n' "$NAMES" | grep -c .)" -ge 8 ] && [ -z "$hits" ]; } \
  && ok "no stack or stack-repo name ($(printf '%s\n' "$NAMES" | grep -c .) searched: the mirror's non-platform stacks and repos, the fixture's) in islands/intake/scripts/ or the manifest" \
  || bad "a stack name in the launcher, the selector or the manifest" "$hits"

# ── the listed-islands gauge (the gate of IslandIntakeStale; the #3574 assembly review) ─────────
section "the list step says which islands it walks (listed-push.sh)"
LP="$REPO/islands/intake/scripts/listed-push.sh"; LBIN="$TMP/lbin"; mkdir -p "$LBIN"
cat > "$LBIN/curl" <<'LPEOF'
#!/bin/bash
echo "curl $*" >> "$H/lp.calls"
for a in "$@"; do case "$a" in @*) cat "${a#@}" >> "$H/lp.body";; esac; done
exit "${STUB_CURL_RC:-0}"
LPEOF
chmod +x "$LBIN/curl"
printf 'gateway\nscan\nalpha/alpha-app\n' > "$TMP/lp.txt"; : > "$TMP/lp.calls"; : > "$TMP/lp.body"
H="$TMP" PATH="$LBIN:$PATH" PUSHGATEWAY=http://pgw bash "$LP" "$TMP/lp.txt" > "$TMP/lp.log" 2>&1; rc=$?
{ [ "$rc" = 0 ] && grep -q -- '-X PUT' "$TMP/lp.calls" && grep -q 'http://pgw/metrics/job/island_intake_list$' "$TMP/lp.calls" \
    && [ "$(grep -c '^island_intake_listed_timestamp_seconds{island=' "$TMP/lp.body")" = 3 ] \
    && grep -q '{island="alpha/alpha-app"} ' "$TMP/lp.body" \
    && [ "$(grep '^island_intake_listed' "$TMP/lp.body" | awk '{print $2}' | sort -u | wc -l)" = 1 ]; } \
  && ok "one PUT (the group is replaced) to job island_intake_list: one series per listed island, all with the same epoch" \
  || bad "listed-push" "rc=$rc $(cat "$TMP/lp.calls" "$TMP/lp.body" "$TMP/lp.log" 2>/dev/null | head -8)"
H="$TMP" PATH="$LBIN:$PATH" PUSHGATEWAY=http://pgw STUB_CURL_RC=7 bash "$LP" "$TMP/lp.txt" > "$TMP/lp.log" 2>&1; rc=$?
{ [ "$rc" = 0 ] && grep -q 'not pushed (the previous list stays in force)' "$TMP/lp.log"; } \
  && ok "…and a Pushgateway that cannot be reached is said and is never fatal to the walk" || bad "listed-push unreachable" "rc=$rc $(cat "$TMP/lp.log")"
yq -r '.spec.workflowSpec.templates[] | select(.name == "list-islands") | .container.args[0]' "$YAML" > "$TMP/list-step.sh"
{ [ "$(grep -c 'bash islands/intake/scripts/listed-push.sh /tmp/island-intake-islands.txt' "$TMP/list-step.sh")" = 1 ] \
    && [ "$(grep -n 'listed-push.sh /tmp' "$TMP/list-step.sh" | cut -d: -f1)" -gt "$(grep -n 'exit 0' "$TMP/list-step.sh" | head -1 | cut -d: -f1)" ]; } \
  && ok "the list step calls it once, on the full walk only (after the named-island early exit)" || bad "list step listed-push" "$(grep -n 'listed-push\|exit 0' "$TMP/list-step.sh" 2>/dev/null | head -4)"

# ── the scheduled experiment read (homelab#3604; scripts/experiment-read.sh) ─────────────────────────────
# Stubs: `gh` (answers from files under $EH, logs every call and every body file it is given), the stub
# Prometheus (prom_stub.py, scenarios of fixtures/experiment-read/prom.json), the s5cmd upload (logged), curl
# (the metrics push, logged). body.md's t0 is the closing PR's mergedAt 2026-11-01T00:00:05Z; its bound is
# 2026-11-08T00:00:05Z. EXP_NOW 1794182405 (2026-11-09T00:00:05Z, a day past the bound) is past the bound: scenario pass → pass (value
# 2), fail → fail (value 7), pending's samples never reach 20 → `no data`; EXP_NOW 1793577605 (2026-11-02T00:00:05Z)
# is inside the window: pending.
section "the scheduled experiment read (experiment-read.sh)"
ER="$REPO/islands/intake/scripts/experiment-read.sh"; EXPFX="$REPO/islands/intake/tests/fixtures/experiment-read"
EH="$TMP/er"; mkdir -p "$EH/bin"
cat > "$EH/bin/gh" <<'GHEOF'
#!/bin/bash
echo "gh $*" >> "$EH/gh.calls"
for ((i=1; i<=$#; i++)); do [ "${!i}" = --body-file ] && { j=$((i+1)); { echo "--- $*"; cat "${!j}"; } >> "$EH/gh.bodies"; }; done
case "$1 $2" in
  "issue list") [ -f "$EH/list.fail" ] && { echo "HTTP 502" >&2; exit 1; }; cat "$EH/list.json";;
  "pr view") f="$EH/pr-$3.json"; [ -f "$f" ] && cat "$f" || { echo "no such PR" >&2; exit 1; };;
  "api repos"*|"api "*) case "$2" in
      */parent) n="${2#repos/*/issues/}"; n="${n%/parent}"; f="$EH/parent-$n.json"; [ -f "$f" ] && cat "$f" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; };;
      */sub_issues*) n="${2#repos/*/issues/}"; n="${n%%/sub_issues*}"; cat "$EH/sub-$n.json";;
    esac;;
  "issue comment"|"issue reopen"|"issue edit") [ -f "$EH/write.fail" ] && { echo "HTTP 403" >&2; exit 1; }; :;;
esac
exit 0
GHEOF
cat > "$EH/bin/s5cmd" <<'S5EOF'
#!/bin/bash
echo "s5cmd $* key=${AWS_ACCESS_KEY_ID:-}" >> "$EH/s5.calls"
[ -f "$EH/s5.fail" ] && { echo "ERROR upload" >&2; exit 1; }
cp "$4" "$EH/up-$(basename "$5")"; exit 0
S5EOF
cat > "$EH/bin/curl" <<'CEOF'
#!/bin/bash
echo "curl $*" >> "$EH/curl.calls"
for a in "$@"; do case "$a" in @*) cp "${a#@}" "$EH/metrics.body";; esac; done; exit 0
CEOF
chmod +x "$EH/bin/"*
python3 -I "$REPO/islands/intake/tests/prom_stub.py" "$EXPFX/prom-read.json" "$EH/prom.port" "$EH/prom.log" > "$EH/prom-stub.log" 2>&1 &
EPID=$!
for _ in $(seq 1 100); do [ -s "$EH/prom.port" ] && break; sleep 0.1; done
EPROM="http://127.0.0.1:$(cat "$EH/prom.port" 2>/dev/null)"
issue_row() { # <n> <labels-csv> <body-file|-> [comments-json] [closing-pr|-]
  local body="" prs='[]'; [ "$3" != - ] && body="$(cat "$3")"; [ "${5:--}" != - ] && prs="[{\"number\":$5}]"
  jq -nc --argjson n "$1" --arg l "$2" --arg b "$body" --argjson c "${4:-[]}" --argjson p "$prs" \
    '{number:$n, title:"t", body:$b, labels:($l | split(",") | map(select(length>0)) | map({name:.})), comments:$c, closedByPullRequestsReferences:$p}'
}
erun() { # <scenario> <now> [args] — a fresh world per call: $EH/list.json (set by the row), logs cleared
  : > "$EH/gh.calls"; : > "$EH/gh.bodies"; : > "$EH/s5.calls"; : > "$EH/curl.calls"; rm -f "$EH"/up-* "$EH/metrics.body"
  local sc="$1" now="$2"; shift 2
  EH="$EH" PATH="$EH/bin:$PATH" PROMETHEUS="$EPROM/$sc" EXP_NOW="$now" PUSHGATEWAY=http://pgw EXPERIMENT_REPO=o/r \
    AGENT_TS_ENDPOINT=http://garage AGENT_TS_BUCKET=agent-transcripts AGENT_TS_ACCESS_KEY_ID=wkey AGENT_TS_SECRET_ACCESS_KEY=wsec \
    bash "$ER" "$@" > "$EH/out.log" 2>&1
}
writes() { grep -cE '^gh issue (comment|reopen|edit)' "$EH/gh.calls"; }
for n in 90 91; do echo '{"mergedAt":"2026-11-01T00:00:05Z"}' > "$EH/pr-$n.json"; done
echo '[]' > "$EH/sub-1.json"
NOW_AFTER=1794182405; NOW_INSIDE=1793577605
B="$EXPFX/body.md"

# pass
issue_row 41 "experiment/open" "$B" '[]' 90 > "$EH/one.json"; jq -s '.' "$EH/one.json" > "$EH/list.json"
erun pass $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 2 ] && grep -q '^gh issue comment 41 --repo o/r --body-file' "$EH/gh.calls" \
    && grep -q '^gh issue edit 41 --repo o/r --remove-label experiment/open$' "$EH/gh.calls" \
    && ! grep -q 'reopen' "$EH/gh.calls" \
    && grep -q '^<!-- experiment-verdict id=press-waits-down -->$' "$EH/gh.bodies" && grep -q 'Experiment `press-waits-down`: pass' "$EH/gh.bodies" \
    && grep -q 'At most three press jobs wait' "$EH/gh.bodies" && grep -q '| window | 2000m from t0 2026-11-01T00:00:05Z |' "$EH/gh.bodies" \
    && grep -q '| value | 2.0 |' "$EH/gh.bodies" && grep -q '| baseline | 5 |' "$EH/gh.bodies" && grep -q 'pass condition | `<= 3`' "$EH/gh.bodies" \
    && grep -q 'guard `errors` | value 0.0, pass `< 1` — ok' "$EH/gh.bodies"; } \
  && ok "pass: one comment (marker, verdict, prose line, the table with its guard), the label removed, nothing reopened" \
  || bad "pass writes" "rc=$rc $(cat "$EH/gh.calls" "$EH/out.log" | head -8)"
{ [ "$(wc -l < "$EH/s5.calls")" = 1 ] && grep -q "s5cmd --endpoint-url http://garage cp .* s3://agent-transcripts/homelab/experiments/41-press-waits-down.json key=wkey" "$EH/s5.calls" \
    && jq -e '.verdict == "pass" and .issue == 41 and .repo == "o/r" and .id == "press-waits-down"' "$EH/up-41-press-waits-down.json" >/dev/null; } \
  && ok "…and its report object goes to s3://agent-transcripts/homelab/experiments/41-<id>.json with the writer key" || bad "report upload" "$(cat "$EH/s5.calls")"
{ grep -q 'metrics/job/island_intake_experiments' "$EH/curl.calls" && grep -q -- '-X PUT' "$EH/curl.calls" \
    && grep -qx 'island_intake_experiments_open 0' "$EH/metrics.body" && grep -qx 'island_intake_experiments_decided_total{verdict="pass"} 1' "$EH/metrics.body" \
    && grep -qx 'island_intake_experiments_oldest_overdue_seconds 0' "$EH/metrics.body" && grep -qx 'island_intake_experiments_fault 0' "$EH/metrics.body" \
    && grep -qx "island_intake_experiments_last_run_timestamp_seconds $NOW_AFTER" "$EH/metrics.body"; } \
  && ok "…and the run's metrics are PUT to job island_intake_experiments" || bad "metrics" "$(cat "$EH/curl.calls" "$EH/metrics.body" 2>&1 | head -8)"

# a second run writes nothing: the label is gone, so the list is empty — and an issue that still carries the label with its marker only loses the label
echo '[]' > "$EH/list.json"; erun pass $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ] && [ ! -s "$EH/s5.calls" ] && [ "$(grep -c '^gh issue list' "$EH/gh.calls")" = 1 ] && ! grep -q '^gh pr' "$EH/gh.calls"; } \
  && ok "a second run writes nothing (one list call, no comment, no upload)" || bad "second run" "rc=$rc $(cat "$EH/gh.calls")"
issue_row 41 "experiment/open" "$B" '[{"body":"<!-- experiment-verdict id=press-waits-down -->\nold"}]' 90 > "$EH/one.json"; jq -s '.' "$EH/one.json" > "$EH/list.json"
erun pass $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'issue comment' "$EH/gh.calls" && [ "$(writes)" = 1 ] && [ ! -s "$EH/s5.calls" ]; } \
  && ok "the marker in the issue's comments is what stops a second comment (a run that died before the label only removes it)" || bad "marker" "rc=$rc $(cat "$EH/gh.calls")"

# fail, no Goal: reopened, agent/* labels removed
issue_row 41 "experiment/open,agent/done,agent-fix,bug" "$B" '[]' 90 > "$EH/one.json"; jq -s '.' "$EH/one.json" > "$EH/list.json"
erun fail $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && grep -q '^gh issue reopen 41 --repo o/r$' "$EH/gh.calls" && grep -q '^gh issue edit 41 --repo o/r --remove-label agent/done$' "$EH/gh.calls" \
    && grep -q '^gh issue edit 41 --repo o/r --remove-label experiment/open$' "$EH/gh.calls" && ! grep -q 'remove-label bug' "$EH/gh.calls" \
    && grep -q 'Experiment `press-waits-down`: fail' "$EH/gh.bodies" \
    && [ "$(grep -n 'issue comment' "$EH/gh.calls" | cut -d: -f1)" -lt "$(grep -n 'issue reopen' "$EH/gh.calls" | cut -d: -f1)" ] \
    && grep -qx 'island_intake_experiments_decided_total{verdict="fail"} 1' "$EH/metrics.body"; } \
  && ok "fail, no Goal ancestor: the comment, then the issue reopened and its agent/* labels (only) removed, the label last" || bad "fail" "rc=$rc $(cat "$EH/gh.calls" "$EH/out.log")"

# fail under a Goal: the child stays closed, the verdict goes to the open post-launch sub-issue (else the Goal)
echo '{"number":1,"labels":[{"name":"task/goal"}]}' > "$EH/parent-41.json"
echo '[{"number":9,"state":"closed","title":"post-launch: old"},{"number":8,"state":"open","title":"Post-launch: verdict of #1"},{"number":7,"state":"open","title":"other"}]' > "$EH/sub-1.json"
erun fail $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && ! grep -q 'reopen' "$EH/gh.calls" && ! grep -q 'remove-label agent/' "$EH/gh.calls" \
    && grep -q '^gh issue comment 41 ' "$EH/gh.calls" && grep -q '^gh issue comment 8 --repo o/r --body-file' "$EH/gh.calls" && ! grep -q '^gh issue comment 1 ' "$EH/gh.calls" \
    && grep -q '^gh issue edit 41 --repo o/r --remove-label experiment/open$' "$EH/gh.calls" && grep -q 'its Goal is #1' "$EH/gh.bodies"; } \
  && ok "fail under a Goal: the child is not reopened or unlabelled; the verdict also goes on the open post-launch: sub-issue; the label is removed" || bad "goal fail" "rc=$rc $(cat "$EH/gh.calls")"
echo '[]' > "$EH/sub-1.json"; erun fail $NOW_AFTER
{ grep -q '^gh issue comment 1 --repo o/r --body-file' "$EH/gh.calls" && ! grep -q 'reopen' "$EH/gh.calls"; } \
  && ok "…and with no post-launch sub-issue, on the Goal itself" || bad "goal fallback" "$(cat "$EH/gh.calls")"
echo '{"number":5,"labels":[{"name":"enhancement"}]}' > "$EH/parent-41.json"; echo '{"number":1,"labels":[{"name":"task/goal"}]}' > "$EH/parent-5.json"
erun fail $NOW_AFTER
{ grep -q '^gh issue comment 1 --repo o/r' "$EH/gh.calls" && ! grep -q 'reopen' "$EH/gh.calls"; } \
  && ok "…a Goal further up the parent chain counts as the ancestor" || bad "goal chain" "$(cat "$EH/gh.calls")"
rm -f "$EH"/parent-*.json

# pass-through of a Goal lookup that errors: nothing written for it, step fails
issue_row 41 "experiment/open" "$B" '[]' 90 > "$EH/one.json"; jq -s '.' "$EH/one.json" > "$EH/list.json"

# no data
erun pending $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && grep -q 'Experiment `press-waits-down`: no data' "$EH/gh.bodies" && [ "$(writes)" = 2 ] && ! grep -q reopen "$EH/gh.calls" \
    && grep -q '^gh issue edit 41 --repo o/r --remove-label experiment/open$' "$EH/gh.calls" && grep -qx 'island_intake_experiments_decided_total{verdict="no data"} 1' "$EH/metrics.body" \
    && grep -q 'min_samples\|samples' "$EH/gh.bodies"; } \
  && ok "no data: the comment with its reason, the label removed, no state change" || bad "no data" "rc=$rc $(cat "$EH/gh.calls" "$EH/gh.bodies" | head -12)"

# pending writes nothing — and an overdue count of 0 inside the window
erun pending $NOW_INSIDE; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ] && [ ! -s "$EH/s5.calls" ] && grep -qx 'island_intake_experiments_open 1' "$EH/metrics.body" \
    && grep -qx 'island_intake_experiments_oldest_overdue_seconds 0' "$EH/metrics.body"; } \
  && ok "pending (inside the window) writes nothing and counts the issue as open" || bad "pending" "rc=$rc $(cat "$EH/gh.calls" "$EH/out.log")"

# faults: no loadable block / no merged closing PR — one comment, the label kept, once
issue_row 42 "experiment/open" - '[]' 91 > /dev/null 2>&1
printf '## Deliverable\nnothing\n' > "$EH/nob.md"
issue_row 42 "experiment/open" "$EH/nob.md" '[]' 91 > "$EH/a.json"; issue_row 43 "experiment/open" "$B" '[]' - > "$EH/b.json"
jq -s '.' "$EH/a.json" "$EH/b.json" > "$EH/list.json"; echo '{"mergedAt":"2026-11-01T00:00:05Z"}' > "$EH/pr-91.json"
erun pass $NOW_AFTER; rc=$?
{ [ "$rc" = 0 ] && [ "$(grep -c '^gh issue comment' "$EH/gh.calls")" = 2 ] && ! grep -q 'remove-label' "$EH/gh.calls" \
    && [ "$(grep -c '^<!-- experiment-fault -->$' "$EH/gh.bodies")" = 2 ] && grep -q 'no loadable experiment block' "$EH/gh.bodies" && grep -q 'no merged pull request' "$EH/gh.bodies" \
    && grep -qx 'island_intake_experiments_fault 2' "$EH/metrics.body" && grep -qx 'island_intake_experiments_open 2' "$EH/metrics.body"; } \
  && ok "a body with no loadable block, and an issue no merged PR closed: one fault comment each, label kept, counted as fault" || bad "faults" "rc=$rc $(cat "$EH/gh.calls" "$EH/gh.bodies" | head -12)"
issue_row 42 "experiment/open" "$EH/nob.md" '[{"body":"<!-- experiment-fault -->\nx"}]' 91 > "$EH/a.json"; issue_row 43 "experiment/open" "$B" '[{"body":"<!-- experiment-fault -->\nx"}]' - > "$EH/b.json"
jq -s '.' "$EH/a.json" "$EH/b.json" > "$EH/list.json"
erun pass $NOW_AFTER
{ [ "$(writes)" = 0 ] && grep -qx 'island_intake_experiments_fault 2' "$EH/metrics.body"; } \
  && ok "…and the fault comment is written once (the marker), the fault still counted" || bad "fault once" "$(cat "$EH/gh.calls")"

# overlap: two experiments, overlapping windows, one metric name
sed 's/press-waits-down/press-second/; s/max_over_time(fx_value\[\$window\])/max_over_time(fx_value[$window])/' "$B" > "$EH/body2.md"
issue_row 41 "experiment/open" "$B" '[]' 90 > "$EH/a.json"; issue_row 42 "experiment/open" "$EH/body2.md" '[]' 91 > "$EH/b.json"
jq -s '.' "$EH/a.json" "$EH/b.json" > "$EH/list.json"; echo '{"mergedAt":"2026-11-01T12:00:05Z"}' > "$EH/pr-91.json"
erun pass 1794182405; rc=$?   # 2026-11-09: both windows (11-01 and 11-03 → 11-08, 11-10) overlap
{ [ "$rc" = 0 ] && [ "$(grep -c '^Overlap: ' "$EH/gh.bodies")" = 2 ] && grep -q '^Overlap: #42 (experiment `press-second`) .* metric `fx_up`' "$EH/gh.bodies" \
    && grep -q '^Overlap: #41 (experiment `press-waits-down`)' "$EH/gh.bodies"; } \
  && ok "overlapping windows on one metric name: each verdict comment carries one line naming the other issue" || bad "overlap" "rc=$rc $(cat "$EH/gh.bodies" | grep -n 'Overlap' )"
echo '{"mergedAt":"2026-11-01T00:00:05Z"}' > "$EH/pr-91.json"
sed 's/fx_value/fx_other_metric/g; s/fx_up/fx_other_up/g' "$EH/body2.md" > "$EH/body3.md"; issue_row 42 "experiment/open" "$EH/body3.md" '[]' 91 > "$EH/b.json"; jq -s '.' "$EH/a.json" "$EH/b.json" > "$EH/list.json"
erun pass 1794182405
{ ! grep -q '^Overlap: ' "$EH/gh.bodies"; } && ok "…and no line for overlapping windows on different metrics" || bad "no overlap" "$(grep Overlap "$EH/gh.bodies")"

# Prometheus down: non-zero, nothing written, nothing pushed; GitHub down likewise
issue_row 41 "experiment/open" "$B" '[]' 90 > "$EH/one.json"; jq -s '.' "$EH/one.json" > "$EH/list.json"
erun down $NOW_AFTER; rc=$?
{ [ "$rc" != 0 ] && [ "$(writes)" = 0 ] && [ ! -s "$EH/s5.calls" ] && [ ! -s "$EH/curl.calls" ] && grep -q 'Prometheus cannot be read' "$EH/out.log"; } \
  && ok "Prometheus unreachable: exit non-zero, nothing written, uploaded or pushed" || bad "prom down" "rc=$rc $(cat "$EH/out.log" "$EH/gh.calls")"
touch "$EH/list.fail"; erun pass $NOW_AFTER; rc=$?; rm -f "$EH/list.fail"
{ [ "$rc" != 0 ] && [ "$(writes)" = 0 ] && [ ! -s "$EH/curl.calls" ] && grep -q 'GitHub did not answer' "$EH/out.log"; } \
  && ok "GitHub unreachable: exit non-zero, nothing written" || bad "gh down" "rc=$rc $(cat "$EH/out.log")"
erun value-down $NOW_AFTER; rc=$?
{ [ "$rc" != 0 ] && [ "$(writes)" = 0 ] && grep -qx 'island_intake_experiments_open 1' "$EH/metrics.body" && grep -qx 'island_intake_experiments_oldest_overdue_seconds 86400' "$EH/metrics.body"; } \
  && ok "one experiment whose read fails mid-run: decided nothing, step non-zero, counted open and overdue (now − bound = 1 d)" || bad "value down" "rc=$rc $(cat "$EH/out.log" "$EH/metrics.body" 2>&1| head -8)"

# the upload fails AFTER the comment is written
touch "$EH/s5.fail"; erun pass $NOW_AFTER; rc=$?; rm -f "$EH/s5.fail"
{ [ "$rc" != 0 ] && grep -q 'issue comment 41' "$EH/gh.calls" && grep -q 'FAILED to upload' "$EH/out.log"; } \
  && ok "a failed report upload fails the step, after the comment was written" || bad "upload fail" "rc=$rc $(cat "$EH/out.log")"

# --dry-run writes nothing and says what it would
erun pass $NOW_AFTER --dry-run; rc=$?
{ [ "$rc" = 0 ] && [ "$(writes)" = 0 ] && [ ! -s "$EH/s5.calls" ] && [ ! -s "$EH/curl.calls" ] \
    && grep -q '\[dry-run\] would comment the verdict (pass) on #41' "$EH/out.log" && grep -q '\[dry-run\] would upload s3://agent-transcripts/homelab/experiments/41-press-waits-down.json' "$EH/out.log" \
    && grep -q 'would remove the label experiment/open from #41' "$EH/out.log"; } \
  && ok "--dry-run prints what it would write and writes nothing (no gh write, upload or push)" || bad "dry-run" "rc=$rc $(cat "$EH/out.log" "$EH/gh.calls" | head -10)"
kill "$EPID" 2>/dev/null; wait "$EPID" 2>/dev/null

# the workflow shape: the `experiments` step runs before the sittings, continues on failure, the workflow still fails
SPEC='.spec.workflowSpec'
steps="$(yq -r "$SPEC.templates[] | select(.name == \"intake-islands\") | .steps | map(.[].name) | join(\" \")" "$YAML")"
[ "$steps" = "experiments islands sitting experiments-failed" ] && ok "intake-islands runs experiments → islands → sitting → experiments-failed, in that order" || bad "step order" "$steps"
[ "$(yq -r "$SPEC.templates[] | select(.name == \"intake-islands\") | .steps[0][0].continueOn.failed" "$YAML")" = true ] \
  && ok "the experiments step is continueOn: failed (the sittings still run)" || bad "continueOn" "$(yq -c "$SPEC.templates[] | select(.name == \"intake-islands\") | .steps[0][0]" "$YAML")"
{ [ "$(yq -r "$SPEC.templates[] | select(.name == \"intake-islands\") | .steps[3][0].when" "$YAML")" = '{{steps.experiments.status}} == Failed' ] \
    && [ "$(yq -r "$SPEC.templates[] | select(.name == \"experiments-failed\") | .container.args[0]" "$YAML" | tr -d ' \n')" != "" ] \
    && yq -r "$SPEC.templates[] | select(.name == \"experiments-failed\") | .container.args[0]" "$YAML" | grep -q 'exit 1'; } \
  && ok "…and a failed experiments step fails the workflow at the end (a step that exits 1 when it failed)" || bad "workflow ends failed" "$(yq -c "$SPEC.templates[] | select(.name == \"experiments-failed\")" "$YAML")"
leaf() { yq -o=json -I=0 ".spec.workflowSpec.templates[] | select(.name == \"$1\") | .container | [.image, .command, .volumeMounts[0], (.env | map(select(.name | test(\"^(HOME|NIX_CONFIG|DEVBOX_.*|DO_NOT_TRACK|VERSION_CACHE_TTL|ORG|GH_TOKEN|AWS_REGION|AGENT_TS_ENDPOINT|AGENT_TS_BUCKET|AGENT_TS_ACCESS_KEY_ID|AGENT_TS_SECRET_ACCESS_KEY|PUSHGATEWAY)\$\")))) ]" "$YAML"; }
{ [ -n "$(leaf experiments)" ] && [ "$(leaf experiments)" = "$(leaf intake)" ]; } \
  && ok "the experiments leaf's image, command, mounts, token, writer key, bucket, HOME and nix env equal a sitting's" || bad "leaf identity (env)" "experiments: $(leaf experiments | cut -c1-300)
       intake:      $(leaf intake | cut -c1-300)"
# the identity: the ServiceAccount is the workflow's (one for every template), the token and the writer key are the sitting's
[ "$(yq -r "$SPEC.serviceAccountName" "$YAML")" = island-intake ] && [ "$(yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .serviceAccountName // \"\"" "$YAML")" = "" ] \
  && ok "…under the workflow's island-intake ServiceAccount (the leaf names none of its own)" || bad "leaf identity" "$(yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .serviceAccountName" "$YAML")"
yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .container.args[0]" "$YAML" > "$TMP/exp-step.sh"
{ grep -q 'devbox install --config islands/intake' "$TMP/exp-step.sh" && grep -q 'islands/intake/scripts/experiment-read.sh' "$TMP/exp-step.sh" \
    && grep -q 'devbox run --config islands/intake' "$TMP/exp-step.sh" && grep -q 'PROMETHEUS' <(yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .container.env[].name" "$YAML"); } \
  && ok "the step bootstraps like a sitting (clone, the island devbox) and runs experiment-read.sh through it, with PROMETHEUS set" || bad "step bootstrap" "$(grep -c . "$TMP/exp-step.sh") lines"
[ "$(yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .container.env[] | select(.name == \"PROMETHEUS\") | .value" "$YAML")" = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090" ] \
  && ok "…Prometheus is the in-cluster service" || bad "prometheus url" "$(yq -r "$SPEC.templates[] | select(.name == \"experiments\") | .container.env[].value" "$YAML" | grep prom)"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
