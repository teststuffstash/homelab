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
# no_slots: nothing banked — no slot dir, no pending dir, no pre-slot file.
no_slots() { [ -z "$(find "$MAINT_STATE_DIR" -name baseline.json 2>/dev/null)" ]; }
no_slots && ok "no baseline left behind" || bad "a baseline file was left behind"

# 2. A hand-made GOOD baseline + unreachable Prometheus => check FAILS and says so.
mkdir -p "$MAINT_STATE_DIR"
cat > "$TMP/baseline.fixture.json" <<'EOF'
{"at":"2026-01-01T00:00:00Z","alerts":[],"alerts_ok":true,"up":100,"up_ok":true,
 "pods_bad":0,"pods_ok":true,"cilium_have":1,"cilium_missing":0,"cilium_unknown":0,
 "nodes":1,"nodes_ok":true}
EOF
# Re-laid before every case: some cases run `open`, which deletes the baseline when it refuses.
# One slot, keyed like a real window (the state layout is one slot per window id — §7).
baseline() { mkdir -p "$MAINT_STATE_DIR/fixture"; cp "$TMP/baseline.fixture.json" "$MAINT_STATE_DIR/fixture/baseline.json"; }
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
rm -rf "$MAINT_STATE_DIR"/*
out="$(PROM_URL="$DEAD_PROM" FAKE_NODES_FAIL=1 bash "$SUT" open --reason "self-test" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "open refuses a zero-node baseline (rc=$rc)" \
                || bad "open banked a baseline with 0 nodes — rc=$rc"
grep -q "nodes_ok=false" <<<"$out" && ok "open names the node read in its refusal" \
                || bad "open's refusal did not name nodes_ok: $out"
no_slots && ok "no zero-node baseline left behind" || bad "a zero-node baseline was left behind"

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
rm -rf "$MAINT_STATE_DIR"/*
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

# ---------------------------------------------------------------------------------------------
# 6. The UNATTENDED pair — `snapshot` + `compare`, what the management box's apply loop brackets a
# Talos config apply with (mgmt/scripts/mgmt-apply.sh). A fake curl answers as Prometheus (FAKE_ALERTS
# = the firing names, FAKE_UP = sum(up)); everything else is the stub kubectl above.
REAL_CURL="$(PATH="${PATH#"$TMP/bin:"}" command -v curl)"
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
[ "\${FAKE_PROM:-0}" = 1 ] || exec "$REAL_CURL" "\$@"
case "\$*" in
  *api/v1/alerts*) printf '{"status":"success","data":{"alerts":[%s]}}' "\$(for a in \${FAKE_ALERTS:-}; do printf '%s{"state":"firing","labels":{"alertname":"%s"}}' "\${sep:-}" "\$a"; sep=,; done)" ;;
  *api/v1/query*)  printf '{"status":"success","data":{"result":[{"value":[0,"%s"]}]}}' "\${FAKE_UP:-100}" ;;
esac
EOF
chmod +x "$TMP/bin/curl"
FAKE_STATE="$TMP/snap"; mkdir -p "$FAKE_STATE"; export FAKE_STATE
out="$(PROM_URL="$DEAD_PROM" bash "$SUT" snapshot 2>"$TMP/snap.err")"; rc=$?
[ "$rc" -eq 1 ] && ok "snapshot exits 1 when Prometheus is unreadable" || bad "snapshot rc=$rc (want 1) with Prometheus down"
grep -q "alerts_ok=false" "$TMP/snap.err" && ok "snapshot names the unread probe on stderr" || bad "snapshot's refusal did not name alerts_ok: $(cat "$TMP/snap.err")"
FAKE_PROM=1 FAKE_ALERTS="Watchdog" FAKE_UP=100 bash "$SUT" snapshot > "$TMP/base.json"; rc=$?
[ "$rc" -eq 0 ] && jq -e '.alerts == ["Watchdog"] and .up == 100 and .cilium_have == 1' "$TMP/base.json" >/dev/null \
  && ok "snapshot banks a readable baseline (rc=0)" || bad "snapshot rc=$rc on a readable cluster: $(cat "$TMP/base.json")"
out="$(FAKE_PROM=1 FAKE_ALERTS="Watchdog" FAKE_UP=100 bash "$SUT" compare "$TMP/base.json" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "compare exits 0 on an unchanged cluster" || bad "compare rc=$rc on an unchanged cluster: $out"
grep -q "CI runs" <<<"$out" && bad "compare ran the CI probe (the box has no gh)" || ok "compare leaves the CI probe out"
out="$(FAKE_PROM=1 FAKE_ALERTS="Watchdog KubeAPIDown" FAKE_UP=100 bash "$SUT" compare "$TMP/base.json" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "NEW firing alerts: KubeAPIDown" <<<"$out" && ok "compare exits 2 naming a new firing alert" \
  || bad "compare rc=$rc on a new alert: $out"
out="$(FAKE_PROM=1 FAKE_ALERTS="Watchdog" FAKE_UP=100 FAKE_CILIUM_NO_BACKEND=1 bash "$SUT" compare "$TMP/base.json" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "NO backend for 10.96.0.1:443" <<<"$out" && ok "compare exits 2 on the 2026-09-20 signature (cilium backend lost)" \
  || bad "compare rc=$rc on a lost cilium backend: $out"
out="$(FAKE_PROM=1 FAKE_UP=60 FAKE_ALERTS="Watchdog" bash "$SUT" compare "$TMP/base.json" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "scrape targets DOWN: 100 -> 60" <<<"$out" && ok "compare exits 2 on lost scrape targets" \
  || bad "compare rc=$rc on lost targets: $out"
out="$(bash "$SUT" compare "$TMP/absent.json" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "compare refuses a missing baseline file (rc=$rc)" || bad "compare passed with no baseline: $out"
unset FAKE_STATE

# ---------------------------------------------------------------------------------------------
# 7. ONE STATE SLOT PER WINDOW (GAPS maintenance-window-G1). On 2026-09-22 a seat and its subagent
# had windows open at once; the single per-user slot let the second `open` overwrite the first's
# baseline + window id, so the first `close` would have closed the SUBAGENT's window. Runs the REAL
# script from a stub repo whose agents/seat-window.sh only mints ids and logs calls — DEVBOX_PROJECT_ROOT
# is pinned to it, because `devbox run` exports the real checkout and the real one writes the cluster.
WREPO="$TMP/wrepo"; mkdir -p "$WREPO/scripts" "$WREPO/agents"
cp "$ROOT/scripts/maintenance-window.sh" "$WREPO/scripts/"
cat > "$WREPO/agents/seat-window.sh" <<'EOF'
#!/usr/bin/env bash
log="$FAKE_STATE/seat-window.log"
case "$1" in
  open)  n=$(( $(cat "$FAKE_STATE/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_STATE/n"
         echo "open w$n" >> "$log"; echo "✓ window w$n open until 2099-01-01T00:00:00Z — stub" ;;
  close) echo "close $*" >> "$log"; echo "✓ closed 1 window(s)" ;;
  *)     echo "$*" >> "$log" ;;
esac
EOF
FAKE_STATE="$TMP/slots"; mkdir -p "$FAKE_STATE"; export FAKE_STATE
export MAINT_STATE_DIR="$TMP/slot-state"
mw() { DEVBOX_PROJECT_ROOT="$WREPO" FAKE_PROM=1 FAKE_UP=100 bash "$WREPO/scripts/maintenance-window.sh" "$@" 2>&1; }
closes() { grep -c '^close' "$FAKE_STATE/seat-window.log" 2>/dev/null || true; }

# 7a. Legacy single-window flow: open → check → close, no --id anywhere.
out="$(FAKE_ALERTS="Watchdog" mw open --reason "single")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$MAINT_STATE_DIR/w1/baseline.json" ] && ok "open banks its baseline in the window's slot (w1)" \
  || bad "open rc=$rc did not bank a w1 slot: $out"
grep -q "pass '--id w1'" <<<"$out" && ok "open prints the id to pass" || bad "open did not print the --id hint: $out"
out="$(FAKE_ALERTS="Watchdog" mw check)"; rc=$?
[ "$rc" -eq 0 ] && ok "check without --id uses the one open window" || bad "single-window check rc=$rc: $out"
out="$(FAKE_ALERTS="Watchdog" mw close)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^close close --id w1 --tail-min 20$' "$FAKE_STATE/seat-window.log" && [ ! -e "$MAINT_STATE_DIR/w1" ] \
  && ok "close without --id closes the one window and drops its slot" || bad "single-window close rc=$rc: $out / $(cat "$FAKE_STATE/seat-window.log")"

# 7b. Two concurrent opens keep SEPARATE baselines: w2 before a Foo alert, w3 after it.
FAKE_ALERTS="Watchdog" mw open --reason "seat" >/dev/null
FAKE_ALERTS="Watchdog Foo" mw open --reason "subagent" >/dev/null
jq -e '.alerts == ["Watchdog"]' "$MAINT_STATE_DIR/w2/baseline.json" >/dev/null \
  && jq -e '.alerts == ["Foo","Watchdog"]' "$MAINT_STATE_DIR/w3/baseline.json" >/dev/null \
  && ok "two concurrent opens keep separate baselines" || bad "the second open clobbered the first's baseline"
out="$(FAKE_ALERTS="Watchdog Foo" mw check --id w2)"; rc=$?
[ "$rc" -eq 2 ] && grep -q "NEW firing alerts: Foo" <<<"$out" && ok "check --id w2 compares against w2's own baseline" \
  || bad "check --id w2 rc=$rc did not flag Foo: $out"
out="$(FAKE_ALERTS="Watchdog Foo" mw check --id w3)"; rc=$?
[ "$rc" -eq 0 ] && ok "check --id w3 compares against w3's own baseline" || bad "check --id w3 rc=$rc: $out"

# 7c. Without --id and two live windows: REFUSE and list both — never guess.
n0="$(closes)"
out="$(FAKE_ALERTS="Watchdog Foo" mw close)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "REFUSING" <<<"$out" && grep -q "w2" <<<"$out" && grep -q "w3" <<<"$out" \
  && ok "close without --id refuses with 2 windows open, listing both" || bad "close without --id rc=$rc: $out"
[ "$(closes)" -eq "$n0" ] && ok "the refused close closed no window" || bad "the refused close still called seat-window close"
out="$(FAKE_ALERTS="Watchdog Foo" mw check)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "REFUSING" <<<"$out" && ok "check without --id refuses with 2 windows open" \
  || bad "check without --id rc=$rc: $out"

# 7d. close --id closes ONLY that window; the other slot survives, and is then the one.
out="$(FAKE_ALERTS="Watchdog Foo" mw close --id w3)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$MAINT_STATE_DIR/w3" ] && [ -f "$MAINT_STATE_DIR/w2/baseline.json" ] \
  && [ "$(tail -1 "$FAKE_STATE/seat-window.log")" = "close close --id w3 --tail-min 20" ] \
  && ok "close --id w3 closes only w3" || bad "close --id w3 rc=$rc: $out / $(cat "$FAKE_STATE/seat-window.log")"
out="$(FAKE_ALERTS="Watchdog Foo" mw close)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "REFUSING to close" <<<"$out" && [ -e "$MAINT_STATE_DIR/w2" ] \
  && ok "the remaining window's close still gates on ITS baseline (Foo is new to w2)" || bad "w2 close rc=$rc: $out"
out="$(FAKE_ALERTS="Watchdog Foo" mw close --force --id w2)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$MAINT_STATE_DIR/w2" ] && [ "$(tail -1 "$FAKE_STATE/seat-window.log")" = "close close --id w2 --tail-min 20" ] \
  && ok "close --force --id (either order) closes it" || bad "close --force --id w2 rc=$rc: $out"

# 7e. Unknown / path-shaped ids are refused, not resolved.
out="$(mw check --id nope)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "no maintenance-window slot for 'nope'" <<<"$out" && ok "an unknown --id is refused" || bad "unknown --id rc=$rc: $out"
out="$(mw close --id ..)"; rc=$?
[ "$rc" -eq 64 ] && ok "a path-shaped --id is refused" || bad "close --id .. rc=$rc: $out"

# 7f. Pre-slot state (a window opened by the single-slot version) migrates and closes by its id.
mkdir -p "$MAINT_STATE_DIR"; printf 'old-7' > "$MAINT_STATE_DIR/window-id"
jq '.alerts=["Watchdog"]' "$TMP/baseline.fixture.json" > "$MAINT_STATE_DIR/baseline.json"
out="$(FAKE_ALERTS="Watchdog" mw list)"
grep -q "old-7" <<<"$out" && [ ! -e "$MAINT_STATE_DIR/baseline.json" ] && ok "a pre-slot baseline migrates into a slot" || bad "legacy migration: $out"
out="$(FAKE_ALERTS="Watchdog" mw close)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(tail -1 "$FAKE_STATE/seat-window.log")" = "close close --id old-7 --tail-min 20" ] \
  && ok "a migrated window closes by its recorded id" || bad "legacy close rc=$rc: $out"
unset FAKE_STATE

# ---------------------------------------------------------------------------------------------
# 8. LEASES, CLAIMS AND THE TAIL (operator ruling 2026-10-09, FU-230). Three defects, one per
# assertion block: (1) a fixed `--hours 2` declaration lapsed mid-window (window 2, 2026-10-08:
# lapsed ~20:59Z, work ran to 05:21Z, ~8 sessions on the 04:57Z burst) → the window is a LEASE the
# watch renews; (2) close DELETED the record at Ready and KubePodNotReady (`for: 15m`) fired after it
# (nx-01, 13:44Z close → 13:45–13:47Z, 4 sessions) → close TAILS; (3) a named alert muted the
# responder cluster-wide and nobody owned it → CLAIM, an Alertmanager silence under the lease.
# The REAL agents/seat-window.sh runs against a stateful fake ConfigMap + fake Alertmanager.
S8="$TMP/s8"; mkdir -p "$S8/bin" "$S8/am"
cat > "$S8/bin/kubectl" <<STUB
#!/usr/bin/env bash
# The responder-window ConfigMap lives in \$FAKE_CM; every other read falls through to the
# section-wide fake (nodes, pods, cilium) so maintenance-window.sh open/check still see a cluster.
case " \$* " in *" cm "*) ;; *) exec "$TMP/bin/kubectl" "\$@" ;; esac
f="\${FAKE_CM:?}"; p=""; prev=""; for a in "\$@"; do [ "\$prev" = -p ] && p="\$a"; prev="\$a"; done
case " \$* " in
  *" get cm "*" -o json "*) [ -f "\$f" ] || { echo 'Error from server (NotFound)' >&2; exit 1; }; cat "\$f" ;;
  *" get cm "*) [ -f "\$f" ] ;;
  *" create cm "*) [ -f "\$f" ] || printf '{"data":{}}' > "\$f" ;;
  *" patch cm "*"--type merge"*) jq --argjson p "\$p" '.data = ((.data // {}) + \$p.data)' "\$f" > "\$f.n" && mv "\$f.n" "\$f" ;;
  *" patch cm "*"--type json"*)
    k="\$(jq -r '.[0].path | sub("^/data/";"")' <<<"\$p")"
    jq --arg k "\$k" 'del(.data[\$k])' "\$f" > "\$f.n" && mv "\$f.n" "\$f" ;;
esac
STUB
cat > "$S8/bin/curl" <<STUB
#!/usr/bin/env bash
# Alertmanager (/api/v2/) is served from \$FAKE_AM; Prometheus falls through to the fake above.
case "\$*" in */api/v2/*) ;; *) exec "$TMP/bin/curl" "\$@" ;; esac
d="\${FAKE_AM:?}"; m=GET; data=""; url=""; prev=""
for a in "\$@"; do case "\$prev" in -X) m="\$a";; -d) data="\$a";; esac; case "\$a" in http*) url="\$a";; esac; prev="\$a"; done
[ -d "\$d" ] || exit 7
[ -f "\$d/silences.json" ] || echo '[]' > "\$d/silences.json"
case "\$m \$url" in
  "GET "*/api/v2/silences) cat "\$d/silences.json" ;;
  "GET "*/api/v2/alerts*) cat "\$d/alerts.json" 2>/dev/null || echo '[]' ;;
  "POST "*/api/v2/silences)
    id="\$(jq -r '.id // empty' <<<"\$data")"
    if [ -n "\$id" ]; then jq --argjson b "\$data" 'map(if .id == \$b.id then (. + \$b) else . end)' "\$d/silences.json" > "\$d/s.n"
    else id="s\$(( \$(jq length "\$d/silences.json") + 1 ))"
         jq --argjson b "\$data" --arg id "\$id" '. + [\$b + {id:\$id, status:{state:"active"}}]' "\$d/silences.json" > "\$d/s.n"; fi
    mv "\$d/s.n" "\$d/silences.json"; printf '{"silenceID":"%s"}' "\$id" ;;
  "DELETE "*/api/v2/silence/*)
    jq --arg id "\${url##*/}" 'map(if .id == \$id then .status.state = "expired" else . end)' "\$d/silences.json" > "\$d/s.n"; mv "\$d/s.n" "\$d/silences.json" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$S8/bin/kubectl" "$S8/bin/curl"
