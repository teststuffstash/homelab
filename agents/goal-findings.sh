#!/usr/bin/env bash
# goal-findings — the ADR-106 (3) FINDINGS STORE, one typed machine comment per Goal issue.
# THE ONE HOME of the store format: the scan counts through these fns (checkpoint trigger), the
# coordinator session appends/advances through the CLI verbs, and nothing else parses the shape.
#
#   bash agents/goal-findings.sh append  <owner/repo> <goal-n> "origin=#N surface=<p> class=<c> — <substance>"
#   bash agents/goal-findings.sh counts  <owner/repo> <goal-n>     # → "total dispositioned"
#   bash agents/goal-findings.sh advance <owner/repo> <goal-n> <N> # marker → N (checkpoint close)
#   bash agents/goal-findings.sh burndown <owner/repo> <goal-n> "<open> open / <closed> closed of <total> descendants"
#   bash agents/goal-findings.sh rule    <owner/repo> <goal-n> <entry-n> "<verb> → <target> — <reason>"   # ⇒ suffix on entry n
#   bash agents/goal-findings.sh checkpoint <owner/repo> <goal-n> "<ISO ts> (<trigger>) <outcome>"   # the last-checkpoint: line
#   bash agents/goal-findings.sh --self-test
#
# Shape (a single issue comment, edited in place — ADR-103: ONE machine comment, no per-event
# timeline residue; harvest APPENDS, never mints; checkpoints consume — glossary "findings store"):
#   <!-- goal-findings v1 -->
#   dispositioned-through: 0
#   burn-down: —
#   last-checkpoint: 2026-09-22T21:54:00Z (a+c) 1 minted · 3 dropped · 1 deferred
#   1. origin=#123 surface=agents/replay class=fold — <one line of substance> ⇒ fold → #456 — already in review
#
# The `rule` suffix and the `last-checkpoint:` line ARE the checkpoint's write-back (2026-09-23,
# operator): a ruling is a store row, not a prose comment. Twelve checkpoint rulings on Goal
# #1640 averaged 6 KB each — 70 KB of re-derived evidence nobody read — and four of them ruled
# one row or nothing. The store is bounded by the Goal's real size (members + findings); a
# ride that changes nothing edits ONE header line in place, so the timeline does not grow.
#
# Fail-closed everywhere (rule #6): an unreadable store is "" counts, never invented zeros that
# would arm or disarm a checkpoint; a failed edit is loud and leaves the old comment intact.
set -euo pipefail

MARK='<!-- goal-findings v1 -->'

_gf_comments() {   # $1 slug, $2 issue → full comments json (id+body) or ""
  # --paginate alone emits back-to-back JSON documents (one per page), unparseable past 100
  # comments; --slurp wraps pages in an outer array for safe parsing. Flatten one level if
  # all outer elements are arrays (the multi-page slurped case [[page1],[page2],...]), else
  # pass through unchanged (the single-page or recorded-world shape [comment, comment, ...]).
  local raw; raw="$(gh api "repos/$1/issues/$2/comments?per_page=100" --paginate --slurp 2>/dev/null)" || raw=""
  printf '%s' "$raw" | jq -c 'if type == "array" and (. | length > 0) and (.[0] | type == "array") then [.[] | .[] | select(type == "object")] else . end' 2>/dev/null || echo ""
}

GF_ID=""; GF_BODY=""
_gf_find() {   # $1 slug, $2 issue [, $3 pre-fetched comments json] → 0 = found (GF_ID/GF_BODY set);
  # 1 = confirmed ABSENT (read ok, no store comment); 2 = UNREADABLE. The 1-vs-2 split is
  # load-bearing (bot review, PR#398 r2): a writer that treats a blind read as "absent"
  # CREATES a second store comment on a transient API failure — the exact ONE-machine-comment
  # invariant (ADR-103) this file exists to hold. $3 allows the goal lane to pass comments
  # already fetched for epic_dispositions, folding two reads into one (FU-084, #1439).
  # Two jq passes over one fetch, NOT @tsv: tsv escapes embedded newlines to literal \n, which
  # flattened every real multi-line store into one unparseable line — counts read 0/0 and the
  # burn-down compare always missed (caught by the goal-checkpoint-due fixture, 2026-08-12).
  GF_ID=""; GF_BODY=""
  local js; js="${3:-}"; [ -n "$js" ] || js="$(_gf_comments "$1" "$2")" || js=""
  [ -n "$js" ] || return 2
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"${js:-null}" || return 2
  GF_ID="$(printf '%s' "$js" | jq -r --arg m "$MARK" \
    '[.[] | select((.body // "") | startswith($m))] | first // empty | .id' 2>/dev/null)" || GF_ID=""
  [ -n "$GF_ID" ] || return 1   # read OK, no store → confirmed absent
  GF_BODY="$(printf '%s' "$js" | jq -r --arg m "$MARK" \
    '[.[] | select((.body // "") | startswith($m))] | first.body' 2>/dev/null)" || { GF_ID=""; return 2; }
  return 0
}

