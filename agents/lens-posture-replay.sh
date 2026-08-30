#!/usr/bin/env bash
# lens-posture-replay — behavioural pin for the FU-101 per-stack lens posture knob.
#
#   bash agents/lens-posture-replay.sh     # or: devbox run -- bash agents/lens-posture-replay.sh
#
# WHY THIS EXISTS. The `spec.lenses` knob on the AgentStack XRD graduates a named lens from
# advisory to blocking, sourced through the same fail-closed claim read as the reviewer optout.
# This fixture asserts that:
#   1. No `lenses:` block → every lens is advisory (existing behaviour preserved)
#   2. A lens marked blocking → the `--lens-map` output carries "blocking"
#   3. An unreadable claim → "{}" (fail-closed, empty map = advisory)
#   4. A blocking lens whose fetch fails → loud WARN (never silent advisory)
#
# WHAT IT RUNS. The `--lens-map` flag on reviewer-optout.sh (the shared single claim read) and
# the `>>>REPLAY:lens-posture-handling>>>` block extracted from reviewer-session.sh's PREP heredoc.
# The handling block is verified in isolation with stub lens files.
#
# THE SEAMS:
#   - `kubectl` is a stub on $PATH serving $FIXTURE claims shapes.
#   - `curl` is a stub serving lens files (or failing) so we control fetch outcomes.
#   - No network, no cluster, no credentials. Runs in about a second.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTOUT="${OPTOUT:-$HERE/reviewer-optout.sh}"
SESSION="${SESSION:-$HERE/reviewer-session.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
FIX="$TMP/claims.json"

command -v jq >/dev/null 2>&1 || { echo "lens-posture-replay: needs jq (devbox run -- bash $0)"; exit 2; }
[ -f "$OPTOUT" ] || { echo "lens-posture-replay: missing $OPTOUT" >&2; exit 2; }
[ -f "$SESSION" ] || { echo "lens-posture-replay: missing $SESSION" >&2; exit 2; }

# ── the handling block ──────────────────────────────────────────────────────────────────────────
# Extract and unescape: the block lives inside a heredoc where $ is backslash-escaped, so
# `\$l` becomes `$l`, `\$LENSES` becomes `$LENSES`, etc.
extract() {
  awk -v n="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    line == "# >>>REPLAY:" n ">>>" { inb = 1; saw_open = 1; next }
    line == "# <<<REPLAY:" n "<<<" { inb = 0; saw_close = 1; next }
    inb { print }
    END { if (!saw_open || !saw_close) exit 3 }
  ' "$2" | sed 's/\\\$/$/g'
}
extract lens-posture-gate "$SESSION" > "$TMP/gate.sh" || {
  echo "lens-posture-replay: sentinel >>>REPLAY:lens-posture-gate>>> missing from $SESSION" >&2
  exit 3
}
[ -s "$TMP/gate.sh" ] || { echo "lens-posture-replay: gate block extracted EMPTY" >&2; exit 3; }

extract lens-posture-handling "$SESSION" > "$TMP/handling.sh" || {
  echo "lens-posture-replay: sentinel >>>REPLAY:lens-posture-handling>>> missing from $SESSION" >&2
  exit 3
}
[ -s "$TMP/handling.sh" ] || { echo "lens-posture-replay: handling block extracted EMPTY" >&2; exit 3; }

# ── stubs ───────────────────────────────────────────────────────────────────────────────────────
cat > "$BIN/kubectl" <<'STUB'
#!/bin/bash
case "$*" in
  *agentstacks*) cat "$FIXTURE";;
  *) echo "lens-posture-replay: UNEXPECTED kubectl call: kubectl $*" >&2; exit 9;;
esac
STUB

cat > "$BIN/curl" <<'STUB'
#!/bin/bash
# Stub curl for lens fetch: serve from $LENS_STUBS_DIR if available, else fail.
_args="$*"
for a in $_args; do
  # Match any lens URL: .../<lens>.md
  case "$a" in
    *.md)
      lens_name="$(basename "$a" .md)"
      stub_file="${LENS_STUBS_DIR:-$TMP/lenses}/${lens_name}.md"
      if [ -f "$stub_file" ]; then
        cat "$stub_file"
        exit 0
      fi
      echo "lens-posture-replay: stub lens not found: $a" >&2
      exit 1
      ;;
  esac
