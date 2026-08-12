# machine-comment.sh — the ONE machine channel on an issue/PR timeline (ADR-103 rule 2, homelab#210).
#
# THE BAR ADR-103 SETS: a new PR shows the review verdict plus at most ONE machine comment. The
# 2026-08-09 census found ~2/3 of issue-timeline comments on oracle-fleet/circles were machine
# residue, and the two biggest per-PR offenders were the run-stats table and the dispatch notice —
# each of which posted a NEW comment per round. This file is where that stops being a convention
# and becomes a callable.
#
# TWO SURFACES, and which one a fact belongs on is decided by who reads it:
#
#   mc_event      → one line appended to the single `<!-- agent-summary -->` comment. The INDEX: a
#                   human scanning the timeline sees one comment that grew, not six that piled up.
#                   Edit-in-place, append-only content — history is preserved INSIDE the comment,
#                   never by adding another one.
#   mc_check_run  → the `agent-ride` check-run on a head SHA, `neutral`, markdown in its output.
#                   The DETAIL (the run-stats table, the cost line, the transcripts pointer). It
#                   lands in the PR's checks tab, which is where a reviewer already looks and where
#                   nothing is competing with human conversation. Chosen over a commit status on
#                   #210's ⚖ line: a status carries no markdown body.
#
# NOTHING HERE IS A STORE. `AGENT_STRIKE:` comments and the `state-fp:` debounce marker are
# load-bearing state that other clauses GREP, and they stay ordinary comments until a replay-first
# issue moves them (explicitly out of scope on #210). This helper is for residue only — if a reader
# would break when the line moves, the line is not residue.
#
# READERS OF THE SUMMARY COMMENT. The appended entry carries a machine marker:
#
#   <!-- agent-event kind=<kind> ts=<iso8601> -->
#
# invisible in rendered markdown, and the thing coordinator-scan.sh's round counter keys on now that
# a completed round no longer means "one more comment". Keep that marker's shape STABLE — it is the
# machine interface, exactly as the `AGENT_STRIKE:` first line is.
#
# REST only (`repos/{slug}/issues/{n}/comments`), never the GraphQL pool — the reflex lesson of
# 2026-07-17, and the same rule meta-throughput.sh states. A PR's conversation comments ARE issue
# comments, so one endpoint serves both sides and `mc_event` needs no pr/issue switch.
#
# FOUR I/O SEAMS, on purpose — `mc_gh_comments`, `mc_gh_comment_create`, `mc_gh_comment_patch`,
# `mc_gh_check_post`, plus `mc_now` for the clock. Plain functions a caller may redefine, which is
# how agents/replay/fixtures/summary-comment-* replay the real find-or-create arithmetic against a
# recorded world with no network and no wall clock in the action stream (agents/replay/README.md
# §When a clause depends on a sourced helper).

# The contract marker. One comment per timeline carries it; every later event edits THAT comment.
MC_MARKER='<!-- agent-summary -->'

# ── seams ───────────────────────────────────────────────────────────────────────────────────────
# `--paginate` with no per_page: the query string would otherwise ride the URL positional and every
# replay world file would have to be named after it. Default page size + Link-following is correct
# and keeps the recorded key the bare path.
mc_gh_comments() {   # mc_gh_comments <slug> <number> → the comment array on stdout
  gh api "repos/$1/issues/$2/comments" --paginate 2>/dev/null
}

mc_gh_comment_create() {   # mc_gh_comment_create <slug> <number> <body>
  gh api --method POST "repos/$1/issues/$2/comments" -f body="$3" >/dev/null 2>&1
}

# The comment id is REST-numeric (`.id`), never the GraphQL node id `gh issue view --json comments`
# hands back — the two are not interchangeable on this endpoint and a node id 404s here.
mc_gh_comment_patch() {   # mc_gh_comment_patch <slug> <comment-id> <body>
  gh api --method PATCH "repos/$1/issues/comments/$2" -f body="$3" >/dev/null 2>&1
}

# Check-runs are an App-only endpoint: a classic PAT gets 403 no matter its scopes. That is not a
# failure to route around — it is the reason mc_check_run REPORTS instead of exiting, and the reason
# every caller has a degrade path (see mc_event's use in agent-session.sh).
mc_gh_check_post() {   # mc_gh_check_post <slug> <sha> <title> <summary>
  gh api --method POST "repos/$1/check-runs" \
    -f name=agent-ride -f head_sha="$2" -f status=completed -f conclusion=neutral \
    -f "output[title]=$3" -f "output[summary]=$4" >/dev/null 2>&1
}

