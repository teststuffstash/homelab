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
EOF
chmod +x "$BIN"/*
echo '[]' > "$TMP/pile-empty.json"   # the pile source's seam: an empty pile unless a row sets PILE_JSON
run_script() { # <mode>
  rm -rf "$TMP/work" "$TMP/up"/* "$TMP/run"/*; : > "$TMP/claude.calls"; : > "$TMP/curl.calls"; mkdir -p "$TMP/work"
  ( cd "$TMP" && H="$TMP" PATH="${RUN_PATH:-$BIN}:$PATH" HOME="$TMP/home" MODE="$1" ISLAND=gateway \
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
[ "$(jq -c '[.ruled[] | [.input, .outcome]]' "$TMP/up/receipt.json" 2>/dev/null)" = "[[\"$H#101\",\"seat\"],[\"$H#102\",\"requeue\"],[\"$H#103\",\"unchanged\"],[\"$H#107\",\"split\"]]" ] \
  && ok "receipt: issue ids with seat / requeue / unchanged / split; an unknown outcome and a forged id dropped" || bad "pile receipt" "$(jq -c .ruled "$TMP/up/receipt.json" 2>/dev/null)"
grep -q '/coordinate' "$TMP/curl.calls" && ok "a \`requeue\` rings /coordinate (it queued work)" || bad "requeue ring" "$(cat "$TMP/curl.calls")"
mkdir -p "$TSP/homelab/intake-gateway-2026-10-27/r"; cp "$TMP/up/receipt.json" "$TSP/homelab/intake-gateway-2026-10-27/r/"
rm -rf "$TSP/homelab/intake-gateway-2026-10-24"
pile
[ "$(pk reread)" = "109 115" ] && ok "…and the next pile selection reads that receipt back: #102 #103 #107 are not re-read tomorrow, #109 #115 (no line) are" \
  || bad "pile round trip" "got '$(pk reread)'"
rm -rf "$TSP/homelab/intake-gateway-2026-10-27"
cat > "$TMP/claude.out" <<EOF
INTAKE-RULED: $H#103 unchanged -
EOF
PILE_JSON="$PISS" run_script apply
grep -q '/coordinate' "$TMP/curl.calls" && bad "unchanged ring" "rang /coordinate" || ok "\`unchanged\` alone rings nothing"
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
esc "$TMP/nowhere.json"; rc=$?
[ "$rc" = 2 ] && ok "queued issues + an unreadable PR list → exit 2" || bad "escape rule #6" "rc=$rc"
TSE0="$TMP/tse0"; mkdir -p "$TSE0/homelab"
INTAKE_PRS_JSON="$TMP/nowhere.json" INTAKE_TS_DIR="$TSE0" INTAKE_NOW="$NOW" bash "$SEL" --source escape --island gateway --out "$TMP/esel.json" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "nothing queued → a valid empty selection and NO PR read (an unreadable list is never touched)" || bad "escape nothing queued" "rc=$rc"

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
  [ "\$prev" = -p ] && p="\$a"
  case "\$a" in --allowedTools) inallow=1;; --*) inallow=0;; *) [ "\$inallow" = 1 ] && allow="\$allow \$a";; esac
  prev="\$a"; done
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
  "issue view") case "\$*" in *labels*) cat "$TMP/gh-labels" 2>/dev/null;; *title,body*) cat "$TMP/body-9.md";; esac;;
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
INTAKE-REPAIR: U1 changed fixed the acceptance
INTAKE-REPAIR: R10/9/r1.1 declined the row is right
EOF
review_run() { # <mode> [env…]
  rm -f "$TMP/r.calls" "$TMP/gh.calls" "$TMP/gh.comments" "$TMP"/prompt-*.txt
  RUN_PATH="$RBIN:$BIN" RUN_ENV="INTAKE_SNIPPETS_DIR=$TMP/snip ${*:2}" run_script "$1"
}
rm -rf "$TS/homelab/intake-gateway-2026-10-27"
touch "$TMP/pass1-empty-once"; echo "" > "$TMP/gh-labels"
review_run apply; rc=$?
[ "$rc" = 0 ] && ok "apply run with review-repair exits 0" || bad "review run" "rc=$rc $(tail -5 "$TMP/run.log")"
[ "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')" = "author unit pass1 pass1 pass2 repair " ] \
  && ok "sessions: author → unit lens → rows pass 1 (empty → re-run once) → pass 2 → ONE repair" || bad "session order" "$(cut -d' ' -f1 "$TMP/r.calls" | tr '\n' ' ')"
grep -q "INTAKE-HOLD" "$TMP/prompt-author.txt" && grep -q "review: review-repair" "$TMP/prompt-author.txt" && grep -qF '`## Review units`' "$TMP/prompt-author.txt" \
  && ok "the author is told: review-repair, Review units, INTAKE-HOLD" || bad "author prompt" "$(grep -n REVIEW "$TMP/prompt-author.txt")"
line="$(grep '^unit ' "$TMP/r.calls")"
case "$line" in *"cwd=$TMP/work/homelab gh_token= "*"Read(/$TMP/run/review/case-unit-0/**)"*"Bash(git show:*)"*"Write(/$TMP/run/review/out/unit-0.md)"*) ok "unit lens: no token, Read scoped to its case dir, git show at the base, Write to its one file";;
  *) bad "unit confinement" "$line";; esac
[ "$(grep -c '^unit ' "$TMP/r.calls")" = 1 ] && ok "a unit line whose issue no queue/goal ruling names (#999) gets no lens" || bad "forged unit" "$(grep -c '^unit ' "$TMP/r.calls")"
{ grep -q 'r1.1' "$TMP/pass1-world.txt" 2>/dev/null || grep -q '9.md' "$TMP/pass1-world.txt"; } && ! grep -q 'issues' "$TMP/pass1-world.txt" \
  && ! grep -rq SECRET-DESCRIPTION "$TMP/run/review/rows-pass1-1/" && grep -q '| r1.1 |' "$TMP/run/review/rows-pass1-1/masked/9.md" \
  && ok "rows pass 1 sees masked/ + process/ only: the description is keyed (r1.1), the body is out of reach" || bad "pass 1 world" "$(cat "$TMP/pass1-world.txt" | head -12)"
grep -q "^pass2 cwd=$TMP/work/homelab gh_token= " "$TMP/r.calls" && ok "rows pass 2 runs on the base repo, no token" || bad "pass 2" "$(grep pass2 "$TMP/r.calls")"
grep -q -- '- 9/r1.1' "$TMP/run/review/out/rows-1.md" && grep -q 'R10/9/r1.1' "$TMP/run/review/out/rows-1.md" \
  && ok "the rows file keeps its frozen Pass 1 and gains pass 2's findings" || bad "rows file" "$(cat "$TMP/run/review/out/rows-1.md")"
grep -q 'LENS FINDINGS FILE: unit-0.md' "$TMP/prompt-repair.txt" && grep -q 'LENS FINDINGS FILE: rows-1.md' "$TMP/prompt-repair.txt" && grep -q 'Review units' "$TMP/prompt-repair.txt" \
  && ok "the repair prompt carries the first-pass report and every lens's findings file" || bad "repair prompt" "$(grep -c FINDINGS "$TMP/prompt-repair.txt")"
[ "$(jq -c '[.findings[] | [.id, .lens, .posture, .fate]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["R10/9/r1.1","rows","blocking","declined"],["U1","unit","blocking","changed"],["U2","unit","advisory","unanswered"]]' ] \
  && ok "receipt: one record per finding — id, lens, posture, changed/declined/unanswered" || bad "receipt findings" "$(jq -c .findings "$TMP/up/receipt.json" 2>/dev/null)"
[ "$(jq -c '[.review.lenses[] | [.lens, .status, .runs]]' "$TMP/up/receipt.json" 2>/dev/null)" = '[["unit","ran",1],["rows","ran",2]]' ] && jq -e '.review.repair.status == "ran" and .review.held == ["'"$H"'#9"]' "$TMP/up/receipt.json" >/dev/null \
  && ok "receipt: each lens's status and runs, the repair, the held set (#999 forged → dropped)" || bad "receipt review" "$(jq -c .review "$TMP/up/receipt.json" 2>/dev/null)"
grep -qF "gh issue edit 9 --repo $H --add-label agent-fix,task/fix,agent/queued" "$TMP/gh.calls" && ! grep -q 'agent/approved' "$TMP/gh.calls" && ! grep -q 'edit 999' "$TMP/gh.calls" \
  && ok "the belt labels #9 the repair left unlabelled — brief labels only (agent/approved dropped), no forged ref" || bad "belt labels" "$(grep edit "$TMP/gh.calls")"
[ ! -s "$TMP/gh.comments" ] && ok "…and posts no comment of its own when the repair ran (the repair posts them)" || bad "belt comments" "$(cat "$TMP/gh.comments")"
grep -q '/coordinate' "$TMP/curl.calls" && ok "the queue rings /coordinate after the labels" || bad "review ring" "$(cat "$TMP/curl.calls")"

echo "agent-fix,task/fix,agent/queued" > "$TMP/gh-labels"
review_run apply
! grep -q 'issue edit' "$TMP/gh.calls" && ok "an issue the repair already labelled is left alone" || bad "belt idempotent" "$(grep edit "$TMP/gh.calls")"

echo "" > "$TMP/gh-labels"; touch "$TMP/unit-fail" "$TMP/repair-fail"
review_run apply
{ jq -e '[.review.lenses[] | select(.lens == "unit")][0] | .status == "skipped: failed twice (no findings file)" and .runs == 2' "$TMP/up/receipt.json" >/dev/null \
  && grep -qF "gh issue edit 9" "$TMP/gh.calls" && head -1 "$TMP/gh.comments" | grep -q '^intake: review — 1 findings: 0 changed, 0 declined' \
  && grep -q '^unit review skipped' "$TMP/gh.comments" && tail -1 "$TMP/gh.comments" | grep -q '^intake: queue — queued as authored'; } \
  && ok "a unit lens that writes no file twice + a repair that fails: still labelled; review comment (skipped line) first, ruling LAST" \
  || bad "lens failure" "$(jq -c .review "$TMP/up/receipt.json" 2>/dev/null) | $(cat "$TMP/gh.comments" 2>/dev/null)"
rm -f "$TMP/unit-fail" "$TMP/repair-fail"

review_run dry-run
{ ! grep -qE 'issue (edit|comment)' "$TMP/gh.calls" 2>/dev/null && grep -q 'would carry +agent-fix,task/fix,agent/queued' "$TMP/run.log" && grep -q '^repair ' "$TMP/r.calls"; } \
  && ok "dry-run: lenses and repair run, nothing is written to GitHub" || bad "review dry-run" "$(cat "$TMP/gh.calls" 2>/dev/null)"

rm -f "$TMP/r.calls" "$TMP"/prompt-*.txt; RUN_PATH="$RBIN:$BIN" RUN_ENV="REVIEW=off" run_script apply
{ [ "$(grep -c . "$TMP/r.calls")" = 1 ] && grep -q 'REVIEW: off' "$TMP/prompt-author.txt" && ! grep -q 'INTAKE-HOLD:' "$TMP/prompt-author.txt"; } 2>/dev/null \
  && ok "review=off: one author session, told to label as it rules" || bad "review off" "$(cat "$TMP/r.calls")"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
