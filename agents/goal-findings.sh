#!/usr/bin/env bash
# goal-findings — the ADR-106 (3) FINDINGS STORE, one typed machine comment per Goal issue.
# THE ONE HOME of the store format: the scan counts through these fns (checkpoint trigger), the
# coordinator session appends/advances through the CLI verbs, and nothing else parses the shape.
#
#   bash agents/goal-findings.sh append  <owner/repo> <goal-n> "origin=#N surface=<p> class=<c> — <substance>"
#   bash agents/goal-findings.sh counts  <owner/repo> <goal-n>     # → "total dispositioned"
#   bash agents/goal-findings.sh advance <owner/repo> <goal-n> <N> # marker → N (checkpoint close)
#   bash agents/goal-findings.sh burndown <owner/repo> <goal-n> "<open> open / <closed> closed of <total> descendants"
#   bash agents/goal-findings.sh --self-test
#
# Shape (a single issue comment, edited in place — ADR-103: ONE machine comment, no per-event
# timeline residue; harvest APPENDS, never mints; checkpoints consume — glossary "findings store"):
#   <!-- goal-findings v1 -->
#   dispositioned-through: 0
#   burn-down: —
#   1. origin=#123 surface=agents/replay class=fold — <one line of substance>
#
# Fail-closed everywhere (rule #6): an unreadable store is "" counts, never invented zeros that
# would arm or disarm a checkpoint; a failed edit is loud and leaves the old comment intact.
set -euo pipefail

MARK='<!-- goal-findings v1 -->'

_gf_comments() {   # $1 slug, $2 issue → full comments json (id+body) or ""
  gh api "repos/$1/issues/$2/comments?per_page=100" --paginate 2>/dev/null || true
}

_gf_find() {   # $1 slug, $2 issue → "id<TAB>body" of the store comment, or empty
  _gf_comments "$1" "$2" | jq -r --arg m "$MARK" \
    '[.[] | select((.body // "") | startswith($m))] | first // empty | [(.id|tostring), .body] | @tsv' 2>/dev/null || true
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

gf_counts() {   # $1 slug, $2 issue → "total dispositioned" ("" on unreadable — caller must gate)
  local row body
  row="$(_gf_find "$1" "$2")" || row=""
  [ -n "$row" ] || { echo ""; return 0; }
  body="${row#*	}"
  printf '%s\n' "$body" | awk '
    /^[0-9]+\. / { n = $1 + 0 }
    /^dispositioned-through:/ { d = $2 + 0 }
    END { printf "%d %d\n", n, d }'
}

gf_append() {   # $1 slug, $2 issue, $3 entry-line (no leading number)
  local row id body next
  row="$(_gf_find "$1" "$2")" || row=""
  if [ -n "$row" ]; then id="${row%%	*}"; body="${row#*	}"; else id=""; body="$(_gf_empty_body)"; fi
  next="$(printf '%s\n' "$body" | awk '/^[0-9]+\. /{n=$1+0} END{print n+1}')"
  printf '%s\n%s. %s\n' "$body" "$next" "$3" | _gf_put "$1" "$id" "$2"
  echo "goal-findings: appended entry ${next} to ${1}#${2}"
}

gf_advance() {   # $1 slug, $2 issue, $3 new marker value
  local row id body
  row="$(_gf_find "$1" "$2")" || row=""
  [ -n "$row" ] || { echo "goal-findings: no store on ${1}#${2} — nothing to advance" >&2; return 1; }
  id="${row%%	*}"; body="${row#*	}"
  printf '%s\n' "$body" | awk -v n="$3" '{ if ($0 ~ /^dispositioned-through:/) print "dispositioned-through: " n; else print }' \
    | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} dispositioned-through → ${3}"
}

gf_burndown() {   # $1 slug, $2 issue, $3 burn-down text — the demoted goal-review's whole write
  local row id body
  row="$(_gf_find "$1" "$2")" || row=""
  if [ -n "$row" ]; then id="${row%%	*}"; body="${row#*	}"; else id=""; body="$(_gf_empty_body)"; fi
  printf '%s\n' "$body" | awk -v t="$3" '{ if ($0 ~ /^burn-down:/) print "burn-down: " t; else print }' \
    | _gf_put "$1" "$id" "$2"
  echo "goal-findings: ${1}#${2} burn-down updated"
}

_gf_self_test() {
  # Pure-parse checks over a fixture body — no network, no credential.
  local body counts
  body="$(_gf_empty_body)"
  body="$(printf '%s\n1. origin=#12 surface=a class=fold — x\n2. origin=#13 surface=b class=child — y\n' "$body")"
  counts="$(printf '%s\n' "$body" | awk '
    /^[0-9]+\. / { n = $1 + 0 }
    /^dispositioned-through:/ { d = $2 + 0 }
    END { printf "%d %d\n", n, d }')"
  [ "$counts" = "2 0" ] || { echo "self-test: counts parse got '$counts' want '2 0'" >&2; return 1; }
  next="$(printf '%s\n' "$body" | awk '/^[0-9]+\. /{n=$1+0} END{print n+1}')"
  [ "$next" = "3" ] || { echo "self-test: next-entry got '$next' want 3" >&2; return 1; }
  adv="$(printf '%s\n' "$body" | awk -v n=2 '{ if ($0 ~ /^dispositioned-through:/) print "dispositioned-through: " n; else print }' | grep -c '^dispositioned-through: 2$')"
  [ "$adv" = "1" ] || { echo "self-test: advance rewrite failed" >&2; return 1; }
  echo "goal-findings self-test: OK (counts, append numbering, advance rewrite)"
}

# Source-guard: the scan sources this file for the fns (checkpoint counts, burn-down); the CLI
# dispatcher must not eat the sourcing script's $1 (--spawn would exit 2 here).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    append)   shift; gf_append "$@";;
    counts)   shift; gf_counts "$@";;
    advance)  shift; gf_advance "$@";;
    burndown) shift; gf_burndown "$@";;
    --self-test) _gf_self_test;;
    *) echo "usage: goal-findings.sh append|counts|advance|burndown|--self-test ..." >&2; exit 2;;
  esac
fi
