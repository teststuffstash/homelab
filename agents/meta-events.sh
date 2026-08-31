#!/usr/bin/env bash
# meta-events.sh — THE consolidated meta-seat event loop (FU-166 leg (b), 2026-08-12).
#
# One Monitor arms this; it polls cheap on a 120s tick, diffs each source against durable state,
# Sources: needsmeta · newissue (org-wide, 24h window) · seatpr · goalcmt · alert · famine ·
# stint · blockpark (blocking-class codeowner parks — 2026-08-31).
# and prints ONLY deltas — a quiet loop wakes nobody (a Monitor line is what wakes the seat, so
# edge-detection IS the token economy). ~2-min worst-case latency on the classes the seat serves.
#
# Lessons encoded (the file is the register of why it looks like this):
#   - liveness-not-outputs (2026-07-21): every source is a SET diff with dedup keys, never a log tail.
#   - "too many monitors" (2026-08-08): ONE loop, classed lines; needs-meta is absorbed as a source.
#   - rule #6: a failed probe HOLDS its previous state (no mass-CLEAR churn) and emits one
#     deduplicated PROBEFAIL event — silence is never a verdict.
#   - FU-084: REST + Alertmanager + Prometheus only; the single search call is 1/tick against the
#     30/min search pool. No GraphQL.
#   - Jail PAT: no statusCheckRollup anywhere (Checks perm absent — the hard-fail class).
#
# Sources (per-tick modulo keeps the call budget ~6-8 REST/tick ≈ 250/hr):
#   NEEDSMETA  every 2nd tick — `agents/meta-needs-attention.sh` verbatim (parks, blocked,
#              unlabeled, codeowner parks); its lines are the set elements.
#   GOALCMT    every tick — NEW User comments on open `task/goal` issues (the #278 charter-comment
#              lesson: operator directives on goal threads had no consumer).
#   ALERT      every tick — Alertmanager active fingerprint set (firing/resolved edges).
#   FAMINE     every tick — argo Pending workflow gauge with hysteresis (≥8 raises, ≤2 clears):
#              the doorbell-convoy signal until the FU-168 fixes land.
#
# Usage:  bash agents/meta-events.sh          # the loop (arm via Monitor; verify by process)
#         bash agents/meta-events.sh --once   # one tick; on a cold state dir this prints the
#                                             # full standing set — the fresh-session bootstrap view
set -u
STATE="${META_EVENTS_STATE:-$HOME/.claude/meta-events}"; mkdir -p "$STATE"
INTERVAL="${META_EVENTS_INTERVAL:-120}"
PROM="${META_EVENTS_PROM:-http://192.168.40.13:9090}"
AM="${META_EVENTS_AM:-http://192.168.40.14:9093}"
ORG=teststuffstash
HERE="$(cd "$(dirname "$0")" && pwd)"
TICK=0

emit() { printf 'META-EVENT %s %s\n' "$(date -u +%H:%M:%SZ)" "$1"; }
clearln() { printf 'META-CLEAR %s %s\n' "$(date -u +%H:%M:%SZ)" "$1"; }

# diff_source <name> <newfile> — prints event/clear lines vs stored state, then commits newfile.
diff_source() {
  local name="$1" new="$2" old="$STATE/$1.set"
  touch "$old"
  comm -13 <(sort -u "$old") <(sort -u "$new") | while IFS= read -r l; do emit "$l"; done
  comm -23 <(sort -u "$old") <(sort -u "$new") | while IFS= read -r l; do clearln "$l"; done
  sort -u "$new" > "$old"
}

# hold_source <name> <reason> — probe failed: keep old state, surface ONE deduped PROBEFAIL.
hold_source() {
  local name="$1" reason="$2" old="$STATE/$1.set" tmp
  tmp="$(mktemp)"; touch "$old"
  { cat "$old" | grep -v '^PROBEFAIL|' || true; printf 'PROBEFAIL|%s|%s\n' "$name" "$reason"; } > "$tmp"
  diff_source "$name" "$tmp"; rm -f "$tmp"
}

src_needsmeta() {
  local tmp; tmp="$(mktemp)"
  if bash "$HERE/meta-needs-attention.sh" --once > "$tmp" 2>/dev/null; then
    # each non-empty line is a set element, keyed by its own content
    awk 'NF {print "NEEDSMETA|" $0}' "$tmp" > "$tmp.set"
    diff_source needsmeta "$tmp.set"
  else
    hold_source needsmeta "meta-needs-attention.sh failed"
  fi
  rm -f "$tmp" "$tmp.set" 2>/dev/null
}


