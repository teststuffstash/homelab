# touches-check.sh — compute the escape set for declared `Touches:` footprint (ADR-097, homelab#379).
# Sourced by reviewer-session.sh and coordinator-scan.sh; exercised by agents/touches-check-test.sh.
#
# A Touches footprint is a comma-separated list of path prefixes/globs from an issue's `Touches:`
# body line. This helper computes the ESCAPE SET: paths changed in a PR that fall outside the
# declared footprint (i.e., undeclared paths the worker modified). The check uses the SAME
# normalization/prefix-intersection semantics as the scan's ADR-097 footprint hold.
#
# Governance paths are flagged in the output so the reviewer can highlight escapes into
# `agents/**`, `.agents/**`, `scripts/**`, `policy/**`, `.github/**`, `tofu/github/**`,
# `tofu/cloudflare/**` as BLOCKING findings.

# fp_norm_entry <entry> → boundary prefix on stdout ("" = matches everything)
# (Sourced from coordinator-scan.sh's footprint.sh for consistency)
fp_norm_entry() {
  _e="${1%%\**}"   # cut at the first glob star: chassis/** → chassis/
  _e="${_e%/}"     # drop the trailing slash: chassis/ → chassis
  printf '%s' "$_e"
}

# fp_pair_conflict <entryA> <entryB> → 0 iff the two entries overlap (path-boundary aware)
# (Sourced from coordinator-scan.sh's footprint.sh for consistency)
fp_pair_conflict() {
  _pa="$(fp_norm_entry "$1")"
  _pb="$(fp_norm_entry "$2")"
  if [ -z "$_pa" ] || [ -z "$_pb" ]; then return 0; fi
  case "$_pa" in "$_pb" | "$_pb"/*) return 0;; esac
  case "$_pb" in "$_pa"/*) return 0;; esac
  return 1
}

# fp_conflict <listA> <listB> → 0 iff ANY entry pair overlaps.
# Lists are comma-separated; whitespace around entries is ignored; an empty list never conflicts.
# (Sourced from coordinator-scan.sh's footprint.sh for consistency)
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
# (Sourced from coordinator-scan.sh's footprint.sh for consistency)
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

# governance_paths <path> → "governance" marker if the path lands in a governance tier
governance_paths() {
  local p="$1"
  case "$p" in
    agents/*|.agents/*|scripts/*|policy/*|.github/*|tofu/github/*|tofu/cloudflare/*)
      printf 'governance'
      return 0
      ;;
  esac
  return 1
}

# touches_check <declared-touches> <newline-separated-paths> → escape set with governance markers
# Input:
#   $1 = declared Touches line (comma-separated paths; can be empty/"*" for undeclared)
#   $2 = newline-separated list of changed paths from the PR diff
# Output:
#   newline-separated list of escaped paths; each line is "path" or "path|governance"
#   Empty output = no escapes (all paths covered by declared touches)
touches_check() {
  local declared="$1" paths="$2"
  local path marker

  # Undeclared Touches (empty string or "*") → all paths escape
  if [ -z "$declared" ] || [ "$declared" = "*" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      marker="$(governance_paths "$path")" || marker=""
      if [ -n "$marker" ]; then
        printf '%s|%s\n' "$path" "$marker"
      else
        printf '%s\n' "$path"
      fi
    done <<EOF_PATHS
$paths
EOF_PATHS
    return 0
  fi

  # Declared Touches: for each path, check if it conflicts with the declared footprint.
  # If it doesn't conflict, it's an escape.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    # Treat the changed path as a singleton footprint entry and check against declared
    if ! fp_conflict "$declared" "$path"; then
      # Path does not conflict with declared touches → it's escaped
      marker="$(governance_paths "$path")" || marker=""
      if [ -n "$marker" ]; then
        printf '%s|%s\n' "$path" "$marker"
      else
        printf '%s\n' "$path"
      fi
    fi
  done <<EOF_PATHS
$paths
EOF_PATHS
}
