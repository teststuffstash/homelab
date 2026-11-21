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
{"id": "edge ]]]] [[[[ \\\" {{{{ of the format", "requirement": "a lone surrogate \ud800 is carried", "cases": [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]], "kpi": {"query": "(count(count_over_time((press_job_state{state=\"waiting\"} == 1)[$window:1m]) > 10) or vector(0)) and on() (min(avg_over_time(up{job=\"press-exporter\"}[$window])) > 0.95)", "pass": "> -.5e-3", "baseline": 100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000, "min_window": "1m", "max_window": "168h", "min_samples_query": "count(count by (job_id) (max_over_time(press_job_state[$window])))", "min_samples": 12}}
```
