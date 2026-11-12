# feedback-triage (oracle) run r2 — Claude Opus 5.5 (claude-opus-5-5)
## Coverage (what was read, how much, since when; what could not be reached)
- Postgres `feedback` on oracle-pg-rw as `feedback_ro`: reachable. 67 rows in the triage plan, 2 untriaged rows (ids 160, 163).
- Oldest untriaged row: 160, received 2026-10-19, about 23 days old on 2026-11-11. Row 163 was received 2026-11-02.
- Baseline plan (`feedback-rules.py --no-lapse`): queue 2 (2 with no rule, 0 `CONFLICT`), conflicts 0, regressions 0, 19 rules.
- Step 0: the `in:body "feedback-family:"` search found no issues, so there were no earlier ⚖ rulings and no lane-B `tracked` rules to check.
- Prod MCP `https://mcp.minutark.ee/` was reachable. It answered on protocol revision 2025-11-25; the 2025-06-18 header was refused (the product's known gate, #940, not a reach problem).
- Requirements read: statute.md RT-STATUTE-PROVISION (Response shapes, Unnumbered lõiked, alampunkt without loige), feedback.md FB-RULES/FB-GOLD, the ingestion spec's `<fail>` placeholder rows, docs/ingestion-riigiteataja.md §3 (`lisaAadress`), and #891.
- Not reached: what `lisaAadress` holds for RLS. I did not fetch it.
## Summary (≤5 lines)
- Row 160 (homelab, statute, wrong_citation, VÕS § 278) was replayed on prod and contradicts RT-STATUTE-PROVISION. It went to lane B: defect issue #1040 plus a `tracked` rule.
- Row 163 (external, statute, missing_capability, RLS, act-level) needs a product call: no requirement covers annexes. It went to lane C as ⚖ #1041, with no rule.
- Queue 2 → 1, conflicts 0 → 0, regressions 0 → 0. No row outside the family moved.
## Decisions (counts per outcome; the PR you opened, by URL)
- Rules added: 1 (`statute-unnumbered-loige-point-echo`, tracked → #1040). Rules widened: 0. Rules removed: 0.
- Rows moved by disposition: tracked 1 (homelab 1 / external 0, row 160). No rows moved to fixed, ruled, bucket, praise, platform or upstream.
- Families by lane: A 0, B 1, C 1.
- PR: https://github.com/teststuffstash/oracle-fleet/pull/1042 (gate green at 818cc12, touches only specs/tools/feedback-rules.yaml).
- Lane-B issue: https://github.com/teststuffstash/oracle-fleet/issues/1040 (labels `agent-fix`, `task/fix`, `track/chassis`; no `agent/queued`).
- No gold row was added: the rule is `tracked`, not `fixed`. The FB-GOLD row the fix owes is written into #1040.
- The PR body says `Refs #1041` because `pr-open` refuses a body that names no issue. The brief bans Fixes/Refs only for lane-B issues, so referencing the open ⚖ issue was the one compliant choice.
## Proposals (⚖ — what you did NOT decide and why it is a human's call)
- ⚖ https://github.com/teststuffstash/oracle-fleet/issues/1041, family `statute-annex`, row 163 (0 homelab / 1 external). Shape: tool statute, category missing_capability, req_act RLS, req_paragraph null. Serving, excluding or bucketing a separately published annex is a scope or new-capability call (hard rule 4), so it is not mine. The options and the recommendation are in the issue.
## Evidence confidence (what you could NOT verify and why)
- The row 160 replay was made against corpus 27bf4bb8…, redaction 108072025026, for the filed date. The defect reproduces exactly; numbered § 282 was the control.
- The `source_url` anchor `#para278p1` on the lõige+point path is not claimed as a defect. The spec's tables have no anchor row for this case, and I did not verify RT's own anchor form.
- The `alampunkt`-without-`loige` variant also cites loige null. I left it out of #1040: there the caller sent no numeric `loige`, so the positional sentence does not apply.
- The new rule's predicate was checked against its one real row (160) and moves nothing else. Future wrong_citation rows with this exact shape are not tested.
- Row 163: the annex resource at `lisaAadress` (format, per-redaction dating, count) is unmeasured. I did not fetch it, so options B and C rest on spec silence, not on a census.
- The ⚖ options' predicates are pinned to req_act RLS because no structured field can see "annex". A wider family would need a new structured signal, not a phrase from the comment.
BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[]}
```
END-RETRO-FINDINGS
