#!/usr/bin/env python3
"""Generate loop-health-ci-drift.promtool-test for the week-over-week GithubCiWallTimeDrift.

Simulates the alert's expr (per-run series, max_over_time collapse, per-id dedupe, Prometheus
quantile interpolation, left-open windows, for: 6h at a 1h cadence) to derive every expectation,
then emits the YAML. A change to the alert's expr or thresholds changes the constants here first.
Run from the repo root:
  python3 argocd/resources/github-exporter/loop-health-ci-drift.promtool-gen.py \
    > argocd/resources/github-exporter/loop-health-ci-drift.promtool-test
"""
import sys

WEEK = 168
RATIO, FLOOR, MIN_RUNS, FOR_H = 1.25, 120, 20, 6
OFFSET = WEEK  # offset 7d


def h(i):  # run i starts at hour 8i + 1, three hourly samples h, h+1, h+2
    return 8 * i + 1


def in_window(i, end):  # (end − 7d, end]: any sample inside
    return h(i) + 2 > end - WEEK and h(i) <= end


def quantile(q, vals):
    v = sorted(vals)
    if not v:
        return None
    rank = q * (len(v) - 1)
    lo = int(rank)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (rank - lo)


def window(runs, end):
    """runs: {id: (i, value)} for success runs → per-id values in the window."""
    return [val for (i, val) in runs.values() if in_window(i, end)]


def condition(runs, t):
    cur, base = window(runs, t), window(runs, t - OFFSET)
    if len(cur) < MIN_RUNS or len(base) < MIN_RUNS:
        return False, None
    mc, mb = quantile(0.5, cur), quantile(0.5, base)
    return (mc > RATIO * mb and mc > FLOOR), mc


def first_fire(runs, t_max):
    streak = 0
    for t in range(0, t_max + 1):
        ok, _ = condition(runs, t)
        streak = streak + 1 if ok else 0
        if streak == FOR_H + 1:  # pending at t−6, firing at t
            return t - FOR_H, t
    return None, None


def humanize(sec):
    sec = round(sec)
    m, s = divmod(sec, 60)
    return f"{m}m {s}s" if m else f"{s}s"


def series(labels, i, val):
    return (f"      - series: 'github_workflow_run_duration_seconds{{{labels}}}'\n"
            f"        values: \"_x{h(i)} {val:g}x2\"\n")


def lab(wf, rid, extra="", concl="success"):
    return (f'{extra}repo="homelab",workflow="{wf}",event="push",id="{rid}",'
            f'status="completed",conclusion="{concl}"')


DESC = ("The median successful ci run on homelab (push events) took {d} over the last 7 days — "
        "more than 1.25× the median of the 7 days before that (both windows ≥20 runs; floor 2m). "
        "Slow creep, not an outage: the 2026-08/10 homelab `ci` creep (1.7 → 4.8 min PR median) went "
        "unseen for six weeks. Find which job grew: github_ci_job_duration_seconds{{repo=\\\"homelab\\\","
        "workflow=\\\"ci\\\"}} week over week, then the workflow/script history for what joined that job. "
        "Baseline: quantile by (repo, workflow, event) (0.5, max by (repo, workflow, event, id) "
        "(max_over_time(github_workflow_run_duration_seconds{{repo=\\\"homelab\\\",workflow=\\\"ci\\\","
        "event=\\\"push\\\",status=\\\"completed\\\",conclusion=\\\"success\\\"}}[7d] offset 7d))).")


def firing(t, value):
    return (f"      - eval_time: {t}h\n        alertname: GithubCiWallTimeDrift\n        exp_alerts:\n"
            "          - exp_labels:\n              severity: warning\n              platform_machinery: \"true\"\n"
            "              triage: dig\n              repo: homelab\n              workflow: ci\n              event: push\n"
            "            exp_annotations:\n              summary: \"CI wall time drifting up: homelab ci (push)\"\n"
            f"              description: \"{DESC.format(d=humanize(value))}\"\n")


