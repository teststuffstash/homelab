# Retro cross-review brief — TEMPLATE (v1, 2026-07-25)

<!--
The second leg of a retro run (FU-058 run-3 shape): the OTHER cell reviews the report.
Cells swap — the claude+opus retro is reviewed by the goose+deepseek cell and vice versa;
rotate who-retros/who-reviews across runs to separate harness effect from model effect.

ASSEMBLY (agents/retro-session.sh --review): replace
  {{STACK}} {{RUN_ID}} {{MAIN_REPO}}  — as in BRIEF.md
  {{REPORT}}                          — the full report under review, verbatim
First user message: "Read /tmp/retro-review-brief.md and execute it exactly."

Review-shape caution (run-1 evidence): this task class is HARDER than the generative retro —
nemotron delivered a decent report but bailed on the review 3/3 attempts. Reviews need a
capable model; don't economize here (VERDICT.md tier guidance).
-->

# Cross-review — {{STACK}} retro {{RUN_ID}}

You are reviewing ANOTHER model's retrospective report over the {{STACK}} agent-loop ledger.
Your value is INDEPENDENT verification against ground truth, not politeness. The repo is
`{{MAIN_REPO}}`; `gh` is authenticated for it.

## The report under review

{{REPORT}}

## Task

For EACH finding and proposed process change in the report:
1. **Verify the evidence** against the actual ledger rows and issue/PR trails — do the cited
   task ids, numbers, and sequences exist as claimed?
2. **Fabrication check**: does the change target an artifact/clause/API that actually exists?
   (Run-2 traps: invented goose recipe APIs, misattributed ledger writer, fictional files.)
3. **Verdict per item**: CONFIRMED / WRONG (with the correct fact) / UNVERIFIABLE (with what
   access was missing).
4. **Materiality**: would you BLOCK adopting the change, adopt it AMENDED (say how), or adopt
   as-is?

Then: name up to 3 real patterns the report MISSED (with evidence), and rank the report's
overall grounding 1-5 with one sentence of justification.

Anti-goals: no re-doing the retro from scratch; no style critique; every verdict carries a
checkable citation.

## Output contract (strict)

End your FINAL message with the complete review between these exact markers:

BEGIN-RETRO-REVIEW
# Cross-review of {{RUN_ID}} report — <your model name>
## Per-finding verdicts (table: finding | verdict | evidence check | adopt?)
## Missed patterns (≤3, with evidence)
## Grounding score (1-5, one sentence)
END-RETRO-REVIEW
