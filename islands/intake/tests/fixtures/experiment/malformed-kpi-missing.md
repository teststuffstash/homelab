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
{"id": "press-jobs-not-waiting", "requirement": "docs/intake/example.md ## Sources \u2014 the press queue, live", "cases": []}
```
