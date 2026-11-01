#!/usr/bin/env bash
# island-intake-test — behavioural harness for the WIRED island intake (FU-320): the selector's
# `--source dig` mode (gateway/scripts/intake-select.sh) and the CronWorkflow that runs it
# (agents/coordinator/island-intake-argo.yaml), plus the island table both selector modes read
# (island_members / island_pattern — membership per island, one island per item).
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
finding 2026-10-25 $R1 3 cause-found "snore-recorder owner: delete the venv"          # not the island
finding 2026-10-26 $R2 1 explained   "fires by design after the canary — gateway/specs" # wrong verdict
finding 2026-10-26 $R2 2 cause-found "agent-gateway pod restarts on the parse"
finding 2026-10-10 dig-r1-20261010T033000Z 1 cause-found "gateway/ — too old for the lookback"
sel; rc=$?
[ "$rc" = 0 ] && ok "fires on unruled island findings (exit 0)" || bad "fire" "rc=$rc $(cat "$TMP/sel.err")"
[ "$(ids)" = "dig-2026-10-26/$R2/finding-2 dig-2026-10-25/$R1/finding-1 dig-2026-10-25/$R1/finding-2" ] \
  && ok "selects cause-found ∧ names the island (path, agent-gateway, GW- id) ∧ inside the lookback" \
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
for spec in "1|MgmtOpnsenseDrillScoreRegressed: the drill's realism score fell" \
            "2|agent-gateway pod restarts; agents/agent-session.sh retries" \
            "3|MgmtLeaseExpiredUnreverted: mgmt-lease left the pin" \
            "4|Longhorn volume degraded on wk-02"; do
  jq -n --arg rec "${spec#*|}" '{schema:"dig-finding/v1", verdict:"cause-found", cause:"c", evidence:[], recommendation:$rec,
    pr:"", related:[], alerts:[], members:[]}' > "$TS2/homelab/dig-2026-10-26/r/finding-${spec%%|*}.json"
done
digsel() { INTAKE_TS_DIR="$TS2" INTAKE_NOW="$NOW" bash "$SEL" --source dig --island "$1" --out "$TMP/sel2.json" 2>/dev/null
           jq -r '[.inputs[].id | sub(".*finding-"; "")] | sort | join(" ")' "$TMP/sel2.json"; }
for row in "gateway:2" "router-pair:1" "mgmt-box:3" "substrate:4" "agent-loop:" "dependency-upgrades:"; do
  isl="${row%%:*}"; want="${row#*:}"; got="$(digsel "$isl")"
  [ "$got" = "$want" ] && ok "dig --island $isl takes '${want:-nothing}' (an earlier row's finding is never re-ruled)" \
    || bad "dig precedence $isl" "want '$want' got '$got'"
done

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
# clone stub: the checkout under test, minus .git
dest="\${@: -1}"; mkdir -p "\$dest"; (cd "$REPO" && tar --exclude=.git -cf - .) | (cd "\$dest" && tar -xf -)
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
run_script() { # <mode>
  rm -rf "$TMP/work" "$TMP/up"/* "$TMP/run"/*; : > "$TMP/claude.calls"; : > "$TMP/curl.calls"; mkdir -p "$TMP/work"
  ( cd "$TMP" && H="$TMP" PATH="$BIN:$PATH" HOME="$TMP/home" MODE="$1" ISLAND=gateway \
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

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
