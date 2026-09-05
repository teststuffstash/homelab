#!/usr/bin/env bash
# responder-touches-classify-replay — ADR-103 replay for the #1207 filing-door classify clause.
#
#   bash agents/responder-touches-classify-replay.sh
#   devbox run -- bash agents/responder-touches-classify-replay.sh
#
# WHY THIS EXISTS. The responder-argo.yaml clause file's STEP 3(c) brief gained an instruction
# telling the LLM to classify the `Touches:` footprint it is about to file (via
# `agents/footprint.sh`'s `classify_touches()`) and, on a `codeowner-author` or pin-only GUARDED
# verdict, say so in the body as a plain sentence rather than leaving the verdict in the scan log
# alone (homelab#1207, #1102 leg 1's sequenced half). The ADR-103 ratchet requires every clause
# change to carry a corresponding replay fixture change; this fixture verifies the instruction is
# present in the YAML's embedded shell script by extracting it and checking for the marker text —
# the same shape as agents/responder-remediation-would-replay.sh (#1274).
#
# No network, no cluster, no credentials. Runs in under a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
YAML="$ROOT/agents/coordinator/responder-argo.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v yq >/dev/null 2>&1 || { echo "responder-touches-classify-replay: needs yq (devbox run -- bash $0)"; exit 2; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); local d="${2:-}"; printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "$d" ] && printf '       %s\n' "$d"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "output lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "output contains: $2" || ok "$1"; }

# ── extract the embedded script from the YAML ───────────────────────────────────────────────────
printf '\033[1mresponder-touches-classify-replay\033[0m — #1207: filing-door Touches classification\n\n'

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

# ── verify the STEP 3(c) classify instruction is present ────────────────────────────────────────
section "2 — Touches classification instruction (homelab#1207)"
OUT="$(cat "$TMP/script.sh")"

want "A1: instruction names the classifier function" "classify_touches"
want "A2: instruction sources the one-home predicate" "agents/footprint.sh"
want "A3: instruction sets CLASSIFY_CODEOWNERS"       "CLASSIFY_CODEOWNERS=/work/homelab/CODEOWNERS"
want "A4: instruction names the operator-author verdict" "codeowner-author"
want "A5: instruction names the GUARDED set"          "pin-only-lint.sh"
want "A6: instruction requires ONE sentence in the body" "as ONE plain sentence naming the classifier"
want "A7: instruction forbids a new body line"        "never a new body line for it"
want "A8: instruction cites the issue"                "homelab#1207"

# ── verify the surrounding STEP 3(c) structure is preserved (no regression) ─────────────────────
section "3 — STEP 3(c) structure preserved (no regression)"
want "B1: STEP 3 act header"          "STEP 3"
want "B2: Touches line instruction"   "a 'Touches:' line (ADR-097)"
want "B3: narrowest-surface guidance" "Declare the NARROWEST surface"
want "B4: fix-verdict line"           "fix-verdict:"
want "B5: Cause: line"                "Cause: #"

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe STEP 3(c) Touches-classification instruction changed. If the change was deliberate,\n'
  printf 'update this fixture in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery Touches-classification instruction assertion holds.\033[0m\n'
