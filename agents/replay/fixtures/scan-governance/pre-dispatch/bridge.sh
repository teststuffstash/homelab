# ── bridge ── the scan state the governance blocks read. Every name is a variable the shipped script
# sets before the queued loop (`HERE`, `orphans`), never a harness invention.
#
# `HERE` points at the real `agents/` in the checkout, which is what makes `GOVERNANCE_LINT` resolve
# to the real `scripts/governance-lint.sh` — the one definition of GOVERNANCE. Nothing here declares
# a path: a fixture that named the governance files itself would be the second copy the change exists
# to prevent, and would go green while the scan and the lint drifted apart.
HERE="$REPLAY_ROOT/agents"
# The scan's own source line, verbatim — `fp_norm_entry`/`fp_conflict` are the ADR-097 predicate
# and the governance check must use the same path-boundary reasoning, not a private copy of it.
. "${HERE}/footprint.sh"
# The governance check is scoped to the same repo the GUARDED check uses (homelab's CI's set).
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""