def silent(t, name="GithubCiWallTimeDrift"):
    return f"      - eval_time: {t}h\n        alertname: {name}\n        exp_alerts: []\n"


out = []
W = out.append
W("""# Behaviour fixture for GithubCiWallTimeDrift + GithubCiWallTimeDriftBlind (prometheusrule.yaml,
# group github-ci-drift — the group comment there is the alerts' one home for WHY; this file pins
# WHAT they do). GENERATED: every expectation is derived by a simulator of the expr; regenerate
# rather than hand-edit (loop-health-ci-drift.promtool-gen.py beside this file).
#
#   devbox run -- promtool test rules argocd/resources/github-exporter/loop-health-ci-drift.promtool-test
#
# evaluation_interval 1h = the production group's `interval: 1h`, so the `for: 6h` edge below is
# pinned at the cadence it really runs at.
#
# INPUT SCHEME (every series below follows it — check any expectation against it):
#   run i starts at hour h(i) = 8i + 1 and its series carries 3 hourly samples (h, h+1, h+2);
#   max_over_time collapses each series to one value. One series per run id, labels trimmed to
#   the ones the expr reads (+ pod where the dedupe is the point). 21 runs per 168h week.
#   A window "(T−7d, T]" contains run i iff h(i)+2 > T−168 and h(i) ≤ T (ranges are left-open);
#   the baseline is the same window ending T−168h (`offset 7d`).
rule_files:
  - loop-health-ci-drift.promtool-rules

evaluation_interval: 1h

tests:
""")

