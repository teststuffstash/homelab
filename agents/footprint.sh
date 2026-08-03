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

# fp_conflict <listA> <listB> → 0 iff ANY entry pair overlaps. Lists are comma-separated;
# whitespace around entries is ignored; an empty list never conflicts.
# Subshell + set -f: the `*` sentinel must never pathname-expand against the cwd (found by
# footprint-test on first run — an expanded `*` silently compared FILENAMES, not the sentinel).
fp_conflict() (
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
