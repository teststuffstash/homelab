# Goal lane v1.1 — the FU-165 pilot (homelab#278), measured

**Status:** SETTLED — ADR-106 (2026-08-12) is the v1.2 design this evidence produced; kept as its evidence record. Original framing: feeds the v1.2 design (FU-168, FU-166, the #295
bucket-semantics question, FU-090's §M10 phase-not-clause block). Version register:
[`../agents/issue-authoring.md`](../agents/issue-authoring.md) §Goal lane versions.

The pilot ran the ADR-102 lifecycle end-to-end on the platform stack: 12 direct children,
46 post-launch-bucket sprouts, 41 merged PRs, 16:00Z 2026-08-11 → 06:30Z 2026-08-12, all
rides `claude/haiku` on the subscription rail. Method + rendered views: `agents/goal_graph.py`
(deterministic sub-issue + provenance snapshot, containment vs derivation DAGs); the working
exhibit is a claude.ai artifact ("Goal #278 — sprout DAG") — THIS file is the git-durable record.

## Findings (each measured, none guessed)

1. **The containment tree lies about depth: 2 generations recorded, 5 actual.** IL-T17's
   `bucket=` override files every sprout flat into the post-launch bucket, erasing the
   derivation chain (recoverable only from body-prose provenance). ADR-102's own text scoped
   the bucket to post-assembly parking; the widening to "every sprout" happened in the design
   doc + scan. This pilot had NO launch at all (every PR to master) — the "post-launch" bucket
   was born 7 minutes after the first child merged.
2. **All sprout content is worker/ride-authored; the reviewer authors nothing.** Of 52
   derivation edges: 22 worker PR-body findings, 17 goal-review-ride findings, 10 "reviewer
   Follow-ups" that are verbatim relays of the workers' own "Notes for the reviewer" sections
   (PR#298→#304, PR#310→#312-314, PR#293→#297). The depth-≥2 reviewer bar held as written and
   gated nothing — it silences the messenger, not the author. The platform's honesty rules
   (single-writer tracker, banned paths, `Touches:` ceiling) MAKE PR-body prose the findings
   channel; the harvest converts it 1:1 to issues with dedup as the only filter.
3. **Near-critical branching, converged only by force — but substantially a DEBT DRAIN, not
   steady-state divergence** (operator reframe, 2026-08-12, classification by subject age):
   ~30 of 46 sprouts were PRE-EXISTING defects the goal's first thorough review pass over
   homelab surfaced — the broken-alert estate (~10, incl. a known meta-state warning class),
   doc/tracker drift (~9), missing coverage + old code defects (~8), architecture fragility
   (~3). ~11 were in-goal residue, ~5 first-use defects of the goal machinery itself. The
   jail's verify-then-commit lane checks PRESENCE, not BEHAVIOR (an alert that applies passes;
   one that cannot fire doesn't fail) — the debt source, now countered by the CI-required
   behaviour fixtures the goal shipped. **Falsifiable prediction: the next platform goal's
   sprouts-per-ride lands well under 1.2; if not, the degeneracy reading returns.** Inflow per generation 12/13/11/13/8
   (flat, no die-off), ≈1.2 sprouts per closed ride, generation 5 = 7-of-8 still open. The
   terminators were external: the budget gate ($18>$15 at 18:47Z, raised; $62>$60 at 02:07Z →
   sprouts filed inert) and the operator's verdict gate. Also per-event cadence everywhere:
   21 goal-review ruling sessions (13 re-deriving the same "not complete"), 46 singleton issue
   mints, 3 issue-units on ONE file (`responder-behaviour-test.sh`: #304/#343/#360).
4. **The `Touches:` fence cost rides and prevented nothing.** Whole-run measurement: ONE
   temporally-overlapping same-file write (auto-merged), ZERO merge-conflict 422s;
   counterfactual full-drift ≈ 1 trivial doc collision. Meanwhile ≥7 deferred wants of ≤60
   lines (one was 1 line) each cost a full ride cycle — ~7× against the fence for the
   small-fold class. Deliver-diff sizes split cleanly: ≤60-line folds vs 160–1114-line real
   discovered work (which correctly stays issue-routed). **The flip side, found independently by
   the post-run janitor (homelab#379, 06:33Z):** the ADR-097 escaped-diff belt — reviewer-rubric
   PROSE — did not fire on 3 of the last 12 merges that wrote governance paths outside their
   `Touches:`. The fence over-blocks the harmless class AND under-enforces the critical one;
   both argue the same v1.2 shape — the ❌/governance boundary becomes a mechanical check
   (pin-only-lint's shape), the non-governance fence relaxes to declared drift. NB the janitor
   itself ran ONCE in the window (daily cron + queued behind the same scan mutex), so the goal
   ran board-judgment-blind until 06:33.
5. **The goal was dispatcher-bound, not work-bound.** Queue-wait 3,550 min vs pod time 605 min
   vs merge path 658 min (n=38 rides). Pods ran ≤1-wide for 743 of 870 min; 3-wide for 5 min
   total. **361 min of starvation** (queue>0, zero pods) — attributable to the scan
   mutex/stream serialization (sampled ring→scan-start ≈45 min), one-unit-per-pass dispatch
   (ADR-094), and the 3-slot subscription semaphore shared by workers + reviewers + the 21
   ruling sessions. At instant 3-wide dispatch the work fits ~4–5h; it took 14.5.
   **The doorbell convoy is the visible half** (`argo_workflows_gauge{phase="Pending"}`):
   pending workflows ramped to 20 by 20:00, cliffed on a mutex release, then climbed all night
   to **56 at 03:15** and took 3.5h to drain. Argo collapses nothing — ~100–150 rings became
   ~100–150 serial scan passes for 38 dispatches (~70–75% empty ticks), and a fresh event
   queues BEHIND the stale wakes, so "a false wake costs a scan run" inverts into convoy-depth
   × scan-duration of edge latency. This is an **ADR-093 regression**: the CronJob-era wake was
   a fixed-name `kubectl create` (atomic, `AlreadyExists` = already reconciling, exit 0 — the
   collapse); the Sensor submits `generateName` workflows. Re-applying the fixed-name key
   composes with the mutex/stream fix: collapse ends the convoy, detach ends the hold.
6. **Operator directives on the goal thread have no machine consumer.** The closeout charter
   comment was executed only because the seat re-read it; the close-time terminal (IL-T19) is
   deterministic and a closed goal draws no sessions. (Now FU-166 leg (b)'s named source.)
7. **The budget machinery's own defects surfaced live and were fixed in-run**: the one-hop
   ancestor walk gating rides against the budget-less bucket (#367/PR#378), the refusal-comment
   re-spam (#361), the ratio-join emptiness (#348) — the pilot's second deliverable working as
   intended.

## What settles it

The v1.2 design session (FU-168: ADR-094 concurrency + ADR-097 fence, "no pre-committed shape;
the numbers decide"), plus the sibling decisions it composes with: #295 bucket semantics
(finding 1), the typed worker-findings disposition gate (finding 2), §M10 checkpoint cadence
(finding 3), FU-166(b) event-driven seat watches (finding 6). Plus the stack-scope question
(operator, 2026-08-12): v1.1 ran ONE cross-repo child end-to-end (agent-runtime#66 → its PR#67,
native lineage + budget walk + ride all held), but no sibling platform repo has a merge doorbell
(cron-only edge) and no `-iac` descendant was ever exercised — on consumer stacks the deploy leg
(the -iac bump) sits OUTSIDE the goal tree, so the goal effectively ends at the app-repo merge.
v1.2 should make the Goal a STACK-scoped object: descendants across the claim's repos including
`-iac`, the `Production-leg:` verified through the -iac deploy + KPIs in post-launch.
**THE OBJECTIVE FUNCTION (operator, 2026-08-12) — codeowner-touch events, priced first.** The
current system values codeowner time at ZERO while it is the most expensive resource (the $1.74K
jail subscription exists precisely to FILTER codeowner responsibility; the operator's time is
worth more than that). Count where touches mint: worker-authored platform PRs (41 on goal night),
per-sprout triage reads (46), verdict gates, major/awaiting-human. The Goal type's original
economics — **assembly merge = ONE codeowner tax per feature, all nits solved by then** — was
silently dissolved by the v1.1 master-lane variant (every child its own tax event). v1.2 requirement:
restore the single-tax boundary (goal-branch assembly on platform goals too, or an equivalent
batch point), and evaluate every design option by codeowner-touch count FIRST, wall-clock second,
tokens third. Seat-authored PRs are touch-free (author==sole-codeowner waiver) — the filter works
when the SEAT authors; designs should prefer routing codeowner-class reads to the seat.

**Design synthesis (operator session, 2026-08-12) — the typed findings STORE is the load-bearing
piece**: one machine-readable pile per goal (ADR-103 shape: edited-in-place comment/check-run,
entries = origin + surface + substance), dispositioned at checkpoints. It resolves findings 1+2+3
at once (native provenance ⇒ the derivation DAG stops living in prose; the worker channel gets
its gate; mints batch). Consequences: every dedup reader (janitor, harvest, responder) must read
the pile as well as issues — under pile-up the duplicate window widens from search-lag to
checkpoint-cadence unless the store is readable; the janitor files nothing whose evidence-walk
resolves to an open goal with the substance already piled (annotate-not-attribute, one report
line); and the janitor gains the checkpoint-LIVENESS belt (pile age vs checkpoint cadence —
the outside goal-blind view watching the new machinery, #379's proven advantage), while its
orphan-aging sweep measures piled findings against the checkpoint schedule, not birth.
Single-run caveat throughout:
platform repo, subscription rail, mostly-serialized dispatch — re-measure any fence/concurrency
conclusion on a genuinely concurrent stack before generalizing.
