#!/usr/bin/env bash
# experiment-read — the scheduled read of the platform repo's open experiments (Goal homelab#3586 pins 3, 4, 6, 7, 8, 10;
# child #3604). Runs as the first step of the island-intake workflow, before the sittings: every CLOSED issue
# labelled `experiment/open` is loaded (experiment.py load), given its t0 (the mergedAt of the merged PR that closed
# it), decided (experiment.py read) and — when decided — answered in the issue.
#
#   bash islands/intake/scripts/experiment-read.sh [--dry-run]
#
# --dry-run prints what each verdict would write (comments, label and state changes, the report object, the
# metrics) and writes nothing: no GitHub write, no upload, no push.
#
# Per verdict (pin 6, 7; every write idempotent through the marker `<!-- experiment-verdict id=<id> -->` in the
# issue's own comments — an issue that carries it gets no second comment):
#   pass     one comment (marker, verdict, the section's prose line, a table), label `experiment/open` removed
#   fail     the same comment; no Goal ancestor (no parent chain reaching an issue labelled `task/goal`):
#            the issue is reopened and every `agent/*` label removed (one atomic PATCH with the label); a Goal ancestor: the comment is also
#            posted on the Goal's open `post-launch:` sub-issue (else on the Goal) and the child stays closed;
#            the label is removed either way
#   no data  the comment (its reason line says which), label removed, no state change
#   pending  nothing is written
# The order of writes is: the comment, the report upload, the state, then the label LAST — the label's removal is
# what takes an issue off the list, so any earlier write that fails keeps it listed and the next run redoes it.
# A run that died after the comment finds its marker next time and finishes the rest (the state writes are safe
# to repeat; the Goal-side comment carries its own marker `<!-- experiment-verdict-goal issue=<n> id=<id> -->`)
# — it never comments twice. A `fail` without a Goal reopens, unlabels and removes `experiment/open` in ONE PATCH.
# An issue whose body has no loadable block, or that no merged PR closed, gets ONE comment (marker
# `<!-- experiment-fault -->`) naming the fault and keeps its label; the run counts it as `fault`.
#
# Overlap (pin 10): two experiments of this run whose windows [t0, t0 + max_window] overlap and whose `kpi.query`
# share a metric name each get one line naming the other in their verdict comment. A metric name is, in a plain
# regex over the query, every identifier directly followed (spaces allowed) by `{` or `[`:
#   grep -oE '[A-Za-z_:][A-Za-z0-9_:]*[[:space:]]*[{[]'    — `increase(foo_total{a="b"}[$window])` → foo_total
# No attribution is attempted.
#
# The report object of every decided experiment (the read's object + issue, repo, comment fields) goes to
# s3://$AGENT_TS_BUCKET/homelab/experiments/<issue>-<id>.json with the sitting's writer key; an upload that
# fails fails the step after the comment is written and keeps the label, so the next run uploads it again.
#
# Failure: a GitHub list/read that fails, or a Prometheus that cannot be reached (a preflight read before the
# first write), exits non-zero having written nothing. A single experiment whose read fails is skipped
# (decided nothing) and the step ends non-zero.
#
# Metrics (job island_intake_experiments, one PUT per run; none on a failed preflight or a dry run):
#   island_intake_experiments_open                    labelled issues left open by this run
#   island_intake_experiments_decided_total{verdict}  this run's counts (pass, fail, no data)
#   island_intake_experiments_fault                   issues in fault
#   island_intake_experiments_oldest_overdue_seconds  now − bound of the oldest experiment still open past its bound (0: none)
#   island_intake_experiments_last_run_timestamp_seconds
#
# Env: EXPERIMENT_REPO (default teststuffstash/homelab), PROMETHEUS (default the in-cluster service),
#      PUSHGATEWAY, AGENT_TS_ENDPOINT / AGENT_TS_BUCKET / AGENT_TS_ACCESS_KEY_ID / AGENT_TS_SECRET_ACCESS_KEY,
#      EXP_NOW (epoch seconds, tests).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPY="$HERE/experiment.py"
REPO="${EXPERIMENT_REPO:-teststuffstash/homelab}"
PROM="${PROMETHEUS:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090}"
BUCKET="${AGENT_TS_BUCKET:-agent-transcripts}"
UNSHIPPED_D="${EXPERIMENT_UNSHIPPED_D:-14}"   # a child merged into goal/** this long ago and still not shipped counts overdue
DRY=0
case "${1:-}" in
  --dry-run) DRY=1;;
  "") ;;
  *) echo "experiment-read: usage: experiment-read.sh [--dry-run]" >&2; exit 64;;
