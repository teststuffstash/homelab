# Score v1 — singles: #3180 → PR #3264 (1 CR round) + controls #3011 → #3012, #2782 → #2979, #2753 → #2982 (0 rounds)

Runs scored: v1/out/arm1-single-3180.md, arm1-singles.md, arm2-single-3180.md, arm2-singles.md (all on clean case dirs).
v0 verdicts reused from intake-trial/score/singles.md. New verification: `gh pr diff 3012`, PR #3012's reviews, and `origin/master:gateway/specs/endpoints/catalog.md` (fetched 2026-11-14).

## Recall on the known intake escapes
| truth finding | class | v0 (best clean) | v1 arm1 | v1 arm2 |
|---|---|---|---|---|
| #3264 r1 specs R10: row 3 "both modes render on every gateway, the inactive one at 0 ⚖" repeats row 1's cells (`file`/`1`/`0`), and only the description tells them apart | A | arm2 BLOCKING `R10/3180/endpoints/metrics#GW-METRICS (r2.1, r2.3)`. arm1 saw it and handed it off with no id. | **missed (handed off)**. It is listed only under "Not reviewed (row specialist's): row 1 and row 3 of 'The store mode is a gauge' share the input `file`; the cell '`0` (rendered, never absent)'". No id. | **BLOCKING** `R10/3180/r2.1+r2.3`. "Delete r2.3 … Move r2.3's `⚖` and its intent words into r2.1's description" matches the fix 5652b821. |

Controls #3011, #2782, #2753: the truth has 0 A/B/C findings.
recall, blocking only: v0 arm1 0/1 · v0 arm2 1/1 · v1 arm1 0/1 · v1 arm2 1/1 · v1 either 1/1   (any posture: v1 arm1 0/1 if a handoff note with no id gets no credit, 1/1 if it does; arm2 1/1)

## v1 blocking findings

### #3180 → PR #3264
| finding | arm:id | check | verdict (reused v0 / new) | evidence |
|---|---|---|---|---|
| r2.3 duplicates r2.1's cells, so the distinguishing condition lives only in the description and a parenthetical | arm2:R10/3180/r2.1+r2.3 | rows check 10 | **real-fixed** (it is the truth finding; reused) | Review: "Only the description distinguishes them". Fix 5652b821 deleted r2.3 and folded its ⚖ into r2.1. |
| Acceptance 1 makes the alert rows `rule("GW-METRICS")` pytest cases, but only promtool can observe them | arm1:F1 (arm2: R4 advisory) | U5 | **real-fixed** (reused v0 F5) | b1ead591 wrote the alert as prose and proved it with `db-mode.promtool-test` S1–S3. The round-1 advisory "Prose claims without a row" cost a fix line in 5652b821. |
| The glossary's "a metric for it is a gap (#3180)" goes false, and `glossary.md` is not in Touches | arm1:F2 (arm2: R7 advisory) | U2 | **real-fixed** (reused v0 F1) | PR #3264 diff glossary.md: `+…it is the gateway_db_mode gauge on /metrics`. The code review: "The two Touches escapes (`app.py`, `glossary.md`) are declared". |

