## Deliverable
The press never jams.

## Experiment

No press jam in the seven days after the merge, while at least 20 jobs ran and the exporter was scraped — series `fx_value`; baseline: 4 over the 10 d before. A "stays at zero" claim: min_window is the whole window.

```experiment
{"id": "press-never-jams", "requirement": "docs/intake/example.md ## Sources — the press queue, live", "cases": [], "kpi": {"query": "(count(fx_value[$window:1m]) or vector(0)) and on() (avg_over_time(fx_up[$window]) > 0.95)", "pass": "<= 0", "baseline": 4, "min_window": "7d", "max_window": "7d", "min_samples_query": "count(count_over_time(fx_samples[$window]))", "min_samples": 20}}
```
