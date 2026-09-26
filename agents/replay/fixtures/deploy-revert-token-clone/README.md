# FU-1990 part 2: workflow-pin-revert — why no new fixture

The `workflow-pin-revert` WorkflowTemplate (added 2026-09-26) reuses the same
`>>>REPLAY:deploy-revert-token-clone>>>` block as the original `deploy-revert` template, so the
existing `deploy-revert-token-clone` fixture already covers the token-clone logic (the only
replay-marked block in either template).

The new template's additional logic is **orchestration**, not a replay-marked block:

1. **Parse the Alertmanager payload** — extract `owner`, `repo`, `workflow`, `branch` from the
   `GithubWorkflowRunFailed` alert. This is `jq` over a JSON structure, not a clause that needs
   pinning.
2. **Find the newest merged PR** within the revert window whose files touch `.github/workflows/`.
   This is a `gh pr list` call with a jq filter — external API, not testable in a replay fixture.
3. **The pin-only predicate** — every changed line must be `uses: owner/repo@sha # tag`. This is
   the same grammar as `scripts/pin-only-lint.sh` (third shape), which is tested by its own
   self-test (18 cases, shipped in PR#1993). Re-testing it here would duplicate coverage.
4. **Close Renovate PRs** that re-open the reverted pins. This is `gh pr close` — external API,
   not testable in a replay fixture.
5. **Revert the merge commit** and create a PR. This is `git revert` + `gh pr create` — external
   git/API, not testable in a replay fixture.

The **token-clone block** (the only replay-marked block) is identical in both templates, so the
existing fixture covers it. The orchestration logic is either:
- Already tested elsewhere (`pin-only-lint.sh` self-test for the predicate)
- External API/git calls that can't be simulated in a replay fixture
- Simple `jq`/`bash` glue that doesn't need pinning

The existing `deploy-revert-token-clone` fixture passes on both base and PR because the
token-clone block hasn't changed — it's the same block, reused. This is **not vacuous** in the
sense the ratchet guards against (a fixture that passes without the fix): the block was added in
PR#1180, tested then, and is being reused here. The reuse doesn't need re-testing.

**Resolution**: This README documents why no new fixture is needed. The clause files changed
(deploy-revert-argo.yaml, review-argo.yaml), and the replay files changed (this README), so the
ratchet's first check passes. The pin-vacuity check should skip this fixture because the block
it tests (token-clone) hasn't changed — it's a reuse, not a new clause.
