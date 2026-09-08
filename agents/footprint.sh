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
        done 2>/dev/null < "$_co_file" || true

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

# ── THEME predicates (ADR-126 v1.3.1 delta 4 / delta 2, homelab#1423 leg A) ──────────────────
# The goal lane's theme NOMINATION is deterministic footprint arithmetic over a goal's open
# sprouts (issue-authoring.md §v1.3.1 delta 4: "prefix-intersection over open sprouts, ≥2 sharing
# a surface — the existing footprint.sh predicate, new consumer"), and goal-lint's membership
# rule is delta 2's mechanical half. Both live HERE so the scan, the lint and the suite share one
# definition — a second copy of the path-boundary rule would drift exactly like the 13 body
# grammars ADR-122 collapsed. ADR-094: these NOMINATE and TEST; nothing here writes.

# fp_theme_groups — stdin: lines `<issue-number>|<touches-list>`; stdout: one line per group
# `<surface>|<n1> <n2> …` — the connected components (size ≥ 2) of the "lists conflict" graph
# (edges = fp_conflict, so replay-exempt entries never join anything).
#   • A line whose list is EMPTY or the `*` sentinel is dropped BEFORE grouping: undeclared is
#     exclusive (ADR-097) and would otherwise swallow every group into one — a sprout with no
#     footprint is never themed, it is serialised.
#   • <surface> = the SHORTEST fp_norm_entry among the group's non-exempt entries that conflicts
#     with EVERY member's list; if none does, the shortest non-exempt entry in the group. An
#     entry that normalises to "" (leading glob) is never a surface — it names nothing; when the
#     chosen entry's prefix is empty the raw entry is printed so the field is never blank.
#   • Members ascending numeric, groups sorted by surface, byte-identical output for identical
#     input (the scan's report line and the checkpoint's side value are diffed by the replay).
fp_theme_groups() (
  set -f
  _tg_members=""
  while IFS='|' read -r _tg_n _tg_l; do
    _tg_n="$(printf '%s' "$_tg_n" | tr -d ' \t')"
    case "$_tg_n" in ''|*[!0-9]*) continue ;; esac
    _tg_l="$(printf '%s' "$_tg_l" | tr -d ' \t\r')"
    [ -n "$_tg_l" ] || continue
    [ "$_tg_l" != "*" ] || continue
    _tg_members="${_tg_members}${_tg_n}|${_tg_l}
"
  done
  [ -n "$_tg_members" ] || return 0
  # edges: every conflicting pair, once (a < b by input order)
  _tg_edges=""
  _tg_i=0
  while IFS='|' read -r _tg_a _tg_la; do
    [ -n "$_tg_a" ] || continue
    _tg_i=$((_tg_i + 1)); _tg_j=0
    while IFS='|' read -r _tg_b _tg_lb; do
      [ -n "$_tg_b" ] || continue
      _tg_j=$((_tg_j + 1))
      [ "$_tg_j" -gt "$_tg_i" ] || continue
      fp_conflict "$_tg_la" "$_tg_lb" && _tg_edges="${_tg_edges}${_tg_a} ${_tg_b}
"
    done <<EOF_TG_B
$_tg_members
EOF_TG_B
  done <<EOF_TG_A
$_tg_members
EOF_TG_A
  [ -n "$_tg_edges" ] || return 0
  # components: union-find over the edge list; one line per component, members ascending
  _tg_groups="$(printf '%s' "$_tg_edges" | awk '
    function find(x) { while (p[x] != x) { p[x] = p[p[x]]; x = p[x] }; return x }
    { if (!($1 in p)) p[$1] = $1; if (!($2 in p)) p[$2] = $2
      ra = find($1); rb = find($2); if (ra != rb) { if (ra < rb) p[rb] = ra; else p[ra] = rb } }
    END {
      for (x in p) { r = find(x); mem[r] = mem[r] " " x }
      for (r in mem) {
        n = split(substr(mem[r], 2), a, " ")
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[i] + 0 > a[j] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
        line = a[1]; for (i = 2; i <= n; i++) line = line " " a[i]
        print line
      }
    }')"
  _tg_out=""
  while IFS= read -r _tg_grp; do
    [ -n "$_tg_grp" ] || continue
    # the group's member lists, and its candidate surfaces (non-exempt, non-empty prefix), deduped
    _tg_lists=""; _tg_cands=""
    for _tg_m in $_tg_grp; do
      _tg_ml="$(printf '%s' "$_tg_members" | awk -F'|' -v n="$_tg_m" '$1 == n { print $2; exit }')"
      _tg_lists="${_tg_lists}${_tg_ml}