# NEW ISSUES, trailing 24h — the source the 2026-08-19 sitting was missing: three bot-filed
# issues (#616/#617/#629) reached the seat only when the operator pasted their URLs.
# PER-REPO REST LIST, deliberately NOT search (PR#632 r1): the search index under a fine-grained
# PAT can silently drop private-repo results with a clean 200 (the FU-108 exporter class) — a
# per-repo `gh issue list` either answers for that repo or FAILS for it, and a failed repo read
# holds state loudly (rule #6) instead of looking healthy while blind. Cost: one REST call per
# repo per tick (~13 × 30/hr against the PAT's 5000/hr pool). The repo set = the claim
# universe (stacks.json mirror — the build-time consumer it exists for) + SEAT_REPOS, so an
# unmirrored repo is the one gap; org-wide-by-search bought silence, not coverage.
# The set is the trailing-24h window: an issue emits ONCE on first sight and CLEARs when it
# closes or ages out (the src_seatpr window shape). All authors deliberately included: bot
# filings are the motivating class, and an operator filing is a session pickup, not noise.
# ACT RULE (operator, 2026-08-19): the seat TRIAGES platform-claim repos only; a stack-repo
# event is the stack's own loop/jail's to act on — record it, skip it, unless the operator
# points at it. The watch stays fleet-wide because operator-lane strays have no machine owner.
src_newissue() {
  local tmp since r ok=1 repos
  tmp="$(mktemp)"; : > "$tmp"
  since="$(date -u -d '-24 hours' +%Y-%m-%dT%H:%M:%SZ)"
  # The claim-universe read FAILS LOUDLY (PR#632 r2 — the r1 class one level up): SEAT_REPOS is
  # always non-empty, so a swallowed jq failure here would silently shrink the watch to 4 repos
  # while every tick reports success. An unreadable mirror holds the source instead.
  local stack_repos
  if ! stack_repos="$(jq -r '.stacks[].repos[]' "$HERE/stacks.json" 2>/dev/null)" || [ -z "$stack_repos" ]; then
    hold_source newissue "stacks.json repo universe unreadable"; rm -f "$tmp"; return
  fi
  repos="$(printf '%s\n%s\n' "$stack_repos" "$(printf '%s\n' $SEAT_REPOS)" | sort -u)"
  for r in $repos; do
    gh issue list -R "$ORG/$r" --state open --limit 25 --json number,author,title,createdAt       --jq ".[] | select(.createdAt >= \"$since\") | \"NEWISSUE|$r#\(.number)|\(.author.login)|\(.title[0:70])\""       >> "$tmp" 2>/dev/null || ok=0
  done
  if [ "$ok" = 1 ]; then diff_source newissue "$tmp"
  else hold_source newissue "issue list failed for ≥1 repo"; fi
  rm -f "$tmp"
}

src_goalcmt() {
  local tmp; tmp="$(mktemp)"
  # one search call: the open goals (long-lived; search lag acceptable here, unlike dispatch)
  if ! gh api "search/issues?q=org:${ORG}+is:issue+label:task/goal+state:open&per_page=20" \
      --jq '.items[] | [.repository_url, .number] | @tsv' > "$tmp" 2>/dev/null; then
    hold_source goalcmt "goal search failed"; rm -f "$tmp"; return
  fi
  : > "$tmp.set"
  while IFS=$'\t' read -r rurl n; do
    [ -n "${n:-}" ] || continue
    local repo="${rurl##*/repos/}" curfile="$STATE/goalcmt-cursor-${rurl##*/}-$n"
    local since; since="$(cat "$curfile" 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
    # User (non-bot) comments since the cursor; the cursor advances only on a served read
    local out
    if out="$(gh api "repos/$repo/issues/$n/comments?since=$since&per_page=30" \
        --jq '.[] | select(.user.type=="User") | [.id, (.body|split("\n")[0][0:90])] | @tsv' 2>/dev/null)"; then
      printf '%s\n' "$out" | awk -v r="$repo" -v n="$n" -F'\t' \
        'NF {print "GOALCMT|" r "#" n "/" $1 "|operator comment: " $2}' >> "$tmp.set"
      date -u +%Y-%m-%dT%H:%M:%SZ > "$curfile"
    fi
  done < "$tmp"
  # GOALCMT events are one-shot (a comment never "clears"): merge into cumulative seen-set
  cat "$STATE/goalcmt.set" 2>/dev/null >> "$tmp.set" || true
  diff_source goalcmt "$tmp.set"
  rm -f "$tmp" "$tmp.set" 2>/dev/null
}

