## Deliverable
Fewer errors.

## Experiment

No error is counted over the window, while at least 5 series were sampled — series `errors_total`; baseline 3 over the 10 d before.

```experiment
{"id": "no-errors", "requirement": "docs/intake/example.md ## Sources", "cases": [], "kpi": {"query": "sum(increase(errors_total[$window]))", "pass": "<= 0", "baseline": 3, "min_window": "1h", "max_window": "7d", "min_samples_query": "count(count_over_time(samples_total[$window]))", "min_samples": 5}}
```
