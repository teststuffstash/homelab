#!/usr/bin/env bash
# agents/update-pr-branch.sh — the merge-path UPDATER (FU-041 / MP-T02/MP-T06) as a platform-owned
# script (ADR-111, homelab#742; replaces `adRise/update-pr-branch` + the reusable workflow's shell
# steps — MP-T02's standing "behavior owned upstream" liability ends here).
#
#   GH_TOKEN=<homelab-merge App token> bash agents/update-pr-branch.sh <owner/repo>
#
# Keeps exactly ONE PR per (repo, BASE) LANE current with its base per pass so GitHub auto-merge
# can fire (the ruleset requires an up-to-date branch). ADR-125: the lane, not the repo, is the
# serialization unit — a master-lane update cannot stale a goal-lane PR's approval, so holding the
# goal lane behind it bought nothing and cost the goal its wall-clock. MUST run with the homelab-merge App token, not a workflow
# GITHUB_TOKEN (a GITHUB_TOKEN push doesn't re-trigger `ci`, so a strict branch never sees green).
# In-cluster the token arrives as the `updater-git` ESO secret (homelab#744); a jail hand-run
# mints one ad-hoc. See docs/agents/merge-path.md §Chosen design ▸2 + §Updater token.
#
# Level-triggered: each pass re-reads the world and acts on at most one main-leg update PER LANE; a
# lost doorbell costs nothing (the */15 cron re-derives). Races are safe: update-branch carries
# expected_head_sha (homelab#986), so a concurrent push causes 422 (skip, next pass re-lists)
# instead of clobbering the commit. The merge gate is GitHub's, evaluated once.
#
# Ported guard history (the comments below are load-bearing — they carry the incidents):
#   - update BEFORE review (required_approval_count: 0 in the action era): approval-then-update
#     would dismiss the fresh approval on every catch-up merge (merge-path.md §Why update-before-review).
#   - NO green requirement on the main pick (2026-07-10): requiring passed checks WEDGES — a
#     base-side CI fix can only reach a PR through an update, but the gate refused updates while
#     the PR's checks were red FROM the base-side bug (deploy-pins #20/#21). Updating a red PR is
#     harmless: strict checks re-run and still gate the merge.
#   - armed-only (require_auto_merge_enabled): only PRs actually queued to land — arming is the
#     boundary between the reflex plane and the coordinator's un-armed lanes (major/, drafts).
#   - MERGE-READY-ONLY (2026-09-05, homelab#1452): "update before review" is retired. Leg 1 now
#     brings current ONLY a PR that has nothing but currency + CI left before auto-merge — the
#     platform's own merge queue, built where a GitHub merge queue could not go (private stack
#     repos copy this repo, so the fix must be platform-native). See the leg-1 comment below.
set -euo pipefail

REPO="${1:?usage: update-pr-branch.sh <owner/repo>}"
. "$(cd "$(dirname "$0")" && pwd)/machine-comment.sh"   # gh_label_add / gh_label_rm — the REST label transport

# The reviewer bot's login, normalized: GitHub's REST surface says `homelab-reviewer[bot]` where
# GraphQL says `homelab-reviewer` (the [bot]-suffix mismatch, review-reflex.sh). Compare stripped.
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"

# UPDATER_MERGE_READY_ONLY=1 (default) = the #1452 merge-queue predicate; =0 = the pre-#1452 pick
# (armed ∧ BEHIND, no approval needed). The knob exists so the L-scenario comparison the issue
# asks for is one env flip, not a revert.
if [ "${UPDATER_MERGE_READY_ONLY:-1}" = "0" ]; then MERGE_READY_ONLY=false; else MERGE_READY_ONLY=true; fi

# One list serves all three legs — the snapshot is per-pass by design (level-triggered; anything
# it misses, the next pass sees). `reviews` rides along for the merge-ready predicate; `commits`
# deliberately does NOT: gh expands it to commits(first:100){authors(first:100)}, and at
# --limit 100 the query asks for 1,000,000 possible nodes against GitHub's 500,000 cap — the whole
# list is REJECTED before a single PR is read (every pass on every repo red for 65h, 2026-09-05
# 22:30 → 09-08, the first cron tick after homelab#1465 shipped the field; --limit 50 still lands
# at 505,050). The commit half of "approved at head" is probed per candidate in leg 1 instead.
PRS="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,latestReviews,baseRefName,reviews,author,headRefName)"

