# Retro brief — TEMPLATE (v3, 2026-07-25)

<!--
This is the DURABLE retro brief (FU-058 brief-v2 item (a) — runs 1+2 ran from a /tmp file
that survived only in transcripts; recovered verbatim from s3://agent-transcripts/
oracle-fleet/retro-r1-opus/ and upgraded with the run-1+2 lessons).

ASSEMBLY (agents/retro-session.sh does this): replace
  {{STACK}}        — stack name (e.g. oracle)
  {{RUN_ID}}       — r<N> (docs/agents/retros/ numbering)
  {{MAIN_REPO}}    — the stack's main repo (e.g. teststuffstash/oracle-fleet)
  {{LEDGER_JSON}}  — the full pain-ranked ledger array (worst first)
  {{DEEP_DIVE_K}}  — how many top ranks form the deep-dive set (default 8)
  {{HARNESS_SRC}}  — verbatim excerpts of the harness artifacts findings may target
                     (coordinator-scan clauses, estimate_budget.py bands, fix.yaml text)
Send the assembled file into the ride; the first user message is exactly:
  "Read /tmp/retro-brief.md and execute it exactly. Your final message must contain the
   complete report between the markers it specifies."

Version log:
- v3 2026-07-25: + ledger-semantics warnings (6/9 run-2 reports burned effort rediscovering
  emitter blind spots), + harness-source excerpts (fabricators invented APIs exactly where
  they couldn't read the target), + task-granularity section (operator direction), + wins
  section (B2 "distill wins"), + predecessor scoring slot.
- v1/v2 2026-07-25: runs 1+2 (9 models, ranked verdict in 2026-07-25-oracle-r2-VERDICT.md).
-->

# Retro brief — {{STACK}} stack agent loop ({{RUN_ID}})

You are running a RETROSPECTIVE over the {{STACK}} stack's agent-loop task ledger. The loop:
GitHub issues labelled `agent-fix`+`agent/queued` are fixed by ephemeral LLM worker pods
(rounds), reviewed by an LLM reviewer bot, auto-merged on approval. Every finished task left a
ledger row (below) plus its GitHub issue/PR trail in `{{MAIN_REPO}}`.

## Known ledger blind spots — do NOT rediscover these, work around them

The emitter has known gaps (FU-058 brief-v2(b); fixes pending). Treat these fields as
unreliable and say so ONCE, not per-finding:
- `reviewer_rounds` is 0 even for tasks with real review verdicts — count review rounds from
  the issue/PR trail, never this field.
- `wall_time_s` is NOT decomposed active/idle — long walls are usually queue/review idle;
  cross-check against PR open→merge timestamps before calling something slow.
- `retry_storms` counts harness-level retries only; model-level retry loops inside a session
  do not appear. Trails are the evidence.
- `total_cost_usd` of 0.00 on subscription/haiku rows means UNTRACKED, not free.

## Input — the full ledger, pain-ranked (worst first; ranks 1-{{DEEP_DIVE_K}} are the deep-dive set)

```json
{{LEDGER_JSON}}
```

## Access

- `gh` is authenticated for `{{MAIN_REPO}}` (issues, PRs, reviews, comments, CI runs) — drill
  into the deep-dive set's trails; spot-check at least one GOOD run (1 round, first-approval)
  as contrast.
- **Fleet-wide reads (homelab#587)**: the pain-rank spans every stack's repos, not just
  `{{MAIN_REPO}}`, so a deep-dive whose trail lives in another repo needs cross-repo access.
  When the environment carries `RETRO_GH_TOKEN` (a ~1h READ-ONLY fleet-wide token, App-minted),
  use it for those reads: `GH_TOKEN="$RETRO_GH_TOKEN" gh …`. When the variable is absent, do NOT
  guess at a trail you can't reach — name which repo(s) were unreachable and why in the report's
  Evidence confidence section instead.
- The harness artifacts your process changes may target are excerpted below — cite and edit
  THESE texts; never invent clause or API names beyond them:
- **Name your tool gaps, once (homelab#536)**: when a NAMED diagnostic or tool is unavailable
  in-pod (a `gh` verb that 403s, a ledger read that fails, an egress-blocked fetch) and its
  absence changed what you could verify, emit ONE line in your report whose first characters are
  exactly `TOOL_GAP: <tool-or-verb> — <what it was needed for, one clause>`, once per session per
  tool — evidence, not lobbying.

{{HARNESS_SRC}}

## Task

Find CROSS-TASK patterns — never re-litigate a single bug. Look at: where rounds get burned
(review round-trips? red-CI loops?); failure classes by model; calibration quality by tier;
retry-storm clustering; wall-time outliers; anything the ledger says the loop pays for
repeatedly. For each finding:
- **Evidence**: task ids + the numbers (from the ledger and/or issue trails).
- **Mechanism**: one falsifiable hypothesis for WHY.
- **Process change**: ONE concrete, small change, naming the exact artifact from the excerpts
  above (recipe text, reviewer rubric, scan clause, budget estimator band, an alert) — never
  "improve X".
- **Expected saving**: rounds/tokens/wall-time, quantified from the evidence.

Additionally:
- **Task granularity**: for each deep-dive task, judge whether it should have been ONE
  larger-model task (or a subagent fan-out) instead of chunks — and which chunks needed
  rework at integration. Evidence, not vibes: rounds burned on cross-chunk friction vs
  in-chunk work.
- **Wins**: if any task landed notably under estimate / first-round-approved, name the
  reusable procedure worth codifying into the recipe (the Devin-playbook move).
- **Platform KPIs (ADR-103, weekly — score these FIRST, every run)**: **bucket-A count** —
  platform-logic failure events this week (coordinator/reflex/prompt/scan defects; count distinct
  events from the responder ledger + platform-repo issues, not comments). It should FALL as
  replay gates land; report the number, the trend, and — mandatory — ONE proposed next gate (the
  highest-recurrence unguarded class this week). Sustained non-fall is the named trigger to
  revisit label-carried loop state (AgentStack CR status), per ADR-103. (Jail $/day-equivalent is
  NOT a retro input — it lives on the operator's Grafana subscription/gometer dashboards, not a
  cell recomputing it from a query this pod cannot reach; homelab#587.)
- **Predecessor score**: if a previous retro's process changes have since merged, open by
  checking the ledger KPIs across them (did rounds/issue actually drop?). If none merged,
  say "no merged predecessor changes" and move on.

Anti-goals: no platform rewrites; no more than 6 findings; no finding without ledger evidence.

## The cost model your "expected saving" column MUST use (operator ruling, 2026-08-31)

Denominate savings in the platform's real cost rails, most expensive first — never in bare
machine round-counts (r2's F4 priced a fix in reviewer rides, the cheapest resource on the
board, while the operator's time went unmeasured):

1. **Operator time: €100/h WITH BATCH-ENTRY SEMANTICS** — an operator interaction costs
   `E/B + minutes×(100/60)` where E ≈ €17–25 is the fixed sit-down cost (keyboard, monitor,
   context reload) amortized over the B items handled in that sitting. A change that avoids one
   OUT-OF-SITTING summons (an escalation, a lone park, an alert pair) saves a full E (~€20–30);
   one that merely trims an in-sitting item saves €3–8. Nothing else on this list reaches E per
   event.
2. **Paid API (OpenRouter): billed dollars** (the `/generation` harvest — exact).
3. **Subscription draw: report BOTH prices** — cash-amortized (monthly fee × share of the
   binding window drawn: the honest steady-state cost; marginal ≈ $0 under headroom) and
   API-equivalent (list × tokens — the routing/saturation value; the Go meter computes this
   natively). A saving denominated in reviewer/coordinator rides is THIS rail at its amortized
   price, i.e. usually cents.

Full model: [`../chainless-redesign.md`](../chainless-redesign.md) §The cost rethink
(direction 5). A proposed change whose only saving is rail 2–3 says so honestly; a change
claiming rail-1 savings names the operator-touch class it removes.

## Output contract (strict)

When a retro finding becomes a process-change issue, its parent issue is the finding's ORIGIN
issue (the ledger row's issue the finding was derived from) when singular; standalone-honest
when the finding aggregates many rows; NEVER the retro report. The report links each filed
issue either way.

End your FINAL message with the complete report between these exact markers:

BEGIN-RETRO-REPORT
# {{STACK}} loop retro {{RUN_ID}} — <your model name>
## Summary (≤5 lines)
## Findings (ranked, ≤6)
## Proposed process changes (table: change | artifact | expected saving | confidence)
## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
## Wins to codify (or "none observed")
## Platform KPIs (bucket-A count · trend · proposed next gate)
## Predecessor score (or "no merged predecessor changes")
## Evidence confidence (what you could NOT verify and why)
END-RETRO-REPORT
