#!/usr/bin/env bash
# intake-select — the deterministic half of the island intake sitting (gateway/intake.md).
#
# Lists the island's OPEN issues that nobody has ruled yet and says whether the sitting should
# fire: ≥ --min such issues, or the oldest ≥ --age-h hours. The judgment is the sitting's
# (an LLM over gateway/intake.md); this script only selects, exactly as coordinator-scan.sh
# selects units for the coordinator's clauses. bash + gh + jq + python3 (the ONE body parser,
# agents/issue_body.py — never a grep for Touches).
#
#   bash gateway/scripts/intake-select.sh [--repo teststuffstash/homelab] [--min 3] [--age-h 24] [--json]
#
# A candidate is an open issue that
#   - belongs to the island: every `Touches` entry under gateway/**, or the title starts with
#     "gateway" (any case, followed by `:`, `/` or a space) or names a GW- rule id;
#   - carries NO `agent/*` lifecycle label and is not `task/goal` (a Goal is admitted by a human,
#     breaker #1), not a `post-launch:` / `stint:` container;
#   - has no standing intake ruling: no comment whose FIRST line starts with `intake:` — a ruled
#     item is either labelled (queue/seat), closed (close/fold) or standing (comment only), and
#     the standing ones are exactly the ones this predicate skips.
#
# Output: one line per candidate `<number>\t<age_h>\t<author>\t<title>`, then a verdict line
# `fire: <reason>` or `hold: <reason>` on stderr. Exit 0 = fire, 1 = hold, 2 = a probe failed
# (an empty answer from a failed read is NOT "no candidates" — jail-subagent-card, 2026-10-26).
# --json prints the candidate array instead of the lines (the verdict line still goes to stderr).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO="teststuffstash/homelab"; MIN=3; AGE_H=24; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2;;
    --min)   MIN="$2"; shift 2;;
    --age-h) AGE_H="$2"; shift 2;;
    --json)  JSON=1; shift;;
    -h|--help) sed -n '2,25p' "$0"; exit 0;;
    *) echo "intake-select: unknown arg $1" >&2; exit 2;;
  esac
done
PARSER="$ROOT/agents/issue_body.py"
[ -f "$PARSER" ] || { echo "intake-select: $PARSER missing (run from a homelab checkout)" >&2; exit 2; }

# One list call (REST, paginated by gh); the body rides it so membership needs no second read.
issues="$(gh issue list --repo "$REPO" --state open --limit 500 \
  --json number,title,body,labels,createdAt,author,comments 2>/dev/null)" || {
  echo "intake-select: gh issue list failed for $REPO" >&2; exit 2; }
[ -n "$issues" ] || { echo "intake-select: empty answer from gh issue list (not a verdict)" >&2; exit 2; }

now="$(date -u +%s)"
cands='[]'
count="$(printf '%s' "$issues" | jq 'length')"
i=0
while [ "$i" -lt "$count" ]; do
  row="$(printf '%s' "$issues" | jq -c ".[$i]")"; i=$((i + 1))
  num="$(printf '%s' "$row" | jq -r .number)"
  title="$(printf '%s' "$row" | jq -r .title)"
  # containers and lifecycle-labelled items are never candidates
  case "$title" in post-launch:*|stint:*) continue;; esac
  if printf '%s' "$row" | jq -e '[.labels[].name | select(startswith("agent/") or . == "task/goal")] | length > 0' >/dev/null; then
    continue
  fi
  # membership: the title, else the block's Touches (every entry under gateway/)
  member=0
  if printf '%s' "$title" | grep -qiE '^gateway([:/ ]|$)|\bGW-[A-Z]'; then
    member=1
  else
    touches="$(printf '%s' "$row" | jq -r '.body // ""' | python3 "$PARSER" get Touches --ref "${REPO}#${num}" 2>/dev/null || true)"
    if [ -n "$touches" ]; then
      member=1
      for p in $(printf '%s' "$touches" | tr ',' ' '); do
        case "$p" in gateway/*) ;; *) member=0; break;; esac
      done
    fi
  fi
  [ "$member" = 1 ] || continue
  # a standing ruling: a comment whose first line starts with `intake:`
  if printf '%s' "$row" | jq -e '[.comments[]? | .body | split("\n")[0] | select(startswith("intake:"))] | length > 0' >/dev/null; then
    continue
  fi
  created="$(printf '%s' "$row" | jq -r .createdAt)"
  cts="$(date -u -d "$created" +%s 2>/dev/null || echo "$now")"
  age_h=$(( (now - cts) / 3600 ))
  cands="$(printf '%s' "$cands" | jq -c --argjson n "$num" --argjson a "$age_h" \
    --arg t "$title" --arg au "$(printf '%s' "$row" | jq -r '.author.login')" \
    '. + [{number: $n, age_h: $a, author: $au, title: $t}]')"
done

n="$(printf '%s' "$cands" | jq 'length')"
oldest="$(printf '%s' "$cands" | jq '[.[].age_h] | max // 0')"
if [ "$JSON" = 1 ]; then
  printf '%s\n' "$cands" | jq .
else
  printf '%s' "$cands" | jq -r '.[] | "\(.number)\t\(.age_h)h\t\(.author)\t\(.title)"'
fi
if [ "$n" -ge "$MIN" ]; then
  echo "fire: $n unruled island issues (min $MIN)" >&2; exit 0
elif [ "$n" -gt 0 ] && [ "$oldest" -ge "$AGE_H" ]; then
  echo "fire: oldest unruled island issue is ${oldest}h (≥ ${AGE_H}h)" >&2; exit 0
else
  echo "hold: $n unruled island issues, oldest ${oldest}h" >&2; exit 1
fi
