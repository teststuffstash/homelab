# PR #3264 ← issue #3180  (standalone)
rounds: 1 CHANGES_REQUESTED (code: 0, specs: 1); open 2026-11-11T20:40:29Z → merged 23:12:41Z (2h32m); merged
body edited after queueing: no — userContentEdits show one edit at 19:40:19Z (intake's rewrite), the `intake: queue` comment is 19:40:20Z, no later edit.
Not a review finding, recorded for the tally reader: the PR exists under the operator's login because the ride's `pr-open` gate was red on two environment legs (`component-check` kyverno.github.io fetch, `gateway-specs-site-e2e` no docker) — process, class fix #3262; no reviewer raised it.

| round | reviewer | finding (one line, rule id if cited) | class | evidence (quote ≤ 20 words from body / spec / review) | the intake check that would have caught it (one line; "none" for D/E) |
|---|---|---|---|---|---|
| 1 | specs | R10 / rows-brief check 10 (CONVENTIONS §The intent column, "Rows read without their description"): row 3 "both modes render on every gateway, the inactive one at 0 ⚖" has the same cells as row 1 | A | body: `\| both modes render on every gateway, the inactive one at 0 ⚖ \| \`file\` \| \`1\` \| \`0\` (rendered, never absent) \|` vs row 1 `\| \`file\` \| \`1\` \| \`0\` \|`; review: "Only the description distinguishes them" | per new table: no two rows may share every input cell, and a distinguishing condition may not live in a parenthetical/description — it must be its own column (pinned CONVENTIONS, named in §Island facts) |

Non-blocking, same review (advisory, not tallied): "Prose claims without a row" — the body's three alert rows (`\| the memory store pages after 5 minutes ⚖ \| …`) are not spec rows the gateway suite can prove; the worker turned them into promtool scenarios S1–S3 and a rule-11 in-place mark resolved it. The body handed a row table to a surface (promtool) that has no spec-row join.

## Tally  A=1 B=0 C=0 D=0 E=0
## What the body got right (rows the reviewers passed untouched) — 2 lines
Family row, rows 1–2 (`file`→1/0, `missing-dir`→0/1), the bounded `mode` label, the gap-row deletions and both verbatim index-cell trims all passed; the specs reviewer cites "intent: issue acceptance 1" on each.
The alert pins (name, group, expr, `for: 5m`, no `absent()` ⚖) were built as written and the code reviewer passed them; the body's "Unverified: which module holds the store mode" correctly anticipated the `app.py` escape, which both reviewers accepted as declared.

## Doubts
- The worker dropped the `(rendered, never absent)` parenthetical from row 3's `memory?` cell to satisfy the join ratchet ("The memory-mode cell had a parenthetical the test didn't match"). Classed A, not D: the specs reviewer says even a kept parenthetical fails — the distinguishing condition must be "a column that is also a parameter of the test case", and the body's row 3 had none (same input `file`).
- Code reviewer round 1 (later DISMISSED by the fix push) saw the same duplication ("It is a duplicate of row 1 by parameters") and approved anyway — not a contradiction worth an E, it is outside its rubric.

# Controls — merged with zero change requests

**#3011 → PR #3012** (fix, one requirement GW-CATALOG-GO). Touches 6 paths (one over the ≲5 bar); 6 acceptance lines; 2 key rows, each on its OWN world (`docs-teams`, `docs-no-go-plus`) so no two rows share input cells. The fixture's cell is copied verbatim from the live vendor page ("`\| **Go Teams** \| **$20/member/month** \| Every member gets…`"), with the read's URL and date. Left to the worker: only "verify during implementation whether an existing row already proves it; add only if not" (row 2) — a yes/no, not a design. The specs reviewer's row list is the body's two rows by name, both "✓".

**#2782 → PR #2979** (fix). Touches 2 paths; 3 acceptance lines; zero table rows — an index-row pointer edit whose exact final text is in Acceptance 1 (`` `⚑ gap (2026-10-18, PR #2716 → work #2977)`: … ``). Specs reviewer: "the issue … gives the exact new flag text; the diff matches it character for character". Nothing left to judgment except "whether `spec_gate.py` reads the flag's `→ work` pointer" — a fact the worker resolved by reading the script. Diff: 1 file.

**#2753 → PR #2982** (fix). Touches 2 paths; 4 acceptance lines; no row added — one existing row restated unchanged and one named-gap row deleted; both deletions quoted verbatim in Acceptance 1–2, the siblings that stay named "verbatim". The closure "rests on rows that run" (existing, named). Left to the worker: whether the join keys on the deleted description (worker: "the join ratchet exempts ⚑-prefixed rows"). The one judgment call (fixture SA rename) was pinned ⚖ into Out of scope; the specs reviewer: "The PR body defers this as out of scope, and I agree."

**#3180 by comparison:** Touches 8 paths across two trees (`gateway/**` + `argocd/resources/agent-gateway/**`), 2 requirements (GW-METRICS + GW-HEALTH), 4 acceptance lines, ~8 newly authored rows in three new tables (family, behaviour, alert) — none copied from an existing page or a live wire, and the alert table targets a surface with no spec-row join. The single bounce is on a newly authored row whose input repeats its neighbour's.

## Clean vs. bounced — the differences that are properties of the issue body
- New rows vs. copied text: the controls' row/flag text is either existing page text ("delete … verbatim", "stays verbatim") or a live wire read ("the live `\| **Go Teams** \|…` row"); #3180's rows were intake-authored ("a table of their own, 'The store mode is a gauge'").
- Distinct inputs: #3011's two new rows differ in the input column (`docs-teams` / `docs-no-go-plus`); #3180's rows 1 and 3 both read `file` and differ only by "(rendered, never absent)".
- Size: controls Touches 2 / 2 / 6 paths, 1 requirement each; #3180 Touches 8 paths, 2 requirements, and its own comment had to justify it ("hence eight paths").
- Row count: controls carry 0, 1 (restated) and 2 rows; #3180 carries a family row + 3 behaviour rows + a label row + 3 alert rows.
- Surface fit: every control row lands on a spec table the suite joins; #3180's alert rows ("`\| the memory store pages after 5 minutes ⚖ \|`") landed on promtool, which drew the prose-without-row advisory.
- Judgment left open: controls leave one yes/no fact each ("verify during implementation whether an existing row already proves it"); #3180 leaves a source-file choice ("a second source file is a declared deviation") — which did NOT cost a round.
