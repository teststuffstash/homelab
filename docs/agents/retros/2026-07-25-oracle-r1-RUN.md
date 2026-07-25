# Retro run 1 — oracle stack, multi-model pilot (FU-058, 2026-07-25)

First FU-058 retro AND first multi-large-model tryout (operator-directed). Two rides, one
identical brief (full 32-row pain-ranked ledger inline + gh drill-down permission + strict
output contract), hand-supervised from the meta session:

| ride | harness | model | key | outcome |
|---|---|---|---|---|
| A | goose | nvidia/nemotron-3-ultra-550b-a55b:free | ephemeral only-free ($0.01) | report delivered, $0.00; key cap hit post-report (budget-403) |
| B | claude | opus (subscription) | proxy ref, FU-088 latch | report delivered, 259s / 17 turns / 38k out |

**Selection (meta + operator supervision): the opus report** — mechanisms verified against
real artifacts (file:line cites, incident sequences); changes anchored in components that
exist. Nemotron delivered two real catches (reviewer_rounds=0 ledger blindness; truncation
economics) but anchored fixes to invented artifacts (goose `pre_tool_hook`; "the scan writes
the ledger" — it's ledger.py). Cross-review: nemotron critiques the opus report (next file).

Mechanism notes for run 2: the finalize classifier stamped the claude ride
`error_class=goose-32602-truncation` (claude-harness classification gap); the free-key $0.01
cap can 403 mid-finalize on :free rides — mint 0.05 for report-length tasks.
