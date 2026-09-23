# ── bridge ── the dispatch-loop state the `fu146-resumable-match` block consumes.
#
# FU-199 (folded in, 2026-09-20): the resumable set is NEWLINE-separated and read with
# `IFS= read -r`, so a value carrying whitespace or a glob character can neither word-split nor
# expand. The old `for rb_entry in $resumable_branches` did both — the #1780 dispatch arrived
# carrying `work-branch=**` because the extraction's value word-split there.
#
# A row declares the branch SHAPE it wants (`RB_SHAPE`), never the raw value: the table's `env`
# column is space-separated and glob-expanded by the harness, so a value carrying a space or a `*`
# cannot ride it. The bridge assembles the repo-qualified entry the clause builds.
uclause="c4c5-redispatch"
urepo="homelab"
uitem="issue-42"
case "${RB_SHAPE:-plain}" in
  whitespace) RB_BRANCH="fix/issue-42-a b" ;;
  glob)       RB_BRANCH="fix/issue-42-*" ;;
  *)          RB_BRANCH="fix/issue-42-loop" ;;
esac
resumable_branches="homelab#42=${RB_BRANCH}"$'\n'

# The scratch cwd. The clause runs with the fixture dir as cwd, so the bridge re-points it here —
# a fixture whose glob matches nothing proves nothing. The glob row's word is the WHOLE
# `repo#n=branch` entry (the `for` loop globbed the entry, not the bare branch), so the matching
# file carries that whole name: pre-fix the entry expands to it, post-fix it stays literal.
_scratch="$(mktemp -d)"
mkdir -p "$_scratch/fix"
: > "$_scratch/fix/issue-42-abc"
mkdir -p "$_scratch/homelab#42=fix"
: > "$_scratch/homelab#42=fix/issue-42-abc"
cd "$_scratch"