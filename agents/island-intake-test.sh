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
  ( cd "$TMP" && H="$TMP" PATH="$BIN:$PATH" HOME="$TMP/home" MODE="$1" ISLAND=gateway \
      INTAKE_ISSUES_JSON="${PILE_JSON:-$TMP/pile-empty.json}" \
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
    defer)    printf '%s' '{"decision":"defer","reason":"subscription-sessions-full","retry_after_s":600}' > "$TMP/gw-reply.json";;
    fallback) printf '{"error":"down"}' > "$TMP/gw-reply.json"; printf '503' > "$TMP/gw-http";;
  esac
  ( cd "$TMP" && H="$TMP" PATH="$GBIN:$BIN:$PATH" HOME="$TMP/home" MODE=apply ISLAND=gateway \
      INTAKE_ISSUES_JSON="$TMP/pile-empty.json" \
      INTAKE_TS_DIR="$TS" INTAKE_NOW="$NOW" GH_TOKEN=x AGENT_TS_BUCKET=b AGENT_TS_ENDPOINT=e \
      AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s PUSHGATEWAY="" \
      AGENT_GATEWAY="${2-sessions}" AGENT_GATEWAY_CALLER_TOKEN_FILE="$TMP/gw-caller-token" \
      ANTHROPIC_BASE_URL="$I_OLD_BASE" ANTHROPIC_AUTH_TOKEN="ref:agent-coordinator/coordinator-claude" \
      bash "$TMP/script.sh" ) > "$TMP/run.log" 2>&1
}
rm -rf "$TS/homelab/intake-gateway-2026-10-26/intake-r1-e"   # un-rule the hold row's inputs: these rows need a sitting
gw_intake_run dispatch; rc=$?
grep -qF '"stack":"platform","role":"coordinator","task":"intake-gateway-' "$TMP/curl.calls" && grep -qF '"tier":"heavy"' "$TMP/curl.calls" \
  && ok "dispatch → POST /sessions as stack platform, role coordinator, tier heavy, task intake-<island>-<day>" \
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

gw_intake_run fallback; rc=$?
grep -qF "gateway admission refused rc=3 — old-proxy fallback" "$TMP/run.log" \
  && ok "gateway 503 (fail-closed) → the ONE loud transition-fallback line" || bad "gw fallback line" "$(tail -5 "$TMP/run.log")"
{ [ "$rc" = 0 ] && grep -qx "model opus" "$TMP/claude.calls" && grep -qxF "env ANTHROPIC_BASE_URL=$I_OLD_BASE ANTHROPIC_AUTH_TOKEN=ref:agent-coordinator/coordinator-claude" "$TMP/claude.calls"; } \
  && ok "…and the sitting runs on the old path (resolved model, old-proxy pair)" || bad "gw fallback path" "rc=$rc $(cat "$TMP/claude.calls")"

gw_intake_run dispatch ""; rc=$?
{ ! grep -q '/sessions' "$TMP/curl.calls" && grep -qx "model opus" "$TMP/claude.calls"; } \
  && ok "AGENT_GATEWAY unset → no /sessions call, the old path byte-for-byte" || bad "gw knob off" "$(grep sessions "$TMP/curl.calls")"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
