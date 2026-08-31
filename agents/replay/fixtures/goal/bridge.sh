# ── bridge ── the per-stack loop variables the goal-lane block reads. Every name here is a SCAN
# variable set earlier in the per-repo loop (`slug`, `repo`, `openall`, `orphans`, `units`), never
# a harness invention — a bridge that renames things is a bridge that pins a different clause.
#
# `openall` is the ONE open-issue fetch the whole per-repo loop derives from (coordinator-scan.sh
# §"ONE fetch, two derivations"). It is read far above the sentinel, so it arrives as a fixture
# file rather than a stub recording — the honest split: what the block CALLS is recorded under
# world/gh/, what it INHERITS is set here.
# The REAL findings-store helpers, SOURCED from the checkout unconditionally (extraction-never-
# transcription — the goal-ancestor family's goal-budget.sh precedent). Production's scan sources
# them at top; the extracted block gets them here. Only the checkpoint-due and nonassembly rows
# reach the store fns, but sourcing a helper with a source-guard is harmless on the terminal rows.
# Every read/write they make rides the PATH-shim gh.
. "$REPLAY_ROOT/agents/goal-findings.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
openall="$(cat "$REPLAY_FIXTURE/world/openall.json")"
orphans=""
units=""
punits=""
# ── goal-decompose block variables ── set via env for the two new rows (base-required,
# base-master-pass); empty for existing rows so the block is a no-op.
qclass="${QCLASS:-}"
qnum="${QNUM:-}"
qbase_raw="${QBASE_RAW:-}"
qpin="${QPIN:-}"
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }
