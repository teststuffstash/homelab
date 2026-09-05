#!/usr/bin/env bash
# board — the operator's who-acts todo view (platform pilot, 2026-08-17).
#
# A DETERMINISTIC, read-only jail tool (zero LLM; `gh`/`kubectl` reads only) that
# lists ONLY human-actionable items across a stack's repos, grouped by the action
# the operator takes, with ages. Standing backlog renders as AGGREGATE count+oldest
# lines so the same items never re-scroll (operator ruling 2026-08-17); the
# individually-listed classes are those genuinely awaiting the operator's hands.
# No "parking" concept anywhere: `agent/blocked` means technically-blocked (list it),
# suitable-unqueued is ordinary backlog (aggregate it).
#
# Usage: bash agents/board.sh [stack] [--full]
#   stack  — AgentStack name (default: platform)
#   --full — expand the BACKLOG aggregate into per-issue lines
#
# Stack → repo resolution mirrors coordinator-scan.sh: the cluster AgentStack claim
# (.spec.repos[].name) first, agents/stacks.json as the probe-failed belt (one loud
# WARN when the fallback is taken). Repo owner is $ORG (teststuffstash) when an entry
# is bare. Read-only by construction — mutating gh/kubectl verbs are forbidden (the
# repo's scan discipline: GraphQL is a shared rate pool, so exactly one issues list +
# one PR list per repo, never a loop-poll).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ORG="${ORG:-teststuffstash}"
STACKS_FILE="${STACKS_FILE:-$HERE/stacks.json}"

stack="platform"; full=0; machine=0; scope=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) full=1; shift ;;
    --machine) machine=1; shift ;;
    --scope=*) scope="${1#*=}"; shift ;;
    --scope) scope="${2:-}"; shift 2 ;;
    -*) echo "board: unknown flag: $1" >&2; exit 2 ;;
    *) stack="$1"; shift ;;
  esac
done

# kubectl discovery (mirrors coordinator-scan.sh): point at the repo kubeconfig when
# present, binary via PATH with a devbox-profile fallback.
if [ -f "$ROOT/tofu/kubeconfig" ]; then KUBE="--kubeconfig $ROOT/tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="$ROOT/.devbox/nix/profile/default/bin/kubectl"

# ── stack → repo list ─────────────────────────────────────────────────────────
repos=""
if [ -n "$KUBECTL" ]; then
  kubeout="$($KUBECTL $KUBE get "agentstacks.platform.teststuff.net/$stack" -o json 2>/dev/null)" || kubeout=""
  if [ -n "$kubeout" ]; then
    repos="$(printf '%s' "$kubeout" | jq -r '[.spec.repos[]?.name] | .[]' 2>/dev/null || true)"
  fi
fi
if [ -z "$repos" ]; then
  echo "WARN board: agentstacks read PROBE-FAILED — repos from $STACKS_FILE only" >&2
  repos="$(jq -r --arg s "$stack" '.stacks[] | select(.name==$s) | .repos[]?' "$STACKS_FILE" 2>/dev/null || true)"
fi
if [ -z "$repos" ]; then
  avail="$(jq -r '[.stacks[].name] | join(" ")' "$STACKS_FILE" 2>/dev/null || true)"
  echo "board: unknown stack '$stack' — available stacks: ${avail:-<unreadable stacks.json>}" >&2
  exit 2
fi

# ── per-repo fetch + classification ───────────────────────────────────────────
# Clock: real by default; BOARD_NOW (epoch seconds) overrides — the replay seam the smoke suite
# pins age-sensitive predicates through (loud-clock rule, the fix-debounce family: a DEFAULTED
# clock lets every recorded createdAt silently drift into the past while the suite stays green).
NOW="$(date +%s)"
if [ -n "${BOARD_NOW:-}" ]; then NOW="$BOARD_NOW"; fi

# jq preamble prepended to every classification filter (age/label/bot logic in one
# place). jq takes ONE program string, so the filter text is concatenated after it.
# NOW_EPOCH is substituted for the real epoch just below (shadowing jq's builtin `now`
# keeps every age/`agedays >= 1` predicate deterministic under BOARD_NOW).
JQ='def now: NOW_EPOCH;
def agedays: ((now - (.createdAt | fromdateiso8601)) / 86400 | floor);
def age: agedays as $d | if $d < 1 then "<1d" else "\($d)d" end;
def lab: [.labels[]?.name];
def haslab($l): lab | index($l) != null;
def isbot: (.author.is_bot == true) or (.author.login | test("\\[bot\\]")) or (.author.login | startswith("app/"));
'
JQ="${JQ/NOW_EPOCH/$NOW}"

sec_review=""; sec_fix=""; sec_solve=""; sec_triage=""; sec_verdict=""; sec_backlog=""; nback=0; nfail=0
for repo in $repos; do
  case "$repo" in */*) slug="$repo";; *) slug="$ORG/$repo";; esac
  issues="$(gh issue list --repo "$slug" --state open --limit 200 --json number,title,labels,createdAt,author 2>/dev/null)" || issues=""
  jq -e . >/dev/null 2>&1 <<<"${issues:-null}" || issues=""
  if [ -z "$issues" ]; then
    echo "WARN board: $slug issue list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" >&2
    issues='[]'; nfail=$((nfail + 1))
  fi
  prs="$(gh pr list --repo "$slug" --state open --limit 100 --json number,title,labels,createdAt,reviewDecision,isDraft,autoMergeRequest,latestReviews,author 2>/dev/null)" || prs=""
  jq -e . >/dev/null 2>&1 <<<"${prs:-null}" || prs=""
  if [ -z "$prs" ]; then
    echo "WARN board: $slug PR list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" >&2
    prs='[]'; nfail=$((nfail + 1))
  fi

  # § REVIEW — bot-approved head still on the human gate (require_code_owner_review
  # holds), plus PRs explicitly parked `major/awaiting-human`.
  rline="$(printf '%s' "$prs" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(.isDraft == false) | select(
        ((.reviewDecision == "REVIEW_REQUIRED")
         and ([.latestReviews[]? | select(.state == "APPROVED" and (.author.login | startswith("homelab-reviewer")))] | length > 0))
        or (haslab("major/awaiting-human")))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$rline" ] && sec_review="${sec_review}${rline}"$'\n'

  # § FIX — seat-authored (non-bot) PRs sitting CHANGES_REQUESTED, plus seat-authored `merge-conflict`
  # PRs (MP-T06, homelab#595): only the seat's own push moves them (an operator-lane PR has NO
  # machine owner — the scan's changes-requested clause is WORKER_AUTHOR-scoped by design and the
  # merge-conflict clause is scoped the same way, so the seat case lands here as the board row).
  # agent/error stays SOLVE's line; major/awaiting-human stays REVIEW's. A PR whose fix round is
  # already pushed lists until the bot's re-review replaces the verdict — accepted: tightening
  # that needs per-PR commit reads, and the read-only contract is ONE PR list per repo.
  fline="$(printf '%s' "$prs" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(.isDraft == false) | select(.author != null) | select(isbot | not)
      | select((.reviewDecision == "CHANGES_REQUESTED") or haslab("merge-conflict"))
      | select(haslab("agent/error") | not) | select(haslab("major/awaiting-human") | not)
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$fline" ] && sec_fix="${sec_fix}${fline}"$'\n'

  # § SOLVE — agent/error anomaly breakers (issues + PRs, FU-069 human-first) and
  # agent/blocked gates (issues); a blocked issue already flagged agent/error shows ⛔ only.
  eline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("agent/error")) | "⛔ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$eline" ] && sec_solve="${sec_solve}${eline}"$'\n'
  eline="$(printf '%s' "$prs" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("agent/error")) | "⛔ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$eline" ] && sec_solve="${sec_solve}${eline}"$'\n'
  errn="$(printf '%s' "$issues" | jq -c "$JQ"'[ .[] | select(haslab("agent/error")) | .number ]')"
  bline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" --argjson errn "${errn:-[]}" "$JQ"'[
      .[] | select(haslab("agent/blocked")) | select(.number as $n | ($errn | index($n)) == null)
      | "⏸ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$bline" ] && sec_solve="${sec_solve}${bline}"$'\n'

  # § TRIAGE — bot-authored without agent-fix (🌱), plus zero-label non-bot strays
  # older than a day. `post-launch:` goal buckets and `stint:` parents (chainless-redesign §The
  # jail stint, 2026-08-19) are containers, not work — skipped, or every label-inert stint parent
  # would list as a stray from day two.
  tline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select((.title | (startswith("post-launch:") or startswith("stint:"))) | not)
      | select([lab[] | select(startswith("agent/"))] | length == 0)
      | select(
        (isbot and (haslab("agent-fix") | not))
        or ((isbot | not) and (lab | length == 0) and (agedays >= 1)))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$tline" ] && sec_triage="${sec_triage}${tline}"$'\n'

  # ⚠ half-labeled: `agent/queued` WITHOUT `agent-fix` — every dispatch clause needs the pair,
  # and no other surface lists this state (BACKLOG needs agent-fix, the block above excludes
  # agent/* labels), so it is invisible until the coarse throughput belt notices the cork.
  # Live case: oracle-fleet#260, hand-queued 2026-08-12 with one label of the pair, 7 days
  # undispatchable (2026-08-19 heartbeat catch). The human decides which half was meant:
  # add agent-fix, or de-queue.
  hline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("agent/queued") and (haslab("agent-fix") | not))
      | "⚠ \($repo)#\(.number) \(.title) (\(age)) — agent/queued WITHOUT agent-fix: invisible to every dispatch clause" ] | unique | .[]')"
  [ -n "$hline" ] && sec_triage="${sec_triage}${hline}"$'\n'

  # § VERDICT DUE — goals past assembly-complete (ADR-102) awaiting a post-launch verdict.
  vline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("task/goal") and haslab("goal/post-launch"))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$vline" ] && sec_verdict="${sec_verdict}${vline}"$'\n'

  # § BACKLOG — agent-fix with no agent/* state label: AGGREGATE count + oldest so
  # the same standing items never re-scroll; --full expands beneath.
  bl="$(printf '%s' "$issues" | jq -c "$JQ"'[
      .[] | select(haslab("agent-fix")) | select([lab[] | select(startswith("agent/"))] | length == 0) ]')"
  bcnt="$(printf '%s' "$bl" | jq 'length')"
  if [ "$bcnt" -gt 0 ]; then
    bage="$(printf '%s' "$bl" | jq -r "$JQ"'(
      ([.[].createdAt | fromdateiso8601] | min) as $m
      | ((now - $m) / 86400 | floor) as $d | if $d < 1 then "<1d" else "\($d)d" end)')"
    sec_backlog="${sec_backlog}$repo: $bcnt suitable-unqueued (oldest $bage)"$'\n'
    if [ "$full" = 1 ]; then
      bdet="$(printf '%s' "$bl" | jq -r --arg repo "$repo" "$JQ"'[
        sort_by(.number)[] | "  \($repo)#\(.number) \(.title) (\(age))" ] | .[]')"
      [ -n "$bdet" ] && sec_backlog="${sec_backlog}${bdet}"$'\n'
    fi
    nback=$((nback + bcnt))
  fi
done

# ── platform-request slice: all repos across all stacks (ADR-119) ────────────
# Lists open platform-request issues across ALL stack repos (the stacks_json
# universe, not just the current stack), grouped by their Capability: body-line
# fingerprint, with a per-fingerprint stack count and oldest age. The ≥2-stacks
# generalization bar becomes a number. Deterministic gh reads only, REST.
all_repos=""
if [ -n "$KUBECTL" ]; then
  kube_all="$($KUBECTL $KUBE get agentstacks.platform.teststuff.net -o json 2>/dev/null)" || kube_all=""
  if [ -n "$kube_all" ]; then
    all_repos="$(printf '%s' "$kube_all" | jq -r '[.items[].spec.repos[]?.name] | unique | .[]' 2>/dev/null || true)"
  fi
fi
if [ -z "$all_repos" ]; then
  echo "WARN board: all-stacks agentstacks read PROBE-FAILED — repos from $STACKS_FILE only" >&2
  all_repos="$(jq -r '[.stacks[].repos[]?] | unique | .[]' "$STACKS_FILE" 2>/dev/null || true)"
fi

# Build stack→repo mapping from stacks.json
stack_index="$(jq '[.stacks[] | {key: .name, value: .repos}] | from_entries' "$STACKS_FILE" 2>/dev/null || echo "{}")"

# Collect platform-request issues across all repos
demand_json="[]"
for repo in $all_repos; do
  case "$repo" in */*) slug="$repo";; *) slug="$ORG/$repo";; esac
  preqs="$(gh issue list --repo "$slug" --state open --label "platform-request" --limit 50 --json number,title,createdAt,body,labels 2>/dev/null)" || preqs=""
  jq -e . >/dev/null 2>&1 <<<"${preqs:-null}" || preqs=""
  if [ -z "$preqs" ]; then
    echo "WARN board: $slug platform-request probe PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" >&2
    preqs="[]"; nfail=$((nfail + 1))
  fi
  if [ "$preqs" != "[]" ]; then
    rstacks="$(printf '%s' "$stack_index" | jq -r --arg r "$repo" 'to_entries[] | select(.value | index($r)) | .key' | tr '\n' ',' | sed 's/,$//')"
    [ -z "$rstacks" ] && rstacks="unknown"
    demand_json="$(printf '%s' "$demand_json" | jq --argjson new "$preqs" --arg repo "$repo" --arg stacks "$rstacks" '. + ($new | map(. + {repo: $repo, stacks: $stacks}))')"
  fi
