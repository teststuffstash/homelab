---
name: seat-review
description: >
  Run the platform reviewer BY HAND — a seat subagent briefed with the bot reviewer's own
  instructions — on a change the bot cannot review, before the operator admin-merges or pushes it.
  For the operator path: a PR whose required `ci` is red BY DESIGN (a guarded file pin-only-lint
  refuses, ADR-100), or a governance/direct-to-master change (CODEOWNERS, .agents/review.md,
  .github/workflows/**) that would otherwise land unreviewed. Triggers: "/seat-review <pr>",
  "review this before I admin-merge", "get a bot review on this direct push", "the reviewer
  won't run because CI is red".
---

# seat-review — the platform reviewer's read, run from the seat

> **Glance first**: [`../GAPS.md`](../GAPS.md) §seat-review — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

**Why it exists.** The bot reviewer (`agents/reviewer-session.sh`) dispatches only on GREEN
required checks, and the operator path skips it by construction: an edit to a file
`pin-only-lint` guards is red in `ci` forever (ADR-100: real edits take the operator path), and
a direct-to-master push never opens a PR at all. That is exactly where the most consequential
changes land. Rather than a reviewer trigger for a rare case (operator, 2026-11-01: not frequent
enough to warrant one), the seat gets the same read by hand: **seat PR → seat review → operator
admin-merges.**

## Procedure

1. **A PR exists.** A direct-to-master change that wants a review goes through a PR first (branch
   from `origin/master`), even if it will be admin-merged — the review needs a diff to read and a
   place to leave its record.
2. **Launch ONE review subagent** (`model: sonnet` — the bot's default model; the Agent tool,
   background). Its brief, in substance:
   - It IS the platform reviewer: `.agents/review.md` (the rubric, the bot's system prompt) +
     the generic `PROMPT='…'` block in `agents/reviewer-session.sh` (STEP 1 classification, the
     merge-forward verdict doctrine, STEP FINAL's verdict shape) + the `NO CONTAINER RULE
     (ADR-127` text in the same file when the PR has no epic container. Skip STEP 0 and the
     bot plumbing (asides, TOOL_GAP emission, uploads).
   - Name the red-by-design check and why (e.g. `pin-only-lint` on a guarded file) — it is NOT a
     finding; every OTHER red check or lint failure IS.
   - READ-ONLY: no review, comment, approve, merge or push; a checkout only in its own scratch
     clone (`git fetch origin pull/<n>/head`).
   - Output: the review body the bot would have submitted — first line `VERDICT: APPROVE` or
     `VERDICT: REQUEST_CHANGES`, findings (BLOCKING / comment, file:line, why, fix), then a
     "Not verified" list.
3. **Fix BLOCKING findings in the PR** (the normal PR+watch+fix discipline), then re-run the
   review on the new head — one subagent per round, never a parallel second opinion.
4. **Record it on the PR**: post the final review body as a PR **comment** headed
   `Seat review (manual platform-reviewer pass, <model>, head <sha8>)`. Never as a native
   GitHub review — the seat's token is the operator's identity, so an "approve" from it would
   read as the codeowner's own approval.
5. **Hand the merge to the operator** with the verdict and the exact command
   (`gh pr merge <n> --repo teststuffstash/<repo> --squash --admin`). The admin merge is the
   operator's act: a second jail never runs it, the primary seat only on the operator's explicit
   word for that PR.

## Limits

- It is a read with the bot's instructions, not the bot: no reviewer App identity, no review
  reflex, no harvest of follow-ups. The required checks it cannot run (the red-by-design one)
  stay unrun — say so in the merge hand-off.
- Do not use it to route around a reviewer that DID run and requested changes: fix the findings.
