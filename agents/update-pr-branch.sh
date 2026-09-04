#!/usr/bin/env bash
# agents/update-pr-branch.sh — the merge-path UPDATER (FU-041 / MP-T02/MP-T06) as a platform-owned
# script (ADR-111, homelab#742; replaces `adRise/update-pr-branch` + the reusable workflow's shell
# steps — MP-T02's standing "behavior owned upstream" liability ends here).
#
#   GH_TOKEN=<homelab-merge App token> bash agents/update-pr-branch.sh <owner/repo>
#
# Keeps exactly ONE PR current with master per pass so GitHub auto-merge can fire (the ruleset
# requires an up-to-date branch). MUST run with the homelab-merge App token, not a workflow
# GITHUB_TOKEN (a GITHUB_TOKEN push doesn't re-trigger `ci`, so a strict branch never sees green).
# In-cluster the token arrives as the `updater-git` ESO secret (homelab#744); a jail hand-run
# mints one ad-hoc. See docs/agents/merge-path.md §Chosen design ▸2 + §Updater token.
#
# Level-triggered: each pass re-reads the world and acts on at most one main-leg update; a lost
# doorbell costs nothing (the */15 cron re-derives). Races are safe: update-branch carries
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
set -euo pipefail

REPO="${1:?usage: update-pr-branch.sh <owner/repo>}"

# One list serves all three legs — the snapshot is per-pass by design (level-triggered; anything
# it misses, the next pass sees).
PRS="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,createdAt,mergeStateStatus,autoMergeRequest,reviewDecision,labels,headRefOid,latestReviews)"

# Defensive: `gh pr edit --add-label` FAILS on a missing label, so create it idempotently first
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
label_conflict() {
  GH_TOKEN="${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}" gh label create merge-conflict --repo "$REPO" --color e11d21 \
    --description "PR branch conflicts with master — updater can't auto-resolve" --force >/dev/null 2>&1 || true
  GH_TOKEN="${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}" gh pr edit "$1" --repo "$REPO" --add-label merge-conflict \
    || echo "updater[$REPO]: could not label #$1 merge-conflict (token lacks issues:write?) — the */15 pass retries"
}

# ── leg 1: the main pick ── oldest armed + BEHIND + not-changes-requested, ONE per pass (FIFO —
# `sort: created asc` in the action era). CHANGES_REQUESTED PRs are the unstrand leg's (below);
# DIRTY PRs are the labeler's (an update-branch call cannot resolve a conflict).
# Codeowner-parked PRs (bot-approved at head ∧ reviewDecision == REVIEW_REQUIRED ∧ armed) are
# SKIPPED — the updater leaves them BEHIND so they accumulate no CI cost between human sittings.
# At human approval reviewDecision flips to APPROVED and the next pass refreshes (one CI cycle).
# Measured: PR#1347/#1352/#1354, 47 master moves, 36/32/27 merge commits each, 39/41 CI runs
# each — ≈3.5h runner time on three PRs whose content never changed (homelab#887, 2026-09-04).
pick="$(jq -r '[.[] | select(.autoMergeRequest != null and .mergeStateStatus == "BEHIND"
                             and .reviewDecision != "CHANGES_REQUESTED"
                             and (.reviewDecision != "REVIEW_REQUIRED" or
                                  ([((.latestReviews // [])[] | select((.author.login
                                    | startswith("homelab-reviewer")) and .state == "APPROVED"))]
                                   | length) == 0))]
               | sort_by(.createdAt) | .[0].number // empty' <<<"$PRS")"
if [ -n "$pick" ]; then
  pick_oid="$(jq -r --argjson n "$pick" '.[] | select(.number == $n) | .headRefOid // empty' <<<"$PRS")"
  echo "updater[$REPO]: updating #$pick (oldest armed+BEHIND, FIFO)"
  if ! gh api -X PUT "repos/$REPO/pulls/$pick/update-branch" \
    ${pick_oid:+-f expected_head_sha="$pick_oid"} >/dev/null; then
    # 422 = conflict OR expected_head_sha race (homelab#986). Both are safe to skip: a race
    # preserves the concurrent push's commit; a conflict is caught by the DIRTY labeler (leg 3)
    # on the next pass. Replayed: fixtures/updater `update-fail` row (covers both race and
    # conflict — the script deliberately no longer distinguishes them on 422, homelab#1007).
    echo "updater[$REPO]: update of #$pick failed (422) — skipping; next pass retries"
  fi
else
  echo "updater[$REPO]: no armed+BEHIND PR to update"
fi

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
jq -r '.[] | select(.autoMergeRequest != null and .mergeStateStatus == "BEHIND"
                    and .reviewDecision == "CHANGES_REQUESTED"
                    and (([.labels[].name] | index("agent/error")) == null)
                    and (([.labels[].name] | index("agent/arbitrate")) == null)) | .number' <<<"$PRS" \
| while read -r n; do
    pj="$(gh pr view "$n" --repo "$REPO" --json commits,reviews 2>/dev/null)" || pj=""
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
    GH_TOKEN="${UPDATER_LABEL_TOKEN:-${GH_TOKEN:-}}" gh pr edit "$n" --repo "$REPO" --remove-label merge-conflict || true
  fi
done
