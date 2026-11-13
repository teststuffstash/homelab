# homelab `CI` runtime, 2026-10-14 → 2026-11-13 — the baseline read

_Investigation, no decision yet. The weekly [`ci-optimizer`](../../.agents/ci-optimizer.md) series
starts from these numbers: its first run scores against them. The mechanism behind the workflow
(the warm runner image, the `diff-ci` skip map, backgrounded suites) lives in [`../ci.md`](../ci.md)._

**Method.** Population: all 2,511 `CI` runs in the window (`gh run list`). Changed paths: from git
(squash commits and the PR head refs), never per-PR API calls. Ran or skipped: the current
`scripts/diff-ci.sh` MAP replayed against each PR run's paths. This matched the real step outcomes
in 98% of gate×run cells across 185 sampled runs; the misses are rows widened mid-month. Step times:
the jobs API for 185 sampled runs plus 25 green master pushes. Run and job durations: Prometheus
`github_workflow_run_duration_seconds` / `github_ci_job_duration_seconds`; these start 2026-10-31,
because retention is about 18.8 days.

## Population

| | runs | success | exec median / p90 | runner-min / 30 d |
|---|---|---|---|---|
| `pull_request` | 1,724 | 92% | 194 s / 525 s | 7,008 |
| `push` (master) | 778 | 96% | 755 s / 1,177 s | **8,375 (54%)** |

- **Push grew fast.** The weekly median of push exec went from 611 s to 1,198 s. The 7-day median of
  push run wall went 930 → 1,034 → 1,361 s between 11-02 and 11-13. That is twice the 10.9 min that
  set off the 2026-10-09 fix.
- **Push is effectively serial.** The step durations sum to the job duration, and the two
  backgrounded suites finish before their collect steps, so backgrounding saves nothing there.
- About 330 s of each push run's wall falls **outside the `ci` job**. Job queue is 3 s, so runner
  pickup is not the cause. The likely cause is master pushes queueing behind each other in their
  never-cancel concurrency group: push queue median 39 s, p90 527 s. Unverified.
- **Fixed cost every run pays:** about 34 s (set-up, checkout, devbox warm, the diff step). That is
  24% of a median PR run.

## Where the time goes (25 green master pushes, job median 1,239 s)

| stage | median s | share | in-stage lever (est. saving) | measured? |
|---|---|---|---|---|
| `mgmt-policy-test` | 236 | 19% | its 11 fixture scripts are independent but run one after another; run them concurrently. The reconcile test spawns about 22k processes, a `jq` call per field (−125 s) | yes, locally: 157 → 74 s, green |
| `gateway-ci` | 189 (max 1,291) | 15% | each test database is built by committing the schema statement by statement, waiting on fsync each time (165 ms). Copy one prepared template instead (1.9 ms) (−65 s; much more on a disk-stalled node) | yes, locally: 228 → 119 s, 1231/1231 |
| `gateway-specs-site-e2e` | 174 | 14% | about 180 s is pulling the Playwright image into a fresh dind. Start the pull in the background at job start, like the ghcr pre-warm, and reuse the job's earlier site build (−150 s) | no (no docker in the jail) |
| `deep-dig-test` | 148 | 12% | 85% of it is `island-intake-test.sh`. `intake-select.sh` spawns a `jq` per field and a `python3` per issue (793 × 55 ms). One `jq` pass plus one batched parse (−60 to −90 s) | profiled only |
| `responder-behaviour-test` | 58 | 5% | 5.5k `jq` calls; its scenarios are independent and can run in parallel groups (−30 s) | no |
| `maint-self-test` | 45 | 4% | the tests wait out real timeouts (`READY_TIMEOUT=10`) (−12 s) | no |
| `sentinel-smoke` | 34 | 3% | one `yq` call per YAML file; batch them (−8 s) | no |
| gateway evidence + publish | 48 | 4% | the 44 MB Allure report is generated about 4× per run; generate it once (−30 s) | no |
| `clause-replay` (∥) | hidden | — | 304 s locally; the ci.yaml note of 71–79 s is stale. It becomes the **critical path** once the serial chain falls under about 5 min | needs a CI number |

