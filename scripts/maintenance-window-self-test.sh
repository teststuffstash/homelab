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
# FAKE_STATE carries the markers that make a run have PHASES: `upgraded` is written by the stub
# node-maintenance, so the cilium answer can differ before and after the reboot — which is the
# only way to test a POST-rejoin gate at all.
mark() { [ -n "${FAKE_STATE:-}" ] && touch "$FAKE_STATE/$1"; }
has()  { [ -n "${FAKE_STATE:-}" ] && [ -f "$FAKE_STATE/$1" ]; }
case "$*" in
  # ---- the control-plane verb's reads (must precede the generic `get nodes` case) ----
  *"get node cp-01 -o json"*)
    printf '{"metadata":{"labels":{"node-role.kubernetes.io/control-plane":""}}}\n' ;;
  *"get node cp-01"*jsonpath*) printf '192.168.2.51\n' ;;
  *"get nodes -l node-role.kubernetes.io/control-plane -o json"*)
    cat <<'JSON'
{"items":[
 {"metadata":{"name":"cp-01"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"192.168.2.51"}]}},
 {"metadata":{"name":"cp-02"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"192.168.2.52"}]}},
 {"metadata":{"name":"cp-03"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"192.168.2.53"}]}}
]}
JSON
    ;;
  *"rollout restart"*ds/cilium*)
    [ -n "${FAKE_STATE:-}" ] && echo "$*" >> "$FAKE_STATE/rollouts"
    # Whether the roll actually fixes it is the case's choice: that is the difference between
    # the known signature and something else wearing its clothes.
    [ "${FAKE_CILIUM_RECOVERS:-1}" = 1 ] && mark recovered
    printf 'daemonset.apps/cilium restarted\n' ;;
  *"rollout status"*ds/cilium*) printf 'daemon set "cilium" successfully rolled out\n' ;;
  # ---- the window tool's reads ----
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
    # Unreadable only AFTER the reboot: the post-rejoin read failing is a different case from
    # the pre-flight one, and the CP verb must not roll the DaemonSet on either.
    [ "${FAKE_CILIUM_EXEC_FAIL_AFTER_UPGRADE:-0}" = 1 ] && has upgraded && exit 1
    # The backend is gone if this case says so — either from the start, or only once the node
    # has rebooted — and comes back when a rollout has been recorded.
    if { [ "${FAKE_CILIUM_NO_BACKEND:-0}" = 1 ] \
         || { [ "${FAKE_CILIUM_LOSE_ON_UPGRADE:-0}" = 1 ] && has upgraded; }; } && ! has recovered; then
      printf 'ID Frontend Service Backend\n10 10.96.0.1:443/TCP ClusterIP\n'; exit 0
    fi
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

# 4b. `cilium-check` alone — the subcommand the CP verb consumes. Its EXIT CODES are the
# contract (0 ok / 2 genuinely missing / 3 unread), and 2-vs-3 is what decides whether
# controlplane-upgrade.sh restarts a DaemonSet, so pin them here rather than only through §5.
FAKE_STATE="$TMP/cc"; mkdir -p "$FAKE_STATE"; export FAKE_STATE
out="$(bash "$SUT" cilium-check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "cilium-check exits 0 when the backend is held" || bad "cilium-check rc=$rc on a healthy fleet: $out"
out="$(FAKE_CILIUM_NO_BACKEND=1 bash "$SUT" cilium-check 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "cilium-check exits 2 on a genuinely missing backend" || bad "cilium-check rc=$rc (want 2) on a missing backend: $out"
out="$(FAKE_CILIUM_EXEC_FAIL=all bash "$SUT" cilium-check 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "cilium-check exits 3 when every exec fails" || bad "cilium-check rc=$rc (want 3) on an unread fleet: $out"
out="$(FAKE_CILIUM_LIST_FAIL=1 bash "$SUT" cilium-check 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "cilium-check exits 3 when the agent list fails" || bad "cilium-check rc=$rc (want 3) on an unreadable list: $out"
unset FAKE_STATE

