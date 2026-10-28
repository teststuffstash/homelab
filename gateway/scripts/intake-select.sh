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
#
# --source dig (FU-320, the first wired source — agents/coordinator/island-intake-argo.yaml runs it):
# the island's inputs are the deep dig's `cause-found` findings (docs/agents/roles.md §deep dig)
# whose text names the island, not yet ruled by an earlier APPLY sitting. They become the sitting's
# `text:` inputs (`source: dig`), so the dig itself files nothing and intake stays the island's one
# admission — dedup (step 2's `fold`) happens BEFORE anything is filed.
#
#   bash gateway/scripts/intake-select.sh --source dig [--island gateway] [--out sel.json]
#
#   inputs    = homelab/dig-<date>/<run>/finding-N.json over INTAKE_DIG_LOOKBACK_D days, verdict in
#               INTAKE_DIG_VERDICTS, text matching the island's pattern (island_pattern below)
#   ruled     = every input id an earlier APPLY receipt lists with an outcome other than `deferred`
#               (homelab/intake-<island>-<date>/<run>/receipt.json — the receipt is the ledger, the
#               way the dig's own findings are its re-dig key; the bucket is read with the READER key)
#   cap       = INTAKE_DAILY_MAX apply sittings per UTC day (the responder's daily-cap shape, counted
#               from the same receipts) — the lane's spend is a budget knob, not a code change
#   fire      = ≥ 1 unruled input and the cap not reached; else hold
# Exit 0 = fire, 1 = hold, 2 = a probe failed: an unreadable bucket is NEVER "no inputs" (it would
# also be "nothing ruled", i.e. the same findings fed again every day). Seam: INTAKE_TS_DIR = a local
# directory laid out like the bucket (<dir>/homelab/dig-…, <dir>/homelab/intake-…) served instead
# of S3 — gateway/scripts/intake-select-test.sh and a jail run use it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPO="teststuffstash/homelab"; MIN=3; AGE_H=24; JSON=0; SOURCE=issues; ISLAND=gateway; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2;;
    --island) ISLAND="$2"; shift 2;;
    --out)   OUT="$2"; shift 2;;
    --repo)  REPO="$2"; shift 2;;
    --min)   MIN="$2"; shift 2;;
    --age-h) AGE_H="$2"; shift 2;;
    --json)  JSON=1; shift;;
    -h|--help) sed -n '2,45p' "$0"; exit 0;;
    *) echo "intake-select: unknown arg $1" >&2; exit 2;;
  esac
done

# ── --source dig ─────────────────────────────────────────────────────────────────────────────────
# The island's text pattern: what a finding must name to be this island's. One row per island; a
# new island adds a row here and an §Island facts block to its brief.
island_pattern() {
  case "$1" in
    gateway) printf '%s' 'gateway/|agent-gateway|GW-[A-Z]';;
    *) return 1;;
  esac
}
TS_BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
TS_ENDPOINT="${AGENT_TS_ENDPOINT:-http://garage.garage.svc.cluster.local:3900}"
_s5() { AWS_ACCESS_KEY_ID="${AGENT_TS_READER_ID:-}" AWS_SECRET_ACCESS_KEY="${AGENT_TS_READER_SECRET:-}" AWS_REGION=garage \
          s5cmd --endpoint-url "$TS_ENDPOINT" "$@"; }
