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
  *"get nodes"*) [ "${FAKE_NODES_FAIL:-0}" = 1 ] && exit 0; printf 'n1 Ready <none> 1d v1\n' ;;
  *"get pods -A"*) [ "${FAKE_PODS_FAIL:-0}" = 1 ] && exit 1; printf 'ns p1 1/1 Running 0 1d\n' ;;
  *"get pod -l k8s-app=cilium"*)
    [ "${FAKE_CILIUM_LIST_FAIL:-0}" = 1 ] && exit 1
    # `partial` needs two agents: one answers, one does not.
    [ "${FAKE_CILIUM_EXEC_FAIL:-0}" = partial ] && { printf 'pod/cilium-aaa\npod/cilium-bbb\n'; exit 0; }
    printf 'pod/cilium-aaa\n' ;;
  *"exec"*cilium-dbg*)
    case "${FAKE_CILIUM_EXEC_FAIL:-0}" in
      all) exit 1 ;;
      partial) case "$*" in *cilium-bbb*) exit 1 ;; esac ;;
    esac
    printf 'ID Frontend Service Backend\n10 10.96.0.1:443/TCP ClusterIP 1 => 192.168.2.51:6443/TCP (active)\n' ;;
  *) printf '' ;;
esac
EOF
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_GH_FAIL:-0}" = 1 ] && { echo "gh: auth expired" >&2; exit 1; }
# A FRESH queued run (age well under the grace period) — i.e. healthy, not stranded. This is the
# path that had zero coverage and that killed cmd_check outright (review, #1804 round 3).
[ "${FAKE_GH_FRESH:-0}" = 1 ] && { printf '%s 123 CI [main]\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; exit 0; }
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
cat > "$TMP/baseline.fixture.json" <<'EOF'
{"at":"2026-01-01T00:00:00Z","alerts":[],"alerts_ok":true,"up":100,"up_ok":true,
 "pods_bad":0,"pods_ok":true,"cilium_have":1,"cilium_missing":0,"cilium_unknown":0,
 "nodes":1,"nodes_ok":true}
EOF
# Re-laid before every case: some cases run `open`, which deletes the baseline when it refuses.
baseline() { cp "$TMP/baseline.fixture.json" "$MAINT_STATE_DIR/baseline.json"; }
baseline
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

# 3b. A failing cilium AGENT LIST is unreadable, not "have=0 missing=0" (review, #1804 round 2).
out="$(PROM_URL="$DEAD_PROM" FAKE_CILIUM_LIST_FAIL=1 bash "$SUT" check 2>&1)"
grep -qi "cilium UNREADABLE" <<<"$out" && ok "check reports an unreadable cilium agent list" \
                || bad "a failed cilium list did not surface as UNREADABLE: $out"
grep -qi "ok  cilium apiserver backend" <<<"$out" && bad "check printed cilium 'ok' on a FAILED list read" \
                || ok "check does not claim cilium ok on a failed list read"

# 3c. A failing `gh` is unreadable, not "no CI runs stranded".
out="$(PROM_URL="$DEAD_PROM" MAINT_REPOS="homelab" FAKE_GH_FAIL=1 bash "$SUT" check 2>&1)"
grep -qi "CI status UNREADABLE" <<<"$out" && ok "check reports unreadable CI status" \
                || bad "a failed gh did not surface as UNREADABLE: $out"
grep -qi "no CI runs stranded" <<<"$out" && bad "check printed 'no CI runs stranded' when gh FAILED" \
                || ok "check does not claim 'no CI runs stranded' when gh failed"

# 3d. A LAST repo with a fresh (non-stranded) queued run must not kill cmd_check. The bug: the
# function's exit status was the last `[ age -gt grace ] && echo`, so a healthy repo returned 1 and
# `set -e` aborted the script before the CI line printed — no warning, no message, just dead.
out="$(PROM_URL="$DEAD_PROM" MAINT_REPOS="homelab sleep-iac" FAKE_GH_FRESH=1 bash "$SUT" check 2>&1)"
grep -qiE "no CI runs stranded|CI runs stranded" <<<"$out" && ok "check reaches the CI line with a fresh queued run" \
                || bad "check died before the CI line on a healthy fresh run: $out"

# 3e. Zero nodes — the apiserver fully unreachable, the worst case this tool exists for. `check`
# run DIRECTLY (the way SKILL.md documents for mid-window) must report it like any other probe and
# still print the rest of the breakdown. The bug: snapshot() `exit`ed, which in cmd_check's command
# substitution killed only the subshell, then `set -e` killed the script on the bare assignment —
# one stderr line, no header, no probe lines — while `close` (cmd_check under `||`) printed the
# full breakdown for the identical cluster. Review, #1804 round 4.
out="$(PROM_URL="$DEAD_PROM" FAKE_NODES_FAIL=1 bash "$SUT" check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "check fails on zero nodes (rc=$rc)" \
                || bad "check PASSED with an unreachable apiserver — rc=$rc"
grep -qi "nodes UNREADABLE" <<<"$out" && ok "check names the unreadable node list" \
                || bad "zero nodes did not surface as UNREADABLE: $out"
grep -q "check vs baseline" <<<"$out" && ok "check prints its header on zero nodes" \
                || bad "check died before its header on zero nodes: $out"
grep -qE "hard-failed pods|pods UNREADABLE" <<<"$out" && ok "check still reports the other probes on zero nodes" \
                || bad "check died before the later probes on zero nodes: $out"

# 3f. Same condition through `open`: a zero-node baseline is never banked.
rm -f "$MAINT_STATE_DIR/baseline.json"
out="$(PROM_URL="$DEAD_PROM" FAKE_NODES_FAIL=1 bash "$SUT" open --reason "self-test" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "open refuses a zero-node baseline (rc=$rc)" \
                || bad "open banked a baseline with 0 nodes — rc=$rc"
grep -q "nodes_ok=false" <<<"$out" && ok "open names the node read in its refusal" \
                || bad "open's refusal did not name nodes_ok: $out"
[ -f "$MAINT_STATE_DIR/baseline.json" ] && bad "a zero-node baseline was left behind" \
                || ok "no zero-node baseline left behind"

# 3g. EVERY agent's exec fails => the backend check answered nothing about a single node, so it
# must block. The three-way split's footnote ("unknown = exec did not answer twice") is the right
# response only while some agent answered — then missing=0 is a real reading of the responsive
# ones. have=0 with unknown>0 is an unread check wearing an `ok`. Review, #1804 round 5.
baseline
out="$(PROM_URL="$DEAD_PROM" FAKE_CILIUM_EXEC_FAIL=all bash "$SUT" check 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "check fails when every cilium exec fails (rc=$rc)" \
                || bad "check PASSED with the whole cilium fleet unread — rc=$rc"
grep -qi "every agent's exec failed" <<<"$out" && ok "check names the wholly-unread cilium fleet" \
                || bad "a fleet-wide exec failure did not surface as UNREADABLE: $out"
grep -q "ok  cilium apiserver backend" <<<"$out" && bad "check printed cilium 'ok' with have=0 unknown>0" \
                || ok "check does not claim cilium ok when nothing answered"

# 3h. The other side of that line: SOME agent answered, so missing=0 is a real reading and the
# unknown stays a footnote under `ok`. Pins the split itself, which had no assertion either way.
out="$(PROM_URL="$DEAD_PROM" FAKE_CILIUM_EXEC_FAIL=partial bash "$SUT" check 2>&1)"
grep -q "ok  cilium apiserver backend: have=1 missing=0 unknown=1" <<<"$out" \
                && ok "a partial exec failure stays ok with have>0" \
                || bad "a partially-unknown cilium fleet was not reported as ok: $out"
grep -q "unknown = exec did not answer twice" <<<"$out" && ok "the partial case keeps its footnote" \
                || bad "the partial case lost its footnote: $out"

# 3i. And open never banks a baseline the cilium read could not fill.
rm -f "$MAINT_STATE_DIR/baseline.json"
out="$(PROM_URL="$DEAD_PROM" FAKE_CILIUM_EXEC_FAIL=all bash "$SUT" open --reason "self-test" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "open refuses a wholly-unread cilium baseline (rc=$rc)" \
                || bad "open banked a baseline with have=0 unknown>0 — rc=$rc"
grep -q "cilium\[have=0 unknown=1\]" <<<"$out" && ok "open names the unread cilium counts" \
                || bad "open's refusal did not name the cilium counts: $out"

# 4. close must not close a window while a check is failing.
baseline
out="$(PROM_URL="$DEAD_PROM" bash "$SUT" close 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "close refuses while a probe is unreadable (rc=$rc)" \
                || bad "close succeeded on an unreadable cluster — rc=$rc"
grep -qi "REFUSING to close" <<<"$out" && ok "close says why" || bad "close did not explain: $out"

echo
[ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
echo "self-test: $fails FAILURE(S)"; exit 1
