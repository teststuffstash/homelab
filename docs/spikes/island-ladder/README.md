# Island ladder — one shared maturity ladder, a roadmap per island

> **Spike, nothing ruled.** Operator direction, 2026-11-22: island intake has no idea where an
> island is going. Each island needs its own roadmap (not the platform
> [`ROADMAP.md`](../../../ROADMAP.md)), and most of each roadmap is the same list of steps for
> every island. This spike reads every island against one draft ladder and sorts what is common.
> Read at homelab `f1be04ca` and oracle-fleet `c3f7ee1`. Each island page was written by one
> subagent reading that island only; this page is the seat's reconciliation of them. It extends
> the island intake work tracked by FU-320 ([`follow-ups.md`](../../follow-ups.md)).

What an island is: [`docs/glossary.md`](../../glossary.md) ("island"). The rules intake runs
today: [`islands/intake/rules/intake.md`](../../../islands/intake/rules/intake.md).

## The pages

| Page | Covers |
|---|---|
| [gateway](gateway.md) | the agent gateway — live, the furthest platform island |
| [scan](scan.md) | the coordinator scan rebuild — source of world mining |
| [launch](launch.md) · [retro](retro.md) | the ride rebuild · the weekly retro rebuild |
| [intake](intake.md) | island intake itself, and what it needs from every other island |
| [oracle-fleet](oracle-fleet.md) | the stack island, read from outside (its facts stay in its repo, ADR-160) |
| [facts-only islands](facts-only-islands.md) | agent-loop, dependency-upgrades, mgmt-box, router-pair, substrate |
| [replay to specs](replay-to-specs.md) | the migration map: every replay family, its claiming island, its state |

## Where every island stands

The draft rungs (R1–R10) are defined in each page's Position table. `●` reached, `◐` partial,
`○` absent, `–` does not fit.

| Rung | gateway | scan | launch | retro | intake | oracle-fleet | infrastructure (4) | agent-loop |
|---|---|---|---|---|---|---|---|---|
| R1 Boundary | ● | ● | ● | ● | ◐ | ● | ◐ | ◐ |
| R2 Specs | ● | ● | ● | ● | ○ | ● | – (a register) | – |
| R3 Evidence | ● | ◐ 6 of 35 | ◐ | ◐ | ◐ no rule labels | ● | ◐ promtool tests | old replay |
| R4 Worlds | ◐ built, unused | ◐ 2 worlds | ○ | ○ | ◐ | ● | – (router-pair: the drill) | old replay |
| R5 Gates | ● | ◐ runs, does not gate | ◐ | ◐ | ◐ | ● | ●/◐ | ● (old) |
| R6 Replaces the old | ◐ | ◐ 2 families ruled | ◐ | ◐ | – | – | – | shrinks |
| R7 Metrics | ◐ | ○ | ○ | ○ | ◐ | ● | ● | ● |
| R8 Feedback loop | ◐ | ○ | ○ | ○ | ◐ | ◐ built, not run | ◐ | ◐ |
| R9 Intake | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ● | ● |
| R10 Learns | ◐ | ○ | ○ | ○ | ◐ | ◐ | ◐ | ◐ |

## What the pages change in the ladder

1. **The ladder is not one line. It has a proving side and an operating side, joined at "live".**
   R2–R5 prove a component against its page. R7–R10 operate a running one. A rebuilt island (scan,
   launch, retro) ships nothing until a switch-over, so it cannot start R7, R8 or R10 at all. The
   gateway and oracle-fleet are live and climb both sides. Intake and the infrastructure islands
   started on the operating side and have little or none of the proving side. An island's roadmap
   is therefore "which side is it on, and what gets it to the join".
2. **R6 is two different rungs.** For a rebuilt platform island it is "compared and ruled against
   the old member, callers switched, old member retired". For a stack it is "a release reaches
   prod through stages and can be rolled back". Both are the same join: the proven thing is the
   thing that runs. Call the rung **Live** and give it two forms.
3. **R4 needs splitting by the kind of input.** The scan recorder reads GitHub answers. Launch's
   first world is gateway answers checked against the supplier's schema; retro's is Prometheus
   answers; the gateway records its vendors' wire; oracle-fleet mines law dumps. What is common is
   the rule ("mined, never invented", provenance, a strict reader that refuses an unrecorded
   read), not the recorder.
4. **R5 must separate "runs" from "gates".** The scan suite already runs in CI inside the
   specs-site step, which does not fail on red. Nothing required gates any island suite until
   PR #3627 lands (#3391).
5. **R3 must separate "passes" from "joined".** Retro's cases pass while its evidence pack reports
   mismatched cells; launch's cases take their rows from the replay fixture, not from the page.
