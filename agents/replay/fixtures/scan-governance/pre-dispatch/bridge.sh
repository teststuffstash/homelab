# ── bridge ── the scan state the operator-lane blocks read. Every name is a variable the shipped
# script sets before the queued loop (`HERE`, `orphans`), never a harness invention.
#
# `HERE` points at the real `agents/` in the checkout, which is what makes `footprint.sh` resolve
# to the real file — the one definition of classify_touches(). Nothing here declares a path: a
# fixture that named the ❌ set itself would be the second copy the change exists to prevent.
HERE="$REPLAY_ROOT/agents"
# The scan's own source line, verbatim — `classify_touches()` is the ADR-097 predicate and the
# operator-lane check must use the same path-boundary reasoning, not a private copy of it.
. "${HERE}/footprint.sh"
# classify_touches() reads CODEOWNERS at runtime. Point it at the real file in the checkout.
CLASSIFY_CODEOWNERS="${HERE}/../CODEOWNERS"
# The operator-lane check is scoped to the same repo the GUARDED check uses (homelab's CI's set).
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""