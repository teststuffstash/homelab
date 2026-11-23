---
Touches: widgets/press.yaml
Origin: example/repo#1
Class: fix

---
## Deliverable
The press queue holds eight jobs instead of four.

## Experiment

At most three press jobs wait more than ten minutes once twenty jobs ran after the merge, while the press exporter was scraped for over 95 % of the window and no job errored — series `fx_value`; baseline: 5 over the 10 d before.

```experiment
{"id": "press-waits-down", "requirement": "docs/intake/example.md ## Sources — the press queue, live", "cases": [], "kpi": {"query": "max_over_time(fx_value[$window]) and on() (avg_over_time(fx_up[$window]) > 0.95)", "pass": "<= 3", "baseline": 5, "min_window": "1h", "max_window": "7d", "min_samples_query": "count(count_over_time(fx_samples[$window]))", "min_samples": 20, "guards": [{"id": "errors", "query": "sum(increase(fx_errors[$window]))", "pass": "< 1"}]}}
```
