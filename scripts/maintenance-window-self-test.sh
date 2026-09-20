#!/usr/bin/env bash
# Self-test for scripts/maintenance-window.sh — the read-failure semantics, with no cluster.
#
# Exists because the #1804 review landed a BLOCKING finding the required `ci` job could not have
# caught: nothing exercised this script at all. The bug was that a failed read (curl to Prometheus,
# `kubectl get pods`) produced empty output, exited 0 through a pipe, and printed `ok` — so "never
# asked" was indistinguishable from "verified clean", and `close` would let a window close on a
# signal nobody read. These cases pin that behaviour.
#
#   devbox run maint-self-test
set -uo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SUT="$ROOT/scripts/maintenance-window.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
ok()   { echo "  ok $*"; }
bad()  { echo "  FAIL $*"; fails=$((fails+1)); }

# A closed port: nothing listens, so curl fails rather than returning data.
DEAD_PROM="http://127.0.0.1:59321"

# Fake kubectl/gh on PATH so the test never touches a real cluster or GitHub.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get nodes"*) printf 'n1 Ready <none> 1d v1\n' ;;
  *"get pods -A"*) [ "${FAKE_PODS_FAIL:-0}" = 1 ] && exit 1; printf 'ns p1 1/1 Running 0 1d\n' ;;
  *"get pod -l k8s-app=cilium"*) printf '' ;;
  *) printf '' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf ''
EOF
chmod +x "$TMP/bin/kubectl" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export KUBECONFIG="$TMP/kubeconfig"; : > "$KUBECONFIG"
export MAINT_STATE_DIR="$TMP/state"
export MAINT_REPOS=""

echo "== maintenance-window self-test =="

# 1. Prometheus unreachable => open REFUSES rather than banking an unread baseline.
out="$(PROM_URL="$DEAD_PROM" bash "$SUT" open --reason "self-test" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then ok "open refuses when Prometheus is unreadable (rc=$rc)"
else bad "open banked a baseline with Prometheus down — rc=$rc"; fi
grep -qi "UNREADABLE" <<<"$out" && ok "open says UNREADABLE" || bad "open did not report UNREADABLE: $out"
[ -f "$MAINT_STATE_DIR/baseline.json" ] && bad "a baseline file was left behind" || ok "no baseline left behind"

# 2. A hand-made GOOD baseline + unreachable Prometheus => check FAILS and says so.
mkdir -p "$MAINT_STATE_DIR"
cat > "$MAINT_STATE_DIR/baseline.json" <<'EOF'
{"at":"2026-01-01T00:00:00Z","alerts":[],"alerts_ok":true,"up":100,"up_ok":true,
 "pods_bad":0,"pods_ok":true,"cilium_have":1,"cilium_missing":0,"cilium_unknown":0,"nodes":1}
EOF
out="$(PROM_URL="$DEAD_PROM" bash "$SUT" check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "check fails when the alert read fails (rc=$rc)" \
                || bad "check PASSED with Prometheus down — the regression is back (rc=$rc)"
grep -qi "alerts UNREADABLE" <<<"$out" && ok "check names the unread alert probe" \
                || bad "check did not name the unread alert probe: $out"
grep -qi "no new firing alerts" <<<"$out" && bad "check printed 'no new firing alerts' on a FAILED read" \
                || ok "check does not claim 'no new firing alerts' on a failed read"

# 3. A failing `kubectl get pods` is reported as unreadable, not as zero.
out="$(PROM_URL="$DEAD_PROM" FAKE_PODS_FAIL=1 bash "$SUT" check 2>&1)"
grep -qi "pods UNREADABLE" <<<"$out" && ok "check reports an unreadable pod list" \
                || bad "a failed 'kubectl get pods' did not surface as UNREADABLE: $out"

# 4. close must not close a window while a check is failing.
out="$(PROM_URL="$DEAD_PROM" bash "$SUT" close 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "close refuses while a probe is unreadable (rc=$rc)" \
                || bad "close succeeded on an unreadable cluster — rc=$rc"
grep -qi "REFUSING to close" <<<"$out" && ok "close says why" || bad "close did not explain: $out"

echo
[ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
echo "self-test: $fails FAILURE(S)"; exit 1
