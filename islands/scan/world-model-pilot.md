# Mining the scan's checkpoint specification

[Trial #3550](https://github.com/teststuffstash/homelab/issues/3550) asks whether one detailed YAML model can give a reader a short lifecycle overview, a decision table precise enough to implement, and the evidence for each row. Scan is the first island to try this. The result another island needs is a worked decision that caught a real class of mistakes and a measure of what it cost to maintain. The [first-leg Goal](https://github.com/teststuffstash/homelab/issues/3490) covers the handoff and updater. The [scan-decision leg](https://github.com/teststuffstash/homelab/issues/3448) owns the checkpoint requirement. This note records the experiment design.

## Why start here

[IL-T12](../../docs/agents/issue-lifecycle-fsm.yaml) identifies the lifecycle owner and the reasons for waking a checkpoint. The [FSM lint](../../scripts/merge-path-lint.py) checks code anchors, fixture pins in both directions and document freshness. In a local renderer experiment, replacing IL-T12's entire `when` value with “never schedule a checkpoint” yielded identical Markdown and zero render failures. The renderer copies the diagram string and omits the transition's `when` from the table. A field that decides behavior needs a visible cell and an executable expectation.

The [checkpoint storm](https://github.com/teststuffstash/homelab/pull/3312) cost ten reasoning rides in one hour, eight of which reported no change. Filtering in-flight checks addressed one cause. The [subsequent ruling](https://github.com/teststuffstash/homelab/pull/3319) gives a much smaller decision: once a checkpoint has dealt with an open assembly PR, pushes, reviews and check changes on that PR leave trigger (b) held. The identity of the open assembly PR suffices. A changes-requested verdict may still wake a different clause.

## Find the world that distinguishes the decisions

Start with two predictions for the same sequence: a push to the marked PR wakes trigger (b), or it stays held. Search the incident timestamps, Goal, assembly PR and dispatch markers for the smallest witness that distinguishes them. Oracle's [world quarry and series census](https://github.com/teststuffstash/oracle-fleet/blob/master/specs/worlds/README.md) offers the precedent: search by shape, including across related records, extract a named specimen with provenance, and identify derived variations.

Here the unit is a Goal over successive wakes. Record the public supplier reads whole, with argv, repo, item, timestamp, head where available and recorder revision under the [island recording rules](../README.md#built-from-the-specs-never-copied). A present-day PR view cannot establish an earlier open board. Keep missing observations explicit. Label any replay of a changed value as derived and describe the delta. The ruling supplies the expected effect; an observed dispatch supplies evidence about the failure.

An exporter edge wakes the scan; the scan reads GitHub to evaluate the decision. Keep a narrow typed reader at that boundary: one exact read, validated fields, distinct results for absent and unreadable. A local handoff experiment exercised the same approach on real PR data and distinguished an empty reviews list from a malformed response. For checkpoint, the decisive facts are assembly identity and marker readability. Preserve process tests over the raw recorded answers so a convenient typed fixture cannot hide an impossible query. The [updater outage](../../docs/incidents/2026-09-05-updater-node-cap-responder-dead-triage.md) illustrates that risk.

## One model, several views

The scan island authors the guard under [SCAN-CLAUSE-GOAL](specs/scan-decision.md#scan-clause-goal). IL-T12 remains the owner of the surrounding Goal lifecycle. A policy change cites its operator ruling. The adapter supplies observations, the scan evaluates and selects candidates, and the coordinator performs a selected checkpoint.

Start the YAML with one decision. Give each case a stable identity, named world and step, observations, expected eligibility and expected external effects. Carry the actual marker between steps. Generate the decision table for the spec page and a view joining case, witness, test and result. A reader must see each field that affects the verdict. Keep evidence status unverified until there is a run. Use the generated page rows in the labelled tests, preserving the [portable row conventions](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md). CI compares a fresh render with the committed page. The implementation computes its answer independently. Further views can use whatever tooling best serves the reader.

## First sequence and pass condition

Begin with trigger (b)'s precondition met: the pre-launch child set is complete. An open assembly PR A without a matching marker is eligible. Let another candidate win the lane. A must remain eligible on the next wake. Select A, allow the marker write to succeed, then vary the checks, head and verdict on A across wakes. Trigger (b) contributes zero additional dispatches. Close A or replace it with B: evaluate eligibility again. The [old guard and dispatch site](../../agents/coordinator-scan.sh) deliberately leave (b) eligible on an unreadable fingerprint and attempt the marker write only after selection. A failed marker write can therefore leave the next wake eligible. Exercise these boundaries explicitly.

Change the implementation to stamp on evaluation or to release on same-PR churn: a sequence must fail. Change the model's expected decision alone: the generated table must change and the test against the unchanged implementation must fail. Run old replay as a separate comparison and rule each difference under the island convention. Report which historical mistake the trial detected, what the views exposed to a reviewer, and the authoring cost. That evidence is the basis for adoption by another island.

## Result

The trial of [#3550](https://github.com/teststuffstash/homelab/issues/3550) on trigger (b), goal [#3656](https://github.com/teststuffstash/homelab/issues/3656). One table; a row per measure, a column per arm: `hand` is [`trial/checkpoint-b-hand.md`](trial/checkpoint-b-hand.md) with its decoding in `tests/test_checkpoint_b.py`; `model` is [`specs/models/scan-clause-goal-b.yaml`](specs/models/scan-clause-goal-b.yaml), whose table is the one on the [spec page](specs/scan-decision.md). `tests/test_trial_result.py` fails when a cell differs from what the suite and [`trial/measure.py`](trial/measure.py) produce.

| measure | hand | model |
|---|---|---|
| mutants detected (of 2) | 2 | 2 |
| facts written twice | 83 | 0 |
| edits for one policy change | 16 (2 arm-specific) | 16 (2 arm-specific) |

- **Mutants detected.** The two mutants under `tests/mutants/`, each run against every labelled row of the arm: the stamp-on-evaluation mutant turns `lane-lost-stays-eligible` red, the release-on-churn mutant turns `goal-checkpoint-b-content-push-held` red, in both arms.
- **Facts written twice.** `trial/measure.py` counts, per case, the cells that decide the verdict and that name a pull request number, a marker hash or an expected literal (open assembly PR, markers, the three expected cells), and asks whether a second authored file of the arm holds the same text as a string literal. The files are the issue's: `model` has one, so its count is zero by construction; `hand` has two (the table and the decoders). The count is crude: a literal such as `none` or `A` that the decoders happen to spell counts, so 83 of 90 is an upper bound. The same count for the model's cases over the decoders and `scripts/render_model.py`'s lookup tables (files the issue does not list, because the model arm still needs them) is also 83 (`note.` line of `measure.py`): the YAML states each fact once, the arm around it restates them.
- **Edits for one policy change.** The change is fixed: "a marker read that fails holds (b) this pass" in place of Goal pin 9 — the component's decision (`HELD: pr=<n> marker read failed`), the page's legend literal and sentence, one test name, and the one case row (`marker-read-fails`) that expects it. It was applied on a scratch copy per arm and the added plus deleted lines counted over the authored files; the two diffs are [`trial/policy-change/hand.diff`](trial/policy-change/hand.diff) and [`model.diff`](trial/policy-change/model.diff). `model.diff` leaves out the regenerated table rows of the page and `trial/checkpoint-b-view.md` (generated files); the suite passed on each scratch copy for that arm's rows (`test_trigger_b_hold_<arm>`) after the change, the model one after `scripts/render_model.py`. Counted for the hand arm: the hand table and the shared files; the test file's decoding needed no line beyond the shared test name. 14 of the 16 lines are shared (component, page legend and sentence, test name); the arm-specific edit is one row (2 lines) in either arm. The change is not merged: the page, the model, the hand table and the component at this head still state pin 9.

**Order.** The hand arm was written first (child 2, #3658), the model arm second (child 3, #3659). The arm written second is cheaper to write: it reused the case list, the decoders, the recorded world and the sequence driver the first arm had built, so no authoring-cost number in this report compares the arms on equal terms.

**What each view shows.** The page table and `trial/checkpoint-b-hand.md` carry the same ten columns; `trial/checkpoint-b-view.md` is the case view rendered from the model.

| field that decides the verdict | page table | `checkpoint-b-hand.md` | `checkpoint-b-view.md` |
|---|---|---|---|
| open assembly PR | yes | yes | yes (`open list:` in the derived elements) |
| markers | yes | yes | yes (`comments:`) |
| since the marker | yes | yes | yes, when not `—` |
| fault | yes | yes | yes, when not `—` |
| lane winner | yes | yes | no |

The view also omits the three expected cells; it shows what a case stands on and where its test is, not what it decides. `since the marker` is decoded into the world but the component reads only the open list and the comments (`test_the_component_reads_only_the_open_list_and_the_comments`).

**Which historical mistake a mutant stands for.** The stamp-on-evaluation mutant writes the marker in `evaluate`: a Goal that lost its lane is stamped without being dispatched — the mistake the trial question names. The release-on-churn mutant folds the head commit id into the marker, so a push to the same assembly PR releases the hold: the storm of 2026-11-12 ([#3312](https://github.com/teststuffstash/homelab/pull/3312), ruled in [#3319](https://github.com/teststuffstash/homelab/pull/3319)).

**Result as measured.** A tie on mutants detected (2 and 2) and on edits for the policy change (16 and 16, 2 arm-specific each). The one difference, facts written twice, is 83 against 0 on the issue's file list and 83 against 83 when the model's lookup tables and the shared decoders are counted. The model arm shows no measured advantage here; it also shows no loss.

**Unresolved.** Step 3 of #3550 (the deferral forks) is not run and waits on #3553. Which table stays is the Goal's verdict; neither table is removed.