src_alert() {
  local tmp body; tmp="$(mktemp)"
  # keyed on (alertname, namespace) — NEVER the fingerprint: instance churn re-keys fingerprints
  # (the #355 restart-gap identity lesson) and would flap this set forever. Watchdog (the
  # always-firing liveness canary) and InfoInhibitor (stock machinery) are excluded.
  # ⚠ Guard the CURL's exit, never the pipeline's: `if curl | jq | sort > tmp` tests SORT's
  # exit, so an unreachable Alertmanager fed jq empty stdin and served an EMPTY set as truth —
  # a 10s blip mass-cleared five live alerts (Go latch included) at 2026-08-25 17:31Z. The
  # pipe-filter-a-gate class (CLAUDE.md §lanes), on a read instead of a push.
  if body="$(curl -sf -m 10 "$AM/api/v2/alerts?active=true&silenced=false")"; then
    if printf '%s' "$body" \
        | jq -r '.[] | select(.labels.alertname != "Watchdog" and .labels.alertname != "InfoInhibitor")
                 | "ALERT|\(.labels.alertname)/\(.labels.namespace // "-")|firing"' | sort -u > "$tmp" 2>/dev/null; then
      diff_source alert "$tmp"
    else
      hold_source alert "alert payload unparseable"
    fi
  else
    hold_source alert "alertmanager unreachable"
  fi
  rm -f "$tmp"
}

src_famine() {
  local v tmp; tmp="$(mktemp)"
  v="$(curl -sf -m 10 -G "$PROM/api/v1/query" \
        --data-urlencode 'query=max(argo_workflows_gauge{phase="Pending"})' \
        | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null)" || v=""
  case "$v" in (''|*[!0-9.]*) hold_source famine "prometheus unreachable"; rm -f "$tmp"; return;; esac
  local prev; prev="$(cat "$STATE/famine.level" 2>/dev/null || echo ok)"
  local level="$prev"
  awk -v v="$v" 'BEGIN{exit !(v>=8)}' && level=high
  [ "$prev" = high ] && awk -v v="$v" 'BEGIN{exit !(v<=2)}' && level=ok
  echo "$level" > "$STATE/famine.level"
  if [ "$level" = high ]; then printf 'FAMINE|convoy|pending workflows ≥8 (now %s)\n' "$v" > "$tmp"; else : > "$tmp"; fi
  diff_source famine "$tmp"; rm -f "$tmp"
}

