#!/usr/bin/env bash
# scan-wedge-alert-test — the BEHAVIOUR pin for `AgentCoordinateScanWedged` (FU-145, homelab#283).
#
#   bash agents/scan-wedge-alert-test.sh      (also runs under `devbox run clause-replay`,
#                                              registered as agents/replay/fixtures/scan-wedge-alert)
#
# WHY THIS EXISTS. The alert used to key on POD LIFETIME and fired on any healthy ride >15m — the
# scan pod blocks streaming the session it dispatched (docs/agents/observability-and-retro.md
# §Part A″). It is now keyed on the scan PHASE, and the whole value of that re-key is a claim about
# firing behaviour: "a healthy >15m ride cannot raise it, a wedged deterministic phase still does".
# Prose cannot hold that. `devbox run prometheus-rules-lint` proves the expr PARSES (FU-158's check
# half); this replays it against series, which is FU-158's remaining leg applied to one rule.
#
# THE EXPR IS READ OUT OF THE SHIPPED MANIFEST, never transcribed — the same rule the spend-probe
# self-test follows (homelab#217/#220): a transcribed expr goes green while the deployed one drifts.
# Annotations are stripped from the extracted copy on purpose: this pins the FIRING behaviour, not
# the prose (the prose is a runbook and changes on its own schedule).
#
# The series are the 2026-08-06 ledger's own shape — pod up 18m32s, the deterministic pass handing
# off to an item session at ~3m — plus the two wedge shapes the alert must still catch.
set -uo pipefail
cd "$(dirname "$0")/.."

RULE_FILE="argocd/resources/pushgateway/prometheusrule.yaml"
SCAN_FILE="agents/coordinator-scan.sh"
ALERT="AgentCoordinateScanWedged"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

for t in yq jq promtool; do
  command -v "$t" >/dev/null 2>&1 || { echo "scan-wedge-alert-test: needs $t (run under devbox)" >&2; exit 2; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ── 1. extract the shipped rule ────────────────────────────────────────────────────────────────
yq eval-all -o=json 'select(.kind=="PrometheusRule") | .spec.groups' "$RULE_FILE" \
  | jq -s --arg a "$ALERT" '{groups: [{name: "scan-wedge-replay",
        rules: [ .[] | select(type=="array") | .[].rules[]? | select(.alert == $a) | del(.annotations) ]}]}' \
  > "$TMP/rules.json"
nrules="$(jq '.groups[0].rules | length' "$TMP/rules.json")"
if [ "$nrules" = "1" ]; then
  ok "extracted 1 ${ALERT} rule out of ${RULE_FILE}"
else
  bad "expected exactly 1 ${ALERT} rule in ${RULE_FILE}, extracted ${nrules}" \
      "The alert was renamed, removed or duplicated — this replay is pinning nothing."
  printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1
fi
cp "$TMP/rules.json" "$TMP/rules.yaml"   # JSON is valid YAML; promtool reads either

# ── 2. drift pin: the metrics the alert reads are the metrics the scan pushes ───────────────────
expr_txt="$(jq -r '.groups[0].rules[0].expr' "$TMP/rules.json")"
for m in agent_scan_phase_start_timestamp agent_scan_in_deterministic; do
  if printf '%s' "$expr_txt" | grep -q "$m" && grep -q "$m" "$SCAN_FILE"; then
    ok "metric ${m} is both pushed by ${SCAN_FILE} and read by the alert"
  else
    bad "metric ${m} is missing on one side (scan pushes / alert reads)" \
        "A rename on one side only leaves the alert permanently silent — the FU-145 failure class."
  fi
done

