#!/usr/bin/env bash
# board-machine test — golden pinning for board.sh --machine (homelab#892).
#
# Runs board.sh --machine against a synthetic Prometheus response and asserts the
# key=value line grammar output. Uses the replay stubs for gh/kubectl.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STUBS="$ROOT/agents/replay/stubs"
NOW=1786465900   # 2026-08-18T12:00:00Z

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

present() { if printf '%s' "$3" | grep -Fq -- "$2"; then ok "$1"; else bad "$1 — missing: $2"; fi }
absent()  { if printf '%s' "$3" | grep -Fq -- "$2"; then bad "$1 — present but must not be: $2"; else ok "$1"; fi }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cp "$STUBS/gh" "$STUBS/kubectl" "$TMP/bin/" && chmod +x "$TMP/bin/gh" "$TMP/bin/kubectl"

# Create a stub curl that returns synthetic Prometheus data
cat > "$TMP/bin/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Stub curl for Prometheus queries
if [[ "$*" == *"/api/v1/query"* ]]; then
  cat <<'JSON'
{"status":"success","data":{"resultType":"vector","result":[
  {"metric":{"repo":"homelab","item":"833","class":"held-merged-unlinked","who":"operator"},"value":[1786465900,"1"]},
  {"metric":{"repo":"homelab","item":"834","class":"queued-held-by-ghost","who":"operator"},"value":[1786465900,"1"]},
  {"metric":{"repo":"homelab","item":"889","class":"riding","who":"machine"},"value":[1786465900,"1"]},
  {"metric":{"repo":"homelab","item":"840","class":"container","who":"none"},"value":[1786465900,"1"]},
  {"metric":{"repo":"homelab","item":"aggregate","class":"backlog-aggregate","who":"operator"},"value":[1786465900,"1"]}
]}}
JSON
fi
exit 0
CURLSTUB
chmod +x "$TMP/bin/curl"

# Run board.sh --machine
BOARD_OUT="$(env PATH="$TMP/bin:$PATH" REPLAY_WORLD="$HERE/world" \
  BOARD_NOW="$NOW" PROMETHEUS_URL="http://stub" \
  bash "$ROOT/agents/board.sh" --machine platform 2>/dev/null)" || true

# ── assertions ──────────────────────────────────────────────────────────────────
# Header line 1
present "header: board v1 prefix" "board v1" "$BOARD_OUT"
present "header: scope=stack:platform" "scope=stack:platform" "$BOARD_OUT"
present "header: sources=labels:live pods:live derived:tick@" "sources=labels:live pods:live derived:tick@" "$BOARD_OUT"

# Stable sort: who=operator rows first (held-merged-unlinked, queued-held-by-ghost, backlog-aggregate),
# then who=machine (riding), then who=none (container)
present "row: held-merged-unlinked (who=operator)" "who=operator class=held-merged-unlinked id=homelab/833" "$BOARD_OUT"
present "row: queued-held-by-ghost (who=operator)" "who=operator class=queued-held-by-ghost id=homelab/834" "$BOARD_OUT"
present "row: backlog-aggregate (who=operator)" "who=operator class=backlog-aggregate id=homelab/aggregate" "$BOARD_OUT"
present "row: riding (who=machine)" "who=machine  class=riding id=homelab/889" "$BOARD_OUT"
present "row: container (who=none)" "who=none     class=container id=homelab/840" "$BOARD_OUT"

# No human board sections in --machine mode
absent "no § REVIEW section" "§ REVIEW" "$BOARD_OUT"
absent "no § FIX section" "§ FIX" "$BOARD_OUT"
absent "no totals line" "totals —" "$BOARD_OUT"

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1