esac
NOW="${EXP_NOW:-$(date -u +%s)}"
NOW_RFC="$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
say() { echo "experiment-read: $*"; }
die() { say "$*"; exit 1; }

# ── the list: ONE call ───────────────────────────────────────────────────────────────────────────
gh issue list --repo "$REPO" --state closed --label experiment/open --limit 200 \
  --json number,title,body,labels,comments,closedByPullRequestsReferences > "$W/list.json" 2> "$W/list.err" \
  || die "GitHub did not answer the list of open experiments — nothing decided: $(tr '\n' ' ' < "$W/list.err" | cut -c1-300)"
jq -e 'type == "array"' "$W/list.json" >/dev/null 2>&1 || die "the list is not an array — nothing decided"
TOTAL="$(jq 'length' "$W/list.json")"
say "$TOTAL closed issue(s) labelled experiment/open in $REPO"

if [ "$TOTAL" -gt 0 ]; then
  # preflight: Prometheus must answer before anything is written
  python3 -I "$EXPY" at --prometheus "$PROM" --query 'count(count_over_time(up[$window]))' --window 5m --at "$NOW_RFC" \
    > /dev/null 2> "$W/pre.err" || die "Prometheus cannot be read ($PROM) — nothing decided: $(tr '\n' ' ' < "$W/pre.err" | cut -c1-300)"
fi

names_of() { # <query> → the metric names, one per line
  printf '%s' "$1" | grep -oE '[A-Za-z_:][A-Za-z0-9_:]*[[:space:]]*[{[]' | sed -E 's/[[:space:]]*[{[]$//' | sort -u
}
sane() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

goal_of() { # <n> → prints the Goal number; exit 0 found, 1 none, 2 error
  local cur="$1" p
  for _ in 1 2 3 4 5; do
    p="$(gh api "repos/$REPO/issues/$cur/parent" 2> "$W/p.err")" || {
      grep -qiE '404|not found' "$W/p.err" && return 1
      say "GitHub did not answer for the parent of #$cur: $(tr '\n' ' ' < "$W/p.err" | cut -c1-200)" >&2; return 2; }
    cur="$(jq -r '.number' <<<"$p")"
    jq -e '[.labels[]?.name] | index("task/goal")' <<<"$p" >/dev/null 2>&1 && { echo "$cur"; return 0; }
  done
  return 1
}