# ---------------------------------------------------------------------------------------------
# 5. The OTHER side of the shared cilium check: scripts/controlplane-upgrade.sh.
#
# A control-plane upgrade restarts an apiserver, and on this fleet that drops Cilium's backend
# for 10.96.0.1:443 with no re-sync (FU-258). The verb's contract is narrow and each half of it
# is a way to make an outage worse if it is wrong: roll ds/cilium when an agent GENUINELY lost
# the backend, never on a reading that failed, never twice, and never leave a run reporting OK
# on a fleet that still cannot reach the API. None of that is reachable from the real cluster in
# CI, so the verb runs against a stub repo: the REAL maintenance-window.sh (the shared check is
# the thing under test) plus a stub node-maintenance that only marks the reboot as having
# happened, which is what lets the cilium answer differ before and after.
CPREPO="$TMP/cprepo"; mkdir -p "$CPREPO/scripts"
cp "$ROOT/scripts/controlplane-upgrade.sh" "$ROOT/scripts/maintenance-window.sh" "$CPREPO/scripts/"
cat > "$CPREPO/scripts/node-maintenance.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_STATE:-}" ] && touch "$FAKE_STATE/upgraded"
echo "stub node-maintenance: $*"
EOF
cat > "$TMP/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"etcd members"*)
    printf 'NODE ID HOSTNAME PEER CLIENT LEARNER\n'
    printf '192.168.2.51 a cp-01 https://192.168.2.51:2380 https://192.168.2.51:2379 false\n'
    printf '192.168.2.52 b cp-02 https://192.168.2.52:2380 https://192.168.2.52:2379 false\n'
    printf '192.168.2.53 c cp-03 https://192.168.2.53:2380 https://192.168.2.53:2379 false\n' ;;
  *"etcd status"*)
    # 14 whitespace fields per row == the table with an EMPTY errors column (see assert_etcd_status).
    printf 'NODE ID PROTOCOL DB DBSIZE INUSE PCT RAFTIDX RAFTTERM APPLIED LEARNER LEADER STORAGE ERRORS\n'
    for i in 1 2 3; do printf '192.168.2.5%s a etcd 3.6 1MB 1MB 1%% 1 1 1 false a healthy\n' "$i"; done ;;
  *"etcd snapshot"*) for a in "$@"; do last="$a"; done; printf 'snapshot' > "$last" ;;
  *) printf '' ;;
esac
EOF
chmod +x "$CPREPO/scripts/node-maintenance.sh" "$TMP/bin/talosctl"

# One case = one fresh phase directory, so `upgraded`/`recovered`/`rollouts` never leak between them.
cp_run() { # <case-name> [VAR=VAL ...]
  local name="$1"; shift
  FAKE_STATE="$TMP/cp-$name"; rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"
  env FAKE_STATE="$FAKE_STATE" CP_SNAPSHOT_DIR="$FAKE_STATE/snap" TALOSCONFIG="$TMP/talosconfig" \
      "$@" bash "$CPREPO/scripts/controlplane-upgrade.sh" cp-01 2>&1
}
rolls() { local n="$1"; [ -f "$TMP/cp-$n/rollouts" ] && awk 'NF{c++} END{print c+0}' "$TMP/cp-$n/rollouts" || echo 0; }
: > "$TMP/talosconfig"

# 5a. Nothing wrong: the verb completes and says the backend is held — and does NOT roll cilium.
out="$(cp_run clean)"; rc=$?
[ "$rc" -eq 0 ] && ok "cp-upgrade succeeds on a healthy fleet (rc=$rc)" \
                || bad "cp-upgrade failed on a healthy fleet (rc=$rc): $out"
grep -q "cilium holds the apiserver backend" <<<"$out" && ok "cp-upgrade reports the backend check in its OK line" \
                || bad "cp-upgrade's OK line does not mention the cilium check: $out"
[ "$(rolls clean)" -eq 0 ] && ok "cp-upgrade does not roll ds/cilium when nothing is missing" \
                || bad "cp-upgrade rolled ds/cilium on a healthy fleet"

