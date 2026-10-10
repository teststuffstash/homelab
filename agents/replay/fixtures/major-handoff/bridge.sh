# gh_label_add / gh_label_rm — the shipped REST label transport the clause calls (FU-290); sourced, never stubbed.
. "$REPLAY_ROOT/agents/machine-comment.sh"
# ── bridge ── the argv seam only. The script reads `<owner/repo> <pr>` from $1/$2 at load time;
# a composed clause has no argv, so the family supplies the pair from its env. Everything else
# (the reviewer login, the three label names, the refuse/unreadable printers) arrives through the
# script's own >>>REPLAY:major-handoff-seams>>> block, composed FIRST (README §S5) — nothing here
# renames or shadows a gate variable, so the fixture pins the shipped defaults.
SLUG="$IN_SLUG"
PR="$IN_PR"