# RENOVATE OWNS ITS OWN CURRENCY (ADR-141 (minted in homelab PR#2003 — GitHub Actions majors merge on their own; this carve-out is one of its consequences), 2026-09-27). Renovate stops maintaining a branch the
# moment a commit it did not author lands on it (its edited-PR rule — this updater's merge commit
# counts: agent-coordinator#14 went "Edited/Blocked" after one update-branch and its third
# `actions/checkout` call site, added on master later, was never bumped). The GitHub Actions rules
# in .github/renovate-global.json ride `rebaseWhen: behind-base-branch`, so an UNTOUCHED Renovate
# PR is rebased by Renovate itself, which also re-extracts master on each rebase. Predicate: the
# PR author is Renovate AND every non-merge commit is Renovate-authored — then this updater keeps
# its hands off. A Renovate PR a worker has pushed to (the FU-046 deps-review shape) is NOT
# skipped: Renovate has already stopped maintaining it, and this belt is its only currency.
# EVERY Renovate PR, since 2026-10-12 (ADR-153 — operator ruling after sleep-tracking#185):
# `rebaseWhen: behind-base-branch` is the ORG DEFAULT in .github/renovate-global.json (it was the two
# grouped Actions rules' alone, PR#2004 review, and this skip was scoped to `^renovate/github-actions
# (-major)?$`), so Renovate keeps every untouched PR current, rebases it on conflict and autocloses it
# when superseded — and this updater's merge is exactly what used to take those three abilities away
# (#185: one update-branch → "Edited/Blocked" → neither rebase nor autoclose, a zombie). ONE EXCEPTION,
# the merge-ready one: an untouched Renovate PR that is armed, APPROVED and GREEN has nothing but
# currency between it and the merge; the updater takes it so the fast path keeps its 15-min currency
# instead of Renovate's 6-h cron. Not green, not approved, conflicted: Renovate's. `renovate_green`
# reads the per-candidate probe (`renovate_probe`: commits + REST check-runs/status — renovate-currency.sh);
# an absent rollup is NOT green, an unreadable one HOLDS (fail toward leaving it to Renovate).
# ⚠ THE EXCEPTION CAN STILL MINT A ZOMBIE — so it HANDS BACK (2026-10-24). "Minutes to merge" holds
# only if the update's own CI lands before master moves again and stays green; Renovate's edited-PR
# rule counts the updater's MERGE commit too, and `renovate_untouched` (merge commits are not content)
# did not, so a PR whose fast-path update missed was handed "back to Renovate" by this script while
# Renovate had already disowned it. Live 2026-10-20: homelab#2754 (master moved in the SAME minute —
# #2748's agent-gateway deploy auto-bump; the duplicate `ci` run's CANCELLED entry then read not-green)
# and sleep-tracking#203 (the update pulled master's playwright bump in; its first mirror pull timed
# out) — both armed + approved + BEHIND, both "Edited/Blocked" at Renovate's 16:1x run, both still
# there four days later. So: an untouched PR that carries a non-Renovate MERGE commit
# (`renovate_merged_into` — only this updater's update-branch writes those) and is not merge-ready is
# handed back through Renovate's own escape hatch, the rebase/retry checkbox (`renovate_handback`):
# Renovate's next run rebuilds the branch from master + its change, the foreign merge is gone, and
# the PR is Renovate's again. Same box, same idempotence as the scan's merge-conflict rebase-tick
# (coordinator-scan.sh, homelab#1977); a worker-adapted branch never reaches it (not untouched).
# `renovate_green` also drops a CANCELLED entry that a same-named sibling outlives — a superseded
# duplicate run (two `synchronize` events on one update) is not a red check (#2754's rollup).
# `author` and `headRefName` are scalar list fields (no node cost); commit authorship comes from
# the per-candidate `gh pr view --json commits` probe leg 1 already pays for bot-approved candidates.
# ⚠ LOGIN SHAPE (homelab#2007, 2026-09-27): `gh pr list --json author` reports an App as
# `app/homelab-renovate-1234` (the `app/` prefix), `pr view --json commits … authors[].login` as
# the same or `homelab-renovate-1234[bot]`, and GraphQL `reviews[].author.login` without either.
# A raw `startswith` on the list shape matched nothing, so the updater merged master into
# homelab#2007 (branch renovate/github-actions, one Renovate commit) and Renovate dropped the
# branch as edited — the exact defect this skip exists to prevent. Normalize BOTH affixes before
# the prefix test, the same `sub("\\[bot\\]$"; "")` idiom the reviewer-identity reads below use.
# The predicate's functions (renovate_author/_probe/_green/_untouched/_merged_into/_handback) live in
# ONE file shared with coordinator-scan.sh's FU-124 nudge — two copies of it was how the nudge kept
# minting the zombies after this file was fixed (2026-10-24).
. "$(cd "$(dirname "$0")" && pwd)/renovate-currency.sh"