_gf_put() {   # $1 slug, $2 comment-id ('' = create on issue $3), $3 issue, body on stdin
  local body; body="$(cat)"
  if [ -n "$2" ]; then
    gh api -X PATCH "repos/$1/issues/comments/$2" -f body="$body" >/dev/null
  else
    gh api -X POST "repos/$1/issues/$3/comments" -f body="$body" >/dev/null
  fi
}

_gf_empty_body() {
  printf '%s\ndispositioned-through: 0\nburn-down: —\n' "$MARK"
}

gf_parse_counts() {   # store body on stdin → "total dispositioned" — THE one parse of the shape
  awk '
    /^[0-9]+\. / { n = $1 + 0 }
    /^dispositioned-through:/ { d = $2 + 0 }
    END { printf "%d %d\n", n, d }'
}

gf_counts() {   # $1 slug, $2 issue → "total dispositioned" ("" on unreadable — caller must gate)
  _gf_find "$1" "$2" || { echo ""; return 0; }
  printf '%s\n' "$GF_BODY" | gf_parse_counts
}

gf_append() {   # $1 slug, $2 issue, $3 entry-line (no leading number)
  local id body next _rc
  _gf_find "$1" "$2" && _rc=0 || _rc=$?
  case "$_rc" in
    0) id="$GF_ID"; body="$GF_BODY";;
    1) id=""; body="$(_gf_empty_body)";;
    *) echo "goal-findings: comments UNREADABLE for ${1}#${2} — refusing to append (a create on a blind read risks a SECOND store; ADR-103)" >&2; return 1;;
  esac
  next="$(printf '%s\n' "$body" | awk '/^[0-9]+\. /{n=$1+0} END{print n+1}')"
  printf '%s\n%s. %s\n' "$body" "$next" "$3" | _gf_put "$1" "$id" "$2"
  echo "goal-findings: appended entry ${next} to ${1}#${2}"
}

gf_advance() {   # $1 slug, $2 issue, $3 new marker value
  local id body
  _gf_find "$1" "$2" || { echo "goal-findings: no store on ${1}#${2} — nothing to advance" >&2; return 1; }
  id="$GF_ID"; body="$GF_BODY"
  printf '%s\n' "$body" | awk -v n="$3" '{ if ($0 ~ /^dispositioned-through:/) print "dispositioned-through: " n; else print }' \
    | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} dispositioned-through → ${3}"
}

gf_burndown() {   # $1 slug, $2 issue, $3 text [, $4 id, $5 body — pre-fetched: skips the re-GET
  # (the goal lane already holds GF_ID/GF_BODY from its own read; a second identical comments GET
  # per changed tick is pure FU-084 API-pool burn — bot review, PR#398)]
  local id body
  if [ $# -ge 5 ] && [ "$4" = "-" ]; then id=""; body="$(_gf_empty_body)"   # cached: store known absent → create, no re-GET
  elif [ $# -ge 5 ] && [ -n "$4" ]; then id="$4"; body="$5"
  else
    local _rc; _gf_find "$1" "$2" && _rc=0 || _rc=$?
    case "$_rc" in
      0) id="$GF_ID"; body="$GF_BODY";;
      1) id=""; body="$(_gf_empty_body)";;
      *) echo "goal-findings: comments UNREADABLE for ${1}#${2} — burn-down skipped (no blind create; ADR-103)" >&2; return 1;;
    esac
  fi
  printf '%s\n' "$body" | awk -v t="$3" '{ if ($0 ~ /^burn-down:/) print "burn-down: " t; else print }' \
    | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} burn-down updated"
}

gf_rule() {   # $1 slug, $2 issue, $3 entry number, $4 ruling text → "N. … ⇒ <ruling>" (replaces an earlier ⇒)
  local id body n
  case "${3:-}" in ''|*[!0-9]*) echo "goal-findings: rule needs a numeric entry, got '${3:-}'" >&2; return 1;; esac
  [ -n "${4:-}" ] || { echo "goal-findings: rule needs a ruling text" >&2; return 1; }
  _gf_find "$1" "$2" || { echo "goal-findings: no store on ${1}#${2} — nothing to rule" >&2; return 1; }
  id="$GF_ID"; body="$GF_BODY"
  n="$(printf '%s\n' "$body" | awk -v n="$3" '$0 ~ ("^" n "\\. ") {c++} END{print c+0}')"
  [ "$n" -eq 1 ] || { echo "goal-findings: entry ${3} not found (or not unique) on ${1}#${2}" >&2; return 1; }
  printf '%s\n' "$body" | awk -v n="$3" -v r="$4" '
    $0 ~ ("^" n "\\. ") { sub(/ ⇒ .*$/, ""); print $0 " ⇒ " r; next }
    { print }' | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} entry ${3} ⇒ ${4}"
}

gf_checkpoint() {   # $1 slug, $2 issue, $3 text → the ONE `last-checkpoint:` header line, replaced in place
  local id body
  [ -n "${3:-}" ] || { echo "goal-findings: checkpoint needs a text" >&2; return 1; }
  _gf_find "$1" "$2" || { echo "goal-findings: no store on ${1}#${2} — nothing to stamp" >&2; return 1; }
  id="$GF_ID"; body="$GF_BODY"
  printf '%s\n' "$body" | gf_stamp_checkpoint "$3" | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} last-checkpoint → ${3}"
}