done

# Group by capability fingerprint and format
demand_section=""
demand_rows=""
if [ "$(printf '%s' "$demand_json" | jq 'length')" -gt 0 ]; then
  groups="$(printf '%s' "$demand_json" | jq -c "$JQ"'[
    .[] | select(haslab("platform-request"))] | group_by((.body | capture("(?im)^Capability:[ \t]+(?<cap>[^\\n]+)") | .cap) // "unknown")
    | map({
        capability: ((.[0].body | capture("(?im)^Capability:[ \t]+(?<cap>[^\\n]+)") | .cap) // "unknown"),
        items: [.[] | {ref: "\(.repo)#\(.number)", title: .title, age: age, stacks: .stacks, created: (.createdAt | fromdateiso8601)}],
        stack_count: ([.[].stacks | split(",") | .[]] | unique | length),
        oldest_created: ([.[].createdAt | fromdateiso8601] | min)
    })')"

  # Human format: per-capability group with items and summary
  demand_section="$(printf '%s' "$groups" | jq -r "$JQ"'[
    .[] | {
      cap: .capability,
      lines: [(.items[] | "  \(.ref) \(.title) (\(.age))")],
      oldest_days: ((now - .oldest_created) / 86400 | floor),
      sc: .stack_count
    }
    | "\(.cap)\n\(.lines | join("\n"))\n  — \(.sc) stacks, oldest \(if .oldest_days < 1 then "<1d" else "\(.oldest_days)d" end)"
  ] | .[]')"

  # Machine format: one row per capability group
  demand_rows="$(printf '%s' "$groups" | jq -r "$JQ"'
    .[] | "who=operator class=platform-request capability=\(.capability) stacks=\(.stack_count) oldest=\(((now - .oldest_created) / 86400 | floor) as $d | if $d < 1 then "<1d" else "\($d)d" end)"
  ')"
fi

# ── render ────────────────────────────────────────────────────────────────────
mrepos="$(printf '%s' "$repos" | wc -w | tr -d ' ')"
if [ -n "${BOARD_NOW:-}" ]; then hdr="$(date -u -d "@$BOARD_NOW" +%Y-%m-%dT%H:%M:%SZ)"; else hdr="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi

# ── MACHINE MODE (homelab#892) ─────────────────────────────────────────────────────────────────
# Consumes derived classes from Prometheus (the `agent_item_class` series pushed by
# coordinator-scan.sh per tick) and enriches with gh/kubectl reads. Never re-derives the
# classes board-side — the one-computer rule.
if [ "$machine" = 1 ]; then
  # Prometheus endpoint: in-cluster or jail (env-picked, responder-runbook pattern)
  PROMETHEUS_URL="${PROMETHEUS_URL:-http://kube-prometheus-stack-prometheus.monitoring.svc:9090}"
  DERIVED_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Query Prometheus for the current agent_item_class series
  prom_query() {
    curl -sS --max-time 10 "${PROMETHEUS_URL}/api/v1/query" \
      --data-urlencode "query=$1" 2>/dev/null | jq -r '.data.result? // []' 2>/dev/null || true
  }

  # Build the scope filter
  scope_filter=""
  scope_label=""
  if [ -n "$scope" ]; then
    case "$scope" in
      goal:*) scope_label="goal=${scope#goal:}" ;;
      stack:*) scope_label="stack=${scope#stack:}" ;;
      repo:*) scope_label="repo=${scope#repo:}" ;;
    esac
    # Scope via goal_descendant_info if available (homelab#892)
    if [ -n "$scope_label" ] && [[ "$scope" == goal:* ]]; then
      # Resolve goal descendants from the exporter's series
      gid="${scope#goal:}"
      gmembers="$(prom_query "goal_descendant_info{goal=\"${gid}\"}" | jq -r '.[] | .metric.item // ""' 2>/dev/null || true)"
      [ -n "$gmembers" ] && scope_filter="item=~\"$(printf '%s' "$gmembers" | tr '\n' '|' | sed 's/|$//')\""
    fi
  fi

  # Fetch all classified items from Prometheus (both class and timestamp series)
  query="agent_item_class${scope_filter:+{$scope_filter}}"
  [ -z "$scope_filter" ] && query="agent_item_class"
  raw="$(prom_query "$query" 2>/dev/null || true)"

  # Fetch timestamp series for age calculations
  query_ts="agent_item_class_since_timestamp_seconds${scope_filter:+{$scope_filter}}"
  [ -z "$scope_filter" ] && query_ts="agent_item_class_since_timestamp_seconds"
  raw_ts="$(prom_query "$query_ts" 2>/dev/null || true)"

  if [ -z "$raw" ] || [ "$raw" = "[]" ]; then
    # No data from Prometheus — emit empty machine board
    echo "board v1 scope=stack:${stack} ts=${DERIVED_TS} sources=derived:tick@none"
    echo "# no agent_item_class series found — the scan has not pushed a tick yet, or Prometheus is unreachable"
    exit 0
  fi

  # Parse both series and compute elapsed times
  rows="$(printf '%s' "$raw" | jq -r --arg now "$NOW" --argjson ts_series "$(printf '%s' "$raw_ts" | jq -c 'reduce .[] as $r ({}; .[$r.metric.item] = ($r.value[1] | tonumber))')" '
    .[] |
    {
      repo: .metric.repo,
      item: .metric.item,
      class: .metric.class,
      who: .metric.who,
      since_seconds: (($ts_series[.metric.item // ""]) as $t | if $t == null then null else (($now | tonumber) - $t) end)
    } |
    def format_elapsed:
      if . == null then "unknown" else
        (. | floor) as $secs |
        if $secs < 60 then "<1m"
        elif $secs < 3600 then "\(($secs / 60 | floor))m"
        elif $secs < 86400 then
          (($secs / 3600) | floor) as $h
          | ((($secs - ($h * 3600)) / 60) | floor) as $m
          | (if $m == 0 then "\($h)h" else "\($h)h\($m)m" end)
        else "\(($secs / 86400 | floor))d" end
      end;
    [.who, .class, .repo, .item, (.since_seconds | format_elapsed)] | @tsv
  ' 2>/dev/null || true)"

  # ── tree-member dispositions, in GOAL SCOPE only (ADR-122 (4), homelab#1419) ──────────────
  # The board renders the container's ruling, it never derives one (the one-computer rule): a
  # `disposition=` token per tree-member row, read ONCE per scope from the goal's own store. Out
  # of goal scope there is no container to ask, so nothing is added and no call is made.
  # An unreadable store leaves the token off entirely rather than printing a guess — a board that
  # says `disposition=undispositioned` on an API blip would send the operator to rule a member
  # the container already ruled.
  disp_json=""
  if [ -n "$scope_label" ] && [[ "$scope" == goal:* ]] && command -v python3 >/dev/null 2>&1; then
    # The repo comes from the series itself — a goal's members live in the goal's repo, and the
    # scope filter has already narrowed `raw` to them.
    disp_repo="$(printf '%s' "$raw" | jq -r '[.[] | .metric.repo // ""] | map(select(. != "")) | first // ""' 2>/dev/null || true)"
    if [ -n "$disp_repo" ]; then
      disp_json="$(python3 "$HERE/epic_dispositions.py" read "$ORG/$disp_repo" "${scope#goal:}" 2>/dev/null || true)"
    fi
  fi
  disp_token() {   # disp_token <item> → " disposition=<state>" or "" (no store / not goal scope)
    [ -n "$disp_json" ] || return 0
    case "$1" in ''|*[!0-9]*) return 0 ;; esac   # `aggregate` is not a tree member
    printf ' disposition=%s' \
      "$(printf '%s' "$disp_json" | jq -r --arg k "$1" '.[$k].disposition // "undispositioned"' 2>/dev/null || echo undispositioned)"
  }

  # Build machine output rows
  # Stable sort: who, class, repo, item
  printf 'board v1 scope=stack:%s ts=%s sources=labels:live pods:live derived:tick@%s\n' \
    "$stack" "$hdr" "$DERIVED_TS"

  # Build per-item rows from the parsed data
  had_rows=0
  while IFS=$'\t' read -r who class repo item elapsed; do
    [ -n "$item" ] || continue
    id="${repo}#${item}"
    dtok="$(disp_token "$item")"
    # Map to board display format
    case "$class" in
      riding)                  echo "who=machine  class=riding id=${id} age=${elapsed}${dtok}" ;;
      phantom)                 echo "who=operator class=phantom id=${id} since=${elapsed} note=\"agent/in-progress with no live pod — reconcile pending\"${dtok}" ;;
      strike-held)             echo "who=operator class=strike-held id=${id} pod=none since=${elapsed} next=\"verify goal branch, then close or re-queue\"${dtok}" ;;
      footprint-held)          echo "who=operator class=footprint-held id=${id} since=${elapsed} note=\"held by in-progress issue's Touches\"${dtok}" ;;
      cap-held)                echo "who=operator class=cap-held id=${id} since=${elapsed} note=\"held by PR budget cap\"${dtok}" ;;
      blockpark)               echo "who=operator class=blockpark id=${id} since=${elapsed} note=\"held by codeowner-parked PR budget\"${dtok}" ;;
      parked-blocked)          echo "who=operator class=parked-blocked id=${id} since=${elapsed} note=\"human-gated — agent/blocked\"${dtok}" ;;
      parked-infeasible)       echo "who=operator class=parked-infeasible id=${id} since=${elapsed} note=\"AGENT_INFEASIBLE — re-scope needed\"${dtok}" ;;
      arbitrate-standing)      echo "who=operator class=arbitrate-standing id=${id} since=${elapsed} note=\"escalated to human — agent/arbitrate\"${dtok}" ;;
      queued-held)             echo "who=machine  class=queued-held id=${id} since=${elapsed} note=\"held by in-progress footprint\"${dtok}" ;;
      queued-held-by-ghost)    echo "who=operator class=queued-held-by-ghost id=${id} since=${elapsed} note=\"held by phantom/infeasible blocker\"${dtok}" ;;
      queued-ready)            echo "who=machine  class=queued-ready id=${id} since=${elapsed} note=\"dispatchable — next tick\"${dtok}" ;;
      deferred-capacity)       echo "who=machine  class=deferred-capacity id=${id} since=${elapsed} note=\"held by WIP ceiling\"${dtok}" ;;
      guarded-path)            echo "who=operator class=guarded-path id=${id} since=${elapsed} note=\"pin-only guarded path — operator push needed\"${dtok}" ;;
      orphan-unarmed)          echo "who=operator class=orphan-unarmed id=${id} since=${elapsed} note=\"open PR not on merge path — arm or park\"${dtok}" ;;
      container)               echo "who=none     class=container id=${id} note=\"post-launch bucket, container\"${dtok}" ;;
      backlog-aggregate)       echo "who=operator class=backlog-aggregate id=${repo}/aggregate note=\"suitable-unqueued backlog\"" ;;
      *)                       echo "who=${who} class=${class} id=${id} since=${elapsed}${dtok}" ;;
    esac
    had_rows=1
  done <<< "$rows"

  [ "$had_rows" = 0 ] && echo "# no classified items from current tick"

  # Emit platform-request rows (ADR-119)
  if [ -n "$demand_rows" ]; then
    printf '%s\n' "$demand_rows"
  fi

  exit 0