# 5b. The known signature: the backend is there before and gone after the reboot => roll ONCE,
# re-read, finish clean. This is the whole point of the change.
out="$(cp_run lost FAKE_CILIUM_LOSE_ON_UPGRADE=1 FAKE_CILIUM_RECOVERS=1)"; rc=$?
[ "$rc" -eq 0 ] && ok "cp-upgrade recovers the dropped backend and succeeds (rc=$rc)" \
                || bad "cp-upgrade did not recover the dropped backend (rc=$rc): $out"
grep -q "Rolling ds/cilium" <<<"$out" && ok "cp-upgrade says it is rolling ds/cilium" \
                || bad "cp-upgrade rolled nothing when the backend was dropped: $out"
[ "$(rolls lost)" -eq 1 ] && ok "cp-upgrade rolls ds/cilium exactly once" \
                || bad "cp-upgrade rolled ds/cilium $(rolls lost) time(s), expected 1"

# 5c. Already broken BEFORE the window: refuse, roll nothing, take no snapshot. Rebooting a
# control plane on a fleet that cannot reach the API is how a bad state becomes an incident.
out="$(cp_run pre FAKE_CILIUM_NO_BACKEND=1)"; rc=$?
[ "$rc" -ne 0 ] && ok "cp-upgrade refuses to start with the backend already missing (rc=$rc)" \
                || bad "cp-upgrade started on a fleet already missing the backend (rc=$rc)"
grep -q "BEFORE the upgrade" <<<"$out" && ok "the pre-flight refusal says when it is refusing" \
                || bad "the pre-flight refusal is not legible: $out"
[ "$(rolls pre)" -eq 0 ] && ok "the pre-flight refusal rolls nothing" || bad "the pre-flight refusal rolled ds/cilium"
[ -f "$TMP/cp-pre/upgraded" ] && bad "cp-upgrade reached the upgrade despite the refusal" \
                || ok "cp-upgrade refused before touching the node"

# 5d. The post-rejoin read FAILS. `rollout restart` on a reading nobody could take is a blind
# roll, during exactly the apiserver instability that makes the read flaky — so: refuse, do not
# roll, and do not report success either.
out="$(cp_run unread FAKE_CILIUM_EXEC_FAIL_AFTER_UPGRADE=1)"; rc=$?
[ "$rc" -ne 0 ] && ok "cp-upgrade fails when the post-rejoin cilium read is unreadable (rc=$rc)" \
                || bad "cp-upgrade reported success on an unread cilium fleet (rc=$rc): $out"
[ "$(rolls unread)" -eq 0 ] && ok "cp-upgrade does not roll ds/cilium on an unreadable read" \
                || bad "cp-upgrade rolled ds/cilium blind"
grep -qi "UNREADABLE" <<<"$out" && ok "cp-upgrade names the unread cilium state" \
                || bad "cp-upgrade's failure did not name the unread state: $out"

# 5e. Rolled, and the backend is STILL missing: not the known signature. Fail loudly with one
# roll behind us — a second restart would be superstition, and an OK here would send the
# operator into the next control plane on a broken fleet.
out="$(cp_run stuck FAKE_CILIUM_LOSE_ON_UPGRADE=1 FAKE_CILIUM_RECOVERS=0)"; rc=$?
[ "$rc" -ne 0 ] && ok "cp-upgrade fails when the roll does not restore the backend (rc=$rc)" \
                || bad "cp-upgrade reported success with the backend still missing (rc=$rc): $out"
[ "$(rolls stuck)" -eq 1 ] && ok "cp-upgrade does not roll a second time" \
                || bad "cp-upgrade rolled ds/cilium $(rolls stuck) time(s), expected exactly 1"
grep -qi "NOT the known signature" <<<"$out" && ok "cp-upgrade says the signature does not match" \
                || bad "cp-upgrade's failure did not distinguish this from the known bug: $out"

echo
[ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
echo "self-test: $fails FAILURE(S)"; exit 1