6. **A rung is missing on the intake side: the identity can do what the rules write.** The rules
   tell a sitting to cut a Goal's branch; the ruleset refuses (HTTP 422). Three Goals wait on it
   today (#3656, #3480, #3482). Nothing tracks it.
7. **Infrastructure islands do not climb the proving side and should not.** In place of specs each
   has a register with a "last proven" column; its evidence is a promtool-tested alert rule; its
   experiment is a declared maintenance window or the box's lease. They need no roadmap of this
   kind. agent-loop's roadmap is a carve list: it shrinks as islands take its replay families.

## The three groups

| Item | Group | Note |
|---|---|---|
| Boundary: a directory, a README, a facts file | common | infrastructure islands: the facts file and selector row are the whole rung |
| Requirements written down, each row provable | common | spec pages for components; a "last proven" register for infrastructure |
| Specs in the pinned snippets shape, rule ids | common to software islands | gateway, scan, launch, retro and oracle-fleet all pin v0.6.9 |
| Evidence: one rule-labelled case per row, rows are the test source, joined | common to software islands | |
| Spec gate, join ratchet, hygiene ratchet, evidence-carrying review pack | common to software islands | the scripts exist for `gateway/` and for oracle-fleet; scoped to neither scan, launch nor retro |
| Worlds: mined, with provenance, behind a strict reader | common (the rule) | recorders are per input kind; GitHub and Prometheus recorders are shareable |
| Supplier-schema check of a consumer's hand-written world | common | launch needs it against the gateway today |
| Metrics: gauges, promtool-tested alerts, a dashboard, reads named in the facts file | common | routing alerts to intake by rule file exists only for the gateway |
| Feedback loop, write side: alert or feedback → inert issue → intake with an experiment → ride | common | |
| Intake sitting, wait and escape records, the learning loop | common | |
| Identity can do what the rules write (Goal branch cut) | common | missing from the draft ladder |
| Replay family compared and ruled, then retired | platform-common | 271 families; 2 ruled; no rule says when one may be deleted |
| Switch-over of live callers from the old member | platform-common | planned nowhere yet |
| Required `ci` step per island suite (#3391) | platform-common | homelab's `ci.yaml` |
| Kubernetes, S3 and gateway-seam worlds | platform-common | loop state and claims |
| Dig and responder as intake sources, the wait step, `seat-only` notes | platform-common | |
| Specs site and evidence in homelab buckets | platform-common | |
| Releases through stages (Kargo `shadow`, `prod`), rollback | stack-common | the stack form of "Live" |
| Feedback loop, verdict side: an experiment checked against prod traffic, closeout closes or reopens | stack-common | oracle-fleet has it built; no release carries a claim yet |
| Feedback rows from real users, gold rows | stack-common | |
| Privacy and retention alerts | stack-common | |
| A built data artifact with its own boundary (corpus regen) | stack-common | |
| Lanes, a work-in-progress cap, a gates table, a membership section in the facts file | stack-common | oracle-fleet's `TRACKS.md` and facts file |
| High availability | stack-common | platform islands are single-replica by design |
| A product roadmap | island-only | oracle-fleet's `docs/roadmap.md`; the gateway's router parity |

Two items sit on a group boundary and need a ruling rather than a row:

- **The experiment reader.** Homelab's reader already takes oracle-fleet's experiment format, but
  oracle-fleet reads claims through its own Kargo step and its facts file marks no experiment
  source row. One format, two readers: fine if the readers are declared stack-common and
  platform-common, a clash if they are meant to be one.
- **World mining.** Scan's recorder and oracle-fleet's mining both exist. The shared part is the
  rule set; whether a shared recorder is worth building depends on how many islands record GitHub
  and Prometheus answers (today: scan, and next retro, launch and the gateway).

## Roadmap per island

Each page's "Next steps, in order" is the full list. The first steps:

| Island | Side | Next steps |
|---|---|---|
| gateway | both | label its 251 unlabelled test rows → metrics (#3501, #3504, #3503, waiting on #3088) → first claim to a verdict (#3505) → use its wire recorder (#3300's production step) → parity record and caller switch-over (FU-269 first) |
| scan | proving | required gate (PR #3627) → the remaining rows over worlds (#3448) → Goal #3656 → spec gate and ratchets for its root → remaining families ruled (#3389) → switch-over of the two compared members |
| retro | proving | required gate → Prometheus world and recorder (#3487) → guard rows from the page, ruled (#3488, #3489) → fix the join |
| launch | proving | required gate → gateway-seam worlds (#3483) → rows from the page, in Python (#3484) → ruled comparison (#3485) |
| intake | both (since 2026-11-22) | done: the branch-cut identity, its first spec page and tests, its own App (see §Direction since the spike) → spec pages for the deterministic scripts (selector, facts check, launcher, wait ledger, experiment reader) → its own facts file and sitting → the deployment test tier → first experiment verdicts (#3607) → a dashboard |
| oracle-fleet | both | read its first sitting → settle the experiment reader → the four proposed loop briefs get their codeowner read → first release carrying a claim |
| infrastructure (4) | operating | no ladder roadmap; close the named gaps (alerts routed by rule file, `node-fstrim` rules untested, no gate for `mgmt/nixos/**` and `ansible/**`) |
| agent-loop | shrinking | the carve list: 98–105 replay families no island claims, mostly the reviewer, the responder and the revert chains |

**Order across islands** (revised 2026-11-22, see §Direction since the spike). The live islands
come first: intake, then the gateway. Both already run and can block work when they misbehave, so
a stall on a rebuilt island would otherwise be debugged on the wrong island. Each stops at the same
line: the island reports its own faults and its feedback loop has run once. For the gateway that is
its metrics (#3501, #3504, #3503, waiting on #3088), the first claim to a verdict (#3505) and the
parity record against the old router with the caller switch-over (FU-269 first). Then the rebuilt
islands: one member taken all the way to live before widening (scan's two ruled members), retro
before launch (retro has Python components and its first world needs no supplier schema), and
#3448 before #3656 on scan (the scan page's recommendation: #3656's child #3660 rules rows on the
page #3448 re-sources). PR #3627, the required gate for scan, launch and retro, merged 2026-11-22.

## What intake would do with it

Today a sitting decides each input alone: work order is the gap index, at most 3 queued a
sitting, and a Goal only comes from an input. The [intake page](intake.md) names where a roadmap
plugs into the procedure:

- **step 2 (already owned?)** — an item for a rung the island's roadmap already carries binds to it;
- **step 3 (c) (direction)** — an item that skips a rung, or contradicts the island's next step, is
  the operator's, and the sitting can now recognise it;
- **step 4 (size)** — a Goal for a later rung waits while an earlier rung is open;
- **the parity check** — a rung one island has reached and a sibling island lacks is the "obvious
  gap" it already knows how to file, across islands instead of inside one.

It also needs R7 and R8 on the island it decides for: the rules' "you decide, feedback corrects"
assumes an alert row and an experiment exist. Only the gateway has an alert row today, so every
other island's bodies carry `Experiment: none`.

## Direction since the spike

Operator, 2026-11-22, after reading this page. These overturn parts of the text above; the island
pages are left as read on that day.

- **Live islands first.** Intake, then the gateway, before scan, launch and retro (§Roadmap per
  island, the order paragraph).
- **Intake gets specs now, over the running code.** The pages above say "specs only when a fresh
  build starts"; that conflated specs with a rebuild. The rule files a sitting reads stay out of the
  spec; they improve through the wait and escape records.
- **Non-functional requirements are spec rows.** The missing rung in §What the pages change, item 6
  ("the identity can do what the rules write") is now a page:
  [`islands/intake/specs/access.md`](../../../islands/intake/specs/access.md) — one row per act a
  sitting performs with the credential and permission it needs, and the acts it must be refused.
  Its first failing row was the Goal branch cut; the fix (creation of `goal/**` is not check-gated)
  is applied and proven by a recorded answer.
- **Each identity is its own App.** Intake runs as `homelab-intake`, with a second read-only token
  for a stack's source repo ([`islands/intake/CONTRACT.md`](../../../islands/intake/CONTRACT.md)).
- **A deployment test tier.** An island's image and manifests are deployed to a throwaway cluster
  with mocked external services before merge. No island has it: the gateway's tests run in-process
  and its "e2e" covers only the specs site. The rig that lets jail sessions run such a cluster is
  proposed in PR #3678 and unmerged. It belongs on the proving side, between Worlds and Gates, and
  is common to software islands.

Not started, in order for intake: spec pages for the deterministic scripts; its own facts file and
sitting; the GitHub stand-in and the deployment tier's first slice (cluster rows of the access
page); the first experiment verdict (#3607).

## What would settle it

1. **The rung list.** Accept the revisions above (a proving side and an operating side joined at
   Live; R4 by input kind; "runs" against "gates"; the identity rung) or name a different cut.
2. **Where a roadmap lives.** Recommendation: the ladder once, in
   [`islands/README.md`](../../../islands/README.md) (it already lists "what every island shares"
   as gaps), and each island's position plus its own items as one optional part of its facts
   file, so a stack island fills its own through
   [`islands/intake/CONTRACT.md`](../../../islands/intake/CONTRACT.md).
3. **Software islands only, or all.** Recommendation: the proving side binds software islands
   only; the operating side binds every island.
4. **Replay retirement.** No file says when a replay family may be deleted, and the island tests
   themselves read the replay fixtures. This needs a rule before any switch-over.
5. **The two boundary items** above: the experiment reader and a shared recorder.

## Not verified

- Each page lists its own gaps. Across them: no suite was run except the gateway's pytest and the
  intake harness; replay-family counts differ by method (98 by the migration map, 105 by the
  facts-only page); live Kargo and alert state for oracle-fleet was not read.
- The intake page could not confirm that the scheduled run reached oracle-fleet. The seat read
  that run's workflow the same day: the `oracle/oracle-fleet` sitting ran and succeeded
  (07:07–07:20 UTC).
- Stale text the pages found and this spike did not fix:
  [`docs/intake/scan.md`](../../intake/scan.md) and the scan README still say the island has no
  evidence pipeline; `islands/intake/CONTRACT.md` still says no stack has turned intake on.
