# The specs reviewer — a second review pass over `specs/` and its evidence

> Design note for [`agents/lenses/specs.md`](../../agents/lenses/specs.md) (the brief, rules only).
> DRAFT: lens written, wiring PROPOSED, nothing dispatches it yet. Born with the P2 gateway island
> ([`context-and-autonomy.md`](../spikes/context-and-autonomy.md) §Direction, FU-270 / ADR-139).

## Why a second reviewer

Oracle's spec process ([`docs/process/README.md`](https://github.com/teststuffstash/oracle-fleet/blob/master/docs/process/README.md)
rule 1) makes `specs/` the HUMAN gate against golden-mastering. §Direction 2 moves that read off
the operator: **specs are reviewer-gated, not codeowner-gated** — a full-context reviewer (the
island's specs + the consumer contracts it touches) gates spec changes; ⚖ rows reach the operator
as a digest. The code reviewer cannot be it: reading rows beside the code, a row that matches the
code looks RIGHT — the one failure the gate exists to catch. The specs reviewer never sees code.

## What it gates, on what input

- **Gates spec ROWS**: intent source (vs golden-mastered), ⚖ flagging + `Spec changes:` listing,
  removed-row reasons, row ⇄ schema contradictions, evidence stamped at head, glossary terms —
  BLOCKING. Table SHAPE is advisory always: propose the split, never a size.
- **Does not gate**: code, tests, manifests, the mechanical coupling (`spec_gate.py` in `ci`
  owns it), prose polish. `--request-changes` on a blocking check, `--comment` otherwise, so a
  clean read never overwrites the code reviewer's verdict state.
- **Input**: the `**/specs/**` diff, the PR body (`Spec changes:`, the closing issue), and the
  CI evidence the head rendered (`gh run list --commit <head>` → the evidence-render step, or
  `specs/evidence/` in the diff) — counted only when its stamp names THIS head. No rubric, no
  implementation files.

## Grounding

- Oracle process rules 2–10 and `.agents/review.md` items 1–2 and 8 (rows not functions; rows
  derive from intent; provenance for "real shape" claims).
- The operator's reviewer-shape trial (claude.ai artifact "Reviewer shape trial", 2026-09-29;
  three rule sets × three oracle requirements). **R-HARD** (≤3 cols × ≤5 rows) split by count,
  not meaning — 10–14 IDs from one, cross-key rows dropped, constants pushed into prose, cells
  re-packed to fit the cap: **rejected**. **R-ATOMIC** (one value per cell, size a smell) and
  **R-JUDGE** (one question per table, same axes, plain values, no split for size): **adopted**,
  with the trial's own caveats in the lens checklist — a set is one value (strict atomicity
  exploded `{A, B}` into boolean columns and wide sparse tables), a cross-key row is a proof,
  a mostly-constant column may carry the rule being proven, and every split mints NEW rows
  (new scope → ⚖ + `🚧 WIP`) and moves IDs (alias anchors).

## Proposed wiring in `reviewer-session.sh` (not landed — governance path, seat/operator)

Hook point: after the main `claude -p` (the code verdict), before `assert_review_terminal`.
Trigger: `grep -qE '(^|/)specs/' <<< "$CHANGED"`. Second pass: fetch `$LENS_BASE/specs.md` into
its OWN system-prompt file (no rubric, no other lens); `git diff "$(git merge-base
origin/$PR_BASE HEAD)" -- ':(glob)**/specs/**' > /tmp/specs.diff`; `claude -p` naming only that
diff, the PR body and the head's evidence; one review headed `## Specs review`. Order matters:
under one App identity a later `CHANGES_REQUESTED` supersedes the code pass's `APPROVED` (the
gate) while `--comment` leaves it untouched. A fetch/pass failure logs "specs read MISSING, not
clean" — a blocking lens never silently degrades to advisory.

## Open questions

1. **Identity.** Same App (state supersession, cheapest) vs a distinct specs-reviewer App (clean
   two-gate semantics; a new credential = ADR-sized; prior art: the second-reviewer capability
   bound in [`iac-lane.md`](iac-lane.md)). Same App also puts two reviews per round in front of
   the reflex breaker and `assert_review_terminal` — read both before the hook lands.
2. **Evidence stamp.** `evidence_render.py` fixes what the stamp carries; the lens needs the head.
3. **`Spec changes:` as a deterministic pre-open check** (the 2026-07-25 oracle retros asked):
   the reviewer is the backstop, not the first line.
4. **Reach.** Oracle-fleet keeps its rule-1 codeowner gate; replacing it is per island, operator's call.
