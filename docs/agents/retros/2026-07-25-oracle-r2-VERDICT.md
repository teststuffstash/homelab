# Retro run 2 — ranked verdict (9 reports, repo-verified comparison)

Scored by an independent read against repo/issue ground truths (fabrication traps checked:
invented goose recipe APIs, misattributed ledger writer, real incident facts). Headers inside
reports are self-declared and sometimes wrong — scored by ride, not header.

| rank | model | grounding | patterns | actionable | run cost | note |
|---|---|---|---|---|---|---|
| 1 | opus (r1, subscription) | 5 | 5 | 5 | sub | line-exact cites; both ledger bugs; zero fabrications |
| 2 | deepseek-v4-pro | 5 | 4.5 | 4.5 | $0.076 | pinned #29's redundant redispatch to the finalize phase |
| 3 | hy3 | 4.5 | 4.5 | 4 | $0.022 | cleanest strike-schema fix; minor fix-target misroute |
| 4 | kimi-k3 | 4 | 5 | 4 | $1.09 | best unique finds (#52 double-dispatch race; stats on 2/32 issues) but mischaracterizes ledger.py |
| 5 | mimo-v2.5 | 3.5 | 4 | 3 | $0.016 | unique finds (key-PATCH expiry bug; #45 @rule regression); factual mix-ups |
| 6 | nemotron-ultra:free | 3.5 | 3.5 | 2 | $0 | novel REFACTOR_REQUIRED idea; invents whole fix.yaml schemas |
| 7 | nemotron-super:free (2nd) | 2 | 2 | 2 | $0 | thin |
| 8 | gpt-oss-120b | 2 | 2 | 1.5 | $0.003 | most fabrications (fictional files, misread incidents) |
| 9 | nemotron-super:free (1st) | 1.5 | 1 | 1 | $0 | misses every real incident |

**Routing conclusions (FU-095 data):**
- Audit/reasoning tier, API side: **deepseek-v4-pro** and **hy3** carry opus-adjacent grounding
  at $0.02-0.08/run — the practical audit-chain entries. kimi = the wide-net second reader
  (unique finds justify it on high-stakes audits despite cost + a grounding wobble).
- **gpt-oss-120b + nemotron-super are fabricators on this task class — keep out of audit chains**
  (gpt-oss's cheapness is a trap here; fine for other classes, not evidence work).
- **Complementarity is real**: 5 distinct unique finds across models — multi-model on audits
  pays in coverage, not redundancy.
- Free-tier: nemotron-ultra usable-but-flaky (1/2 reports, 0/3 reviews); super consistent but shallow.
