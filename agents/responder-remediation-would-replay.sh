#!/usr/bin/env bash
# responder-remediation-would-replay — ADR-103 replay for the #1274 REMEDIATION-WOULD marker.
#
#   bash agents/responder-remediation-would-replay.sh
#   devbox run -- bash agents/responder-remediation-would-replay.sh
#
# WHY THIS EXISTS. The responder-argo.yaml clause file gained a REMEDIATION-WOULD MARKER
# instruction block in the brief sent to the LLM. The ADR-103 ratchet requires that every
# clause change carries a corresponding replay fixture change. This fixture verifies the
# instruction is present in the YAML's embedded shell script by extracting it and checking
# for the marker text.
#
# No network, no cluster, no credentials. Runs in under a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
YAML="$ROOT/agents/coordinator/responder-argo.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v yq >/dev/null 2>&1 || { echo "responder-remediation-would-replay: needs yq (devbox run -- bash $0)"; exit 2; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); local d="${2:-}"; printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "$d" ] && printf '       %s\n' "$d"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "output lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "output contains: $2" || ok "$1"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2"; }

# ── extract the embedded script from the YAML ───────────────────────────────────────────────────
printf '\033[1mresponder-remediation-would-replay\033[0m — #1274: REMEDIATION-WOULD shadow marker\n\n'

section "1 — extract the embedded script from responder-argo.yaml"
yq -r 'select(.kind == "WorkflowTemplate") | .spec.templates[] | select(.container != null) | .container.args[0]' \
   "$YAML" > "$TMP/script.sh" 2>"$TMP/yq-err.txt"
RC=$?
if [ "$RC" != 0 ]; then
  bad "extract: yq failed" "$(cat "$TMP/yq-err.txt")"
  exit 1
fi
[ -s "$TMP/script.sh" ] || { bad "extract: extracted script is empty"; exit 1; }
ok "extract: script extracted from YAML ($(wc -c < "$TMP/script.sh") bytes)"

# ── verify the REMEDIATION-WOULD marker instruction is present ──────────────────────────────────
section "2 — REMEDIATION-WOULD marker instruction"
OUT="$(cat "$TMP/script.sh")"

want "A1: REMEDIATION-WOULD MARKER section header" "REMEDIATION-WOULD MARKER"
want "A2: marker format instruction"               "REMEDIATION-WOULD: <verb>"
want "A3: example remediation line"                "bump oracle-fleet/agent/agentstack.yaml"
want "A4: at-most-one-per-session guard"           "At most one per distinct remediation per session"
want "A5: report-only exclusion"                   "Do NOT emit this line when your verdict is report-only"
want "A6: no-mechanical-remediation exclusion"     "when no mechanical remediation applies"

# ── verify the HARD RULES section is still present (no regression) ──────────────────────────────
section "3 — HARD RULES section preserved (no regression)"
want "B1: HARD RULES header"     "HARD RULES:"
want "B2: alert-fp search rule"  "alert-fp:"
want "B3: no kubectl mutations"  "No kubectl mutations"
want "B4: never push to master"  "Never push to master"

# ── verify the existing brief structure is preserved ────────────────────────────────────────────
section "4 — existing brief structure preserved"
want "C1: STEP 3 act header"     "STEP 3"
want "C2: fix-verdict line"      "fix-verdict:"
want "C3: Cause: line"           "Cause: #"
want "C4: TOOL_GAP marker"       "TOOL_GAP:"
want "C5: never-auto-merge cap"  "NEVER enable auto-merge"

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe REMEDIATION-WOULD marker changed. If the change was deliberate, update the fixture\n'
  printf 'in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery REMEDIATION-WOULD marker assertion holds.\033[0m\n'