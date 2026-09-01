# Research → specs — the multi-model authoring process

**This doc owns the research process**: how a product contract (a `specs/` tree) is authored by a
multi-model fan-out, evaluated, woven, hardened by implementation, and handed to a Goal.
**First-pass record (2026-08-10) from ONE full run** — circles, 2026-08-03..08 — plus the design
rulings from the operator session that harvested it. Per the ≥2-projects rule, the *unsettled
register* at the bottom is deliberate: the second run (idp, FU-126) settles it. Model selection
mechanics live in [`model-routing.md`](model-routing.md) §M13 (ADR-104); the researcher role's
machinery in [`roles.md`](roles.md); branch/lineage mechanics in
[`issue-authoring.md`](issue-authoring.md) §`Base:`.

## Research precedes the Goal (operator ruling, 2026-08-10)

Research is the **pre-goal phase**: a research MISSION prepares the contract (the woven `specs/`
tree, landed by harvest); a **Goal** (ADR-102) then exists to *implement* those specs. Two issue
kinds with different lifecycles, budgets, and outputs — a woven branch vs merged code.

**Vocabulary (FU-163 — rename executed, S4 #766, 2026-08-23):** the research kind is a
**mission**, never "a goal". The historical bare `goal` dispatch label no longer exists anywhere
— the authoritative IssueLabels sync deleted the hand-made legacy labels, and NO machine
predicate ever read it (the scan keys on `task/goal`, the Goal type; research dispatch is
operator-manual by issue number). A mission issue therefore carries **no label today**; when
FU-090(c) graduates research dispatch, the label minted via the claim taxonomy is **`mission`**
(name reserved in [`../glossary.md`](../glossary.md)).

**Evidence sighting (operator, 2026-09-01 — the oracle riigiteataja miss):** a Goal built
against an UNDOCUMENTED upstream (what Riigi Teataja actually publishes is trial-and-error
knowledge, documented nowhere) ran the loop cleanly and still required deleting and redoing a
large part of the work — the miss sat upstream of every worker: nothing answered "what does the
source actually publish" before the build committed. Worker-cost optimization is the wrong
lever on this class; a recon mission (cheapest form: ONE instrument arm probing the live
source, never a full fan-out) would have saved more than any routing or counting refinement.
⚖ One sighting — NOT codified per the ≥2-pattern rule; the candidate rule sits in the
unsettled register below.

## The process

As run on circles (the worked example — PR numbers are circles'):

0. **Mission issue** — the product intent, human-authored, self-contained (#1). **Open the
   mission log with it**: an append-only `research/mission.md` on the mission branch in the
   stack repo — TICK-LOG-shaped (condition → action) — recording the roster **as dispatched**
   (would have caught the run-1 flash/pro slip on day one), mid-run process inventions, judge
   verdicts, and artifact links. It lands with the harvest PR; run 1 had no log and its process
   had to be reconstructed from PR metadata + a TICK-LOG parenthesis + operator memory
   (2026-08-10 session — expensive, and one artifact was memory-only).
1. **Spec fan-out** — N models author independent `specs/` trees on `research/<mission>-<slug>`
   branches, un-armed (human-gated by construction). Circles: opus #3, kimi-k3 #4,
   deepseek-v4-flash #2, mimo-v2.5-pro #5. Machinery: `agents/research-fanout.sh` (FU-126).
2. **Evaluation mission** — a SECOND issue (#6) carrying only the arm table (deliberately no
   product content), dispatching two instruments:
   - **Judge panel** (`.agents/research-compare.yaml`): blind checklist → per-arm inventory →
     union matrix → scorecard + **per-page cherry-pick map** + deduped ⚖ register — never
     "arm X wins". Run in ≥2 judge cells (different models) — a cross-check *on the judge*;
     the divergence between judge maps is itself signal (which pages are contested).
   - **Downstream proxy**: ONE fixed cheap model × N runs, one arm each, role-playing the
     builder who must implement P0 from that tree alone; output = every question still needed,
     graded `blocker / judgment / minor / answered-by-⚖`. Fewer blockers = the more complete
     spec — fitness-for-purpose, orthogonal to the judge's structural metric. Isolation: the
     proxy must not read the mission, the other arms, or PR bodies.
3. **Contested-page resolution** — where judge maps diverge, render the page BOTH ways from the
   real arm trees (body + grafts, provenance-marked) side-by-side, plus the weave-invariant
   core (what survives either way) → the operator decides per page from a visual. Circles: the
   `color.md` artifact ("one spec page, two weaves", claude.ai). **Rule: link the decision
   artifact from the weave PR** — it is process evidence and currently the one artifact with no
   durable reference (found unlinked 2026-08-10).
4. **Weave** — operator cherry-picks per page across arms, merges the ⚖ registers → one woven
   tree on the mission branch (#16→#25: 15 pages, 91 requirements, 49 ⚖). One weave sufficed on
   circles; carrying **two weaves** forward and letting implementation break the tie is the
   over-provisioned form (see Principles).
5. **Implementation experiment** — build against the woven contract as a TEST of the spec (and
   of goal decomposition: circles ran a decomposed goal #17 vs a one-shot arm #21 — the
   evidence behind §M10's "a goal small enough for one ride is not a goal").
6. **Harvest** — fold what implementation taught back into the specs (#28: 3 new rulings,
   ⚖ 49→52, palette fix), **discard the implementations** ("the contract is the artifact"),
   merge the specs-only PR to master, freeze the experiment branches as benchmark arms.
7. **The Goal** — a fresh implementation Goal built from the hardened contract with the full
   evidence chain (#29 "P0 complete": spec row → test case → fragment → page).

## The step ladder (model policy per step)

The agentic lane's tier principle — *capability escalates with judgment leverage* (haiku writes,
sonnet reviews, sonnet/opus coordinates, opus/fable meta-coordinates) — transposed onto a process
whose cost shape is inverted: the FIRST step carries the volume, each later step shrinks in
tokens while growing in leverage, so unit cost may rise:

| step | token volume | selection (bands: §M13 pools) |
|---|---|---|
| fan-out arms | largest (N × full tree) | `regular` pool, slots 1..N — diversity is the product |
| downstream proxy | small × N | `instrument` — one fixed cheap model, constant by construction |
| judges | medium | `premium`, slots 1..K — tier ≥ strongest arm (reviewer≥author decorrelation) |
| weave assist / synthesis | smallest | `ultra` — top tier, subscription |

Callers name **zero models** — `class` + `slot` + `jitter:false` against the scout-curated pools
(§M13; the draw verb + pools build is tracked by FU-162, shipped 2026-08-11 in homelab#290). The
bands are disjoint *by curation convention*, which structurally prevents run-1's two selection
slips (below) without router enforcement.

In practice, for step 1: `bash agents/research-fanout.sh <project> <mission-issue> --arms 7`
(`--dry-run` draws the roster and stops). A slot whose model is unavailable comes back a typed
defer and stays EMPTY — over-provision covers it; nothing is substituted. Record the arm table it
prints, `pool-version` included: that triple is what re-draws the mission. ⚠ The hand-seeded
`regular` band is 6 deep today, so a 7-arm ask visibly defers its last slot until the scout's
weekly refresh (§M7 leg 5) deepens it.

## Principles (rulings, 2026-08-10)

- **The shape is the resilience, not any individual selection.** Over-provision every stage
  (7 arms for 5, two weaves, ≥2 judges), prune late on evidence. A slipped opus judge is
  *visible* in the arm table and weighed accordingly — that is the guard.
- **Visibility over enforcement.** Research is an operator-driven lane with a human at every
  judgment point (un-armed PRs, human weave, human harvest). Enforcement machinery (roster
  validation, exclusion invariants, retry protocols) belongs to autonomous lanes where nobody
  watches; here it would be doctrine-weight without a watcher to replace.
- **Failure = over-provision + depth.** A dead arm waits, relaunches (the draw is idempotent),
  or takes `slot=N+1`. No retry protocol anywhere.
- **Experiments do not jitter.** The jitter band is exploration budget for high-volume dispatch;
  inside a ~13-call mission it is corruption (ADR-104).
- **Provenance is part of the artifact**: arm tables with exact slugs, per-section source chips
  in weave materials, model slugs in branch names, cost per arm recorded as context (never
  merit).
- Standing brief rules apply: volume ≠ quality (a spec restating the issue has failed);
  overreach/premature depth is a defect (specs are grown during implementation); recount —
  never trust self-reported counts.

## Run-1 lessons (circles — kept verbatim so run 2 doesn't rediscover them)

- **The roster was hand-applied and unvalidated**: arm #2 rode deepseek-v4-**flash**-0731 where
  the intent was **pro** — a one-token slug slip nothing displayed (TICK-LOG 2026-08-03: "draw =
  AA intelligence tier ∩ own reliability evidence; operator picked"). Fix = the §M13 draw +
  recorded arm table, not enforcement.
- **The proxy graded its own arm**: the instrument (deepseek-v4-flash) was also arm #2. Fixed
  structurally by band disjointness (`instrument` ∉ `regular`).
- **Renaming the weave base closed the weave PR** (#16→#25) — the full hazard is
  [`issue-authoring.md`](issue-authoring.md) §`Base:`.
- **"Goal met" fired with the weave unmerged** — the assembly reviewer approved the code; the
  spec weave predated it. The harvest step (specs-only PR, `Closes` the harvest issue) is what
  actually lands the contract; the weave PR itself may stay frozen as a benchmark.
- Judge cells grew 2→3 mid-run; the side-by-side artifact was invented mid-run — both kept as
  process (steps 2–3 above), which is exactly the grow-then-codify arc working.

## Unsettled register (run 2 — idp, FU-126 — answers these)

- **Budget**: per-ride caps + `FANOUT_APPROVE_ESCALATE` + the subscription leg are the
  primitives; a mission-level `Budget:` line (Goal-shaped) is expected but NOT designed. Run-1
  data: kimi $4.33, others <$2, opus on subscription.
- **Dispatch automation**: missions are operator-manual (FU-090(c) is the graduation shape).
- ~~The `goal` label / mission naming — FU-163~~ — **resolved 2026-08-23 (S4 #766)**: the
  vocabulary note above; `mission` is the reserved future dispatch label.
- **Harvest cadence** for a longer mission (one harvest at the end vs per-phase).
- **Two-weave mode**: designed here, never yet run — first mission that hits a genuinely split
  judge verdict should try it.
- **The mission log** (step 0): first kept log is the idp run — does TICK-LOG-shape fit a
  mission that spans repos, and does "lands with the harvest PR" survive a mission that never
  reaches harvest?
- **When is a mission REQUIRED, not optional** (2026-09-01 sighting, one instance — codify at
  the second): a Goal whose contract depends on an UNVERIFIED external source (undocumented
  API/data publisher) may need a mandatory recon spike/probe arm first — the riigiteataja
  build-first cost was a large delete-and-redo the loop itself executed flawlessly.