### #3011 → PR #3012 (control)
| finding | arm:id | check | verdict (reused v0 / new) | evidence |
|---|---|---|---|---|
| The r1.2 expected cell is a worker instruction plus a conditional ("the last good — verify during implementation whether an existing row already proves it; add only if not"), and the base already decides the conditional: no such row and no `docs-no-go-plus` fake | arm2:R1/3011/r1.2 (arm1: A1 advisory) | rows check 1 | **real-fixed, at no review cost** (reused v0 #3011 F1). On the false-positive question it is **not a wrong block on the facts, but a costless one.** | What the worker did with the cell: it added the row **unconditionally** and dropped the conditional. PR #3012 catalog.md: `+\| "a Plan table without the Go Plus row is a parse failure" \| 5 \| \`docs-no-go-plus\` \|\| parse-failed \| the last good \|`. It also registered the fake (worlds/README `+\| docs-no-go-plus \| the Plan table without its **Go Plus** row …`) and the knob (`_catalog_world.py` `+elif behaviour == "docs-no-go-plus"`). That is exactly R1's "satisfied by". It cost 0 review rounds. The specs review cites "Acceptance 2 … proven by a row". arm2 notes this block itself: RULES rule 10 *sanctions* "verify during implementation" as a mark, while check 1 blocks it inside a cell. |
| r1.2 "a Plan table without the Go Plus row is a parse failure" is a judgment row without a ⚖, while its sibling "no plan table is a parse failure ⚖" carries one | arm2:R2/3011/r1.2 | rows check 2 | **new: refuted (wrong block)** | The merged page gave that row **no ⚖**. PR #3012 diff line: `"a Plan table without the Go Plus row is a parse failure"`. Master today still has none: `origin/master catalog.md:331` `\| a Plan table without the Go Plus row is a parse failure \| 5 \| docs-no-go-plus \| parse-failed \| 5 \|`. The PR #3012 specs reviewer ran the same check 2 on this row and ruled: "⚖: not needed. It is a mechanical parse-failure row, and the PR body says so." The outcome follows from the base's strict paragraph ("a shape the parser does not know is a parse failure, never a guess") and the schema's `plan_fees required [go, go-plus]`. rows.md check 2 says "A `⚖` on a mechanical boundary row is noise". |

### #2782 → PR #2979 (control)
| finding | arm:id | check | verdict | evidence |
|---|---|---|---|---|
| no blocking finding. arm1 and arm2 both APPROVED (arm1 B1–B4 advisory, arm2 no findings). | — | — | — | Truth: 0 rounds; specs review "the diff matches it character for character". |

### #2753 → PR #2982 (control)
| finding | arm:id | check | verdict | evidence |
|---|---|---|---|---|
| no blocking finding. arm1 APPROVED (C1–C5 advisory) and arm2 APPROVED (R3 advisory: "check 3 is advisory pre-ride"). | — | — | — | Truth: 0 rounds. |

blocking totals: v0 per run: arm1 7 (5 real / 2 wrong), arm2 2 (1 real / 1 wrong) → v1 arm1 **2** (2 real / 0 wrong), arm2 **3** (2 real / 1 wrong).
distinct v1 blocking 5: real 4 (all real-fixed, one of them costless) / wrong-block 1 / open 0 / unknown 0.
wrong-block share of decided: v1 1/5 = 20% (excluding the truth match: 1/4 = 25%), against v0 3/8 = 37.5% (excluding the truth match).
Control verdicts: v0 put CHANGES_REQUESTED on 2/3 controls under arm1 and 1/3 under arm2. v1 puts it on **0/3 under arm1** and **1/3 under arm2** (#3011, from one costless real block and one wrong block). #2782 and #2753 pass in both arms.

## Lost (real in v0, demoted or dropped in v1)
- (a) demoted, **#3180 health.md:8** "the one place the store mode is visible" (v0 **real-landed**: still false on master): v1 arm1 A1 advisory, arm2 R4 "prose drift" advisory. Neither arm blocks it now, so the one real defect that reached master would not be fixed pre-queue.
- (a) demoted, **#3180 metrics.md "Thirty-seven families"** (v0 real-fixed): v1 arm1 A2 advisory, arm2 R4 advisory. The worker fixed it anyway.
- (a) demoted in one arm only, **#3011 `docs-no-go-plus`** (v0 real-fixed): v1 arm1 A1 advisory, but arm2 R1 now blocks it. It is not lost on either-arm.
- (b) dropped entirely: none. Every v0 real finding is still mentioned in at least one v1 arm.
Count: 2 lost (demoted in both arms), 0 dropped.

## Shed (wrong in v0, no longer blocking in v1)
- **#3180 F4** (GW-METRICS "values owned by another requirement", v0 moot): not raised by either v1 arm. Shed.
- **#2753 arm1 F1** (the ⚖ out-of-scope pin's escape clause, Q8, v0 moot): not raised. arm1 lists the fixture rename under "Premises not reopened". Shed.
- **#2753 arm2 R3 / arm1 A1** (the closure carrier, v0 moot): still raised, advisory only in both arms (arm2 R3, arm1 C1). Shed from blocking.
Count: 3 of 3 shed (none still blocks). The one new wrong block (#3011 R2) is noise that v0 did not have.

## Lint lines
| case | line | verdict |
|---|---|---|
| 3180 | `T2: r2.1 and r2.3 share every input cell ['file'] — with DIFFERENT expected cells: the deciding input is in no column` | **real**: it matches the truth R10. The "different expected" part comes only from the parenthetical. |
| 3180 | `T2: r2.3 expected `memory?` carries a parenthetical '(rendered, never absent)' — a condition outside the cells` | **real**: the same truth finding, its second half. The worker dropped that parenthetical (truth §Doubts). |
| 3011 | `clean` | correct (0 truth findings; the one real cell defect, an instruction in a cell, is outside the lint's T2) |
| 2782 | `clean` | correct |
| 2753 | `clean` | correct |
Tally: 2 real · 0 noise · 0 unknown; 3 clean on the controls, all consistent with zero rounds.

## Would it have been queued more correctly — one paragraph
An author who fixed ONLY v1's blocking findings would have prevented the one TRUTH round on #3180: arm2's R10 asks for exactly the deletion that 5652b821 made. They would also have pre-paid two edits the worker made anyway: the glossary line, and the alert-as-prose/promtool shape, which also kills the round-1 advisory "Prose claims without a row". They would NOT have fixed health.md:8, which v1 demoted to advisory in both arms and which is still false on master today. On the controls, v1 arm1 queues all three unchanged, which is correct. v1 arm2 holds #3011, which rode clean, for two edits. The first (R1, the cell's conditional) is what the worker did at zero cost. The second (R2, add a ⚖) is a wrong block: the merge-time specs reviewer, applying the same check 2, ruled "⚖: not needed … mechanical parse-failure row", and master carries no ⚖ on that row. So the cost on the controls fell from v0's 2 wrong blocks on 2 held controls to 1 wrong block on 1 held control. That wrong block is cheap to fix (one glyph), but it adds a mark the page's own reviewer calls noise.

## Doubts
- #3011 R1 is scored real-fixed, following v0. As a false-positive test it is a block that is correct on the facts and useless on cost. The worker resolved "verify during implementation" by adding the row, which is exactly what the issue delegated. arm2 itself names the conflict: RULES rule 10 sanctions the mark, and check 1 blocks it inside a cell. If the rule becomes "the mark lives on the Unverified line, never in a cell", the block is right. Under today's rules it is a policy-conflict block.
- The arm1 R10 handoff ("Not reviewed (row specialist's)") is scored missed, as in v0. If the two arms always run together, the handoff is by design, and either-arm recall (1/1) is the right number.
- Master's #3011 row now reads `… parse-failed | 5 |`, not `the last good` (a later change to the table convention). This does not affect the verdicts.
- The health.md:8 demotion: both arms rated it "no gate reads it", which is true, but it is the only v0 finding that is real-landed. Q3/U2 stale-prose findings may need a "the page now contradicts itself" → blocking rule.