# <prefix under homelab/> <file glob> → one JSON object per line, each stamped with `_key` (the
# object's path under homelab/). Bucket rows are `<date> <time> <size> <key>`; the key column may be
# relative to the listed prefix or full, so the path is rebuilt from the `<run>/<file>` tail.
ts_read_objects() {
  local prefix="$1" glob="$2" f rel
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    for f in "$INTAKE_TS_DIR"/homelab/$prefix/*/$glob; do
      [ -f "$f" ] || continue
      rel="${f#"$INTAKE_TS_DIR"/homelab/}"
      jq -c --arg k "$rel" '. + {_key: $k}' "$f" 2>/dev/null || echo "intake-select: unparseable $rel — skipped" >&2
    done
    return 0
  fi
  _s5 ls "s3://$TS_BUCKET/homelab/$prefix/*" 2>/dev/null | awk '{print $NF}' \
    | grep -E "/${glob//\*/[^/]*}\$" | sed -E 's#^.*/([^/]+/[^/]+)$#\1#' | sort -u \
    | while read -r rel; do
        _s5 cat "s3://$TS_BUCKET/homelab/$prefix/$rel" 2>/dev/null \
          | jq -c --arg k "$prefix/$rel" '. + {_key: $k}' 2>/dev/null \
          || echo "intake-select: unreadable $prefix/$rel — skipped" >&2
      done
}
cmd_dig() {
  local pat now lookback verdicts dmax d k findings receipts sel n today sittings
  pat="$(island_pattern "$ISLAND")" || { echo "intake-select: no dig pattern for island '$ISLAND'" >&2; exit 2; }
  now="${INTAKE_NOW:-$(date -u +%s)}"; lookback="${INTAKE_DIG_LOOKBACK_D:-7}"
  verdicts="${INTAKE_DIG_VERDICTS:-cause-found}"; dmax="${INTAKE_DAILY_MAX:-2}"
  # Positive control first (rule #6): a listing of the prefix that FAILS is not an empty prefix.
  if [ -n "${INTAKE_TS_DIR:-}" ]; then
    [ -d "$INTAKE_TS_DIR/homelab" ] || { echo "intake-select: INTAKE_TS_DIR has no homelab/ — probe failed" >&2; exit 2; }
  else
    [ -n "${AGENT_TS_READER_ID:-}" ] || { echo "intake-select: no bucket READER key — cannot read findings or receipts (fail-closed)" >&2; exit 2; }
    command -v s5cmd >/dev/null 2>&1 || { echo "intake-select: s5cmd missing" >&2; exit 2; }
    _s5 ls "s3://$TS_BUCKET/homelab/" >/dev/null 2>&1 || { echo "intake-select: bucket listing failed ($TS_ENDPOINT) — probe failed" >&2; exit 2; }
  fi
  findings=""; receipts=""
  for k in $(seq 0 "$lookback"); do
    d="$(date -u -d "@$(( now - k * 86400 ))" +%Y-%m-%d)"
    findings="${findings}$(ts_read_objects "dig-$d" 'finding-*.json')"$'\n'
    receipts="${receipts}$(ts_read_objects "intake-$ISLAND-$d" 'receipt.json')"$'\n'
  done
  today="$(date -u -d "@$now" +%Y-%m-%d)"
  sel="$(jq -n --arg pat "$pat" --arg verdicts "$verdicts" --arg island "$ISLAND" --arg today "$today" \
      --argjson dmax "$dmax" --arg ts "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" \
      --slurpfile f <(printf '%s' "$findings" | grep -v '^$' || true) \
      --slurpfile r <(printf '%s' "$receipts" | grep -v '^$' || true) '
    def fid: (._key | sub("\\.json$"; ""));
    ([ $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply")
            | .ruled[]? | select(.outcome != "deferred") | .input ] | unique) as $ruled
    | ([ $r[] | select(.schema == "island-intake-receipt/v1" and .mode == "apply" and .session_ran == true
                       and ((.ts // "") | startswith($today))) ] | length) as $sittings
    | [ $f[] | select(.schema == "dig-finding/v1")
             | select(.verdict as $v | ($verdicts | split(",")) | index($v))
             | select(([.cause, .recommendation, (.evidence // []), (.related // []), .pr] | tostring) | test($pat))
             | {id: fid, run: (.run // ""), verdict, alerts: (.alerts // []), members: (.members // []),
                cause, recommendation, evidence: (.evidence // []), related: (.related // []), pr: (.pr // "")} ] as $match
    | [ $match[] | select(.id as $i | $ruled | index($i) | not) ] as $inputs
    | {schema: "island-intake-select/v1", island: $island, source: "dig", ts: $ts,
       counts: {matched: ($match | length), ruled: (($match | length) - ($inputs | length)), inputs: ($inputs | length)},
       sittings_today: $sittings, daily_max: $dmax, inputs: $inputs}')" \
    || { echo "intake-select: selection jq failed" >&2; exit 2; }
  [ -n "$OUT" ] && printf '%s\n' "$sel" > "$OUT" || printf '%s\n' "$sel"
  printf '%s' "$sel" | jq -r '.inputs[] | "\(.id)\t\(.verdict)\t\(.alerts | join(", ") | .[0:80])"' >&2
  n="$(printf '%s' "$sel" | jq '.counts.inputs')"; sittings="$(printf '%s' "$sel" | jq '.sittings_today')"
  if [ "$n" -eq 0 ]; then
    echo "hold: no unruled dig finding names island $ISLAND ($(printf '%s' "$sel" | jq -c .counts))" >&2; exit 1
  elif [ "$sittings" -ge "$dmax" ]; then
    echo "hold: daily cap — $sittings apply sitting(s) today (INTAKE_DAILY_MAX=$dmax); $n input(s) wait for tomorrow" >&2; exit 1
  fi
  echo "fire: $n unruled dig finding(s) for island $ISLAND" >&2; exit 0
}
case "$SOURCE" in
  issues) ;;
  dig) cmd_dig; exit $?;;
  *) echo "intake-select: unknown --source $SOURCE (issues|dig)" >&2; exit 2;;
esac

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
  if grep -qiE '^gateway([:/ ]|$)|\bGW-[A-Z]' <<< "$title"; then
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
