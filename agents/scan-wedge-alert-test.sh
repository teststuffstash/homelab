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

  # ══ the KSM-roll rows (homelab#352) — what PR #347's `[5m]` bridge actually buys ═══════════════
  # All three are built on the arm-1 no-marker shape above, because arm 1 is where both bridged
  # KSM conjuncts live. They are ADDITIVE: no assertion above was touched.
  #
  # ⚠ THE HOLE IS WRITTEN `stale`, NOT `_`, AND THAT IS THE WHOLE TEST. A `_` gap is only a missing
  # sample, and an unbridged instant selector still resolves it out of Prometheus' 5m lookback
  # delta — so a `_`-shaped row goes green with the bridge AND without it, pinning nothing. A real
  # KSM roll is not a `_`: Prometheus appends a stale marker for every series of a target whose
  # scrape fails or which goes away, and a stale marker ends the instant selector on the spot while
  # `max_over_time(...[5m])` reads straight past it. `stale` is therefore both the faithful shape
  # and the only shape that can tell the bridged expr from the unbridged one. Verified against
  # promtool 3.13.1: same series, `_` → both forms fire; `stale` → only the bridged form does.
  #
  # Each row was mutation-checked against the shipped expr, so none of them is decorative — they
  # fail on a real regression, not just on a rename:
  #   row 1 ← bridge REMOVED (the pre-#347 identity-only expr): resolves at 22m, row goes red
  #   row 2 ← bridge WIDENED to [10m] (the option the manifest comment rejects): still firing at
  #           26m, row goes red — so this row is what pins the ceiling AT 5m
  #   row 3 ← bridge REMOVED (loses continuity at 22m, row goes red) AND `max by (namespace,pod,uid)`
  #           REMOVED (the alert carries KSM's `instance`, and that label CHANGES across the roll:
  #           gen 1 at 22m, gen 2 at 27m — one wedge re-keyed into a resolve + a fresh fire)

  # ── 1. a KSM hole SHORTER than the bridge: the alert must KEEP firing, `for: 2m` must not reset ──
  # Measured worst raw hole on this cluster is 120s, twice (PR #347, live Prometheus @192.168.40.13;
  # #288 saw 69-116s across 10 pod generations). This row is 180s — 1.5x the measured worst and
  # still well inside the 5m bridge, so it pins headroom rather than just the observed case.
  # Unbridged, the alert would resolve at 20m and not re-fire until 25m; bridged it never drops.
  - interval: 1m
    name: KSM hole shorter than the bridge keeps the alert firing
    input_series:
      - series: 'kube_pod_start_time{namespace="agent-coordinator",pod="coordinate-perstack-r8k4n",uid="u5"}'
        values: "0+0x19 stale _ _ 0+0x17"
      - series: 'kube_pod_status_phase{namespace="agent-coordinator",pod="coordinate-perstack-r8k4n",uid="u5",phase="Running"}'
        values: "1+0x19 stale _ _ 1+0x17"
    alert_rule_test:
      # baseline: already firing before the hole opens (pod age >15m since 16m, `for: 2m` since 18m).
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-r8k4n
              uid: u5
      # mid-hole, 3m after the last KSM sample. Unbridged this is RESOLVED. This is PR #347's claim.
      - eval_time: 22m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-r8k4n
              uid: u5
      # KSM back since 23m. Unbridged the `for` window would still be PENDING here (re-armed 23m,
      # fires 25m) — so a firing alert at 24m is the proof the window never reset.
      - eval_time: 24m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-r8k4n
              uid: u5

  # ── 2. a KSM hole LONGER than the bridge: the ceiling, ACCEPTED and asserted, not a bug ──────────
  # 8m absent (crash-loop, cold image pull, node drain). Past 5m the bridge is exhausted, the expr
  # goes empty, and the 2m window does reset. Asserted explicitly — the same ceiling #310 and #328
  # carry, and the one PR #347's body promised for this alert. The cost is bounded: one `for`
  # window, not the alert. Written to MEET the reset, not to dodge it.
  - interval: 1m
    name: KSM hole longer than the bridge resets the window (the accepted ceiling)
    input_series:
      - series: 'kube_pod_start_time{namespace="agent-coordinator",pod="coordinate-perstack-t2w7j",uid="u6"}'
        values: "0+0x19 stale _ _ _ _ _ _ _ 0+0x12"
      - series: 'kube_pod_status_phase{namespace="agent-coordinator",pod="coordinate-perstack-t2w7j",uid="u6",phase="Running"}'
        values: "1+0x19 stale _ _ _ _ _ _ _ 1+0x12"
    alert_rule_test:
      # baseline: firing before the hole, exactly as row 1.
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-t2w7j
              uid: u6
      # 7m past the last KSM sample: beyond [5m], expr empty, alert RESOLVED. THE CEILING.
      - eval_time: 26m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
      # KSM back since 28m and the wedge never ended — still silent at 29m, because the window
      # genuinely reset and is only pending. This is what makes the ceiling a reset, not a blip.
      - eval_time: 29m
        alertname: AgentCoordinateScanWedged
        exp_alerts: []
      # re-arms 2m after recovery and fires again: the ceiling costs one `for` window, not the alert.
      - eval_time: 30m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-t2w7j
              uid: u6

  # ── 3. KSM moves instance mid-firing: ONE alert, not two ────────────────────────────────────────
  # A KSM pod roll changes `instance` on every series it exports, and both generations sit inside
  # the 5m bridge at once during the overlap. Without the aggregation that `instance` lands in the
  # ALERT's label set, so the roll RE-KEYS a firing alert mid-wedge — Alertmanager sees the first
  # identity resolve and a second one fire, two notifications for one unbroken wedge. This is what
  # `max by (namespace,pod,uid)` buys: the alert is keyed to the SUBJECT pod and nothing else.
  # `uid` is deliberately that pod's, not KSM's, so it does not churn when KSM moves — u7 at every
  # eval below, and the fired alert carries no `instance` at all.
  # promtool compares the alert set exhaustively, so a single exp_alerts entry with no `instance`
  # is the assertion: one identity, unchanged, across the roll.
  - interval: 1m
    name: KSM instance change mid-firing still resolves to one alert
    input_series:
      # KSM generation 1 — goes away at 20m.
      - series: 'kube_pod_start_time{namespace="agent-coordinator",pod="coordinate-perstack-m5q9d",uid="u7",instance="192.168.32.11:8080"}'
        values: "0+0x19 stale"
      - series: 'kube_pod_status_phase{namespace="agent-coordinator",pod="coordinate-perstack-m5q9d",uid="u7",phase="Running",instance="192.168.32.11:8080"}'
        values: "1+0x19 stale"
      # KSM generation 2 — same subject pod, same uid, new instance, first scrape at 21m.
      - series: 'kube_pod_start_time{namespace="agent-coordinator",pod="coordinate-perstack-m5q9d",uid="u7",instance="192.168.32.12:8080"}'
        values: "_x21 0+0x19"
      - series: 'kube_pod_status_phase{namespace="agent-coordinator",pod="coordinate-perstack-m5q9d",uid="u7",phase="Running",instance="192.168.32.12:8080"}'
        values: "_x21 1+0x19"
    alert_rule_test:
      # baseline: one alert, one KSM generation.
      - eval_time: 19m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-m5q9d
              uid: u7
      # mid-roll: BOTH generations are inside the [5m] bridge. Still exactly one alert, no
      # `instance` label, and still firing — the roll neither doubled it nor reset the window.
      - eval_time: 22m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-m5q9d
              uid: u7
      # generation 1 has aged out of the bridge; one alert, unbroken, same uid.
      - eval_time: 27m
        alertname: AgentCoordinateScanWedged
        exp_alerts:
          - exp_labels:
              severity: warning
              namespace: agent-coordinator
              pod: coordinate-perstack-m5q9d
              uid: u7
YAML

if out="$(cd "$TMP" && promtool test rules scan-wedge.test.yaml 2>&1)"; then
  ok "promtool test rules: 7 replays green (healthy ride silent ×2, no-marker wedge fires, post-dispatch wedge fires on phase time, stale marker silent, KSM hole under the bridge keeps firing, KSM hole over the bridge resets — the accepted ceiling, KSM instance roll stays one alert)"
else
  bad "promtool test rules FAILED — the alert's firing behaviour moved" "$out"
fi

printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
