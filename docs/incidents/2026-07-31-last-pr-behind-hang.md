# 2026-07-31 — The last PR in a batch hung BEHIND for ~1h on an unreliable GitHub cron

**Residual:** FU-124.
**Related:** FU-041 (updater / merge path), ADR-093 (the review edge),
`docs/agents/merge-path-fsm.yaml` MP-T02.

The finale PR of a 14-item drive sat `BEHIND/APPROVED` for about an hour because the only mechanism
that could rescue it was GitHub's `schedule: */15` cron, and GitHub did not run it.

## Timeline

| When (UTC) | What |
|---|---|
| ~16:47 | Last run of `update-pr-branch.yml`. sleep-tracking **#100** (the #77 finale) is `BEHIND/APPROVED`. |
| 17:00 / 17:15 / 17:30 / 17:45 | The `schedule: */15` sweeper **does not fire**. GitHub delays or drops scheduled workflows under load. |
| ~17:50 | Manual `workflow_dispatch` of the updater. |
| ~17:50 | #100 goes BEHIND → BLOCKED → merged, immediately. |

The updater **logic is fine** — only its trigger failed. That is what the manual dispatch proved.

## Root cause

**The review edge approves without gating on `not-behind`, and the last PR in a batch has no push
behind it.**

The ADR-093 review edge approves a PR on `green ∧ armed ∧ review_required` **without** checking
whether it is behind its base. That inverts the merge path's intended *update-before-review* order,
so PRs routinely become approved-while-behind.

For a **non-last** PR that is harmless: the next PR's merge produces a `push`, which re-triggers
the updater. For the **last open PR** there is nothing behind it — the `push` and `workflow_run`
edges are both dead, so the `*/15` cron is the sole backstop. An unreliable cron as a sole backstop
is an indefinite hang.

## Fix direction (open — FU-124; impl not asserted)

Give the updater a **reliable in-cluster trigger** instead of GitHub's cron. The coordinate scan
already reads `mergeStateStatus` for its conflict-flagging step, so it can
`gh workflow run update-pr-branch.yml` when it sees an armed PR stuck BEHIND with no updater
progress. The coordinator's `*/10` + doorbell cadence is far more reliable than Actions cron.

**Belt for the meta-watch:** add a check for an armed PR sitting BEHIND for >~15min. The existing
loop watch missed this entirely — it checks CI-failure and merge, not **updater liveness**.

## Probe lesson

- **A sole backstop on someone else's scheduler is not a backstop.** GitHub Actions `schedule:` is
  explicitly best-effort; treating it as the only rescue path for a terminal state converts a
  provider hiccup into an unbounded hang.
- **Watch for the case with no successor.** The batch worked for 13 PRs because each was rescued by
  the *next* one's merge. The failure only exists at the tail — the class of bug that testing with
  N>1 items hides.
- Watches should cover **liveness of the fixer**, not only the symptom it fixes.
