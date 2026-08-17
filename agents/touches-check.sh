# touches-check.sh — compute the escape set for declared `Touches:` footprint (ADR-097, homelab#379).
# Sourced by reviewer-session.sh and coordinator-scan.sh; unit-tested in homelab#474.
#
# A Touches footprint is a comma-separated list of path prefixes/globs from an issue's `Touches:`
# body line. This helper computes the ESCAPE SET: paths changed in a PR that fall outside the
# declared footprint (i.e., undeclared paths the worker modified). The check uses the SAME
# normalization/prefix-intersection semantics as the scan's ADR-097 footprint hold.
#
# Governance paths are flagged in the output so the reviewer can highlight escapes into
# `agents/**`, `.agents/**`, `scripts/**`, `policy/**`, `.github/**`, `tofu/github/**`,
# `tofu/cloudflare/**` as BLOCKING findings.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/footprint.sh"

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