# Defensive: create the label idempotently first (the porcelain add FAILED on a missing label; the
# REST add would auto-create it grey — this keeps the colour + description)
# (the AgentStack claim provisions it via IssueLabels, but this survives a not-yet-claimed repo or
# a deleted label — the reflex must never hard-fail and block the merge path).
#
# Label writes ride a SEPARATE identity (the #744 decide-at-build point, decided): gh's label
# mutations need issues:write, and the homelab-merge App deliberately carries NO Issues permission
# (docs/github-apps.yaml `absent:` — "a leaked merge key must not grant issue writes"; in the
# action era the labeler step used the workflow's own GITHUB_TOKEN for exactly this reason).
# In-cluster the WorkflowTemplate hands coordinator-git (issues:write across the agent repos) as
# UPDATER_LABEL_TOKEN; absent (a jail hand-run), the main token is tried and a refusal stays
# loud-but-non-fatal.
#
# ⚠ REST, NEVER `gh pr edit --add-label`/`--remove-label` (homelab#2476, FU-290's 2026-10-10 19:00Z
# drain). `gh pr edit` label flags are GraphQL mutations (addLabelsToLabelable/removeLabelsFrom…);
# when the App installation's GraphQL pool is drained (installation 142724430, "API rate limit
# already exceeded") the write fails even though the installation's REST pool is still open — and
# the old code then printed a WRONG diagnosis ("token lacks issues:write?"), so #2476 sat armed +
# DIRTY with no label and no correct signal either. `gh api -X POST/DELETE .../labels[...]` draws on
# the separate REST (core) pool and keeps labeling live through a GraphQL-only drain. Label creation
# rides the same REST call so neither leg ever touches GraphQL.
label_conflict() {
  local tok="${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}" create_err add_err
  create_err="$(GH_TOKEN="$tok" gh api -X POST "repos/$REPO/labels" \
    -f name=merge-conflict -f color=e11d21 \
    -f description="PR branch conflicts with master — updater can't auto-resolve" 2>&1 >/dev/null)" || true
  # A create failure is expected and fine once the label exists (422 "already_exists") — the add
  # below is what actually matters, and it reports create's real error too if that one is why it fails.
  # gh_label_add (machine-comment.sh) is the one REST label transport; its stderr IS gh's error.
  if ! add_err="$(GH_TOKEN="$tok" gh_label_add "$REPO" "$1" merge-conflict 2>&1)"; then
    echo "updater[$REPO]: could not label #$1 merge-conflict — ${add_err:-gh gave no output}${create_err:+ (label create: $create_err)} — the */15 pass retries"
  fi
}

