# ── bridge ── the per-PR loop variables the ci-failure-run-select block reads. Every name is a
# variable the context-prefetch block sets earlier in agents/agent-session.sh (`PF_SLUG` from the
# repo, `PF_PR`/`PF_PR_REF` from the PR head, `PF_CI_FAILURE_MD`/`PF_INDEX`/`PF_INDEX_ITEM` from
# the bundle builder), never a harness invention — a bridge that renames things pins a different
# clause.
#
# The world supplies the two `gh run list` answers: `run-list-<branch>-failure.json` (the
# settled-failure run) and `run-list-<branch>.json` (the newest run on the branch). The
# `unsettled-sibling` row overlays its own newest-run answer and patches the settled-failure list
# empty.

PF_SLUG="$IN_SLUG"
PF_PR="$IN_PR"
PF_PR_REF="fix/issue-1413-pypi-cache-env"

# Defined above the extracted block in agents/agent-session.sh — the fixture composes only
# block:ci-failure-run-select, so the bridge supplies them.
PF_CI_FAILURE_MD=""
PF_INDEX=""
PF_INDEX_ITEM() { PF_INDEX="${PF_INDEX}${1}  ${2}${3:+  ${3}}"$'\n'; }