REPO8="$TMP/repo8"; mkdir -p "$REPO8/scripts" "$REPO8/agents"
cp "$ROOT/scripts/maintenance-window.sh" "$REPO8/scripts/"; cp "$ROOT/agents/seat-window.sh" "$REPO8/agents/"
export FAKE_CM="$S8/cm.json" FAKE_AM="$S8/am"
sw() { PATH="$S8/bin:$PATH" SEAT_WINDOW_AM=http://am.test:9093 bash "$REPO8/agents/seat-window.sh" "$@" 2>&1; }
mw8() { PATH="$S8/bin:$PATH" SEAT_WINDOW_AM=http://am.test:9093 DEVBOX_PROJECT_ROOT="$REPO8" MAINT_STATE_DIR="$S8/state" \
        FAKE_PROM=1 FAKE_UP=100 FAKE_ALERTS="Watchdog" bash "$REPO8/scripts/maintenance-window.sh" "$@" 2>&1; }
rec() { jq -c --arg id "$1" '[.data[] | fromjson | select(.id == $id)] | first' "$FAKE_CM"; }
iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
claims() { jq -c --arg by "seat-window/$1" '[.[] | select(.createdBy == $by and .status.state != "expired")]' "$FAKE_AM/silences.json"; }
setuntil() { # <id> <iso> — age a record in place
  jq --arg id "$1" --arg u "$2" '.data |= with_entries(if (.value | fromjson | .id) == $id then .value = (.value | fromjson | .until = $u | tojson) else . end)' \
    "$FAKE_CM" > "$FAKE_CM.n" && mv "$FAKE_CM.n" "$FAKE_CM"
}

# 8a. open --minutes: a lease, not a term.
out="$(sw open --reason "lease test" --alerts KubePodNotReady,TargetDown --minutes 30)"
W="$(sed -n 's/^✓ window \([^ ]*\) open.*/\1/p' <<<"$out")"
u="$(rec "$W" | jq -r .until)"
[[ "$u" > "$(iso '+25 minutes')" && "$u" < "$(iso '+35 minutes')" ]] && ok "open --minutes 30 declares a 30-minute lease" || bad "lease until=$u: $out"

# 8b. claim: the grammar refuses name-wide and unscoped pod-regex claims; a good one is a silence
# on the alert's labels, under the window's lease, comment naming the window.
out="$(sw claim --id "$W" --alert KubePodNotReady --match 'pod=~cilium-.*')"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'namespace' <<<"$out" && ok "a pod=~ claim without namespace= is refused" || bad "unscoped pod regex rc=$rc: $out"
out="$(sw claim --id "$W" --alert KubePodNotReady --match 'alertname=KubePodNotReady')"; rc=$?
[ "$rc" -ne 0 ] && ok "a name-only claim (the old cluster-wide mute) is refused" || bad "name-only claim rc=$rc: $out"
out="$(sw claim --id "$W" --alert KubePodNotReady --match 'namespace=kube-system,pod=~.*')"; rc=$?
[ "$rc" -ne 0 ] && ok "a match-everything regex is refused" || bad "match-all claim rc=$rc: $out"
out="$(sw claim --id "$W" --alert KubePodNotReady --match 'namespace=kube-system,pod=~cilium-.*')"; rc=$?
c="$(claims "$W")"
[ "$rc" -eq 0 ] && jq -e --arg u "$u" --arg w "$W" 'length == 1 and .[0].endsAt == $u and (.[0].comment | contains($w))
      and (.[0].matchers | any(.name == "pod" and .isRegex and .value == "cilium-.*"))
      and (.[0].matchers | any(.name == "alertname" and .value == "KubePodNotReady"))' <<<"$c" >/dev/null \
  && ok "claim = a silence on the alert's labels, endsAt = the lease, comment names the window" || bad "claim rc=$rc: $out / $c"
printf '[{"fingerprint":"fp9","labels":{"alertname":"TargetDown","job":"x","namespace":"ns"},"status":{"state":"active"}}]' > "$FAKE_AM/alerts.json"
out="$(sw claim --id "$W" --fp fp9)"; rc=$?
[ "$rc" -eq 0 ] && jq -e '[.[] | select(.matchers | any(.name == "job" and .value == "x"))] | length == 1' <<<"$(claims "$W")" >/dev/null \
  && ok "claim --fp derives equality matchers from the alert's own labels" || bad "claim --fp rc=$rc: $out"

# 8c. renew pushes the lease AND every claim with it.
out="$(sw renew --id "$W" --minutes 90)"; rc=$?
u2="$(rec "$W" | jq -r .until)"
[ "$rc" -eq 0 ] && [[ "$u2" > "$(iso '+85 minutes')" ]] && jq -e --arg u "$u2" 'all(.[]; .endsAt == $u)' <<<"$(claims "$W")" >/dev/null \
  && ok "renew extends the lease and the claims' endsAt together" || bad "renew rc=$rc until=$u2: $out / $(claims "$W")"
out="$(sw renew --id "$W" --minutes 5)"
[ "$(rec "$W" | jq -r .until)" = "$u2" ] && ok "renew never shortens a longer lease" || bad "renew --minutes 5 shortened: $out"
SEAT_WINDOW_BY=nm sw open --reason "node w" --alerts X --node n1 --minutes 30 >/dev/null
sw has --node n1 --by nm >/dev/null && ok "has sees a live window" || bad "has missed the live window"

# 8d. close: mutex released NOW (every `until > now` reader), tail for the responder, claims tail.
out="$(sw close --id "$W" --tail-min 20)"; rc=$?
r="$(rec "$W")"; now="$(iso now)"
[ "$rc" -eq 0 ] && [[ ! "$(jq -r .until <<<"$r")" > "$now" ]] && [ -n "$(jq -r '.closed_at // ""' <<<"$r")" ] \
  && [[ "$(jq -r .tail_until <<<"$r")" > "$(iso '+15 minutes')" ]] \
  && ok "close keeps the record: until=now (mutex released), closed_at, tail_until ≈ now+20m" || bad "close rc=$rc: $out / $r"
mutex="$(jq -c --arg now "$now" '[.data[] | fromjson | select((.until // "") > $now) | .id]' "$FAKE_CM")"
jq -e --arg w "$W" 'index($w) | not' <<<"$mutex" >/dev/null && ok "…the mgmt readers' filter (until > now) no longer sees it" || bad "closed window still live to the mutex: $mutex"
jq -e --arg t "$(jq -r .tail_until <<<"$r")" 'length == 2 and all(.[]; .endsAt == $t)' <<<"$(claims "$W")" >/dev/null \
  && ok "…and its claims now end with the tail, not at the close" || bad "claims after close: $(claims "$W")"
grep -q 'triage tail until' <<<"$(sw list)" && ok "list shows a closed window in its tail" || bad "list lost the tailing window: $(sw list)"
out="$(sw renew --id "$W")"; rc=$?
[ "$rc" -ne 0 ] && grep -q CLOSED <<<"$out" && ok "renew refuses a closed window" || bad "renew after close rc=$rc: $out"
out="$(sw claim --id "$W" --alert TargetDown --match 'job=y')"; rc=$?
[ "$rc" -ne 0 ] && ok "claim refuses a closed window" || bad "claim after close rc=$rc: $out"
out="$(sw close --id "$W")"
grep -q 'no matching window' <<<"$out" && ok "a closed window is history, not a close target" || bad "re-close: $out"
out="$(sw close --node n1 --by nm)"
sw has --node n1 --by nm >/dev/null && bad "a --node/--by close left the window live to has" || ok "a --node/--by close releases has at once"
[ "$(sw list | head -1)" = "no live seat window" ] && grep -q 'still in their triage tail' <<<"$(sw list)" \
  && ok "list: 'no live seat window' first (helm-release-evidence greps it), the tails after" || bad "list with only tails: $(sw list)"

# 8e. A dead seat: the lease lapses and renew says so (exit 1) — never a silent re-open.
jq --arg p "$(iso '-5 minutes')" '.data["w-dead"] = ({id:"dead-1", by:"seat", until:$p, reason:"dead", alerts:["X"], node:"", note:""} | tojson)' "$FAKE_CM" > "$FAKE_CM.n" && mv "$FAKE_CM.n" "$FAKE_CM"
out="$(sw renew --id dead-1)"; rc=$?
[ "$rc" -ne 0 ] && grep -q LAPSED <<<"$out" && ok "renew of a lapsed lease exits 1 (LAPSED)" || bad "lapsed renew rc=$rc: $out"

# 8f. History: ≥ 4 days kept for the deep dig, older pruned by the next write.
jq --arg o "$(iso '-5 days')" --arg y "$(iso '-3 days')" '.data["w-old"] = ({id:"old", until:$o, closed_at:$o, tail_until:$o, reason:"r", alerts:["X"]} | tojson)
      | .data["w-young"] = ({id:"young", until:$y, closed_at:$y, tail_until:$y, reason:"r", alerts:["X"]} | tojson)' "$FAKE_CM" > "$FAKE_CM.n" && mv "$FAKE_CM.n" "$FAKE_CM"
sw open --reason gc --alerts X --minutes 5 >/dev/null
jq -e '(.data | has("w-old") | not) and (.data | has("w-young"))' "$FAKE_CM" >/dev/null \
  && ok "history older than 4 days is pruned on write; 3-day-old history stays" || bad "gc: $(jq -c '.data | keys' "$FAKE_CM")"

# 8g. tail-silences: a verb's own silences (node-maintenance.sh/<node>) end at now+N, not now.
jq '. + [{id:"nm1", createdBy:"node-maintenance.sh/n1", matchers:[{name:"node",value:"n1",isRegex:false,isEqual:true}], startsAt:"2026-01-01T00:00:00Z", endsAt:"2099-01-01T00:00:00Z", comment:"c", status:{state:"active"}}]' \
  "$FAKE_AM/silences.json" > "$FAKE_AM/s.n" && mv "$FAKE_AM/s.n" "$FAKE_AM/silences.json"
out="$(sw tail-silences --created-by node-maintenance.sh/n1 --minutes 20)"; rc=$?
e="$(jq -r '.[] | select(.id == "nm1") | "\(.status.state) \(.endsAt)"' "$FAKE_AM/silences.json")"
[ "$rc" -eq 0 ] && [ "${e%% *}" = active ] && [[ "${e#* }" > "$(iso '+15 minutes')" && "${e#* }" < "$(iso '+25 minutes')" ]] \
  && ok "tail-silences retimes a verb's silences to now+20m instead of expiring them" || bad "tail-silences rc=$rc: $out / $e"
out="$(FAKE_AM=/nonexistent/x sw tail-silences --created-by node-maintenance.sh/n1)"; rc=$?
[ "$rc" -ne 0 ] && ok "tail-silences exits non-zero when Alertmanager is unreadable" || bad "unreadable AM tail rc=$rc: $out"

# 8h. maintenance-window.sh: open without --hours is a LEASE; --hours is a fixed term.
out="$(mw8 open --reason "mw lease")"; rc=$?
M="$(sed -n 's/^✓ window \([^ ]*\) open.*/\1/p' <<<"$out")"
mu="$(rec "$M" | jq -r .until)"
[ "$rc" -eq 0 ] && [[ "$mu" < "$(iso '+35 minutes')" ]] && grep -q "must call 'renew --id $M'" <<<"$out" \
  && jq -e '.lease == true' "$S8/state/$M/meta.json" >/dev/null \
  && ok "maint open (no --hours) declares a 30m lease and says the watch must renew it" || bad "maint open rc=$rc until=$mu: $out"
out="$(mw8 open --reason "mw fixed" --hours 3)"; F="$(sed -n 's/^✓ window \([^ ]*\) open.*/\1/p' <<<"$out")"
[[ "$(rec "$F" | jq -r .until)" > "$(iso '+170 minutes')" ]] && ok "maint open --hours 3 keeps a fixed term (unattended callers)" || bad "maint --hours: $out"

# 8i. renew / check renew; claim passes through; close tails; a lapsed lease is loud.
out="$(MAINT_LEASE_MIN=60 mw8 renew --id "$M")"; rc=$?
[ "$rc" -eq 0 ] && [[ "$(rec "$M" | jq -r .until)" > "$(iso '+55 minutes')" ]] && ok "maint renew extends the declared window" || bad "maint renew rc=$rc: $out"
out="$(MAINT_LEASE_MIN=120 mw8 check --id "$M")"; rc=$?
[ "$rc" -eq 0 ] && [[ "$(rec "$M" | jq -r .until)" > "$(iso '+115 minutes')" ]] && ok "maint check renews the lease too (rc stays the cluster verdict)" || bad "check renew rc=$rc: $out"
out="$(mw8 claim --id "$M" --alert KubePodNotReady --match 'namespace=longhorn-system,pod=~engine-image-.*')"; rc=$?
[ "$rc" -eq 0 ] && [ "$(claims "$M" | jq length)" = 1 ] && ok "maint claim creates the claim under the window's id" || bad "maint claim rc=$rc: $out"
out="$(mw8 close --id "$M")"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$(rec "$M" | jq -r '.closed_at // ""')" ] && [[ "$(rec "$M" | jq -r .tail_until)" > "$(iso '+15 minutes')" ]] \
  && [ ! -e "$S8/state/$M" ] && ok "maint close tails the declared window (history kept) and drops the slot" || bad "maint close rc=$rc: $out / $(rec "$M")"
setuntil "$F" "2020-01-01T00:00:00Z"
out="$(mw8 renew --id "$F")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'NOT live any more' <<<"$out" && ok "maint renew of a lapsed window fails loudly (the watch hears it)" || bad "maint lapsed renew rc=$rc: $out"

# 8j. node-maintenance.sh `up`'s close half (silence-close): the verb's silences TAIL past Ready, the
# node's pods-as-of-now get a `#pods-tail` silence (reinstalls mint new DaemonSet pod names), and
# its declared record closes with a tail — the nx-01 13:44Z → 13:45–13:47Z sessions (defect 2).
cp "$ROOT/scripts/node-maintenance.sh" "$REPO8/scripts/"
jq 'map(if .id == "nm1" then .endsAt = "2099-01-01T00:00:00Z" else . end)' "$FAKE_AM/silences.json" > "$FAKE_AM/s.n" && mv "$FAKE_AM/s.n" "$FAKE_AM/silences.json"
SEAT_WINDOW_BY=node-maintenance.sh sw open --reason "nm window" --alerts KubePodNotReady --node n1 --hours 3 >/dev/null
out="$(PATH="$S8/bin:$PATH" NM_AM=http://am.test:9093 bash "$REPO8/scripts/node-maintenance.sh" silence-close n1 2>&1)"; rc=$?
e="$(jq -r '.[] | select(.id == "nm1") | "\(.status.state) \(.endsAt)"' "$FAKE_AM/silences.json")"
[ "$rc" -eq 0 ] && [ "${e%% *}" = active ] && [[ "${e#* }" < "$(iso '+25 minutes')" ]] \
  && ok "node-maintenance silence-close tails its silences (active, ≤20m) instead of expiring them" || bad "nm silence-close rc=$rc: $out / $e"
jq -e '[.[] | select(.createdBy == "node-maintenance.sh/n1#pods-tail" and .status.state == "active")] | length == 1' "$FAKE_AM/silences.json" >/dev/null \
  && ok "…and opens a #pods-tail silence over the node's CURRENT pod names" || bad "no #pods-tail silence: $out"
nmr="$(jq -c '[.data[] | fromjson | select(.by == "node-maintenance.sh" and .node == "n1")] | first' "$FAKE_CM")"
[ -n "$(jq -r '.closed_at // ""' <<<"$nmr")" ] && [[ "$(jq -r .tail_until <<<"$nmr")" > "$(iso '+15 minutes')" ]] \
  && ok "…and its declared record closes with a triage tail" || bad "nm declared record: $nmr"
unset FAKE_CM FAKE_AM

echo
[ "$fails" -eq 0 ] && { echo "self-test: PASS"; exit 0; }
echo "self-test: $fails FAILURE(S)"; exit 1