# ── leg 1: the main pick ── oldest armed + BEHIND + not-changes-requested, ONE per (repo, base)
# LANE per pass (FIFO within the lane — `sort: created asc` in the action era). CHANGES_REQUESTED
# PRs are the unstrand leg's (below); DIRTY PRs are the labeler's (an update-branch call cannot
# resolve a conflict).
# ADR-125 (2), homelab#1422: the pick groups by `baseRefName` before taking the oldest. One update
# per repo per pass serialized lanes that cannot invalidate each other — the merge -> behind ->
# dismiss-approval chain this leg paces only ever runs between PRs sharing a base. Legs 2 and 3
# below are untouched: the unstrand belt is per-PR by construction, and the labeler is a sweep.
# Codeowner-parked PRs (bot-approved at head ∧ reviewDecision == REVIEW_REQUIRED ∧ armed) are
# SKIPPED — the updater leaves them BEHIND so they accumulate no CI cost between human sittings.
# At human approval reviewDecision flips to APPROVED and the next pass refreshes (one CI cycle).
# Measured: PR#1347/#1352/#1354, 47 master moves, 36/32/27 merge commits each, 39/41 CI runs
# each — ≈3.5h runner time on three PRs whose content never changed (homelab#887, 2026-09-04).
# ⚠ MERGE-READY ONLY (homelab#1452, 2026-09-05) — THE PLATFORM-NATIVE MERGE QUEUE. Until now this
# leg updated EVERY armed+BEHIND PR on every master move: with N armed PRs and M master moves,
# ~N×M CI runs (measured 2026-09-05: ≥300 workflow runs on homelab in one day, 62 cancelled
# mid-flight, org-wide job queue wait 22-40 min on ONE 3-slot ARC scale set — homelab's churn
# starves every other stack, FU-218). The ordering it served ("update before review") lost its
# premise when PR#1446 admitted BEHIND-but-green PRs to their first review: update-branch merges
# do NOT dismiss a verdict (GitHub re-points commit_id; PR#1386 survived four). Currency is
# therefore needed at exactly ONE moment — merge — which is a merge queue's whole insight, and a
# GitHub merge queue is the wrong shape here (homelab is the public source-of-truth repo every
# private stack repo copies; the fix must be platform-native so they all get it).
# So: update only what is MERGE-READY — nothing but currency + CI left before auto-merge fires.
#   * reviewDecision == APPROVED — GitHub's own gate is satisfied (dismiss_stale_reviews_on_push
#     means APPROVED already implies "at the current content"), or
#   * reviewDecision == "" (a repo whose ruleset requires no approval) ∧ (bot_approved_head ∨ the
#     PR carries the `automerge` label — the review reflex's skip class, homelab#1896).
# Everything else stays BEHIND and costs nothing: an unreviewed PR is reviewed BEHIND (PR#1446), a
# changes-requested PR gets its fix round pushed BEHIND (CI runs on the content), a codeowner park
# waits for its human — the #887 skip is now just a special case of "not merge-ready".
# ⚠ THE PARK IS DECIDED BY `reviewDecision`, NOT RECONSTRUCTED FROM THE BOT'S REVIEWS (#1649). A
# `REVIEW_REQUIRED` PR has the review gate still open whatever `bot_approved_head` says, so the arm
# is never reached for one (see the guard in the loop): the #887 park skip used to live ONLY in the
# candidate pre-filter's `latestReviews` arm, and that arm is a PROBE-COST filter, never the
# enforcement. The two disagreed exactly on the platform's own documented trap: `latestReviews` is
# the latest review PER AUTHOR, so an approve-then-aside reviewer sequence (the PR#235 trap —
# docs/agents/* and 4 sibling readers carry the `reviews[]`, never `latestReviews[]` lesson) leaves
# it non-APPROVED while `reviews[]` still carries the APPROVED at head. A park in that shape was a
# candidate, and the arm below then re-admitted it → one update per master push for the whole park
# (measured #1649: PR#1576 ×87, PR#1540 ×92, PR#1541 ×50 — the class #1452 exists to end).
# NOT IMPLEMENTED, deliberately: the sole-codeowner waiver arm (author is the repo's only
# codeowner ⇒ REVIEW_REQUIRED is waivable). CODEOWNERS ownership is not readable from the picker's
# `gh pr list` snapshot, and this leg fails toward NOT updating: a park costs a pass, a wasted CI
# run is exactly what #1452 measures. This is behaviourally identical to the #887 park skip, which
# has been live since 2026-09-04 without stranding a homelab PR.
# `bot_approved_head` is review-reflex.sh's definition, restated (that script is a reflex loop, not
# a sourceable library): the newest bot APPROVED submittedAt must post-date the newest NON-MERGE
# commit — updater merge commits are not content, or this leg would invalidate its own approvals
# (the nine-review loop, oracle-fleet#57).
# The commit half is NOT in the snapshot (the node-cap note at the list call): it is probed per
# candidate with `gh pr view --json commits`. The candidate pre-filter above exists ONLY to keep
# that probe off the common BEHIND population (unreviewed, waiting for its first review) at zero
# API cost — it is not an admission rule: everything it lets through still faces the park guard and
# `bot_approved_head` below, and its `latestReviews` arm may be wrong (the trap above) without any
# consequence beyond one wasted candidate slot. An APPROVED reviewDecision is ready on the
# snapshot alone. An unreadable probe HOLDS with a line (rule #6 — this leg fails toward NOT
# updating; the */15 cron retries).
# The leg-1 and leg-2 DOMAINS are named jq defs because the hand-back sweep (leg 1b) is their
# complement — one spelling of each, read by both the leg and the sweep (homelab#1985 residual 5).
LEG_DOMAINS_JQ='
  def breakered: ([.labels[].name] | (index("agent/error") != null or index("agent/arbitrate") != null));
  def leg1_cand: .autoMergeRequest != null and .mergeStateStatus == "BEHIND"
                and .reviewDecision != "CHANGES_REQUESTED"
                and (.reviewDecision != "REVIEW_REQUIRED" or
                     ([((.latestReviews // [])[] | select(((.author.login // "")
                       | startswith("homelab-reviewer")) and .state == "APPROVED"))]
                      | length) == 0);
  def leg2_domain: .autoMergeRequest != null and .mergeStateStatus == "BEHIND"
                and .reviewDecision == "CHANGES_REQUESTED";'
