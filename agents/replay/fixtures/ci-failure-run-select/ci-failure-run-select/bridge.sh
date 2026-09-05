# Bridge: set up the PR context for the ci-failure-run-select fixture
# Scenario: PR #1435 on branch fix/issue-1413-pypi-cache-env has two runs:
#   - failing run: 33965268108 (status=failure) — the CI workflow
#   - skipped run: 33965534792 (status=skipped) — the newest, from renovate-approve
#
# The prefetch should select the failing run (33965268108), not the newest one.

PF_SLUG="$IN_SLUG"
PF_PR="$IN_PR"
PF_PR_REF="fix/issue-1413-pypi-cache-env"