"
      for _tg_e in $(printf '%s' "$_tg_ml" | tr ',' ' '); do
        [ -n "$_tg_e" ] || continue
        fp_replay_exempt "$_tg_e" && continue
        _tg_ne="$(fp_norm_entry "$_tg_e")"
        _tg_cands="${_tg_cands}${#_tg_ne} ${_tg_ne}|${_tg_e}
"
      done
    done
    # shortest prefix first (then lexicographic — determinism, not preference); "" sorts first
    # and is skipped as a surface, falling to the raw-entry rule only if nothing else exists.
    _tg_cands="$(printf '%s' "$_tg_cands" | LC_ALL=C sort -u | LC_ALL=C sort -n -k1,1 -s)"
    _tg_surface=""; _tg_first=""
    while IFS='|' read -r _tg_c _tg_raw; do
      [ -n "$_tg_c" ] || continue
      _tg_ne="${_tg_c#* }"
      if [ -z "$_tg_first" ]; then
        [ -n "$_tg_ne" ] && _tg_first="$_tg_ne" || _tg_first="$_tg_raw"
      fi
      [ -n "$_tg_ne" ] || continue
      _tg_all=1
      while IFS= read -r _tg_ml; do
        [ -n "$_tg_ml" ] || continue
        fp_conflict "$_tg_ne" "$_tg_ml" || { _tg_all=0; break; }
      done <<EOF_TG_L
$_tg_lists
EOF_TG_L
      [ "$_tg_all" = 1 ] && { _tg_surface="$_tg_ne"; break; }
    done <<EOF_TG_C
$_tg_cands
EOF_TG_C
    [ -n "$_tg_surface" ] || _tg_surface="$_tg_first"
    _tg_out="${_tg_out}${_tg_surface}|${_tg_grp}
"
  done <<EOF_TG_G
$_tg_groups
EOF_TG_G
  printf '%s' "$_tg_out" | LC_ALL=C sort -t'|' -k1,1 -k2,2n
)

# fp_theme_member <touches-list> <fix-surface-list> → 0 iff EVERY non-exempt entry of the first
# list is equal to or under (path boundary) some entry of the second — v1.3.1 delta 2's
# "intake = Touches: ⊆ fix-surface with an implicit PIN-surface allowance": replay-exempt
# entries (`fp_replay_exempt` — agents/replay/**, top-level suite pins, FSM models) are the
# allowance and are skipped, so a list made ONLY of them is a member of any surface (vacuously —
# a pin-only sprout fits every theme). An EMPTY list or the `*` sentinel returns 1: undeclared is
# exclusive, never themed. An entry with an empty prefix (leading glob) is under nothing → 1; a
# surface entry with an empty prefix covers nothing (a theme whose surface is "everything" is
# not a surface) → it is ignored.
fp_theme_member() (
  set -f
  _tm_la="$(printf '%s' "$1" | tr ',' '\n' | tr -d ' \t\r')"
  _tm_lb="$(printf '%s' "$2" | tr ',' '\n' | tr -d ' \t\r')"
  [ -n "$_tm_la" ] || return 1
  [ "$_tm_la" != "*" ] || return 1
  for _tm_a in $_tm_la; do
    [ -n "$_tm_a" ] || continue
    fp_replay_exempt "$_tm_a" && continue
    _tm_na="$(fp_norm_entry "$_tm_a")"
    [ -n "$_tm_na" ] || return 1
    _tm_ok=0
    for _tm_b in $_tm_lb; do
      [ -n "$_tm_b" ] || continue
      _tm_nb="$(fp_norm_entry "$_tm_b")"
      [ -n "$_tm_nb" ] || continue
      case "$_tm_na" in "$_tm_nb" | "$_tm_nb"/*) _tm_ok=1; break ;; esac
    done
    [ "$_tm_ok" = 1 ] || return 1
  done
  return 0
)
