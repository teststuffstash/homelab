# touches-check.sh — compute the escape set for declared `Touches:` footprint (ADR-097, homelab#379).
# Sourced by reviewer-session.sh and coordinator-scan.sh; unit-tested by agents/touches-check-test.sh
# (devbox run touches-check-test, wired in ci — homelab#474).
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

# sentinel_only_paths <unified-diff-text> → newline list of changed files whose ENTIRE +/-
# content delta is REPLAY sentinel marker comments (homelab#944, ADR-097 addendum 3). The
# fourth compelled-counterpart class, and the one that cannot be path-keyed: run.sh extract()
# is sentinel-only, so pinning a block of ANY script requires planting the markers in that
# script — a comment-only edit the ratchet itself demands. Path-keying it (`agents/*.sh`)
# would exempt real edits to the launcher/scan/reflex — the exact worker-edits-its-own-governor
# hazard the escape check exists for — so this class is CONTENT-verified from the diff instead:
# a file qualifies iff it has ≥1 sentinel line and ZERO other added/removed content lines
# (extract()'s exact grammar, leading whitespace trimmed). A mixed diff qualifies nowhere and
# keeps ordinary escape semantics; an unavailable diff yields the empty set — conservative,
# the exemption simply doesn't engage. Residual (accepted, same disposition as the other three
# classes): a sentinel-shaped line inside a heredoc/string is content — the review rubric's
# ordinary read of the diff is the guard, never this classifier.
sentinel_only_paths() {
  printf '%s\n' "${1:-}" | awk '
    function flush() { if (f != "" && sent > 0 && dirty == 0) print f }
    /^diff --git / { flush(); f = ""; sent = 0; dirty = 0; next }
    /^\+\+\+ b\// { f = substr($0, 7); next }
    /^(--- |\+\+\+ |@@ |index |new file|deleted file|similarity |rename |old mode|new mode)/ { next }
    /^[+-]/ {
      line = substr($0, 2)
      sub(/^[ \t]+/, "", line)
      if (line ~ /^# >>>REPLAY:[A-Za-z0-9._-]+>>>$/ || line ~ /^# <<<REPLAY:[A-Za-z0-9._-]+<<<$/) sent++
      else dirty++
    }
    END { flush() }
  '
}

# touches_check <declared-touches> <newline-separated-paths> [<sentinel-only-paths>] → escape set
# Input:
#   $1 = declared Touches line (comma-separated paths; can be empty/"*" for undeclared)
#   $2 = newline-separated list of changed paths from the PR diff
#   $3 = OPTIONAL newline-separated list of sentinel-only paths (from sentinel_only_paths over
#        the SAME PR's diff) — each is skipped like the fp_replay_exempt classes, in BOTH
#        branches. Callers without diff access pass nothing and get the stricter behaviour.
# Output:
#   newline-separated list of escaped paths; each line is "path" or "path|governance"
#   Empty output = no escapes (all paths covered by declared touches)
touches_check() {
  local declared="$1" paths="$2" sentinel_only="${3:-}"
  local path marker

  # Undeclared Touches (empty string or "*") → all paths escape.
  # ADR-097 addendum (fp_replay_exempt, footprint.sh): a changed path under agents/replay/ is
  # NEVER an escape — governance or otherwise — in EITHER branch. The ADR-103 ratchet compels
  # replay touches on every clause PR; flagging the compelled edit is the PR#547 defect.
  if [ -z "$declared" ] || [ "$declared" = "*" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      fp_replay_exempt "$path" && continue
      if [ -n "$sentinel_only" ] && printf '%s\n' "$sentinel_only" | grep -qxF -- "$path"; then continue; fi
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
    # ADR-097 addendum: replay paths are exempt here too — REQUIRED, not belt: fp_conflict
    # strips replay entries from both lists, so without this skip an exempt changed path would
    # read as "no conflict" and surface as an ESCAPE, inverting the exemption.
    fp_replay_exempt "$path" && continue
    # Addendum 3 (#944): sentinel-only files, content-verified by the caller.
    if [ -n "$sentinel_only" ] && printf '%s\n' "$sentinel_only" | grep -qxF -- "$path"; then continue; fi
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
