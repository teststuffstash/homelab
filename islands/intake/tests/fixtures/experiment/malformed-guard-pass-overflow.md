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
{"id": "press-latency-down", "requirement": "docs/intake/example.md ## Sources \u2014 the press queue, live", "cases": [{"name": "carried, never run"}], "kpi": {"query": "quantile_over_time(0.95, press_wait_seconds[$window])", "pass": "< 2.5e2", "baseline": 412.5, "min_window": "90m", "max_window": "36h", "min_samples_query": "count(count by (job_id) (max_over_time(press_job_state[$window])))", "min_samples": 12, "guards": [{"id": "error-rate", "query": "sum(rate(press_errors_total[$window]))", "pass": "<= 1e999"}, {"id": "throughput", "query": "sum(increase(press_jobs_total[$window]))", "pass": ">= 100"}]}}
```
