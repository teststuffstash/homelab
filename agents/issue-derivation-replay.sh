#!/usr/bin/env bash
# issue-derivation-replay — behavioural pin for the ISSUE derivation logic (#1189).
#
#   bash agents/issue-derivation-replay.sh     # or: devbox run -- bash agents/issue-derivation-replay.sh
#
# WHY THIS EXISTS. The ISSUE derivation in reviewer-session.sh's PREP heredoc has two sources:
#   1. `closingIssuesReferences[0].number` (authoritative when populated)
#   2. PR body closing keyword fallback (when the API field is empty — #1189)
#
# This fixture asserts that:
#   A. Populated closingIssuesReferences → ISSUE from that source (unchanged path)
#   B. Empty closingIssuesReferences + body "Fixes #N" → ISSUE from body fallback
#   C. Neither source → ISSUE empty (clean degrade to undeclared)
#
# WHAT IT RUNS. The `>>>REPLAY:issue-derivation>>>` block extracted from reviewer-session.sh's
# PREP heredoc. The block is verified in isolation with stub gh output.
#
# THE SEAMS:
#   - `gh` is a stub on $PATH serving controlled PR metadata JSON.
#   - No network, no cluster, no credentials. Runs in about a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${SESSION:-$HERE/reviewer-session.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

command -v jq >/dev/null 2>&1 || { echo "issue-derivation-replay: needs jq (devbox run -- bash $0)"; exit 2; }
[ -f "$SESSION" ] || { echo "issue-derivation-replay: missing $SESSION" >&2; exit 2; }

# ── the derivation block ─────────────────────────────────────────────────────────────────────────
# Extract and unescape: the block lives inside a heredoc where $ is backslash-escaped, so
# `\$l` becomes `$l`, `\$ISSUE` becomes `$ISSUE`, etc.
extract() {
  awk -v n="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb = 1; saw_open = 1; next }
    line == "# <<<REPLAY:" n "<<<" { inb = 0; saw_close = 1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$2" | sed 's/\\\$/$/g'
}
extract issue-derivation "$SESSION" > "$TMP/derive.sh" || {
  echo "issue-derivation-replay: sentinel >>>REPLAY:issue-derivation>>> missing from $SESSION" >&2
  exit 3
}
[ -s "$TMP/derive.sh" ] || { echo "issue-derivation-replay: derivation block extracted EMPTY" >&2; exit 3; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout contains: $2" || ok "$1"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2 (stderr: $(printf '%s' "$ERR" | tail -1))"; }

# _derive <pr-meta-json> — run the derivation block with a stub gh that returns the given JSON
_derive() {
  local pr_meta="$1"
  # Write the pr meta to a temp file so the stub can serve it
  printf '%s' "$pr_meta" > "$TMP/pr_meta.json"

  # Create gh stub that returns the canned PR metadata
  # Use a marker we can sed-replace so $TMP expands at write time
  _TMP="$TMP"
  cat > "$BIN/gh" <<STUB
#!/bin/bash
case "\$*" in
  *"pr view"*)
    cat "$_TMP/pr_meta.json"
    ;;
  *)
    echo "issue-derivation-replay: UNEXPECTED gh call: gh \$*" >&2
    exit 9
    ;;
esac
STUB
  chmod +x "$BIN/gh"

  # PR is set for the gh call, ISSUE starts empty
  PR="123" ISSUE="" PATH="$BIN:$PATH" \
    bash -c '
      source "$1" 2>/dev/null
      echo "ISSUE=${ISSUE:-}"
    ' _ "$TMP/derive.sh" > "$TMP/d_out.txt" 2> "$TMP/d_err.txt"
  RC=$?; OUT="$(cat "$TMP/d_out.txt")"; ERR="$(cat "$TMP/d_err.txt")"
}

printf '\033[1missue-derivation-replay\033[0m — #1189: ISSUE derivation from closingIssuesReferences or body fallback\n'
printf 'session: %s\n\n' "$SESSION"

# ── A ── closingIssuesReferences populated (unchanged path) ──────────────────────────────────────
section "A — closingIssuesReferences populated (authoritative source)"

_PR_META_A=$(cat <<'JSON'
{"closingIssuesReferences":[{"number":42}],"baseRefName":"master","body":"Fixes #42\n\nSome description."}
JSON
)
_derive "$_PR_META_A"
want    "A1: ISSUE derived from closingIssuesReferences"        "ISSUE=42"
wantnot "A2: no body-fallback message"                          "derived from PR body"

# ── B ── closingIssuesReferences empty, body has Fixes #N (fallback) ────────────────────────────
section "B — closingIssuesReferences empty, body has Fixes #N (fallback)"

_PR_META_B=$(cat <<'JSON'
{"closingIssuesReferences":[],"baseRefName":"goal/1-scan","body":"Fixes #1189\n\nThis fixes the goal-lane footprint issue."}
JSON
)
_derive "$_PR_META_B"
want    "B1: ISSUE derived from body closing keyword"           "ISSUE=1189"
want    "B2: derivation message logged"                         "ISSUE derived from PR body closing keyword: #1189"

# ── B2 ── case-insensitive: "Closes #N" ─────────────────────────────────────────────────────────
section "B2 — case-insensitive: Closes #N"

_PR_META_B2=$(cat <<'JSON'
{"closingIssuesReferences":[],"baseRefName":"goal/1-scan","body":"Closes #456\n\nSome description."}
JSON
)
_derive "$_PR_META_B2"
want    "B2a: ISSUE derived from Closes keyword"                "ISSUE=456"

# ── B3 ── "Resolves #N" ────────────────────────────────────────────────────────────────────────
section "B3 — Resolves #N"

_PR_META_B3=$(cat <<'JSON'
{"closingIssuesReferences":[],"baseRefName":"goal/1-scan","body":"Resolves #789\n\nSome description."}
JSON
)
_derive "$_PR_META_B3"
want    "B3a: ISSUE derived from Resolves keyword"              "ISSUE=789"

# ── C ── Neither source (clean degrade) ─────────────────────────────────────────────────────────
section "C — neither source (clean degrade to undeclared)"

_PR_META_C=$(cat <<'JSON'
{"closingIssuesReferences":[],"baseRefName":"feature/x","body":"Some PR with no closing keyword."}
JSON
)
_derive "$_PR_META_C"
want    "C1: ISSUE empty (no source)"                           "ISSUE="

# ── C2 ── null closingIssuesReferences (API edge case) ──────────────────────────────────────────
section "C2 — null closingIssuesReferences, no body keyword"

_PR_META_C2=$(cat <<'JSON'
{"closingIssuesReferences":null,"baseRefName":"feature/x","body":"Just a description."}
JSON
)
_derive "$_PR_META_C2"
want    "C2a: ISSUE empty (null refs, no body keyword)"         "ISSUE="

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe ISSUE derivation changed behaviour. If the change was deliberate, update the fixture\n'
  printf 'in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery ISSUE derivation case holds.\033[0m\n'