gf_stamp_checkpoint() {   # store body on stdin, $1 text → body with the header line replaced or inserted after burn-down:
  awk -v t="$1" '
    /^last-checkpoint:/ { if (!done) { print "last-checkpoint: " t; done = 1 }; next }
    { print }
    /^burn-down:/ && !done { print "last-checkpoint: " t; done = 1 }'
}

_gf_self_test() {
  # Pure-parse checks over a fixture body — no network, no credential.
  local body counts
  body="$(_gf_empty_body)"
  body="$(printf '%s\n1. origin=#12 surface=a class=fold — x\n2. origin=#13 surface=b class=child — y\n' "$body")"
  counts="$(printf '%s\n' "$body" | gf_parse_counts)"   # THE parse — a hand copy here is how the helper and its test silently diverge (bot review, PR#398 r2)
  [ "$counts" = "2 0" ] || { echo "self-test: counts parse got '$counts' want '2 0'" >&2; return 1; }
  next="$(printf '%s\n' "$body" | awk '/^[0-9]+\. /{n=$1+0} END{print n+1}')"
  [ "$next" = "3" ] || { echo "self-test: next-entry got '$next' want 3" >&2; return 1; }
  adv="$(printf '%s\n' "$body" | awk -v n=2 '{ if ($0 ~ /^dispositioned-through:/) print "dispositioned-through: " n; else print }' | grep -c '^dispositioned-through: 2$')"
  [ "$adv" = "1" ] || { echo "self-test: advance rewrite failed" >&2; return 1; }
  # rule: the ⇒ suffix lands on the numbered entry only, and a second ruling REPLACES the first
  ruled="$(printf '%s\n' "$body" | awk -v n=2 -v r="fold → #9 — already filed" '$0 ~ ("^" n "\\. ") { sub(/ ⇒ .*$/, ""); print $0 " ⇒ " r; next } { print }')"
  [ "$(printf '%s\n' "$ruled" | grep -c ' ⇒ ')" = "1" ] || { echo "self-test: rule suffix count wrong" >&2; return 1; }
  printf '%s\n' "$ruled" | grep -q '^2\. origin=#13 surface=b class=child — y ⇒ fold → #9 — already filed$' || { echo "self-test: rule suffix not on entry 2" >&2; return 1; }
  reruled="$(printf '%s\n' "$ruled" | awk -v n=2 -v r="mint → #77" '$0 ~ ("^" n "\\. ") { sub(/ ⇒ .*$/, ""); print $0 " ⇒ " r; next } { print }')"
  printf '%s\n' "$reruled" | grep -q '^2\. origin=#13 surface=b class=child — y ⇒ mint → #77$' || { echo "self-test: re-rule did not replace" >&2; return 1; }
  [ "$(printf '%s\n' "$reruled" | gf_parse_counts)" = "2 0" ] || { echo "self-test: a ruled entry still counts once" >&2; return 1; }
  # checkpoint: inserted after burn-down: on first stamp, replaced in place on the next, never a second line
  st1="$(printf '%s\n' "$body" | gf_stamp_checkpoint "2026-09-23T06:00:00Z (c) no change")"
  [ "$(printf '%s\n' "$st1" | grep -c '^last-checkpoint:')" = "1" ] || { echo "self-test: checkpoint stamp missing" >&2; return 1; }
  printf '%s\n' "$st1" | sed -n '4p' | grep -q '^last-checkpoint: 2026-09-23T06:00:00Z (c) no change$' || { echo "self-test: checkpoint line not after burn-down:" >&2; return 1; }
  st2="$(printf '%s\n' "$st1" | gf_stamp_checkpoint "2026-09-23T07:00:00Z (a) 2 minted")"
  [ "$(printf '%s\n' "$st2" | grep -c '^last-checkpoint:')" = "1" ] || { echo "self-test: checkpoint re-stamp grew a second line" >&2; return 1; }
  printf '%s\n' "$st2" | grep -q '^last-checkpoint: 2026-09-23T07:00:00Z (a) 2 minted$' || { echo "self-test: checkpoint re-stamp did not replace" >&2; return 1; }
  [ "$(printf '%s\n' "$st2" | gf_parse_counts)" = "2 0" ] || { echo "self-test: the header line disturbed the counts parse" >&2; return 1; }
  echo "goal-findings self-test: OK (counts, append numbering, advance rewrite, rule suffix, checkpoint stamp)"
}

# Source-guard: the scan sources this file for the fns (checkpoint counts, burn-down); the CLI
# dispatcher must not eat the sourcing script's $1 (--spawn would exit 2 here).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    append)   shift; gf_append "$@";;
    counts)   shift; gf_counts "$@";;
    advance)  shift; gf_advance "$@";;
    burndown) shift; gf_burndown "$@";;
    rule)     shift; gf_rule "$@";;
    checkpoint) shift; gf_checkpoint "$@";;
    --self-test) _gf_self_test;;
    *) echo "usage: goal-findings.sh append|counts|advance|burndown|--self-test ..." >&2; exit 2;;
  esac
fi
