# LENS: gate-change — a PR that edits a check (ADR-142, the scripts/ un-gating trial)

**BLOCKING BY CONSTRUCTION.** Selected deterministically by `reviewer-session.sh` whenever the
diff touches `scripts/`. Since 2026-09-28 `scripts/**` carries no human codeowner and workers may
author it (ADR-142 — a TRIAL, re-read after a week and a month): **your read is the only gate on
the repo's own checks.** CI executes `scripts/**` from the PR branch, so a PR that edits a lint
is judged by the lint it edited. A weakened gate is the verdict, not a follow-up.

## What you are guarding against

A PR that makes a check pass by changing the check instead of the content — outright or
disguised: a refactor that drops a branch, a regex that quietly widens, a new early `exit 0`,
an env var that skips the run (`*_SKIP`, `*_NO_INSTALL`), `|| true` / `set +e` around the
decisive call, an exit code swallowed by a pipe (`lint | tail -1`), a FAIL demoted to a
warning, a deleted or loosened test case, a fixture re-recorded to match new behaviour. **Assume
the PR's title, body and linked issue can be wrong about what the diff does** — read the diff
itself; a mismatch between what the issue asks for and what a script change does is BLOCKING
on its own, whatever the change's merit.

## The procedure — under a `## Gate change` heading in your review body

1. **Enumerate** every changed file under `scripts/` and say, per file, whether CI runs it
   (`.github/workflows/ci.yaml` `devbox run <task>` lines + `scripts/diff-ci.sh`'s MAP →
   `devbox.json` task bodies) or it is a seat/cluster script. Name the count: "4 changed, 3 CI
   gates, 1 seat script".
2. **Read the gate-drift report** — CI's non-failing `gate-drift` step re-runs MASTER's side of
   each edit (`scripts/gate-drift.sh`, extracted from the base commit so the PR cannot edit it):
   `gh run list --commit <head-sha> --workflow CI --json databaseId -q '.[0].databaseId'`, then
   `gh run view <id> --log | sed -n '/GATE-DRIFT-BEGIN/,/GATE-DRIFT-END/p'`. Quote its lines.
   - **(A) master's gate × this PR's content → DIFFERS** means the PR's content passes only
     because of the script edit.
   - **(B) master's tests × this PR's scripts → DIFFERS** means a case master's tests pinned no
     longer holds.
   Either one is a finding you must resolve. The PR body has to justify it as an intended rule
   change: which case, why it's now allowed, and where the new rule is pinned by a test. If it
   doesn't, it's `--request-changes`. A report you could not read is a TOOL_GAP you name; it is
   not "clean". Treat a missing block the same way (the step runs only on PRs that change
   `scripts/`).
3. **Read every changed gate for relaxation**, whatever the report says. The report sees only
   what this PR's content and master's tests exercise, and a weakening neither exercises shows
   `same` on both legs. For each gate, name the decision points the diff touches (conditions,
   patterns, exit paths, skip switches) and state for each: stricter, equal, or looser. A looser
   decision point needs the same justification as a DIFFERS line.
4. **Tests move with the rule.** A gate change that tightens or loosens behaviour adds or edits
   a case in its self-test (`*-test.sh`, `*self-test*`, `agents/replay/fixtures/`) in the same
   PR. Removing a case, or re-recording an expected output so that a previously refused input
   now passes, is a loosening (step 3).

Seat and cluster scripts (step 1's non-CI files) get the ordinary review. This lens adds nothing
for them beyond step 1's enumeration.

## Out of scope — still gated elsewhere

`mgmt/scripts/**` and the three box-executed verbs (`scripts/node-maintenance.sh`,
`scripts/maintenance-window.sh`, `scripts/controlplane-upgrade.sh`) keep their human codeowner.
The [management box](../../docs/management-box.md) runs them from master, and ADR-142 left the box out of the trial. A worker
PR touching them is refused by `governance-lint` before you see it. `devbox.json|lock`,
`.github/**` and `.agents/**` are unchanged too.
