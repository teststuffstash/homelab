# feedback-triage (oracle) run r1 — Claude Opus 5.5 (claude-opus-5-5)
## Coverage (what was read, how much, since when; what could not be reached)
- Source: Postgres `feedback` on `oracle-pg-rw.oracle-fleet.svc:5432` as `feedback_ro`, through `scripts/feedback-sql.py` (every script rolled back). Connected without problems; nothing was unreachable.
- Sink size: 67 rows in `feedback`, the oldest received 2026-08-30. The baseline plan covers all 67, one line per row.
- Residue (rows with no `feedback_triage` row): 2 rows, ids 160 and 163, read in full with facets and raw `anchor.request`.
- Oldest residue row: id 160, about 19.5 days old, which is past the 7-day guard. Row 163 is about 5 days old.
- Baseline plan (`feedback-rules.py --no-lapse`): queue = 2 (2 with no rule matched, 0 `CONFLICT`). Conflicts = 0. Regressions = 0.
- The baseline shows 9 rows as `CHANGED` from fixed to tracked (ids 3, 4, 17, 32, 41, 110, 148, 150, 151). These come from running with `--no-lapse`: all seven issues behind those rules (#656, #709, #711, #712, #861, #886, #887) are CLOSED, so the nightly lapse step turns those rules into `fixed`. They are not residue and I did not touch them.
- `feedback-rules.py --check`: 19 rules OK.
- Read: the existing rules in `specs/tools/feedback-rules.yaml`, §FB-RULES in `specs/tools/feedback.md`, and §RT-STATUTE-PROVISION in `specs/tools/statute.md` (unnumbered lõiked, positional fallback, `alampunkt` rules). Searched GitHub issues for annex and lõige-echo matches.
## Summary (≤5 lines)
- Residue is 2 rows, with 0 conflicts and 0 regressions. No rule was added, widened or removed, so I opened no PR.
- Row 160 (origin homelab, statute, `wrong_citation`): looks like a gap against RT-STATUTE-PROVISION's positional-fallback rule, but no open issue tracks it, so `tracked` is not available. ⚖
- Row 163 (external, statute, `missing_capability`, act-level request): asks for annex retrieval. Whether that belongs to #891 item 4 or is a new capability is a scope call. ⚖
- The queue stays at 2. The rules already decide the other 65 rows.
## Decisions (counts per outcome; the PR you opened, by URL)
- Rules added: 0. Rules widened: 0. Rules removed: 0. `overrides` added: 0.
- Rows moved by disposition: fixed 0, tracked 0, ruled 0, bucket 0, praise 0, platform 0, upstream 0.
- Plan delta: queue 2 → 2, conflicts 0 → 0, regressions 0 → 0.
- PR: none, because no rule changed and the brief says to skip the PR in that case. I wrote no DB rows and made no repo edits.
## Proposals (⚖ — what you did NOT decide and why it is a human's call)
- ⚖ P1, row 160 (origin homelab; 1 caller; external 0). Shape: `anchor_tool=statute`, `category=wrong_citation`, `zero_hit=true`, `req_act=VÕS`, `req_paragraph=278`, request carries `loige=1` and `alampunkt=1`, harness curl.
  - What the row reports: the § has a single unnumbered lõige. A lõige-only request echoes `citation.loige` as 1, but the same request with `alampunkt` added echoes `citation.loige` as null.
  - What the spec says: RT-STATUTE-PROVISION makes a numeric `loige` on an all-unnumbered § resolve by position, with `citation.loige` carrying the positional number. Its tables cover the lõige-only case but have no row for the lõige + alampunkt case.
  - Question: is this a server defect (file an issue, then add a `tracked` rule with predicate `r.anchor_tool='statute' AND r.category='wrong_citation' AND r.req_act='VÕS' AND r.req_paragraph='278'`), or a spec gap that needs a ruling first?
  - Recommendation: file a server issue ("positional-fallback lõige dropped from citation when alampunkt is given"), add the missing table row to the spec, then add the `tracked` rule. I file no issues, so a human or the next run has to do this.
- ⚖ P2, row 163 (external; origin null; 1 caller). Shape: `anchor_tool=statute`, `category=missing_capability`, `zero_hit=true`, `req_act=RLS`, request is act-level with only `{act, date}`, harness codex-mcp-client.
  - What the row asks for: dated retrieval of annexes that a § points to.
  - Related: open issue #891 item 4 ("annex attribution") proposes giving annexes their own unit instead of folding them into the last §. The ingest spec also rules that non-image `<fail>` attachments are kept only as a `[lisa: …]` placeholder.
  - Question: is this RLS annex content inline XML that #891 item 4 would expose (then `tracked`, ref #891), or an attachment ruled out of scope (then `ruled`, ref the riigiteataja ingest ruling), or a new roadmap capability (annex retrieval as a tool input)?
  - Recommendation: check how RLS lisa 1 is encoded in the corpus. If inline, add a `tracked` rule (ref https://github.com/teststuffstash/oracle-fleet/issues/891) with predicate `r.anchor_tool='statute' AND r.category='missing_capability' AND r.req_act='RLS' AND r.req_paragraph IS NULL`. Otherwise, make a product ruling on annex retrieval.
- No other proposals. With 0 conflicts there was no rule overlap to resolve.
## Evidence confidence (what you could NOT verify and why)
- Row 160: I did not reproduce the response against the live server. The citation mismatch is known only from the row itself; the `anchor.observed` I could see shows one of the two calls, so the comparison call cannot be confirmed from structured fields.
- Row 163: the anchor has `tool` and `request` but no `observed`, too sparse to confirm from structured data that annex text is missing from the served act. I did not check how RLS lisa 1 is encoded in the corpus, so the choice between #891 and an attachment ruling is open.
- The two predicates sketched in P1 and P2 were never run through the plan, because no rule was written. Each is narrow, keyed on act and paragraph, and should match only its own row, but that is untested.
- The 9 fixed→tracked rows are explained as a lapse effect from the closed issues and the `--no-lapse` flag. I did not run the plan with lapse on (it needs the /status endpoint and git ancestry), so the nightly result for those rows is assumed, not observed.
- I did not check FB-GOLD, since no `fixed` rule was added.
BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[]}
```
END-RETRO-FINDINGS
