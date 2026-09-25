#!/usr/bin/env bash
# major-handoff.sh — the launcher-owned handoff of a `major` dependency-bump PR to the human-merge
# lane: `major/awaiting-human` is SET BY THIS SCRIPT, never by hand (homelab S9 #1987).
#
#   bash agents/major-handoff.sh <owner/repo> <pr>
#
# WHY A SCRIPT. On 2026-09-25 the coordinator relabelled oracle-fleet#738 and oracle-iac#1001
# `major/awaiting-human` with NO reviewer verdict at all (`reviews: []`) — its own comment did the
# "review". The brief (agents/coordinator/README.md §Dependency major bumps, step 5) told the
# session to relabel by hand, and a label a model can apply is advice, not mechanism. ADR-094: the
# LLM judges, launcher-owned shell ACTS — the label now requires the evidence, mechanically:
#
#   1. the PR is OPEN and carries `major` (the lane marker devbox-update.sh sets);
#   2. a review by the reviewer bot (`homelab-reviewer`, the `[bot]` suffix normalized the way
#      review-reflex.sh does) in state APPROVED, submitted AFTER the newest NON-merge commit on the
#      PR head — the reflex's own `bot_approved_head` definition (see below);
#   3. that review's body carries the four migration headings — `Upstream`, `Known issues`,
#      `Platform compatibility`, `Evidence` — each as a line-anchored markdown heading (`## …`) or
#      bold label (`**…**`), case-insensitive;
#   4. only then: ADD `major/awaiting-human` FIRST, REMOVE `agent/in-progress` SECOND (the
#      platform's add-before-remove discipline, IL-T16: the write is not atomic, and removing
#      first would leave the PR label-less in the window), then RE-READ the labels and prove the
#      end state.
#
# EXIT CODES (the coordinator branches on these; the brief names them):
#   0  handed off — one `major-handoff: <slug>#<n> → major/awaiting-human …` line
#   3  REFUSED   — one line `major-handoff: REFUSED — <reason>`; NOTHING written. The migration
#                  evidence is missing: dispatch the reviewer again (brief step 2), never relabel
#                  by hand.
#   4  UNREADABLE — a probe failed before any write; NOTHING written (rule #6: never fail INTO a
#                  write).
#   5  end state NOT PROVEN — the writes were issued but the re-read does not show them (or could
#                  not be made). Not a refusal: a human looks at the labels.
#
# NO COMMENTS are posted by this script: the label IS the record, and the reviewer's approval
# body IS the evidence trail a human reads before merging.
#
# ⚠ DUPLICATED DEFINITION, named on purpose. `newest_commit_at` / `bot_approved_head` below are
# REPLICATED from agents/review-reflex.sh (the `review-pick` block: `def newest_commit_at` — updater
# merge commits are NOT new content, oracle-fleet#57 — and `def bot_approved_head` — the `[bot]`
# suffix sub + APPROVED + newer than the newest content commit). They are jq `def`s inside a
# single-quoted jq program there, not a sourceable shell seam, so this file carries a copy; a change
# to the reflex's definition must be mirrored here (the fixture family
# agents/replay/fixtures/major-handoff pins THIS copy, `review-pick` pins the reflex's).
set -euo pipefail

SLUG="${1:?usage: major-handoff.sh <owner/repo> <pr>}"
PR="${2:?usage: major-handoff.sh <owner/repo> <pr>}"
# >>>REPLAY:major-handoff-seams>>>
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"   # the reviewer App's bot identity (same default as review-reflex.sh)
LANE_LABEL="major"                                      # set by devbox-update.sh — the human-merge lane marker
HANDOFF_LABEL="major/awaiting-human"                    # set ONLY here
CLAIM_LABEL="agent/in-progress"                         # the coordinator's claim (brief step 2), released on handoff

refuse() { printf 'major-handoff: REFUSED — %s\n' "$*"; exit 3; }
unreadable() { printf 'major-handoff: UNREADABLE — %s\n' "$*"; exit 4; }
# <<<REPLAY:major-handoff-seams<<<

# >>>REPLAY:major-handoff>>>
# ── 1. one read for everything the gate needs (state, labels, reviews, commits) ──────────────────
_err="$(mktemp)"
if ! pr_json="$(gh pr view "$PR" --repo "$SLUG" --json state,labels,reviews,commits 2>"$_err")"; then
  _tail="$(tail -c 200 "$_err" | tr '\n' ' ' | sed 's/ *$//')"; rm -f "$_err"
  unreadable "gh pr view $SLUG#$PR failed: ${_tail:-no stderr} — nothing written"
fi
rm -f "$_err"
printf '%s' "$pr_json" | jq -e 'type == "object" and (.commits | type == "array") and (.reviews | type == "array")' >/dev/null 2>&1 \
  || unreadable "gh pr view $SLUG#$PR returned no parseable PR object — nothing written"