# ── 1: creep. weeks 0,1 = 200; week 2 = 240 (1.2× — silent on the ratio); week 3 = 320 (1.33×).
wk = [200, 200, 240, 320, 320]
runs = {}
for i in range(0, 21 * len(wk)):
    runs[str(10000 + i)] = (i, wk[min(h(i) // WEEK, len(wk) - 1)])
T_END = 21 * len(wk) * 8
pend, fire = first_fire(runs, T_END)
assert fire is not None
ok_wk2, _ = condition(runs, 3 * WEEK)  # end of week 2: week 2 vs week 1 = 1.2×
assert not ok_wk2
_, v_fire = condition(runs, fire)
_, v_late = condition(runs, 4 * WEEK)
assert condition(runs, 4 * WEEK)[0]
W(f"""  # ── 1 — A WEEK-OVER-WEEK CREEP: weekly medians 200 → 200 → 240 → 320 → 320 s ──────────────
  #  • {3 * WEEK}h: week 2 (240) vs week 1 (200) = 1.2× < 1.25 — silent on the RATIO.
  #  • {pend}h: the condition first holds (week 3's 320 s runs outweigh 240 in the current median).
  #  • {fire - 1}h: pending 5h < for: 6h → not yet. {fire}h: firing at {humanize(v_fire)}.
  #  • {4 * WEEK}h: week 3 (320) vs week 2 (240) = 1.33× → still firing at {humanize(v_late)}.
  - interval: 1h
    name: "a week-over-week creep fires once it passes 1.25x, after for: 6h; a 1.2x week stays silent"
    input_series:
""")
for rid, (i, val) in runs.items():
    W(series(lab("ci", rid), i, val))
W("    alert_rule_test:\n")
W(silent(3 * WEEK))
W(silent(fire - 1))
W(firing(fire, v_fire))
W(firing(4 * WEEK, v_late))

# ── 2: silent shapes at T = 3 weeks: baseline (168,336], current (336,504]
T = 3 * WEEK
idx = [i for i in range(0, 64) if in_window(i, T) or in_window(i, T - OFFSET)]
shapes = {}
flat = {str(20000 + i): (i, 95 if i % 2 == 0 else 105) for i in idx}
storm = {str(21000 + i): (i, 3000) for i in idx if in_window(i, T)}
outl = {str(30000 + i): (i, 100) for i in idx}
cur_idx = [i for i in idx if in_window(i, T)]
spike_i = cur_idx[len(cur_idx) // 2]
outl[str(30000 + spike_i)] = (spike_i, 2000)
mild = {str(40000 + i): (i, 240 if in_window(i, T) else 200) for i in idx}
tiny = {str(50000 + i): (i, 100 if in_window(i, T) else 40) for i in idx}
few_idx = [i for i in idx if in_window(i, T)][-10:] + [i for i in idx if in_window(i, T - OFFSET) and not in_window(i, T)][-10:]
few = {str(60000 + i): (i, 290 if in_window(i, T) else 100) for i in few_idx}
for name, r in [("flat", flat), ("outlier", outl), ("mild", mild), ("tiny", tiny), ("few", few)]:
    assert not condition(r, T)[0], name
med = lambda r, end: quantile(0.5, window(r, end))
flat_cur, flat_base = med(flat, T), med(flat, T - OFFSET)
both = dict(flat); both.update(storm)
storm_med = quantile(0.5, window(both, T))
assert storm_med > RATIO * flat_base  # without the conclusion filter it would fire
outl_mean = sum(window(outl, T)) / len(window(outl, T))
assert outl_mean > RATIO * med(outl, T - OFFSET)
W(f"""
  # ── 2 — THE SILENT SHAPES at {T}h, each beside the contrast that proves its guard holds it ─────
  #  • flat: 95/105 alternating → medians {flat_base:g} → {flat_cur:g}. PLUS {len(storm)} FAILED runs at 3000 s in the
  #    current window: without the conclusion filter the current median is {storm_med:g} — it would fire.
  #  • outlier: 100 s everywhere except one 2000 s run → median 100; the MEAN would be {outl_mean:.6g}.
  #  • mild: 200 → 240 s = 1.2× < 1.25 — silent on the ratio.
  #  • tiny: 40 → 100 s = 2.5× but 100 < the 120 s floor — silent on the floor.
  #  • few: 100 → 290 s (2.9×) but 10 runs per window, each scraped by TWO exporter pods: 20 SERIES,
  #    10 RUNS. A count over series would pass the guard; the per-id count is 10 — silent.
  - interval: 1h
    name: "flat, failed-run storm, single outlier, 1.2x, under-floor and 10-run shapes stay silent"
    input_series:
""")
for rid, (i, val) in flat.items():
    W(series(lab("flat", rid), i, val))
for rid, (i, val) in storm.items():
    W(series(lab("flat", rid, concl="failure"), i, val))
for wf, r in [("outlier", outl), ("mild", mild), ("tiny", tiny)]:
    for rid, (i, val) in r.items():
        W(series(lab(wf, rid), i, val))
for rid, (i, val) in few.items():
    for pod in ("github-exporter-5c6d9f4f76-kcmdn", "github-exporter-6d7e8a9b1c-p7t2r"):
        W(series(lab("few", rid, extra=f'pod="{pod}",'), i, val))
W("    alert_rule_test:\n")
W(silent(T))
Q = 'quantile by (workflow) (0.5, max by (workflow, id) (max_over_time(github_workflow_run_duration_seconds{{workflow="{w}", status="completed"{c}}}[7d]{o})))'
S = ', conclusion="success"'
def pq(expr, wf, val):
    return f"      - expr: {expr}\n        eval_time: {T}h\n        exp_samples:\n          - labels: '{{workflow=\"{wf}\"}}'\n            value: {val:.17g}\n"
W("    promql_expr_test:\n")
W("      # flat: the medians the alert compares, then the failed-run storm without the conclusion filter\n")
W(pq(Q.format(w="flat", c=S, o=""), "flat", flat_cur))
W(pq(Q.format(w="flat", c=S, o=" offset 7d"), "flat", flat_base))
W(pq(Q.format(w="flat", c="", o=""), "flat", storm_med))
W("      # outlier: the median holds at 100; the mean would not\n")
W(pq(Q.format(w="outlier", c=S, o=""), "outlier", med(outl, T)))
W(pq(f'avg by (workflow) (max by (workflow, id) (max_over_time(github_workflow_run_duration_seconds{{workflow="outlier", status="completed"{S}}}[7d])))', "outlier", outl_mean))
W("      # mild: the ratio is under 1.25\n")
W(pq(Q.format(w="mild", c=S, o="") + " / " + Q.format(w="mild", c=S, o=" offset 7d"), "mild", med(mild, T) / med(mild, T - OFFSET)))
W("      # tiny: the ratio WOULD trip — only the floor holds it\n")
W(pq(Q.format(w="tiny", c=S, o="") + " / " + Q.format(w="tiny", c=S, o=" offset 7d"), "tiny", med(tiny, T) / med(tiny, T - OFFSET)))
W("      # few: 20 series, 10 runs — the guard counts runs\n")
W(pq(f'count by (workflow) (max_over_time(github_workflow_run_duration_seconds{{workflow="few", status="completed"{S}}}[7d]))', "few", 20))
W(pq(f'count by (workflow) (max by (workflow, id) (max_over_time(github_workflow_run_duration_seconds{{workflow="few", status="completed"{S}}}[7d])))', "few", 10))
W(pq(Q.format(w="few", c=S, o="") + " / " + Q.format(w="few", c=S, o=" offset 7d"), "few", med(few, T) / med(few, T - OFFSET)))

# ── 3: the blind belt. Oldest sample at t=0 → history = T. Fires under 15 days, after for: 6h.
W("""
  # ── 3 — THE BLIND BELT: Prometheus's oldest sample is at t=0, so the history held = the eval time.
  #  • 5h: under 15 days but for: 6h not yet met → silent. 6h: firing (history 6h).
  #  • 359h (14d 23h): still under 15 days → firing. 366h: 15d 6h of history → silent.
  - interval: 1h
    name: "the blind belt fires while Prometheus holds under 15 days of history"
    input_series:
      - series: 'prometheus_tsdb_lowest_timestamp_seconds{pod="prometheus-kube-prometheus-stack-prometheus-0"}'
        values: "0x400"
    alert_rule_test:
""")
def blind(t):
    return (f"      - eval_time: {t}h\n        alertname: GithubCiWallTimeDriftBlind\n        exp_alerts:\n"
            "          - exp_labels:\n              severity: warning\n              platform_machinery: \"true\"\n              triage: dig\n"
            "            exp_annotations:\n"
            f"              summary: \"Prometheus holds {humanize_long(t * 3600)} of history — GithubCiWallTimeDrift's 14-day lookback is blind\"\n"
            f"              description: \"The oldest sample Prometheus holds is {humanize_long(t * 3600)} old. GithubCiWallTimeDrift compares the last 7 days against the 7 days before them, so under 14 days of history its baseline reads nothing and it can never fire. Grow `retentionSize` (argocd/platform/values/kube-prometheus-stack.yaml) or cut series count; shortening the alert's windows is the last resort. Check: (time() - min(prometheus_tsdb_lowest_timestamp_seconds)) / 86400.\"\n")
def humanize_long(sec):  # Prometheus humanizeDuration for whole hours
    d, rem = divmod(int(sec), 86400); hh, rem = divmod(rem, 3600); mm, ss = divmod(rem, 60)
    units = [(d, "d"), (hh, "h"), (mm, "m"), (ss, "s")]
    while len(units) > 1 and units[0][0] == 0:
        units.pop(0)  # humanizeDuration prints from the first non-zero unit down to seconds
    return " ".join(f"{v}{u}" for v, u in units)
W(silent(5, "GithubCiWallTimeDriftBlind"))
W(blind(6))
W(blind(359))
W(silent(366, "GithubCiWallTimeDriftBlind"))
sys.stdout.write("".join(out))