fi

echo "board — stack $stack ($mrepos repos) · $hdr"

[ -n "$sec_review" ] && { printf '\n§ REVIEW (codeowner queue)\n'; printf '%s' "$sec_review"; }
[ -n "$sec_fix" ] && { printf '\n§ FIX (seat PRs awaiting your fix round)\n'; printf '%s' "$sec_fix"; }
[ -n "$sec_solve" ] && { printf '\n§ SOLVE (parks & latches)\n'; printf '%s' "$sec_solve"; }
[ -n "$sec_triage" ] && { printf '\n§ TRIAGE\n'; printf '%s' "$sec_triage"; }
[ -n "$sec_verdict" ] && { printf '\n§ VERDICT DUE\n'; printf '%s' "$sec_verdict"; }
[ -n "$sec_backlog" ] && { printf '\n§ BACKLOG (suitable, unqueued)\n'; printf '%s' "$sec_backlog"; }
[ -n "$demand_section" ] && { printf '\n§ DEMAND (platform-request)\n'; printf '%s\n' "$demand_section"; }

cnt() { printf '%s' "$1" | grep -c '[^[:space:]]' 2>/dev/null || true; }
nreview="$(cnt "$sec_review")"; nfix="$(cnt "$sec_fix")"; nsolve="$(cnt "$sec_solve")"; ntriage="$(cnt "$sec_triage")"; nverdict="$(cnt "$sec_verdict")"; ndemand="$(printf '%s' "$demand_section" | grep -c '^[^ 	]' 2>/dev/null || true)"
printf '\ntotals — review: %s · fix: %s · solve: %s · triage: %s · verdict-due: %s · backlog: %s · demand: %s\n' \
  "$nreview" "$nfix" "$nsolve" "$ntriage" "$nverdict" "$nback" "$ndemand"
if [ "$nfail" -gt 0 ]; then
  echo "⚠ $nfail repo fetch(es) failed — the totals above may be incomplete (see WARN on stderr)"
fi

exit 0