# SEATPR — the fix-on-feedback loop's own events (added 2026-08-12 after PR#381's approval went
# unseen: needs-meta reports STUCK states by design, so a healthy verdict→merge — and worse, a
# CHANGES_REQUESTED the seat must act on — had no source). Set lines carry the phase, so a
# verdict flip emits (old clears, new fires); merged PRs hold a line for 24h. CR lines carry
# the newest CR verdict's timestamp (@...) so a SAME-verdict re-review still edges — without it
# #398's round-2 CHANGES_REQUESTED (15:59, three minutes after the fix push) was invisible and
# the seat sat blind for an hour (operator caught it, 2026-08-12).
# CI-RED belt (2026-08-12, operator catch: PR#394 sat CI-red UNSEEN — a red check parks a PR in
# a state no review-decision edge crosses, because the reviewer only lifts green+current PRs, so
# the phase line above never moves). For OPEN seat PRs the head commit's `CI` run conclusion is
# read via `gh run list --commit` (Actions:read) — NEVER statusCheckRollup, which the jail PAT
# hard-fails whole (no Checks scope). A red head emits a set-line, so it fires once and clears
# on the green push. A failed conclusion read emits nothing — needs-meta's unreviewed-PR clause
# is the level backstop underneath.
SEAT_REPOS="${SEAT_REPOS:-homelab agent-runtime agent-coordinator openrouter-operator}"
src_seatpr() {
  local tmp me; tmp="$(mktemp)"; : > "$tmp"
  me="$(cat "$STATE/seatpr.login" 2>/dev/null)" || me=""
  [ -n "$me" ] || { me="$(gh api user --jq .login 2>/dev/null)" && echo "$me" > "$STATE/seatpr.login"; }
  [ -n "$me" ] || { hold_source seatpr "cannot resolve own login"; rm -f "$tmp"; return; }
  local r ok=1 prs pr_sha n sha c
  for r in $SEAT_REPOS; do
    prs="$(gh pr list -R "$ORG/$r" --state all --limit 15 \
        --json number,author,state,reviewDecision,mergedAt,headRefOid,latestReviews 2>/dev/null)" || { ok=0; continue; }
    # pipe to REAL jq — `gh --jq` takes no --arg (the standing coordinator-scan rule)
    printf '%s' "$prs" | jq -r --arg me "$me" --arg r "$r" \
        '.[] | select(.author.login==$me)
         | select(.state=="OPEN" or ((.mergedAt // "") > (now - 86400 | todate)))
         | "SEATPR|\($r)#\(.number)|\(if .state=="MERGED" then "MERGED" else (.reviewDecision // "AWAITING-REVIEW") end)\(if .state != "MERGED" and .reviewDecision == "CHANGES_REQUESTED" then "@" + ([.latestReviews[]? | select(.state == "CHANGES_REQUESTED") | .submittedAt] | max // "?") else "" end)"' \
        >> "$tmp" || ok=0
    for pr_sha in $(printf '%s' "$prs" | jq -r --arg me "$me" \
        '.[] | select(.author.login==$me and .state=="OPEN") | "\(.number):\(.headRefOid)"' 2>/dev/null); do
      n="${pr_sha%%:*}"; sha="${pr_sha##*:}"
      c="$(gh run list -R "$ORG/$r" --commit "$sha" --json name,conclusion \
             --jq '[.[] | select(.name=="CI")][0].conclusion // ""' 2>/dev/null)" || c=""
      case "$c" in failure|timed_out|startup_failure) echo "SEATPR|${r}#${n}|CI-RED" >> "$tmp";; esac
    done
  done
  if [ "$ok" = 1 ]; then diff_source seatpr "$tmp"; else hold_source seatpr "gh pr list failed"; fi
  rm -f "$tmp"
}

# BLOCKPARK — blocking-class codeowner parks (operator direction, 2026-08-31: "the jail should
# monitor for these blocking type codeowner reviews more actively"). The drainage-economics
# ruling made BLOCKING the only class with machinery urgency, and its test structural: a parked
# PR whose closing issue BLOCKS other work (incoming `dependencies/blocking` edges — the ADR-119
# un-park shape) or is hotfix-class (🚨 title). Ordinary parks stay NEEDSMETA/CodeownerParkWaiting
# territory; this source exists so a park that gates a wedged stack ride surfaces as its own
# high-priority class instead of blending into the park pile.
# Parked predicate = OPEN ∧ reviewDecision REVIEW_REQUIRED ∧ a bot APPROVED among latestReviews
# (green-at-review is implied by the bot verdict; no statusCheckRollup — the jail-PAT hard-fail
# class). Every 2nd tick (even ticks — needsmeta takes odd), one pr-list per claim-universe repo
# + one dependencies read per parked closing issue (parks are few; ~7 REST/tick amortized).
# A failed read HOLDS the source (rule #6) — a blind tick must not clear a standing block line.
src_blockpark() {
  local tmp repos stack_repos r prs ok=1
  tmp="$(mktemp)"; : > "$tmp"
  if ! stack_repos="$(jq -r '.stacks[].repos[]' "$HERE/stacks.json" 2>/dev/null)" || [ -z "$stack_repos" ]; then
    hold_source blockpark "stacks.json repo universe unreadable"; rm -f "$tmp"; return
  fi
  repos="$(printf '%s\n%s\n' "$stack_repos" "$(printf '%s\n' $SEAT_REPOS)" | sort -u)"
  for r in $repos; do
    prs="$(gh pr list -R "$ORG/$r" --state open --limit 20 \
        --json number,reviewDecision,latestReviews,closingIssuesReferences 2>/dev/null)" || { ok=0; continue; }
    # parked = REVIEW_REQUIRED with a bot approval at latestReviews; emit per closing issue
    local rows irepo inum ititle bcount
    rows="$(printf '%s' "$prs" | jq -r '.[]
        | select(.reviewDecision=="REVIEW_REQUIRED")
        | select([.latestReviews[]? | select(.state=="APPROVED")] | length > 0)
        | .number as $pr | (.closingIssuesReferences[]? // empty)
        | "\($pr)\t\(.repository.name // "")\t\(.number)\t\((.title // "")[0:60])"' 2>/dev/null)" || { ok=0; continue; }
    [ -n "$rows" ] || continue
    while IFS=$'\t' read -r prn irepo inum ititle; do
      [ -n "${inum:-}" ] || continue
      [ -n "$irepo" ] || irepo="$r"
      if ! bcount="$(gh api "repos/$ORG/$irepo/issues/$inum/dependencies/blocking" --jq 'length' 2>/dev/null)"; then
        ok=0; continue
      fi
      if [ "${bcount:-0}" -gt 0 ] 2>/dev/null; then
        printf 'BLOCKPARK|%s#%s|park gates %s blocked issue(s) via %s#%s — read it AHEAD of the pile\n' \
          "$r" "$prn" "$bcount" "$irepo" "$inum" >> "$tmp"
      elif printf '%s' "$ititle" | grep -q '🚨'; then
        printf 'BLOCKPARK|%s#%s|park on hotfix-class issue %s#%s (🚨) — read it AHEAD of the pile\n' \
          "$r" "$prn" "$irepo" "$inum" >> "$tmp"
      fi
    done <<BPROWS
$rows
BPROWS
  done
  if [ "$ok" = 1 ]; then diff_source blockpark "$tmp"; else hold_source blockpark "pr/dependencies read failed for ≥1 repo"; fi
  rm -f "$tmp"
}

# STINT — the jail stint's burn-down (2026-08-19, chainless-redesign §The jail stint). Armed by
# the seat writing "owner/repo#N" to $STATE/stint at stint start; absent/empty = the source emits
# a clear-set (stale lines from a disarmed stint edge out). One sub-issue list per tick. The
# ORIGINAL child set is snapshotted on first sight ($STATE/stint.originals.<n>), so "originals
# done" — the FIRST-closeout trigger, the sweep the simple watches never ran — is an edge
# diff_source produces naturally; sprouts (children linked after the snapshot) count separately.
# The CLOSEOUT-DUE line stands as a set-line until the seat closes the parent or disarms.
src_stint() {
  local ref tmp repo n ids orig totalo openo opens num st
  ref="$(cat "$STATE/stint" 2>/dev/null || true)"
  if [ -z "$ref" ]; then tmp="$(mktemp)"; : > "$tmp"; diff_source stint "$tmp"; rm -f "$tmp"; return; fi
  repo="${ref%#*}"; n="${ref##*#}"
  ids="$(gh api "repos/$repo/issues/$n/sub_issues?per_page=100" --paginate \
        --jq '.[] | "\(.number):\(.state)"' 2>/dev/null)" || { hold_source stint "sub_issues read failed ($ref)"; return; }
  [ -f "$STATE/stint.originals.$n" ] || printf '%s\n' "$ids" | cut -d: -f1 > "$STATE/stint.originals.$n"
  orig="$(cat "$STATE/stint.originals.$n")"
  totalo="$(printf '%s\n' "$orig" | grep -c . || true)"
  openo=0; opens=0
  while IFS=: read -r num st; do
    [ -n "$num" ] || continue
    if printf '%s\n' "$orig" | grep -qx "$num"; then
      [ "$st" = "open" ] && openo=$((openo+1))
    else
      [ "$st" = "open" ] && opens=$((opens+1))
    fi
  done <<WAVEIDS
$ids
WAVEIDS
  tmp="$(mktemp)"
  {
    printf 'STINT|%s|originals open %s/%s · sprouts open %s\n' "$ref" "$openo" "$totalo" "$opens"
    if [ "$openo" = 0 ] && [ "$totalo" != 0 ]; then
      printf 'STINT|%s|CLOSEOUT-DUE — originals done: run the closeout sitting (docs-cleanup + FU sweep + built-vs-left analysis + sprout disposition; chainless-redesign §The jail stint)\n' "$ref"
    fi
  } > "$tmp"
  diff_source stint "$tmp"; rm -f "$tmp"
}

tick() {
  TICK=$((TICK+1))
  # ONCE_ALL (the --once contract): a cold-state single pass must print the FULL standing set —
  # the fresh-session bootstrap view — so BOTH parity-gated sources run (PR#1114 review catch:
  # the even-tick gate alone made --once structurally blind to BLOCKPARK, the one class it
  # exists to surface ahead of the pile).
  if [ "${ONCE_ALL:-0}" = 1 ]; then
    src_needsmeta
    src_blockpark
  else
    [ $((TICK % 2)) -eq 1 ] && src_needsmeta
    [ $((TICK % 2)) -eq 0 ] && src_blockpark
  fi
  src_newissue
  src_seatpr
  src_goalcmt
  src_alert
  src_famine
  src_stint
}

if [ "${1:-}" = "--once" ]; then TICK=0; ONCE_ALL=1; tick; exit 0; fi
echo "meta-events: loop up (interval ${INTERVAL}s, state $STATE)"
while true; do tick; sleep "$INTERVAL"; done
