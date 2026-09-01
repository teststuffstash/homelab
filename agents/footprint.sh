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

# fp_replay_exempt <entry-or-path> → 0 iff it is a COMPELLED COUNTERPART of clause work —
# a file some required lint forces the PR to touch alongside the change it declares. ADR-097
# addendum (2026-08-18, the FU-167/FU-168 joint call, operator-ruled; WIDENED 2026-08-19,
# homelab#601, seat ruling under the same rationale): requiring a compelled edit's declaration
# is ceremony that manufactures the unsatisfiable-footprint class (homelab#270/PR#275) and
# governance blocks on edits the gates themselves demand (PR#547; PR#599 touched
# state-fp-replay.sh + merge-path-fsm.yaml outside its Touches because the fingerprint suite
# and the FSM replay: declarations MUST move with a fixture — homelab#601's evidence). The
# three compelled classes, each path-boundary aware:
#   agents/replay/**           — the ADR-103 ratchet compels a replay touch on every clause PR
#   agents/*-test.sh, *-replay.sh — the suite pins; a moved extracted block compels the suite edit
#   docs/agents/*-fsm.yaml/.md — the model's replay:/guard declarations + the REGENERATED view
#                                 (merge-path-lint currency reds a stale one)
# Content safety is the review rubric's worlds-are-extraordinary rule + the ratchet, never path
# declaration. ONE predicate, two call sites with deliberately different verbs: fp_conflict
# STRIPS declared exempt entries (no intersection holds), touches_check SKIPS changed exempt
# paths (never an escape) — stripping in only one place would invert the escape direction.
fp_replay_exempt() {
  case "$(fp_norm_entry "$1")" in
    agents/replay | agents/replay/*) return 0 ;;
  esac
  # Suite pins + FSM models match on the LITERAL path (declarations of these are literal file
  # names; changed paths always are). ⚠ case globs cross `/`, so the depth guard comes FIRST:
  # only TOP-LEVEL agents/*-test.sh|*-replay.sh are the compelled suite class —
  # agents/coordinator/responder-behaviour-test.sh is an ordinary declared surface, not exempt.
  case "$1" in
    agents/*/*) : ;;
    agents/*-test.sh | agents/*-replay.sh) return 0 ;;
  esac
  case "$1" in
    docs/agents/*/*) : ;;
    docs/agents/*-fsm.yaml | docs/agents/*-fsm.md) return 0 ;;
  esac
  return 1
}

# fp_goal_exempt <class> → 0 iff the item is a goal-class unit (goal-decompose,
# goal-checkpoint). Goal units write NO code — they author child issues via `gh`
# and toggle labels, never a PR diff — so the ADR-097 footprint hold (which
# prevents write-surface conflicts between concurrently dispatched units) is a
# category error for them. A goal is exempt in BOTH directions: it is not held
# by in-progress issues' footprints and does not hold sibling dispatches.
# Homelab#822.
fp_goal_exempt() {
  case "${1:-}" in goal)
    return 0
  ;; esac
  return 1
}

# classify_touches <footprint> → prints "machine-merge" | "codeowner-merge" | "codeowner-author"
# ONE machine-readable home for the platform lane path tables (docs/agents/iac-lane.md §The
# platform lane). Sources: the ❌ operator-author set (iac-lane.md, collapsed from the second
# copy that was inlined in fix-debounce-argo.yaml) and the repo-root CODEOWNERS (parsed at
# runtime, never restated). Returns the HIGHEST classification across all paths in the footprint:
#   machine-merge    — CI gate only (tier 1: argocd/resources/** and unowned paths)
#   codeowner-merge  — agent may author, human merges (tier 2 + tier 3 CODEOWNERS-owned paths)
#   codeowner-author — only codeowner may author (❌ set: .github/, .agents/, devbox.json|lock,
#                      scripts/ — paths that take effect BEFORE a human approves)
# Callers: coordinator-scan.sh (queued-dispatch operator-lane hold), fix-debounce-argo.yaml
# (queue-time deny), and any future reader — one definition, N readers.
classify_touches() (
  set -f
  local footprint="$1" path tier="machine-merge"
  local _co_file="${CLASSIFY_CODEOWNERS:-CODEOWNERS}"
  local _entries _co_line _co_pat _co_owned _co_has_owner _co_rest _new_tier

  # Tier rank: machine-merge=1, codeowner-merge=2, codeowner-author=3
  _tier_rank() {
    case "$1" in
      machine-merge) echo 1 ;;
      codeowner-merge) echo 2 ;;
      codeowner-author) echo 3 ;;
      *) echo 0 ;;
    esac
  }

  _entries="$(printf '%s' "$footprint" | tr ',' '\n' | tr -d ' \t')"

  for path in $_entries; do
    [ -n "$path" ] || continue
    _new_tier="machine-merge"

    # ── ❌ operator-author set — NEVER agent-authored ──────────────────────────────────────
    # These paths take effect BEFORE a human approves (iac-lane.md §The platform lane):
    #   .github/**       — PR runs its own workflow (arbitrary code on the runner)
    #   .agents/**       — next round reads its recipe from the branch
    #   devbox.json|lock — CI executes from the branch
    #   scripts/**       — CI executes from the branch (in homelab the scripts ARE the checks)
    case "$path" in
      .github/*|.github) _new_tier="codeowner-author" ;;
      .agents/*|.agents) _new_tier="codeowner-author" ;;
      devbox.json|devbox.lock) _new_tier="codeowner-author" ;;
      scripts/*|scripts) _new_tier="codeowner-author" ;;
      *)
        # ── CODEOWNERS-based classification ──────────────────────────────────────────────────
        # Parse CODEOWNERS at runtime: last-matching-pattern wins. A pattern with an owner makes
        # the path codeowner-merge; a carve-out (no owner) makes it machine-merge. Patterns are
        # repo-relative (leading / stripped for matching). Directory patterns (trailing /) match
        # the dir and everything under it; file patterns match exactly.
        _co_owned=-1  # -1 = no match, 0 = carve-out, 1 = owned
        while IFS= read -r _co_line; do
          case "$_co_line" in
            ''|'#'*) continue ;;
          esac
          _co_pat="${_co_line%%[[:space:]]*}"
          # Check if this line has an owner (whitespace after pattern)
          _co_has_owner=0
          _co_rest="${_co_line#$_co_pat}"
          [ -n "$_co_rest" ] && _co_has_owner=1
          _co_pat="${_co_pat#/}"  # strip leading /
          # Match: for directory patterns (trailing /), check if path starts with the pattern
          # (agents/ matches agents/coordinator-scan.sh). For file patterns (no trailing /),
          # check exact equality (agents/images.env matches only that file).
          if [ "$path" = "$_co_pat" ]; then
            _co_owned="$_co_has_owner"
          elif [ "${_co_pat%/}" != "$_co_pat" ] && [ "${path#"$_co_pat"}" != "$path" ]; then
            # Directory pattern match (trailing /)
            _co_owned="$_co_has_owner"
          fi
        done < "$_co_file" 2>/dev/null || true

        if [ "$_co_owned" -eq 1 ]; then
          # Last matching pattern has an owner — codeowner-merge
          _new_tier="codeowner-merge"
        fi
        # Carve-out (last match has no owner) or no match → stays as machine-merge
        ;;
    esac

    # Only escalate tier (never downgrade)
    if [ "$(_tier_rank "$_new_tier")" -gt "$(_tier_rank "$tier")" ]; then
      tier="$_new_tier"
    fi
  done

  printf '%s' "$tier"
)

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
