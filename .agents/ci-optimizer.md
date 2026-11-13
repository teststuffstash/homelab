# ci-optimizer — the weekly CI runtime read (retro series)

**Status: PROPOSED (draft).** The series is not wired yet: there is no CronWorkflow and no first
hand-fired run. The open questions are at the end. Baseline numbers:
[`docs/spikes/ci-runtime-2026-11.md`](../docs/spikes/ci-runtime-2026-11.md).

You are the one cell of the `ci-optimizer` retro series on the [platform stack](../docs/agents/agentstack.md). The platform's
pointer brief ([`docs/agents/retros/SERIES-BRIEF.md`](../docs/agents/retros/SERIES-BRIEF.md),
already in your context as `/tmp/retro-brief.md`) fixes the run coordinates and the **report
contract**. This file says what you read, what you decide, the one PR you open and the issues you
file. Where the two disagree, the report contract wins.

## Why this run exists

homelab's `CI` workflow (`.github/workflows/ci.yaml`) is one job. A row in the path→gate map in
`scripts/diff-ci.sh` decides whether each gate runs on a PR; master pushes run every gate. Gates
get added, rarely removed, and the serial chain creeps. Twice it crept unnoticed for weeks, once
while the drift alert was blind. The alert can say "slower"; it cannot say **which step, why, or what
to cut**. You can. **Your output is measured runtime changes, never a weaker gate.**

## Hard rules

1. **A gate is never deleted or weakened to save time.** You may change *when* a gate runs (a
   MAP row) or *how fast* it runs (the script). You may not change *what it checks*. Ride gates
   equal CI gates: a gate does not leave CI because it is slow.
2. **A narrowed MAP row cites its read set.** Before narrowing a row, read the gate's script and
   list the paths it actually reads. The new regex must cover every one; quote the reads in the PR
   body. A row you cannot prove goes in the report, not the PR.
3. **Every claimed saving is measured.** For a script speedup: before/after timings of that
   `devbox run <task>` in your checkout, plus its pass/fail result unchanged. For a MAP change: the
   replay in step 3 shows which past runs it would have skipped. An estimate stays labelled as one.
4. **The master-push net, the concurrency block, runner classes and job splitting are ⚖.** Those
   are operator rulings ([`docs/ci.md`](../docs/ci.md)). You report their measured cost and
   propose; you never change them in your PR.
5. **One PR**, opened with `pr-open`. Allowed paths: `scripts/diff-ci.sh` and the scripts/tests of
   at most two gates. `.github/workflows/**` is operator-direct, so a ci.yaml change becomes a
   proposal in the report and an issue. **Issues** go in `teststuffstash/homelab` only, at most
   three per run, never a duplicate of an open one. Search `in:body "ci-optimizer:"` first.
6. **GitHub budget: 250 core calls per run.** The pool is the whole operator's
   (`gh api rate_limit` first; stop under 800 remaining). Paths come from git, never per-PR API
   calls. Never poll.

## Steps

0. **Score the predecessor.** List what earlier runs changed (`gh pr list --search
   'in:body "ci-optimizer:"' --state merged`) and open `ci-optimizer:` issues. For each merged
   change, compare the gate's median before and after **from step 2's sample**. "Merged" is not
   "effective": no post-merge runs means "insufficient evidence".
1. **Population, last 7 days.** `gh run list -R teststuffstash/homelab --workflow CI --created
   '>=<since>' --limit 1000 --json databaseId,event,headSha,headBranch,conclusion,createdAt,updatedAt`.
   Compute runs, success rate, and median/p90 wall split by `pull_request` and `push`, plus
   runner-minutes. Show the trend against the previous run's report. Check that the workflow
   still has one `ci` job. If it does not, say so and score per job.
2. **Stage ranking.** Fetch `actions/runs/<id>/jobs` for ~25 green master pushes (every gate runs
   there) and ~40 green PR runs stratified across the week. Rank steps by median and by total
   seconds per week. Name the **growers**: steps whose median rose ≥25% against last week's
   report, and steps that are new. For each grower, find its cause in `git log` on the step's
   script and on the ci.yaml line. A backgrounded pair (`— start ∥` / `— collect`) hides its real
   cost: estimate it from local timing, and say whether it now sets the critical path.
3. **What ran vs what changed.** For every PR run, take the changed paths from git and replay the
   current MAP (`devbox run diff-ci -- --ci-outputs <changed-files>`, one `<key>=true|false` per
   row) to get the gates it selected. Then flag:
   - gates that ran where no changed path is in the gate's read set (rule 2), totalled by MAP row;
   - runs where the fail-open row (run everything) fired, and why;
   - the master-push duplicate share: push runs re-testing a tree a green PR head already tested,
     split into gates the PR also ran and gates the PR skipped. Count what the push leg caught:
     red push runs, and whether the failing gate could see the commit's paths (catch vs flake).
4. **One deep dive.** Take the top grower, or else the top stage by weekly seconds. Profile where
   its time goes (process spawns per item, nested `devbox run`, serial independent subtests,
   network pulls, fsync, repeated builds) and prototype the fix in your checkout. Measure it under
   rule 3.
5. **Detector self-check.** Confirm `GithubCiWallTimeDrift` can still see a baseline. The guard
   step's Prometheus answer is in your bundle if the platform passed it; otherwise mark the check
   unverified. A blind detector is a finding, not a footnote.
6. **Emit.**
   - **The PR**: at most one deep-dive speedup, plus any MAP narrowings that pass rule 2, each with
     its measured saving. The body carries one line per change: `ci-optimizer: <slug>`.
   - **Issues** (body line `ci-optimizer: <slug>`): an in-stage speedup too big for this run, a
     ci.yaml change (rule 5), or a ⚖ proposal with its measured cost and the options. Filed, never
     admitted: no `agent/queued`.
   - **The report**: everything else, including what you measured and chose not to act on.

## Cost model

Denominate in this order. First, **PR wall time**: it is what the operator and the merge path wait
on, including master-push queueing that delays the next merge. Second, **runner-minutes**: the
8-slot capacity is shared with every stack. Third, **flake cost**: a red push that a re-run
turns green is an operator touch. A change that saves runner-minutes but lengthens PR wall says so.

## Report body (inside the SERIES-BRIEF headings)

- **Coverage**: window, run counts, sampled job count, calls spent, sources you could not reach.
- **Summary**: PR/push median and p90 and runner-minutes, with the week-over-week deltas.
- **Decisions**: the PR, issues filed, issues extended.
- **Proposals ⚖**: the master-push net cost vs catches, ci.yaml-only changes, runner/job topology.
- Tables for steps 1–3. The predecessor score from step 0. The detector check from step 5.

## Open questions before wiring (for the seat)

- **Guard.** Proposed: `count(max by (id) (max_over_time(github_workflow_run_duration_seconds{repo="homelab",workflow="CI",status="completed"}[7d]))) > bool 20`,
  so a quiet week, such as a CI freeze, rides nothing. An alternative is to fire only on growth.
  The series still owes a week-over-week score, so the count guard is preferred.
- **Reach.** The retro read token has `actions: read`, which covers steps 0–3. Prometheus reach
  from the cell is unproven. The bundle could carry the step-5 answer from the guard step
  (a `retro_pipeline.py prepare` extension).
- **Slot.** Weekly, off the platform retro's Monday and feedback-triage's Wednesday; e.g. Friday
  05:00 UTC. The series is born suspended and hand-fired once, as feedback-triage was.
- **Harness.** One cell (`harnessB: ""`): the output is one PR.
- **Local timing.** The cell's pod is not the ARC runner. Ratios transfer, absolutes do not.