# ── 3. the behaviour replay ────────────────────────────────────────────────────────────────────
# promtool's clock starts at epoch 0, so a pod that started at t=0 has `kube_pod_start_time 0` and
# `time()` at eval_time IS its age. Marker values are the epoch of the phase transition.
cat > "$TMP/scan-wedge.test.yaml" <<'YAML'
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  # ── the 2026-08-06 shape: pod alive 18m+, deterministic pass handed off at 3m, ride healthy ──
  - interval: 1m
    name: healthy long ride cannot fire the alert
    input_series:
      - series: 'kube_pod_start_time{namespace="circles-agents",pod="coordinate-circles-1",uid="u1"}'
        values: "0+0x40"
      - series: 'kube_pod_status_phase{namespace="circles-agents",pod="coordinate-circles-1",uid="u1",phase="Running"}'
        values: "1+0x40"
      - series: 'agent_scan_phase_start_timestamp{job="agent_scan_phase",namespace="circles-agents",pod="coordinate-circles-1"}'
        values: "_ _ _ 180+0x37"
      - series: 'agent_scan_in_deterministic{job="agent_scan_phase",namespace="circles-agents",pod="coordinate-circles-1"}'
        values: "_ _ _ 0+0x37"
    alert_rule_test:
      # 19m of pod lifetime — the OLD rule fired here (and did, twice, on 2026-08-06).
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
      # 31m: past the workflow's own 1800s deadline. Still silent — streaming a ride is WORK.
      - eval_time: 31m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []

  # ── the 2026-08-05 shape (homelab#103): wedged before the first dispatch, nothing ever pushed ──
  - interval: 1m
    name: wedged deterministic phase with no marker still fires
    input_series:
      - series: 'kube_pod_start_time{namespace="agent-coordinator",pod="coordinate-perstack-lvsmt",uid="u2"}'
        values: "0+0x40"
      - series: 'kube_pod_status_phase{namespace="agent-coordinator",pod="coordinate-perstack-lvsmt",uid="u2",phase="Running"}'
        values: "1+0x40"
    alert_rule_test:
      # inside the measured tail (p99 302s, max 1458s) — no alert yet.
      - eval_time: 5m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-lvsmt
              uid: u2

  # ── wedged in the deterministic pass AFTER a dispatch came back: the clock restarts at the phase ──
  - interval: 1m
    name: wedge after a dispatch returns fires on phase time, not pod time
    input_series:
      - series: 'kube_pod_start_time{namespace="oracle-agents",pod="coordinate-oracle-2",uid="u3"}'
        values: "0+0x60"
      - series: 'kube_pod_status_phase{namespace="oracle-agents",pod="coordinate-oracle-2",uid="u3",phase="Running"}'
        values: "1+0x60"
      # dispatch at 2m, back in the deterministic pass at 10m — and stuck there.
      - series: 'agent_scan_phase_start_timestamp{job="agent_scan_phase",namespace="oracle-agents",pod="coordinate-oracle-2"}'
        values: "_ _ 120+0x8 600+0x50"
      - series: 'agent_scan_in_deterministic{job="agent_scan_phase",namespace="oracle-agents",pod="coordinate-oracle-2"}'
        values: "_ _ 0+0x8 1+0x50"
    alert_rule_test:
      # pod age 19m, deterministic phase only 9m — silent. This is the whole re-key in one row.
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
      # phase age 18m — fires, and carries the pushgateway series' labels.
      - eval_time: 28m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              job: agent_scan_phase
              namespace: oracle-agents
              pod: coordinate-oracle-2

  # ── a marker outliving its pod must not fire: every branch is gated on the pod being Running ──
  - interval: 1m
    name: stale marker for a finished pod stays silent
    input_series:
      - series: 'kube_pod_start_time{namespace="sleep-agents",pod="coordinate-sleep-3",uid="u4"}'
        values: "0+0x40"
      - series: 'kube_pod_status_phase{namespace="sleep-agents",pod="coordinate-sleep-3",uid="u4",phase="Running"}'
        values: "1+0x5 0+0x34"
      - series: 'agent_scan_phase_start_timestamp{job="agent_scan_phase",namespace="sleep-agents",pod="coordinate-sleep-3"}'
        values: "_ 60+0x38"
      - series: 'agent_scan_in_deterministic{job="agent_scan_phase",namespace="sleep-agents",pod="coordinate-sleep-3"}'
        values: "_ 1+0x38"
    alert_rule_test:
      - eval_time: 30m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
YAML

if out="$(cd "$TMP" && promtool test rules scan-wedge.test.yaml 2>&1)"; then
  ok "promtool test rules: 4 replays green (healthy ride silent ×2, no-marker wedge fires, post-dispatch wedge fires on phase time, stale marker silent)"
else
  bad "promtool test rules FAILED — the alert's firing behaviour moved" "$out"
fi

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