done
echo "lens-posture-replay: curl stub: no lens URL matched in args: $_args" >&2
exit 1
STUB

chmod +x "$BIN/kubectl" "$BIN/curl"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
fx_base() {
  cat > "$FIX" <<'JSON'
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "metadata": {"name": "platform"},
      "spec": {
        "reviewer": {"enabled": true},
        "lenses": {"k8s-prod": "blocking", "helm": "advisory"},
        "repos": [{"name": "agent-runtime"}, {"name": "agent-coordinator"}, {"name": "homelab"}, {"name": "openrouter-operator"}]
      }
    },
    {
      "metadata": {"name": "sleep"},
      "spec": {
        "reviewer": {"enabled": true},
        "repos": [{"name": "sleep-iac"}, {"name": "sleep-tracking"}]
      }
    },
    {
      "metadata": {"name": "oracle"},
      "spec": {
        "reviewer": {"enabled": true},
        "lenses": {"k8s-prod": "advisory"},
        "repos": [{"name": "oracle-fleet"}]
      }
    }
  ]
}
JSON
}
fx() { jq "$1" "$FIX" > "$FIX.new" && mv "$FIX.new" "$FIX" || { echo "lens-posture-replay: fixture edit failed: $1" >&2; exit 2; }; }

# ── helpers ─────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; FAILED=()
ok()       { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "$2"; }
section()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "got '$2', wanted '$3'"; }
want()     { printf '%s' "$OUT" | grep -qF -- "$2" && ok "$1" || bad "$1" "stdout lacks: $2"; }
wantnot()  { printf '%s' "$OUT" | grep -qF -- "$2" && bad "$1" "stdout contains: $2" || ok "$1"; }
wanterr()  { printf '%s' "$ERR" | grep -qF -- "$2" && ok "$1" || bad "$1" "stderr lacks: $2"; }
wantrc()   { [ "$RC" = "$2" ] && ok "$1" || bad "$1" "exit $RC, wanted $2 (stderr: $(printf '%s' "$ERR" | tail -1))"; }

_go() {   # _go <repo>
  FIXTURE="$FIX" PATH="$BIN:$PATH" bash "$OPTOUT" --lens-map "$1" > "$TMP/out.txt" 2> "$TMP/err.txt"
  RC=$?; OUT="$(cat "$TMP/out.txt")"; ERR="$(cat "$TMP/err.txt")"
}

_go_handling() {   # _go_handling <lens-posture-json> <lens-name> <stub-present true|false>
  local posture_json="$1" lens="$2" stub_present="$3"
  mkdir -p "$TMP/lenses"
  if [ "$stub_present" = "true" ]; then
    echo "# Stub lens: $lens" > "$TMP/lenses/${lens}.md"
  else
    rm -f "$TMP/lenses/${lens}.md"
  fi
  : > "$TMP/sysfile.txt"
  LENS_MAP="$posture_json" LENSES="$lens" SYSFILE="$TMP/sysfile.txt" \
    LENS_STUBS_DIR="$TMP/lenses" LENS_BASE="http://stub/agents/lenses" PATH="$BIN:$PATH" \
    bash "$TMP/handling.sh" > "$TMP/h_out.txt" 2> "$TMP/h_err.txt"
  RC=$?; OUT="$(cat "$TMP/h_out.txt")"; ERR="$(cat "$TMP/h_err.txt")"
}

printf '\033[1mlens-posture-replay\033[0m — FU-101: per-stack lens posture knob\n'
printf 'optout: %s\nsession: %s\n\n' "$OPTOUT" "$SESSION"

# ── 1 ── --lens-map: correct posture for each stack ─────────────────────────────────────────────
section "1 — lens map from the shared claim read (reviewer-optout.sh --lens-map)"
fx_base

_go agent-runtime
wantrc  "L1: platform stack — exit 0"                           0
# jq -r outputs a JSON object with ": " after keys
want    "L1: k8s-prod is blocking"                               '"k8s-prod": "blocking"'
want    "L1: helm is advisory"                                   '"helm": "advisory"'

_go sleep-tracking
wantrc  "L2: sleep stack — no lenses block, empty map"          0
want    "L2: empty object"                                       '{'