mc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── mc_event ────────────────────────────────────────────────────────────────────────────────────
# Find-or-create, then APPEND. Deliberately not "replace": the round-2 line must not erase round 1,
# because the round counter reads how many stats markers a PR carries and a replacing writer would
# hand the ci-red clause a permanent attempts=1 — the livelock RED_ROUNDS_MAX exists to bound.
#
# Ties break on the OLDEST marked comment. If a second summary comment ever appears (a race, a
# human paste), every subsequent event converges back onto the first one rather than alternating.
#
# Returns 0 when the timeline now carries the line, 1 when the write was refused. A refused write is
# never fatal here — this is bookkeeping, and no caller may lose its real work over a comment.
mc_event() {   # mc_event <slug> <number> <kind> <line-markdown>
  local slug="$1" num="$2" kind="$3" line="$4"
  local ts entry listed id body
  ts="$(mc_now)"
  entry="- \`${ts}\` · ${line} <!-- agent-event kind=${kind} ts=${ts} -->"

  listed="$(mc_gh_comments "$slug" "$num")" || listed=''
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${listed:-null}"; then   # :-null — jq 1.6 exits 0 on EMPTY input, inverting the guard (homelab#377)
    # Unreadable timeline. Creating a comment here is the one thing that must NOT happen: a probe
    # failure would mint a second summary comment on every event, which is the exact residue this
    # file exists to end. Fail closed and say so.
    printf 'mc_event: could not read comments on %s#%s — no summary line written\n' "$slug" "$num" >&2
    return 1
  fi
  id="$(printf '%s' "$listed" | jq -r --arg m "$MC_MARKER" \
        '[ .[] | select((.body // "") | contains($m)) ] | sort_by(.created_at) | .[0].id // empty' 2>/dev/null)" || id=''

  if [ -n "$id" ]; then
    body="$(printf '%s' "$listed" | jq -r --argjson i "$id" '.[] | select(.id == $i) | .body')"
    mc_gh_comment_patch "$slug" "$id" "$(printf '%s\n%s' "$body" "$entry")"
  else
    mc_gh_comment_create "$slug" "$num" "$(printf '%s\n%s\n\n%s' \
      "$MC_MARKER" \
      "🤖 **Agent activity** — one machine comment per timeline, appended in place (ADR-103). Run detail lives in the \`agent-ride\` check-run, the ledger and \`s3://agent-transcripts/\`; this is the index." \
      "$entry")"
  fi
}

# ── mc_check_run ────────────────────────────────────────────────────────────────────────────────
# `neutral`: an informational check must never colour a PR's mergeability. It is not a required
# context and carries no verdict — the reviewer's verdict is the verdict.
#
# One POST per round, not an update of the previous one. A no-op round re-posts on the SAME head
# SHA, and keeping both is the honest record: two rides happened, and the checks tab shows two.
mc_check_run() {   # mc_check_run <slug> <sha> <title> <summary-markdown>
  [ -n "${2:-}" ] || { printf 'mc_check_run: no head SHA — check-run skipped\n' >&2; return 1; }
  mc_gh_check_post "$1" "$2" "$3" "$4"
}

# https://github.com/OWNER/REPO/pull/N → OWNER/REPO. The launcher holds a PR URL, the API wants a
# slug, and deriving it beats threading a second variable through the bookkeeping leg.
mc_slug_from_url() {   # mc_slug_from_url <pr-url>
  printf '%s' "$1" | sed -n 's#^https\{0,1\}://[^/]*/\([^/]\{1,\}/[^/]\{1,\}\)/\(pull\|issues\)/[0-9]\{1,\}.*#\1#p'
}

# ── CLI ─────────────────────────────────────────────────────────────────────────────────────────
# Sourceable AND runnable. The coordinator brief's dispatch notice is followed by a session driving
# a shell, not by a script that can source a library, so the same find-or-create has to be one
# command it can copy (agents/coordinator/README.md step 2).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  mc_cmd="${1:-}"; shift 2>/dev/null || true
  mc_repo=''; mc_num=''; mc_kind='note'; mc_line=''; mc_sha=''; mc_title=''; mc_summary=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)    mc_repo="$2"; shift 2 ;;
      --number)  mc_num="$2"; shift 2 ;;
      --kind)    mc_kind="$2"; shift 2 ;;
      --line)    mc_line="$2"; shift 2 ;;
      --sha)     mc_sha="$2"; shift 2 ;;
      --title)   mc_title="$2"; shift 2 ;;
      --summary) mc_summary="$2"; shift 2 ;;
      *) printf 'machine-comment.sh: unknown flag %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  case "$mc_cmd" in
    event)
      [ -n "$mc_repo" ] && [ -n "$mc_num" ] && [ -n "$mc_line" ] \
        || { printf 'usage: machine-comment.sh event --repo <owner/repo> --number <n> [--kind <k>] --line <markdown>\n' >&2; exit 2; }
      mc_event "$mc_repo" "$mc_num" "$mc_kind" "$mc_line" ;;
    check-run)
      [ -n "$mc_repo" ] && [ -n "$mc_sha" ] && [ -n "$mc_summary" ] \
        || { printf 'usage: machine-comment.sh check-run --repo <owner/repo> --sha <sha> [--title <t>] --summary <markdown>\n' >&2; exit 2; }
      mc_check_run "$mc_repo" "$mc_sha" "${mc_title:-agent ride}" "$mc_summary" ;;
    *) printf 'usage: machine-comment.sh {event|check-run} …\n' >&2; exit 2 ;;
  esac
fi