# ── 2. the gate, as one jq verdict over the recorded payload ────────────────────────────────────
# Output: one line `OK <approval-submittedAt>` or `REFUSE <reason>`. Every branch is a REFUSAL —
# the only exit-4 paths are above (the probe) and below (the re-read); rule #6 keeps them apart.
verdict="$(printf '%s' "$pr_json" | jq -r --arg bot "$REVIEWER_LOGIN" --arg lane "$LANE_LABEL" --arg SLUGPR "$SLUG#$PR" '
  # ⚠ replicated from agents/review-reflex.sh `review-pick` — see the header.
  def newest_commit_at:
    ([ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not) | .committedDate ] | max) // "";
  def bot_approvals:
    [ .reviews[]?
      | select(((.author.login // "") | sub("\\[bot\\]$"; "")) == $bot)
      | select(.state == "APPROVED") ];
  def approval_at_head:
    # the newest bot approval, and only if it post-dates the newest content commit
    (bot_approvals | sort_by(.submittedAt) | last) as $a
    | if $a == null then null
      elif ($a.submittedAt // "") > newest_commit_at then $a
      else null end;
  # The four migration headings, each line-anchored: `## Upstream` (any heading level) or
  # `**Upstream**` / `**Upstream:**` / `**Upstream**:` — case-insensitive, trailing spaces ok.
  def heading_re(h): "^[ \\t]*(#{1,6}[ \\t]+|\\*\\*)[ \\t]*" + h + "[ \\t]*:?[ \\t]*(\\*\\*)?[ \\t]*:?[ \\t]*$";
  def missing_headings(body):
    # LINE-anchored by construction: jq (Oniguruma) anchors ^/$ to the whole string, not per line
    # (probed 2026-09-25: "x\n## Upstream" fails `^`), so the body is split into CR-stripped
    # lines and each line is tested on its own. `i` = case-insensitive.
    (body | split("\n") | map(sub("\r$"; ""))) as $lines
    | [ "Upstream", "Known issues", "Platform compatibility", "Evidence" ]
    | map(select(. as $h | ($lines | any(test(heading_re($h); "i"))) | not));

  ([ .labels[]?.name ]) as $labels
  | if (.state // "") != "OPEN" then "REFUSE \($SLUGPR) is \(.state // "of unknown state"), not OPEN"
    elif ($labels | index($lane)) == null then "REFUSE \($SLUGPR) does not carry the `\($lane)` label — not the human-merge lane"
    elif (bot_approvals | length) == 0 then "REFUSE no APPROVED review by \($bot) on \($SLUGPR) — dispatch the reviewer (brief step 2)"
    elif approval_at_head == null then
      "REFUSE the newest \($bot) approval (\(bot_approvals | map(.submittedAt) | max)) predates the newest content commit (\(newest_commit_at)) on \($SLUGPR) — the verdict is not at head; re-dispatch the reviewer (brief step 2)"
    else (approval_at_head) as $a
      | (missing_headings($a.body // "")) as $m
      | if ($m | length) > 0 then
          "REFUSE the approval at head (\($a.submittedAt)) lacks the migration heading(s): \($m | join(", ")) — re-dispatch the reviewer (brief step 2)"
        else "OK \($a.submittedAt)" end
    end
' 2>/dev/null)" || unreadable "the gate could not evaluate the $SLUG#$PR payload — nothing written"

case "$verdict" in
  OK\ *)     approved_at="${verdict#OK }" ;;
  REFUSE\ *) refuse "${verdict#REFUSE }" ;;
  *)         unreadable "the gate produced no verdict for $SLUG#$PR — nothing written" ;;
esac

# ── 3. the writes: ADD first, REMOVE second (IL-T16), then PROVE the end state ─────────────────
# A refused ADD stops here with nothing removed — the label-less window is the state the ordering
# exists to prevent. A refused REMOVE still leaves the handoff label in place (the belt/the human
# sees both), so it is reported, not rolled back.
if ! gh pr edit "$PR" --repo "$SLUG" --add-label "$HANDOFF_LABEL" >/dev/null 2>&1; then
  printf 'major-handoff: END STATE NOT PROVEN — adding %s on %s#%s FAILED; %s left in place\n' "$HANDOFF_LABEL" "$SLUG" "$PR" "$CLAIM_LABEL"
  exit 5
fi
if ! gh pr edit "$PR" --repo "$SLUG" --remove-label "$CLAIM_LABEL" >/dev/null 2>&1; then
  printf 'major-handoff: END STATE NOT PROVEN — %s added on %s#%s but removing %s FAILED\n' "$HANDOFF_LABEL" "$SLUG" "$PR" "$CLAIM_LABEL"
  exit 5
fi
# The re-read is the REST labels endpoint, not `pr view` again: a fresh read of the mutated
# resource, keyed apart from the pre-write probe so a replay world has to record the AFTER state.
if ! now_labels="$(gh api "repos/$SLUG/issues/$PR/labels" --jq '.[].name' 2>/dev/null)"; then
  printf 'major-handoff: END STATE NOT PROVEN — both writes issued on %s#%s but the label re-read failed\n' "$SLUG" "$PR"
  exit 5
fi
if ! printf '%s\n' "$now_labels" | grep -qx -- "$HANDOFF_LABEL" || printf '%s\n' "$now_labels" | grep -qx -- "$CLAIM_LABEL"; then
  printf 'major-handoff: END STATE NOT PROVEN — %s#%s labels after the writes: %s\n' "$SLUG" "$PR" "$(printf '%s' "$now_labels" | tr '\n' ',')"
  exit 5
fi
printf 'major-handoff: %s#%s → %s (%s removed; %s approval at head, submitted %s)\n' \
  "$SLUG" "$PR" "$HANDOFF_LABEL" "$CLAIM_LABEL" "$REVIEWER_LOGIN" "$approved_at"
# <<<REPLAY:major-handoff<<<