_go oracle-fleet
wantrc  "L3: oracle stack — k8s-prod=advisory"                  0
want    "L3: k8s-prod is advisory"                               '"k8s-prod": "advisory"'

_go some-unclaimed-repo
wantrc  "L4: unclaimed repo — empty output"                     0
eq      "L4: empty output"                                      "$(printf '%s' "$OUT" | tr -d '\n')" ""

# lens marked blocking explicitly
fx '(.items[] | select(.metadata.name=="platform") | .spec.lenses) = {"k8s-prod":"blocking"}'
_go agent-runtime
wantrc  "L5: only k8s-prod in map"                              0
want    "L5: k8s-prod blocking"                                  '"k8s-prod": "blocking"'
wantnot "L5: helm absent"                                       "helm"
fx_base

# ── 2 ── fail-closed: unreadable claim → empty map ─────────────────────────────────────────────
section "2 — fail-closed: unreadable claim returns {}"
# Override kubectl to fail
cat > "$BIN/kubectl" <<'STUB'
#!/bin/bash
echo "Error from server (Forbidden): agentstacks is forbidden" >&2
printf '{"apiVersion":"v1","kind":"List","items":[]}\n'
exit 1
STUB
chmod +x "$BIN/kubectl"

_go agent-runtime
wantrc  "F1: fail-closed — exit 1"                              1
eq      "F1: empty stdout from raw optout (caller adds || echo {})" "$(printf '%s' "$OUT" | tr -d '\n')" ""
wanterr "F1: PROBE-FAILED message"                               "PROBE-FAILED"

# Gate test: the `|| echo "{}"` in the extracted sentinel provides the fallback
section "2a — fail-closed gate: || echo {} fallback"
LENS_MAP=""
PROJECT="agent-runtime" HERE="$HERE" PATH="$BIN:$PATH" \
  eval "$(cat "$TMP/gate.sh")" 2>/dev/null || true
eq "G1: gate fallback to empty map on probe failure"             "${LENS_MAP:-}" "{}"

# ── 3 ── Handling block: posture appended to sysfile ────────────────────────────────────────────
section "3 — lens-posture-handling block (extracted from reviewer-session.sh PREP)"

# Restore kubectl stub
cat > "$BIN/kubectl" <<'STUB'
#!/bin/bash
cat "$FIXTURE"
STUB
chmod +x "$BIN/kubectl"

# 3a — advisory lens: no blocking text appended
_go_handling '{"k8s-prod":"advisory"}' k8s-prod true
want    "H1: advisory lens attaches normally"                    "lens attached: k8s-prod (advisory — FU-101)"
wantnot "H1: no POSTURE line"                                    "POSTURE: blocking"

# 3b — blocking lens: posture line appended
_go_handling '{"k8s-prod":"blocking"}' k8s-prod true
want    "H2: blocking lens attaches"                             "lens attached: k8s-prod (BLOCKING"
GOT_SYS="$(cat "$TMP/sysfile.txt")"
printf '%s' "$GOT_SYS" | grep -qF "POSTURE: blocking" && ok "H2: POSTURE line in sysfile" \
  || bad "H2: POSTURE line in sysfile" "sysfile: $(printf '%s' "$GOT_SYS" | head -3)"

# 3c — blocking lens fetch fails
_go_handling '{"k8s-prod":"blocking"}' k8s-prod false
wantrc  "H3: blocking fetch fail exits 0 (warning only)"        0
want    "H3: blocking fetch fail — loud WARN"                   "WARN: lens k8s-prod fetch FAILED — lens is BLOCKING"

# 3d — advisory lens fetch fails (existing behaviour)
_go_handling '{"k8s-prod":"advisory"}' k8s-prod false
want    "H4: advisory fetch fail — standard message"            "WARN: lens k8s-prod fetch failed — review proceeds without it (advisory-only"

# 3e — no lens in map (empty) → advisory defaults
_go_handling '{}' helm true
want    "H5: lens not in map → advisory"                         "lens attached: helm (advisory — FU-101)"
wantnot "H5: no blocking text"                                   "BLOCKING"

# ── result ──────────────────────────────────────────────────────────────────────────────────────
section "result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mFAILED:\033[0m\n'; for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
  printf '\nThe lens posture gate changed behaviour. If the change was deliberate, update the fixture\n'
  printf 'in the same commit (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mEvery lens posture case holds.\033[0m\n'