# ── pass 1: load, t0, read — writes nothing ──────────────────────────────────────────────────────
declare -A ID VERDICT FAULT T0 BOUND NAMES QUERY FINAL GOAL
ORDER=()
while IFS= read -r row; do
  n="$(jq -r '.number' <<<"$row")"; ORDER+=("$n")
  jq -r '.body // ""' <<<"$row" > "$W/$n.body"
  if ! python3 -I "$EXPY" load "$W/$n.body" > "$W/$n.block" 2> "$W/$n.load.err"; then
    FAULT[$n]="the body has no loadable experiment block ($(head -c 300 "$W/$n.load.err" | tr '\n' ' '))"; continue
  fi
  ID[$n]="$(sane "$(jq -r '.id' "$W/$n.block")")"
  # t0 = the merge that shipped the fix. First the merged PR that closed the issue (master-based work,
  # post-launch children, themed / Base: master Goals). Only when none exists and the issue has a Goal
  # ancestor: its PR merged into goal/** (no closing reference — GitHub's shape), and the change reaches
  # production when that branch merges on (below; not merged yet = pending, nothing written). The Goal is read
  # for every issue: a fail is routed by it.
  goal="$(goal_of "$n")"; grc=$?
  if [ "$grc" = 2 ]; then FAULT[$n]="__error__ the Goal lookup of #$n failed"; continue; fi
  [ "$grc" = 0 ] && GOAL[$n]="$goal"
  merged=""
  while IFS=$'\t' read -r pn prepo; do
    [ -n "$pn" ] || continue
    gh pr view "$pn" --repo "${prepo:-$REPO}" --json mergedAt > "$W/$n.pr" 2> "$W/$n.pr.err" \
      || die "GitHub did not answer for PR #$pn (closing #$n) — nothing decided: $(tr '\n' ' ' < "$W/$n.pr.err" | cut -c1-300)"
    m="$(jq -r '.mergedAt // ""' "$W/$n.pr")"
    # the latest merged closing PR is the one that closed the issue last
    [ -n "$m" ] && { [ -z "$merged" ] || [[ "$m" > "$merged" ]]; } && merged="$m"
  done < <(jq -r '(.closedByPullRequestsReferences // [])[] | [.number, (if .repository.owner.login and .repository.name then "\(.repository.owner.login)/\(.repository.name)" else "" end)] | @tsv' <<<"$row")
  if [ -z "$merged" ] && [ -n "${GOAL[$n]:-}" ]; then
    # No closing reference: its PR merged into a goal/** branch, where the keyword is inert. Follow THAT branch:
    # the merged PR that carried the child (closing keyword or fix/issue-<n>- head, base goal/**), then the merged
    # PR whose head is that base, until one lands outside goal/** — a Goal assembly (Assembly-for:) or a themed
    # Goal's theme branch merging on (ADR-126), whatever it is called. Each hop must merge after the one below it,
    # so a sibling branch's older merge is never this child's t0.
    gh pr list --repo "$REPO" --state merged --search "$n in:body" --json number,body,baseRefName,headRefName,mergedAt --limit 50 \
      > "$W/$n.car" 2> "$W/$n.car.err" \
      || die "GitHub did not answer for the PR that carried #$n — nothing decided: $(tr '\n' ' ' < "$W/$n.car.err" | cut -c1-300)"
    carrier="$(jq -c --arg n "$n" '[.[] | select((.baseRefName // "") | startswith("goal/"))
      | select(((.body // "") | test("(?i)(^|[^a-z])(fix(es|ed)?|close[sd]?|resolve[sd]?)[ \t]+#" + $n + "([^0-9]|$)"))
               or ((.headRefName // "") | test("issue-" + $n + "(-|$)")))] | sort_by(.mergedAt) | last // empty' "$W/$n.car")"
    if [ -z "$carrier" ]; then FAULT[$n]="no merged pull request closes or carries this issue, so there is no t0"; continue; fi
    base="$(jq -r '.baseRefName' <<<"$carrier")"; after="$(jq -r '.mergedAt' <<<"$carrier")"; cm="$after"
    for _ in 1 2 3 4; do
      gh pr list --repo "$REPO" --state merged --head "$base" --json number,baseRefName,mergedAt --limit 10 > "$W/$n.up" 2> "$W/$n.up.err" \
        || die "GitHub did not answer for the merge of $base (#$n) — nothing decided: $(tr '\n' ' ' < "$W/$n.up.err" | cut -c1-300)"
      up="$(jq -c --arg a "$after" '[.[] | select((.mergedAt // "") >= $a)] | sort_by(.mergedAt) | .[0] // empty' "$W/$n.up")"
      [ -n "$up" ] || break
      base="$(jq -r '.baseRefName' <<<"$up")"; after="$(jq -r '.mergedAt' <<<"$up")"
      case "$base" in goal/*) ;; *) merged="$after"; break;; esac
    done
    if [ -z "$merged" ]; then
      # not in production yet: pending, and an overdue bound UNSHIPPED_D days after the child merged, so a branch
      # that never ships is seen (IntakeExperimentOverdue) instead of a label that sits forever
      VERDICT[$n]=pending; BOUND[$n]=$(( $(date -u -d "$cm" +%s) + UNSHIPPED_D * 86400 ))
      say "#$n: carried into $base, which has not reached the default branch — pending (overdue $UNSHIPPED_D d after $cm)"; continue
    fi
  fi
  if [ -z "$merged" ]; then FAULT[$n]="no merged pull request closes this issue, so there is no t0"; continue; fi
  T0[$n]="$(date -u -d "$merged" +%s)"
  BOUND[$n]=$(( ${T0[$n]} + $(jq -r '.kpi.max_window_s' "$W/$n.block") ))
  QUERY[$n]="$(jq -r '.kpi.query' "$W/$n.block")"
  NAMES[$n]="$(names_of "${QUERY[$n]}" | tr '\n' ' ')"
  python3 -I "$EXPY" read --prometheus "$PROM" --since "$merged" --now "$NOW_RFC" "$W/$n.body" > "$W/$n.report" 2> "$W/$n.read.err"
  rrc=$?
  v="$(jq -r '.verdict // ""' "$W/$n.report" 2>/dev/null)"
  case "$v" in
    pass|fail|pending|"no data") VERDICT[$n]="$v";;
    *) FAULT[$n]="__error__ the read of #$n produced no verdict (exit $rrc): $(jq -r '.error // empty' "$W/$n.report" 2>/dev/null | cut -c1-300) $(head -c 200 "$W/$n.read.err")";;
  esac
done < <(jq -c '.[]' "$W/list.json")

# ── pass 2: write ────────────────────────────────────────────────────────────────────────────────
FAILED=0; FAULTS=0; DECIDED_PASS=0; DECIDED_FAIL=0; DECIDED_NODATA=0; OVERDUE_BOUND=""
has_marker() { jq -e --arg m "$2" '[.[] | select(.number == '"$1"') | .comments[]?.body // empty | select(contains($m))] | length > 0' "$W/list.json" >/dev/null; }
gh_write() { # <what> <gh args…>
  local what="$1"; shift
  if [ "$DRY" = 1 ]; then say "[dry-run] would $what"; return 0; fi
  gh "$@" > /dev/null 2> "$W/w.err" || { say "FAILED to $what: $(tr '\n' ' ' < "$W/w.err" | cut -c1-300)"; return 1; }
}
overlap_lines() { # <n> → one line per overlapping experiment
  local n="$1" m a
  for m in "${ORDER[@]}"; do
    [ "$m" = "$n" ] && continue
    [ -n "${T0[$m]:-}" ] && [ -n "${T0[$n]:-}" ] || continue
    [ "${T0[$n]}" -lt "${BOUND[$m]}" ] && [ "${T0[$m]}" -lt "${BOUND[$n]}" ] || continue
    for a in ${NAMES[$n]}; do
      case " ${NAMES[$m]} " in *" $a "*)
        echo "Overlap: #$m (experiment \`$(jq -r '.id' "$W/$m.block")\`) is open over an overlapping window and reads the same metric \`$a\`; both fixes act on that series and no attribution is attempted."
        break;; esac
    done
  done
}
comment_text() { # <n> → $W/<n>.comment.md
  local n="$1" prose
  prose="$(awk '/^## Experiment[[:space:]]*$/{f=1; next} f && /^## /{exit} f && NF {print; exit}' "$W/$n.body")"
  {
    printf '<!-- experiment-verdict id=%s -->\n' "${ID[$n]}"
    jq -r --slurpfile b "$W/$n.block" --arg prose "$prose" --arg t0 "$(date -u -d "@${T0[$n]}" +%Y-%m-%dT%H:%M:%SZ)" '
      def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
      def c: if . == null then "—" else tostring end;
      ($b[0]) as $x |
      "**Experiment `\($x.id)`: \(.verdict)**\n\n\($prose)\n\n\(.reason)\n\n" +
      "| | |\n|---|---|\n" +
      "| query | `\($x.kpi.query | esc)` |\n" +
      "| window | \(if .window_s == null then "—" else "\(.window_s / 60 | floor)m" end) from t0 \($t0) |\n" +
      "| instant | \(.at | c) |\n" +
      "| value | \(.value | c) |\n" +
      "| samples | \(.samples | c) (`\($x.kpi.min_samples_query | esc)`, needs \($x.kpi.min_samples)) |\n" +
      "| baseline | \($x.kpi.baseline) |\n" +
      "| pass condition | `\($x.kpi.pass)` |\n" +
      ([ .guards[]? as $g | ($x.kpi.guards // [] | map(select(.id == $g.id)) | .[0]) as $d
         | "| guard `\($g.id)` | value \($g.value | c), pass `\($d.pass // "?")` — \(if $g.ok then "ok" else "failed" end) |" ] | join("\n")) +
      "\n\nbound \(.bound)." ' "$W/$n.report"
    overlap_lines "$n"
  } > "$W/$n.comment.md"
}

for n in "${ORDER[@]}"; do
  row="$(jq -c --argjson n "$n" '.[] | select(.number == $n)' "$W/list.json")"
  if [ -n "${FAULT[$n]:-}" ]; then
    f="${FAULT[$n]}"
    if [[ "$f" == __error__* ]]; then say "#$n: ${f#__error__ } — nothing decided"; FAILED=1; continue; fi
    FAULTS=$((FAULTS+1)); say "#$n: fault — $f"
    if has_marker "$n" '<!-- experiment-fault -->'; then say "#$n: fault comment already written"; continue; fi
    printf '<!-- experiment-fault -->\nThe experiment read cannot decide this issue: %s.\n\nIt keeps the label `experiment/open`; the read tries again on its next run.\n' "$f" > "$W/$n.fault.md"
    [ "$DRY" = 1 ] && cat "$W/$n.fault.md"
    gh_write "comment the fault on #$n" issue comment "$n" --repo "$REPO" --body-file "$W/$n.fault.md" || FAILED=1
    continue
  fi
  v="${VERDICT[$n]}"
  if [ "$v" = pending ]; then say "#$n: pending — nothing written"; continue; fi
  marker="<!-- experiment-verdict id=${ID[$n]} -->"
  comment_text "$n"
  # the Goal (pass 1) and, for a fail, its post-launch sub-issue — read BEFORE any write
  goal="${GOAL[$n]:-}"; target=""
  if [ "$v" = fail ] && [ -n "$goal" ]; then
    target="$(gh api "repos/$REPO/issues/$goal/sub_issues?per_page=100" 2> "$W/s.err" \
      | jq -r '[.[] | select(.state == "open") | select(.title | ascii_downcase | startswith("post-launch:"))] | sort_by(.number) | .[0].number // empty')" \
      || { say "GitHub did not answer for the sub-issues of Goal #$goal"; FAILED=1; continue; }
    [ -n "$target" ] || target="$goal"
  fi
  # 1. the comment — once (the marker); a run that died after it finishes the rest below
  if has_marker "$n" "$marker"; then
    say "#$n: verdict comment already written ($v) — finishing what the earlier run left"
  else
    [ "$DRY" = 1 ] && { say "[dry-run] #$n: $v"; cat "$W/$n.comment.md"; }
    gh_write "comment the verdict ($v) on #$n" issue comment "$n" --repo "$REPO" --body-file "$W/$n.comment.md" || { FAILED=1; continue; }
  fi
  # 2. the report object — before ANY state write: a reopen takes the issue off the CLOSED list, so an upload after it
  #    could never be retried; here a failed upload keeps the issue listed (an idempotent cp next run)
  key="homelab/experiments/$n-${ID[$n]}.json"
  jq --arg repo "$REPO" --argjson issue "$n" --arg goal "$goal" --arg target "$target" \
    '. + {repo: $repo, issue: $issue, goal: (if $goal == "" then null else ($goal | tonumber) end), goal_comment_on: (if $target == "" then null else ($target | tonumber) end)}' \
    "$W/$n.report" > "$W/$n.out.json"
  if [ "$DRY" = 1 ]; then say "[dry-run] would upload s3://$BUCKET/$key"; cat "$W/$n.out.json"
  elif [ -z "${AGENT_TS_ACCESS_KEY_ID:-}" ] || ! command -v s5cmd >/dev/null 2>&1 \
      || ! AWS_ACCESS_KEY_ID="$AGENT_TS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="${AGENT_TS_SECRET_ACCESS_KEY:-}" \
           s5cmd --endpoint-url "${AGENT_TS_ENDPOINT:-}" cp "$W/$n.out.json" "s3://$BUCKET/$key" > "$W/up.log" 2>&1; then
    say "FAILED to upload the report of #$n to s3://$BUCKET/$key: $(head -c 200 "$W/up.log" 2>/dev/null) — the label stays"; FAILED=1; continue
  fi
  # 3. the state (fail only) — every step safe to repeat; any failure keeps the label so the next run redoes it
  ok_state=1; label_done=""
  if [ "$v" = fail ] && [ -z "$goal" ]; then
    # ONE atomic write (PATCH /issues/<n>: state + the whole label set): reopened, the agent/* labels and
    # experiment/open gone, together or not at all. Separate writes can strand it either way — reopened with
    # the label left (an open issue the CLOSED-only list never reads again), or unlabelled and still closed.
    jq -c '{state: "open", labels: [.labels[]?.name | select((startswith("agent/") or . == "experiment/open") | not)]}' <<<"$row" > "$W/$n.patch.json"
    gh_write "reopen #$n and remove its agent/* labels and experiment/open ($(jq -r '.labels | join(",")' "$W/$n.patch.json") kept)" \
      api --method PATCH "repos/$REPO/issues/$n" --input "$W/$n.patch.json" && label_done=1 || ok_state=0
  elif [ "$v" = fail ]; then
    gmarker="<!-- experiment-verdict-goal issue=$n id=${ID[$n]} -->"
    if [ "$DRY" = 0 ] && ! gh api "repos/$REPO/issues/$target/comments?per_page=100" --paginate > "$W/t.json" 2> "$W/t.err"; then
      say "GitHub did not answer for the comments of #$target"; ok_state=0
    elif [ "$DRY" = 0 ] && jq -se --arg m "$gmarker" '[.[][]?.body // empty | select(contains($m))] | length > 0' "$W/t.json" >/dev/null 2>&1; then
      say "#$n: the verdict is already on #$target"
    else
      { printf '%s\nThe experiment of #%s failed (its Goal is #%s); the child stays closed.\n\n' "$gmarker" "$n" "$goal"; tail -n +2 "$W/$n.comment.md"; } > "$W/$n.goal.md"
      gh_write "comment the verdict of #$n on #$target" issue comment "$target" --repo "$REPO" --body-file "$W/$n.goal.md" || ok_state=0
    fi
  fi
  if [ "$ok_state" = 0 ]; then FAILED=1; say "#$n: a state write failed — the label stays, the next run redoes it"; continue; fi
  # 4. the label, last — its removal is what takes the issue off the list
  [ -n "$label_done" ] || gh_write "remove the label experiment/open from #$n" issue edit "$n" --repo "$REPO" --remove-label experiment/open || { FAILED=1; continue; }
  FINAL[$n]=1
  case "$v" in pass) DECIDED_PASS=$((DECIDED_PASS+1));; fail) DECIDED_FAIL=$((DECIDED_FAIL+1));; *) DECIDED_NODATA=$((DECIDED_NODATA+1));; esac
done
# overdue: every experiment this run did not finish (pending, a read that failed, any write that failed) past its bound
for n in "${ORDER[@]}"; do
  [ -z "${FINAL[$n]:-}" ] && [ -n "${BOUND[$n]:-}" ] && [ "${BOUND[$n]}" -lt "$NOW" ] || continue
  { [ -z "$OVERDUE_BOUND" ] || [ "${BOUND[$n]}" -lt "$OVERDUE_BOUND" ]; } && OVERDUE_BOUND="${BOUND[$n]}"
done

# ── metrics ──────────────────────────────────────────────────────────────────────────────────────
DECIDED=$((DECIDED_PASS + DECIDED_FAIL + DECIDED_NODATA))
[ "$DRY" = 1 ] && DECIDED=0
OPEN=$((TOTAL - DECIDED))
OVERDUE=0; [ -n "$OVERDUE_BOUND" ] && OVERDUE=$((NOW - OVERDUE_BOUND))
cat > "$W/metrics" <<EOF
# TYPE island_intake_experiments_open gauge
island_intake_experiments_open $OPEN
# TYPE island_intake_experiments_decided_total gauge
island_intake_experiments_decided_total{verdict="pass"} $DECIDED_PASS
island_intake_experiments_decided_total{verdict="fail"} $DECIDED_FAIL
island_intake_experiments_decided_total{verdict="no data"} $DECIDED_NODATA
# TYPE island_intake_experiments_fault gauge
island_intake_experiments_fault $FAULTS
# TYPE island_intake_experiments_oldest_overdue_seconds gauge
island_intake_experiments_oldest_overdue_seconds $OVERDUE
# TYPE island_intake_experiments_last_run_timestamp_seconds gauge
island_intake_experiments_last_run_timestamp_seconds $NOW
EOF
if [ "$DRY" = 1 ]; then say "[dry-run] would push:"; cat "$W/metrics"
elif [ -n "${PUSHGATEWAY:-}" ]; then
  curl -fsS --max-time 5 -X PUT --data-binary "@$W/metrics" "$PUSHGATEWAY/metrics/job/island_intake_experiments" >/dev/null 2>&1 \
    || say "pushgateway unreachable — metrics stale, verdicts unaffected"
fi
say "done: $DECIDED decided (pass $DECIDED_PASS, fail $DECIDED_FAIL, no data $DECIDED_NODATA), $FAULTS fault, $OPEN still open"
[ "$FAILED" = 0 ]