The in-stage levers alone would bring the job to about 800 s. **Runner nodes drive the variance**:
wk-03 917–1,057 s, wk-metal-03 about 1,250 s, nx-01 1,034–2,348 s (the outlier was a disk stall).
The runner pod sets no CPU request or ephemeral-storage request (`argocd/platform/arc-runners.yaml`).
Splitting the job costs about 11 s fixed per extra job plus pickup, but each push then takes several
of the 8 runner slots.

## What could be dropped from a run (runner-min / 30 d)

1. **The full master-push run on a squash merge whose tree a green PR run already tested: up to
   ~7,300.** 540 of the 778 push runs re-tested such a tree. Of that, 1,036 min re-ran gates the PR
   had also run (pure duplicate); 4,919 min ran gates the PR had skipped (the deliberate net, see
   [`../ci.md`](../ci.md)). What the net caught in 30 days: 3 failures from a genuinely too-narrow
   MAP row (#2575, since widened). About 17 more push failures were flakes in gates the commit's paths
   cannot reach (gateway, `publicroute-tf-validate`); the next push went green. The alternatives
   (nightly full run; exempting Renovate squashes, ~3,320 alone) are a **⚖ ruling**, not a lint fix.
2. **`mgmt-policy-test` on push: ~1,900.** It runs serially before the backgrounded suites start, on
   every push. Either path-scope it on push or move it into the background. First confirm it reads
   no live inputs.
3. **The fail-open in `scripts/diff-ci.sh` (the row that runs every gate): ~950.** 33 of the 39 PR
   runs that touched `devbox.json` only added a task script, not a package. Editing `diff-ci.sh`
   itself runs everything (41 runs). A root `devbox.lock` change still runs the gateway rows, though
   the gateway has its own devbox (63 runs).
4. **Bookkeeping-only and docs-only direct pushes: ~630.** A push carries no required check, and
   `githooks/pre-push` already runs the doc lints, so `on.push.paths-ignore` would be safe.
5. **Over-broad `agents/` rows: ~370.** `deep-dig-test` matches all of `agents/`, though it reads only
   the deep-dig and island-intake files. `CLAUSE_PATHS` fires on `.md` edits.

Smaller items: `prometheus-rules-lint` ran on 510 PR runs with no rule-file change, but it is
backgrounded, so the cost was 71 min. `mermaid-lint` ran on Markdown with no diagrams (54 min). The
docs-graph `.` row (18 min). Cancelled superseded PR runs cost 893 min, by design.

## The detector is blind

`GithubCiWallTimeDrift` (`argocd/resources/github-exporter/prometheusrule.yaml`) compares the last
7 days with the 7 days from **21–28 days ago**, and needs 20 or more runs in both windows.
Prometheus holds about 18.8 days: the size cap binds before the 31-day setting. So the baseline
window has been empty since about 10-22. The query succeeds and returns nothing (a 15-day offset
returns 4,713 series), and the alert cannot fire. Prometheus has no firings on record for the whole
retention window. TICK-LOG shows two early firings (10-11, about 10-19), neither attributed. The
1.46× push growth above happened in that blind spot.

`GithubActionsMinutesHigh` counts only billed GitHub-hosted minutes, so it cannot see the
self-hosted `ci` job. No series anywhere carries step-level time, so nothing can say which step
grew. That is why the weekly series reads the jobs API itself.

**Fixed 2026-11-13:** the baseline is now the previous week (`offset 7d`, a 14-day lookback) at
1.25×, sized on the live week-over-week ratios: homelab push held 1.18–1.33 from 11-08 to 11-13,
every other (repo, workflow, event) 0.82–1.16. `GithubCiWallTimeDriftBlind` fires while Prometheus
holds under 15 days, so the lookback cannot go silently blind again.

## What would settle it

- A CI number for `clause-replay` before anyone counts the in-stage savings past about 5 min.
- A ruling on item 1: what the full-push net is for, now that its catch rate is measured.
