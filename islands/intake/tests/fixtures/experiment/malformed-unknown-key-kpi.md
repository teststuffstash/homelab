---
Touches: widgets/press.yaml
Origin: example/repo#1
Class: fix

---
## Deliverable
The press queue holds eight jobs instead of four.

## Out of scope
- The janitor.

## Experiment

No press job waits more than ten minutes in the seven days after the merge, while at least 12 jobs ran and the press exporter was scraped for over 95 % of the window — series `press_job_state`; baseline: 4 such jobs over the 10 d before.

```experiment
{"id": "press-jobs-not-waiting", "requirement": "docs/intake/example.md ## Sources \u2014 the press queue, live", "cases": [], "kpi": {"query": "(count(count_over_time((press_job_state{state=\"waiting\"} == 1)[$window:1m]) > 10) or vector(0)) and on() (min(avg_over_time(up{job=\"press-exporter\"}[$window])) > 0.95)", "pass": "<= 0", "baseline": 4, "min_window": "7d", "max_window": "7d", "min_samples_query": "count(count by (job_id) (max_over_time(press_job_state[$window])))", "min_samples": 12, "control": "up == 1"}}
```
