# footprint.sh — declared-footprint intersection for parallel dispatch (ADR-097, FU-086).
# Sourced by coordinator-scan.sh; exercised by agents/footprint-test.sh (the double-dispatch
# belt: a predicate bug here must fail a test, not double-dispatch into a lane).
#
# A footprint is a comma-separated list of path prefixes/globs from an issue's `Touches:` body
# line. The sentinel `*` (used for issues WITHOUT a Touches line) conflicts with everything —
# undeclared stays exclusive, preserving WIP=1 semantics for legacy issues (ADR-097).
#
# Conservative by construction: an entry whose glob defeats prefix reasoning (leading `*`,
# `**/x.py`) normalizes to the empty prefix and conflicts with everything. Wrong-side errors
# here HOLD work (a deferral, absorbed by the next scan) — never release it.

# fp_norm_entry <entry> → boundary prefix on stdout ("" = matches everything)
fp_norm_entry() {
  _e="${1%%\**}"   # cut at the first glob star: chassis/** → chassis/
  _e="${_e%/}"     # drop the trailing slash: chassis/ → chassis
  printf '%s' "$_e"
}

# fp_replay_exempt <entry-or-path> → 0 iff it lives under agents/replay/ (path-boundary aware:
# agents/replay-foo is NOT exempt). ADR-097 addendum (2026-08-18, the FU-167/FU-168 joint call,
# operator-ruled): the replay tree is EXEMPT from footprint semantics on BOTH sides — the ADR-103
# ratchet COMPELS a replay touch on every clause PR, so requiring its declaration was ceremony
# that manufactured the unsatisfiable-footprint class (homelab#270/PR#275) and a governance block
# on a compelled edit (PR#547), against ZERO real replay conflicts measured over 41 PRs. Content
# safety is the review rubric's worlds-are-extraordinary rule + the ratchet, never path
# declaration. ONE predicate, two call sites with deliberately different verbs: fp_conflict
# STRIPS declared replay entries (no intersection holds), touches_check SKIPS changed replay
# paths (never an escape) — stripping in only one place would invert the escape direction.
fp_replay_exempt() {
  case "$(fp_norm_entry "$1")" in
    agents/replay | agents/replay/*) return 0 ;;
  esac
  return 1
}

# fp_pair_conflict <entryA> <entryB> → 0 iff the two entries overlap (path-boundary aware:
# chassis ∩ chassis/api.py = yes; chassis ∩ chassis-x = no)
fp_pair_conflict() {
  _pa="$(fp_norm_entry "$1")"
  _pb="$(fp_norm_entry "$2")"
  if [ -z "$_pa" ] || [ -z "$_pb" ]; then return 0; fi
  case "$_pa" in "$_pb" | "$_pb"/*) return 0;; esac
  case "$_pb" in "$_pa"/*) return 0;; esac
  return 1
}

# fp_conflict_strict <listA> <listB> → 0 iff ANY entry pair overlaps — NO replay exemption.
# The pin-only GUARDED pre-dispatch check (coordinator-scan.sh, homelab#309) uses THIS variant:
# its invariant is "does the declared footprint touch a guarded FILE", and exempting the replay
# tree there would fail OPEN the day a guarded path lands under agents/replay/ — the issue's own
# declaration would cover the file while the check reads "no conflict" and dispatches (reviewer
# catch on PR#557; dormant today, no current GUARDED path is under the tree — pinned by the
# footprint-test strict rows so it stays a tested property, not a comment).
fp_conflict_strict() (
  set -f
  _la="$(printf '%s' "$1" | tr ',' '\n' | tr -d ' \t')"
  _lb="$(printf '%s' "$2" | tr ',' '\n' | tr -d ' \t')"
  [ -n "$_la" ] && [ -n "$_lb" ] || return 1
  for _a in $_la; do
    for _b in $_lb; do
      fp_pair_conflict "$_a" "$_b" && return 0
    done
  done
  return 1
)

# fp_conflict <listA> <listB> → 0 iff ANY entry pair overlaps. Lists are comma-separated;
# whitespace around entries is ignored; an empty list never conflicts.
# Subshell + set -f: the `*` sentinel must never pathname-expand against the cwd (found by
# footprint-test on first run — an expanded `*` silently compared FILENAMES, not the sentinel).
fp_conflict() (
  set -f
  _la="$(printf '%s' "$1" | tr ',' '\n' | tr -d ' \t')"
  _lb="$(printf '%s' "$2" | tr ',' '\n' | tr -d ' \t')"
  [ -n "$_la" ] && [ -n "$_lb" ] || return 1
  # ADR-097 addendum: replay-tree entries are stripped BEFORE pairing — a list that was
  # replay-only becomes empty and conflicts with nothing (a replay-only issue dispatches beside
  # anything, including a legacy `*` sentinel issue). The `*` sentinel itself normalizes to ""
  # and is NOT exempt — legacy-vs-legacy stays serial exactly as before.
  _fa=""; _fb=""
  for _a in $_la; do fp_replay_exempt "$_a" || _fa="${_fa}${_a}
"; done
  for _b in $_lb; do fp_replay_exempt "$_b" || _fb="${_fb}${_b}
"; done
  [ -n "$_fa" ] && [ -n "$_fb" ] || return 1
  for _a in $_fa; do
    for _b in $_fb; do
      fp_pair_conflict "$_a" "$_b" && return 0
    done
  done
  return 1
)

# fp_conflict_multi <list> <newline-joined lists> → 0 iff <list> conflicts with any line
fp_conflict_multi() {
  [ -n "$2" ] || return 1
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    fp_conflict "$1" "$_line" && return 0
  done <<EOF_FP
$2
EOF_FP
  return 1
}
