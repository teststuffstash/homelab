#!/usr/bin/env bash
# island-intake-test — behavioural harness for the WIRED island intake (FU-320): the selector's
# `--source dig` mode (gateway/scripts/intake-select.sh) and the CronWorkflow that runs it
# (agents/coordinator/island-intake-argo.yaml).
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
INTAKE_TS_DIR="$TS" bash "$SEL" --source dig --island nosuch --out "$TMP/sel.json" 2>/dev/null; rc=$?
[ "$rc" = 2 ] && ok "an island with no pattern row is refused" || bad "island table" "rc=$rc"

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
      AGENT_TS_ACCESS_KEY_ID=k AGENT_TS_SECRET_ACCESS_KEY=s PUSHGATEWAY="" bash "$TMP/script.sh" ) > "$TMP/run.log" 2>&1
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

receipt 2026-10-26 intake-r1-e apply 2026-10-26T06:00:00Z \
  "[{\"input\":\"dig-2026-10-25/$R1/finding-2\",\"outcome\":\"close\",\"refs\":[]},{\"input\":\"dig-2026-10-26/$R2/finding-2\",\"outcome\":\"fold\",\"refs\":[]}]"
run_script apply
[ ! -s "$TMP/claude.calls" ] && grep -q "hold" "$TMP/run.log" && ok "hold: no session, exit 0" || bad "hold" "$(tail -3 "$TMP/run.log")"

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'failed:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
