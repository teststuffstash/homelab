# ── bridge ── the per-PR loop variables the ci-red clause reads. Every name is a SCAN
# variable set earlier in the ci-red clause (`slug`, `repo`, `u`, `u_head`, `red_issue`,
# `head8`, `orphans`, `units`, `red_n`, `items`), never a harness invention — a bridge that
# renames things pins a different clause.
#
# `STATS_TS_DEF` and `NOOP_ROUND_JQ` are deliberately NOT set here: they arrive as the extracted
# `block:round-evidence` part, so this fixture cannot go green against a transcribed copy of the
# very jq the change is about (#166).
slug="$IN_SLUG"
repo="$IN_REPO"
u="$IN_PR"
# The head is goal/** — the protected integration branch. This is what triggers the FU-143
# exclusion. A fix round cannot push to this head.
u_head="goal/281-delta-redesign"
# No linked issue (body has no closing keyword).
red_issue=""
# Short head sha (unused since the exclusion fires before round counting).
head8="bbbbbbbb"
# Per-scan accumulators.
orphans=""
units=""
red_n=0
items=""
item_class_push() { :; }
# The ci-red clause's per-PR loop. Wrap in a single-PR for loop matching the scan's structure.
for u in "$IN_PR"; do
  # ── FU-143 goal/**-head exclusion (homelab#1148) ──
  # This is the code added to the ci-red dispatch leg. It fires before round counting.
  # The `continue` skips the blocks below (ci-red-rounds, ci-red-gate, dispatch).
  if [[ "$u_head" == goal/* ]]; then
    orphans="${orphans}[$repo] ⚠ ASSEMBLY PR #${u} has ci-red (FU-143) — route as a NEW child on the goal; a fix round cannot push to the protected goal/** head\n"
    continue
  fi