cands="$(jq -c "$LEG_DOMAINS_JQ"' .[] | select(leg1_cand)' <<<"$PRS")"
ready="[]"
while read -r pr; do
  [ -n "$pr" ] || continue
  n="$(jq -r '.number' <<<"$pr")"
  cj=""
  if renovate_author "$pr"; then
    cj="$(renovate_probe "$REPO" "$n" "$(jq -r '.headRefOid // ""' <<<"$pr")")" || cj=""
    if [ -z "$cj" ]; then
      echo "updater[$REPO]: #$n commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)"
      continue
    fi
    # The merge-ready exception (ADR-153): untouched + green falls through to the admission below
    # (APPROVED / bot-approved / automerge) — currency is the only gap, this updater closes it.
    if renovate_untouched "$cj" && ! renovate_green "$cj"; then
      if renovate_merged_into "$cj"; then
        renovate_handback "$REPO" "$n" "updater[$REPO]:"
      else
        echo "updater[$REPO]: #$n Renovate-authored, untouched and not green — Renovate's to rebase (rebaseWhen behind-base-branch, ADR-153); skipping"
      fi
      continue
    fi
  fi
  if [ "$MERGE_READY_ONLY" = false ] || [ "$(jq -r '.reviewDecision' <<<"$pr")" = APPROVED ]; then
    ready="$(jq -c --argjson n "$n" '. + [$n]' <<<"$ready")"; continue
  fi
  # THE PARK GUARD (#1649) — the ONE enforcement of the codeowner park, and the reason the
  # candidate pre-filter above must never be read as it. A REVIEW_REQUIRED PR is not merge-ready by
  # GitHub's own computation: a review it requires has not been given, so there is more than
  # currency + CI left, and no reconstruction of the bot's review history may overrule that. This
  # also makes the guard probe-free — a park costs zero API calls, not just zero updates.
  if [ "$(jq -r '.reviewDecision' <<<"$pr")" = REVIEW_REQUIRED ]; then continue; fi
  # ARM 2, THE SKIP-CLASS HALF (homelab#1896). reviewDecision == "" here means the repo's ruleset
  # requires no approval (an approval-required repo reports REVIEW_REQUIRED/APPROVED/
  # CHANGES_REQUESTED, never ""). On such a repo the PR is merge-ready when EITHER the reviewer bot
  # approved at head (the #1452 arm below) OR it carries the `automerge` label — the review reflex's
  # SKIP class (docs/agents/merge-path.md §Decisions/FU-046; docs/agents/iac-lane.md). The
  # mechanical classes on the -iac repos are CI-only BY DESIGN, so the reflex never reviews them and
  # the bot-approval arm can never reach them: before this they stranded armed+BEHIND forever
  # (oracle-iac, 2026-09-21: 10 open PRs, all armed+BEHIND, the oldest from 09-16, ~500 updater
  # passes over them). The label condition is LOAD-BEARING: without it an ordinary unreviewed PR on
  # a no-approval repo would be updated before its review — the waste #1452 removes.
  # ⚠ BOTH halves are required (PR#2303 review, 2026-10-06): the arm tests `reviewDecision == ""`
  # AND the label. The park guard above excludes only REVIEW_REQUIRED, so a label-only arm would
  # read an `automerge` PR at CHANGES_REQUESTED as merge-ready and move its branch — contradicting
  # this file's header ("a changes-requested PR gets its fix round pushed BEHIND") and letting the
  # label bypass an approval-required repo's gate. `reviewDecision == ""` is the no-approval signal;
  # the label is the skip class. Neither alone is merge-ready.
  if [ "$(jq -r '.reviewDecision' <<<"$pr")" = "" ] \
     && [ "$(jq -r '[.labels[].name] | index("automerge") != null' <<<"$pr")" = "true" ]; then
    ready="$(jq -c --argjson n "$n" '. + [$n]' <<<"$ready")"; continue
  fi
  approved_at="$(jq -r --arg bot "$REVIEWER_LOGIN" '
    [ .reviews[]? | select(((.author.login // "") | sub("\\[bot\\]$"; "")) == $bot)
      | select(.state == "APPROVED") | .submittedAt ] | max // ""' <<<"$pr")"
  [ -n "$approved_at" ] || continue
  # Unreadable = the call failed OR the body is not the JSON asked for (a 200 that is not JSON is
  # the `garbage` stub mode, and the shape a proxy error takes live) — both HOLD, never a silent skip.
  if [ -z "$cj" ]; then   # not probed above (a non-Renovate author) — one probe per candidate
    cj="$(gh pr view "$n" --repo "$REPO" --json commits 2>/dev/null)" && jq -e '.commits' <<<"$cj" >/dev/null 2>&1 || cj=""
  fi
  if [ -z "$cj" ]; then
    echo "updater[$REPO]: #$n commit probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)"
    continue
  fi
  if jq -e --arg a "$approved_at" '
       ([ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not)
          | .committedDate ] | max // "") as $c | $a > $c' <<<"$cj" >/dev/null 2>&1; then
    ready="$(jq -c --argjson n "$n" '. + [$n]' <<<"$ready")"
  fi
done <<<"$cands"
# Per-lane ordered candidate lists (oldest first). The lane is the serialization unit (ADR-125
# (2)): at most ONE update LANDS per lane per pass. But a lane's oldest merge-ready member can be
# WEDGED — a persistent 422 (a conflict the DIRTY labeler has not yet seen, or a head that keeps
# racing) leaves `updatedAt` untouched, so it re-enters as the pick on every pass and starves every
# younger merge-ready member of the same lane indefinitely (homelab#2203: #2174 sat BEHIND 54h
# behind a wedged older member). The hop below is the non-blocking fix: within a lane, walk the
# members oldest-first and stop at the first SUCCESSFUL update. A failed attempt landed nothing, so
# it invalidated no approval and the lane's serialization is intact — the hop only spends the
# attempt the pass was already going to spend, and still lands at most one update per lane.
lanes="$(jq -c --argjson ready "$ready" '
  [.[] | select(.number as $n | $ready | index($n) != null)]
  | group_by(.baseRefName // "")
  | map(sort_by(.createdAt))' <<<"$PRS")"
if [ "$(jq 'length' <<<"$lanes")" -gt 0 ]; then
  # `while read` over a here-string: a pipe would run the body in a subshell, which costs nothing
  # today but is the shape that silently loses state the moment this leg keeps any.
  # The FIRST attempt's OUT line is deliberately unchanged: the lane is visible as the SET of
  # first-attempts in one pass (one line per lane), and re-wording it would have rewritten every
  # expected stream in the `updater` replay family for no behavioural reason. A HOP emits its own
  # line, so no pre-#2203 expected stream moves.
  while IFS= read -r lane; do
    [ -n "$lane" ] || continue
    first=1
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      pick="${member%% *}"; pick_oid="${member#* }"
      [ "$pick_oid" != "-" ] || pick_oid=""
      if [ "$first" = 1 ]; then
        echo "updater[$REPO]: updating #$pick (oldest armed+BEHIND, FIFO)"
      else
        echo "updater[$REPO]: updating #$pick (lane hop — the lane's older member did not clear)"
      fi
      if gh api -X PUT "repos/$REPO/pulls/$pick/update-branch" \
        ${pick_oid:+-f expected_head_sha="$pick_oid"} >/dev/null; then
        break   # one update LANDS per lane per pass
      fi
      # 422 = conflict OR expected_head_sha race (homelab#986). Both are safe to skip: a race
      # preserves the concurrent push's commit; a conflict is caught by the DIRTY labeler (leg 3)
      # on the next pass. Replayed: fixtures/updater `update-fail` row (covers both race and
      # conflict — the script deliberately no longer distinguishes them on 422, homelab#1007).
      echo "updater[$REPO]: update of #$pick failed (422) — skipping; next pass retries"
      first=0
    done <<<"$(printf '%s\n' "$lane" | tr '|' '\n')"
  done <<<"$(jq -r '.[] | map("\(.number) \(.headRefOid // "-")") | join("|")' <<<"$lanes")"
else
  echo "updater[$REPO]: no armed+BEHIND PR to update"
fi

# ── leg 1b: the hand-back sweep (homelab#1985 residual 5, 2026-10-31) ─────────────────────────────
# The hand-back (renovate-currency.sh, 2026-10-24) was reachable only from INSIDE legs 1 and 2, so a
# Renovate PR the updater had merged into was handed back only while it sat in one of their domains
# (armed ∧ BEHIND, plus leg 1's park pre-filter). Disowned-and-stuck does not depend on BEHIND: a
# merged-into PR that is CURRENT but red, a codeowner park gone red (leg 1's pre-filter drops it), or
# a current CHANGES_REQUESTED one waited — invisible — until master happened to move under it. So the
# sweep runs the SAME predicate over the complement: every armed, unbreakered Renovate PR that is in
# neither leg's domain (no PR is probed twice per pass). Not merge-ready here = not green OR
# CHANGES_REQUESTED — leg 1's test plus leg 2's (an untouched Renovate PR gets no new content but
# Renovate's, so a CR one is stuck until handed back); green + awaiting review is the reviewer's, and
# green + APPROVED + current is merging. Silent unless it acts or HOLDS (an out-of-domain PR that
# needs nothing must not add a line per pass); an unreadable probe HOLDS (rule #6). Breakered PRs
# are the humans' (leg 2's exclusion). Never an update-branch here — a merge would mint the zombie.
while read -r pr; do
  [ -n "$pr" ] || continue
  renovate_author "$pr" || continue
  n="$(jq -r '.number' <<<"$pr")"
  sj="$(renovate_probe "$REPO" "$n" "$(jq -r '.headRefOid // ""' <<<"$pr")")" || sj=""
  if [ -z "$sj" ]; then
    echo "handback[$REPO]: #$n commit probe unreadable — HOLDING (rule #6; the */15 cron retries)"
    continue
  fi
  renovate_untouched "$sj" && renovate_merged_into "$sj" || continue
  if ! renovate_green "$sj" || [ "$(jq -r '.reviewDecision' <<<"$pr")" = CHANGES_REQUESTED ]; then
    renovate_handback "$REPO" "$n" "handback[$REPO]:"
  fi
done <<<"$(jq -c "$LEG_DOMAINS_JQ"' .[] | select(.autoMergeRequest != null and (leg1_cand | not)
                                         and (leg2_domain | not) and (breakered | not))' <<<"$PRS")"

# ── leg 2: the CR∧BEHIND crack (2026-08-12, found on homelab#398 twice in one hour) ──────────────
# The main pick skips CHANGES_REQUESTED PRs, and the review reflex only lifts green+CURRENT PRs —
# so an armed PR that gets a verdict, a fix push, and then watches master move sits in a state NO
# machine serves: the reflex waits for current, the updater waits for the verdict to clear.
# ⚠ NARROWED 2026-08-17 (measured: 34 of 118 branch-update merges + ~35 of 69 CI runs that day
# were this belt keeping UNMERGEABLE PRs current — #473 ×16 while parked, #475 ×18 while
# breaker-latched). "Over-updating is harmless" is false on a busy master: the crack only exists
# when a FIX PUSH has landed after the verdict (that is what the reflex is waiting to re-review at
# a current head). So the belt fires ONLY when the newest NON-MERGE commit post-dates the newest
# reviewer verdict (the reflex's reviewable_again shape — updater merge commits are NOT content,
# or the belt feeds itself), and never on agent/error / agent/arbitrate PRs (breaker-latched:
# humans own those). Unreadable commit/review data HOLDS with a line, never updates — rule #6;
# the */15 cron retries.
jq -r "$LEG_DOMAINS_JQ"' .[] | select(leg2_domain and (breakered | not)) | .number' <<<"$PRS" \
| while read -r n; do
    pj="$(gh pr view "$n" --repo "$REPO" --json commits,reviews 2>/dev/null)" || pj=""
    # Same rule as leg 1, minus the exception: a CHANGES_REQUESTED PR is not merge-ready, so an untouched
    # Renovate PR here is always Renovate's to rebase (ADR-153; every Renovate branch since 2026-10-12).
    if [ -n "$pj" ] && renovate_author "$(jq -c --argjson n "$n" '.[] | select(.number == $n)' <<<"$PRS")" && renovate_untouched "$pj"; then
      if renovate_merged_into "$pj"; then
        renovate_handback "$REPO" "$n" "unstrand:"
      else
        echo "unstrand: #$n Renovate-authored and untouched — Renovate rebases it itself (rebaseWhen behind-base-branch, ADR-153); skipping"
      fi
      continue
    fi
    verdict_ok=""
    if [ -n "$pj" ]; then
      verdict_ok="$(printf '%s' "$pj" | jq -r '
        ([.commits[] | select(.messageHeadline | startswith("Merge branch ") | not)
           | .committedDate] | max) as $c
        | ([.reviews[] | select(.author.login | startswith("homelab-reviewer"))
             | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")
             | .submittedAt] | max) as $v
        | if ($c != null and $v != null and $c > $v) then "yes" else "no" end' 2>/dev/null)" || verdict_ok=""
    fi
    n_oid="$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefOid // empty' <<<"$PRS")"
    case "$verdict_ok" in
      yes)
        echo "unstrand: updating CR-and-behind PR #$n (new content since verdict)"
        gh api -X PUT "repos/$REPO/pulls/$n/update-branch" \
          ${n_oid:+-f expected_head_sha="$n_oid"} >/dev/null \
          || echo "unstrand: update of #$n failed (422) — skipping; next pass retries" ;;
      no)
        echo "unstrand: #$n CR-and-behind but NO new content since the verdict — nothing to re-review, not updating (2026-08-17 narrowing)" ;;
      *)
        echo "unstrand: #$n commit/review probe unreadable — HOLDING, not updating (rule #6; the */15 cron retries)" ;;
    esac
  done

# ── leg 3: flag conflicted PRs (the updater can't auto-resolve these) ────────────────────────────
# armed ∧ DIRTY gains the merge-conflict label (the scan's merge-conflict clause routes it to
# judgment, MP-T06); anything else carrying the label has it removed — a resolved conflict must
# not keep parking the PR.
jq -c '.[]' <<<"$PRS" | while read -r pr; do
  n="$(jq -r '.number' <<<"$pr")"
  armed="$(jq -r '.autoMergeRequest != null' <<<"$pr")"
  dirty="$(jq -r '.mergeStateStatus == "DIRTY"' <<<"$pr")"
  has="$(jq -r '[.labels[].name] | index("merge-conflict") != null' <<<"$pr")"
  if [ "$armed" = "true" ] && [ "$dirty" = "true" ]; then
    [ "$has" = "true" ] || label_conflict "$n"
  elif [ "$has" = "true" ]; then
    # REST via gh_label_rm, not `gh pr edit --remove-label` (same #2476/FU-290 class as label_conflict
    # above) — already gone is fine, any other failure is swallowed same as before (best-effort clear).
    GH_TOKEN="${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}" gh_label_rm "$REPO" "$n" merge-conflict 2>/dev/null || true
  fi
done
