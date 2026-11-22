# Intake — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`
> (and `oracle-fleet a3c64a81` for its facts file), 2026-11-22.

## What it is

Island intake is the daily admission sitting: it reads an island's undecided inputs (issue pile,
waits, dig and responder findings, spec gap rows, review escapes) and leaves each in one
loop-readable state. [`islands/intake/`](../../../islands/intake/README.md) is running code moved
into one directory (homelab#3575, Goal #3574); it replaces nothing ("What this replaces: Nothing").
Live code reads it every day: the CronWorkflow
[`island-intake`](../../../agents/coordinator/island-intake-argo.yaml) clones `master` and runs
`scripts/sitting.sh` once per island. It has no spec root, and no sitting of its own: its paths
ride the gateway's selector row.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | partial | One directory with a README (consumer contracts, read set, revert class) and a stack contract [`CONTRACT.md`](../../../islands/intake/CONTRACT.md). No facts file of its own: [`islands/README.md`](../../../islands/README.md) row says "its items ride the gateway's sitting"; `intake-select.sh` `island_members gateway` lists `islands/intake/`. The manifest sits under `agents/` (agent-loop's prefix), the alerts under `argocd/resources/pushgateway/` (no island's prefix) | nothing filed |
| R2 Specs | absent | No `specs/`; `island_specs_root` has no intake row; islands/README: "a fresh build of `intake` … not started" | nothing filed |
| R3 Evidence | partial | Ran `devbox run -- bash islands/intake/tests/island-intake-test.sh`: `RESULT: 395 passed, 0 failed`. No `rule(` label in the harness: cases are not rows | nothing filed |
| R4 Worlds | partial | `tests/fixtures/` holds recorded dig and responder findings, 11 wait cases (each `case.json`, schema `intake-wait-case/v1`, with rules path, commit and `recorded_at`, validated by `scripts/intake-wait-cases.py`) and recorded Prometheus answers for the experiment read; the review trial's frozen cases are in `docs/spikes/island-intake-fixtures/` | nothing filed |
| R5 Gates | partial | `scripts/diff-ci.sh` maps `islands/intake/` to `deep-dig-test`, which runs the harness (`agents/deep-dig-test.sh` line 648), so the required `ci` runs it on a touching PR; `island-intake.promtool-test` runs in the rules lint. No spec gate, join or hygiene ratchet, no specs reviewer | nothing filed |
| R6 Replaces the old | does not fit | Moved code, not a rebuild; the rung belongs to the future fresh build | nothing filed |
| R7 Metrics | partial | `island_intake_*` gauges (`sitting.sh` `_push`, `claims-read.sh`, `listed-push.sh`, `experiment-read.sh`); five alerts in [`prometheusrule.yaml`](../../../argocd/resources/pushgateway/prometheusrule.yaml) (`IslandIntakeStale`, `IslandIntakeClaimsUnread`, `IntakeExperimentOverdue`, `IntakeExperimentReadStale`, `IslandRulesDigestOverdue`) with promtool tests. No dashboard (no `*.json` in the tree names `island_intake`); no facts file to name the reads | nothing filed |
| R8 Feedback loop | partial | The experiment read runs as the workflow's first step (#3586); it decides other islands' issues. For intake's own changes the one path is step E: escape class #3655, filed 2026-11-22 05:16Z against `rules/intake.md`, undecided. Its alerts are `triage: none` | #3586 (post-launch #3607); #3655 |
| R9 Intake | partial | Its items reach the gateway's sitting (#3655: "the sitting of the island that owns `islands/intake/rules/intake.md` rules it"). [`docs/intake/gateway.md`](../../intake/gateway.md) names intake only as the rules home; nothing there describes intake's ride surface | nothing filed |
| R10 Learns | partial | All three loops exist and have run: the escape read filed #3655; the wait ledger (`intake-wait-ledger.py`) and recorded wait cases; the weekly digest landed report PR #3565 (`c1f511e8`, "week ending 2026-11-19, 15 change(s)"). No filed class has yet turned into a merged rule edit | #3655 |

## Not on the draft ladder

- **The identity can do what the rules write.** The rules give a sitting "one branch ref per Goal"
  (`rules/intake.md` §Hard limits); the sitting's token got HTTP 422 cutting `goal/3656-scan-checkpoint-b`
  (comment on #3656, then `seat`). Every bot-authored Goal stalls on this. No issue tracks it.
- **Capacity and model spend.** `INTAKE_DAILY_MAX`, the `subscription-capacity` semaphore, and FU-320's
  note that `prefer: strongest` spent the strongest model's weekly limit on 2026-11-21.
- **A contract for stacks.** `CONTRACT.md` is a consumer page no other island has. It says "No stack
  has turned it on yet"; the 05:00Z run walked `oracle/oracle-fleet` (task statement, not verified).
- **The launcher is tested as deployed.** The harness extracts the bootstrap from the manifest and
  runs it with the script, with stubs.

## What intake needs from an island

| Rung | The island has it: the sitting can | The island lacks it: the sitting cannot | Depends on |
|---|---|---|---|
| R1 | hold a sitting; name owners in step 0 | run at all: no selector row or facts file = not listed; an incomplete facts file fails the step before any session. Its paths fall to the commons or to agent-loop's attribution input | README §Schedule; `scripts/facts-check.sh`; rules step 0 |
| R2 | write `spec` bodies with key rows; select `⚑ gap` / `🚧 WIP` rows (`--source gaps`); run the rows lens | only `edit` bodies, the unit lens alone, no gap source | rules §A queue-ready body; selector `island_specs_root`; `sitting.sh` `_snippets_process`; CONTRACT §What a sitting will not do |
| R3 | name the `rule(…)` test file in `Touches` so the footprint serialises two issues on one requirement; test a claim against its row in step 1 | serialise by requirement; a Goal's Production-leg falls back to "evidence in lieu" (#3656) | rules §Both shapes, second bullet; step 1 |
| R4 | quote recorded wire answers into a body as facts | read a surface the pod cannot reach; a missing recording becomes the recorder item filed first | rules §Both shapes ("What the worker cannot read, you read"); gateway facts "A vendor wire answer nobody recorded is such work" |
| R5 | admit work with no operator: "On an island the lens IS the gate" | rely on that premise; the queue bar still demands every path `machine-merge` | rules §Why this sitting exists; §Outcomes `queue` |
| R6 | — | drive a switch-over or retirement: it is entry (c) "direction", always `seat` | rules step 3 (c); scan/launch/retro facts "Operator-only: … the switch-over decision" |
| R7 | match dig findings and responder classes by alert; write an `## Experiment` from a `## Sources` row marked `experiment` | dig inputs fall back to a text pattern (`island_pattern`), responder classes need an alert defined in an island's rule file; every body gets `Experiment: none` | selector `island_alert_rules` (gateway only); rules §Experiment "Series" |
| R8 | decide on evidence and let feedback correct it | justify that: step 3 "No entry → you decide … production feedback … corrects a wrong pin" assumes the feedback exists | rules step 3; CONTRACT §Experiments |
| R9 | run the parity check over sibling sets; mark `seat-only` reads; read `Operator-only` lines | parity (gateway is the only facts file with sibling sets); every unlisted operator fact becomes a judgement | rules step 3 "The parity check"; CONTRACT §What you provide |
| R10 | file an escape class against the facts file; propose a rule edit at the wait ledger's bar | improve the facts file from its own stalls: a stack's facts file is outside the digest | rules steps E and W; CONTRACT §The rules' own upkeep |

**Where a roadmap would be read.** No rule reads one: `roadmap` appears in the rules only as the
platform `ROADMAP.md`. "This island's next rung" would serve four existing steps: step 5 (is it worth
a ride now — "the island's contract gaining a row it relies on"), step 4 (one ride, a Goal, or over the
ceiling), step 2 (a covering Goal: a roadmap item is a surface no Goal names yet), and step 3 (c), where a
recorded rung would be a ruling that binds instead of a `seat` on "what the island is for". The parity
check would gain a template across islands only if the ladder named per-rung facilities.

**What the sitting does today with no roadmap.** It decides what arrives. Gap rows come in index order,
the first `INTAKE_GAP_MAX` (6); at most 3 `queue` outcomes a sitting; step 5 judges "this month" per input.
Goals are authored only from inputs (#3656 from #3550); children are ordered by `blockedBy`; nothing
orders Goals against each other or against a rung.

**Facts-file parts per island** (counts of rows in `## Sources`; "exp" = rows noted `experiment`):

| Island | Body shape | Sources / exp | Operator-only or "`seat`, always" | Sibling sets | Dig by alert | Specs root |
|---|---|---|---|---|---|---|
| gateway | spec | 10 / 1 | yes | rails | yes | `gateway/specs` |
| scan, launch, retro | spec | 7 / 0 (explicit `none`) | yes | — | text pattern | `islands/<i>/specs` |
| router-pair, mgmt-box, substrate | edit | 10–12 / 3–5 | "`seat`, always" | — | text pattern | — |
| agent-loop, dependency-upgrades | edit | 13 / 2, 10 / 3 | yes | — | text pattern | — |
| oracle/oracle-fleet (stack repo) | spec | yes / experiment file | (a), (b), (d), (e) | not checked | no dig source | none declared here |

The stack file adds parts no platform file has: `## Membership`, `## WIP`, `## Gates`, an
experiment-authoring brief.

## The island's own items

- Goal-branch cut refused (422) for the sitting's identity — nothing filed.
- Escape class B, read existing rows before adding rows — #3655.
- Own facts file and selector row, or an explicit statement that the gateway's sitting rules intake — nothing filed.
- Model share for sittings (strongest model vs opus) — FU-320 "Next".
- The replay runner and the edit-PR leg — FU-320 "Next" (not read further).
- What may release a `pr-hold` wait is unruled (`rules/intake.md` step R); `INTAKE_PR_HOLDS` is off by default — nothing filed.
- `CONTRACT.md` currency against the live claim walk — nothing filed.
- The fresh build of intake (with the deep dig and the responder) — nothing filed; islands/README says it waits.

## In flight

- R1/R9: Goal #3574, `goal/post-launch` (post-launch #3582).
- R8: Goal #3586, `goal/post-launch` (post-launch #3607).
- R10: #3655 (open, no labels).
- As consumer: Goal #3656 (scan), filed by today's sitting, parked on the branch cut.
- Tracker: FU-320.

## Next steps, in order

1. **Identity (not on the ladder; serves R9 for every island):** the 422 on `goal/**` — nothing filed;
   waits on the operator (a ruleset is entry (d)). Until it moves, every bot Goal stalls.
2. **R8:** read the first verdicts through #3607 — waits on a merged experiment reaching its window.
3. **R10:** decide #3655 — waits on the gateway's next sitting (or the seat).
4. **R1 + R9:** choose between riding the gateway's sitting and its own facts file plus selector row —
   nothing filed. A real choice; recommendation: its own file, because escape classes land on intake's
   rules and the gateway facts describe a different ride surface.
5. **R7:** a dashboard over `island_intake_*` — nothing filed; no waits.
6. **R2–R6:** specs and the fresh build — nothing filed; waits on the operator. Recommendation: keep the
   harness as the evidence until the fresh build starts.

## What it can lend, what it should borrow

- Lend: `scripts/facts-check.sh` (one "can this file carry a session" test); `scripts/experiment.py` and
  `scripts/experiment-read.sh` (a claim decided from a series, no session in the path);
  `scripts/intake-wait-ledger.py` (a rule-line key counted over distinct items, a bar of two);
  `rules/intake-escape.md` (classify review findings A–E against the author's read set);
  `scripts/listed-push.sh` (keeps a per-member staleness alert quiet for a member that left the list);
  the harness's pattern of extracting the bootstrap from the manifest.
- Borrow: a spec root and `gateway/scripts/spec_gate.py` once it resolves other roots; scan's island gate
  `islands/scan/scripts/ci.sh` and recorder `islands/scan/scripts/record_world.py`; oracle-fleet's `## WIP`
  section and its experiment-authoring brief (`.agents/intake-experiment.md`) as the release-verdict model.

## Three-group sort

- R1, R3, R5, R7, R9, R10: common — every island needs them for a sitting to decide on its own.
- R2: common in shape; the `gaps` source and rows lens are platform-common today (stack roots are not declared to the selector).
- R4: common; worlds feed the "you read, the worker does not" rule on any island.
- R6: platform-common — only platform islands replace an old member.
- R8: common write side; the experiment read is platform-common, the release-bound reader stack-common (CONTRACT §What stays yours).
- Facts parts: Body shape, `## Sources`, `## What a ride can do`, Operator-only lines, experiment rows — common; sibling sets — common in shape, gateway-only in use; `seat-only` notes — platform-common; `## Membership`, `## WIP`, `## Gates` — stack-common.
- Rules: outcomes, steps 0–5, closed list, hard limits, review and repair, step E, Goal authoring — common; dig and responder sources, step W, `/coordinate` ring — platform-common; claims read, membership grammar — stack-common.
- Own items: the 422 identity gap — common (every island's Goals); #3655 — common (rules); own facts file — island-only; model share — platform-common; `pr-hold` release — platform-common; CONTRACT currency — stack-common; fresh build — island-only.

## Not verified

- That today's run walked `oracle/oracle-fleet` and filed nothing else: one cluster query allowed; it
  showed `island-intake-1795323600 Succeeded` only.
- Whether the digest's cron produced #3565: no `island-rules-digest-*` workflow is left, and yesterday's
  `island-intake` run is gone too, so retention removes them; the merge is the evidence.
- "No issue tracks the 422": `gh search issues "422 branch"` returned nothing (exit 0) with no positive
  control; meta-state calls the class untracked.
- Whether the harness's readers are strict in the islands/README rule 2 sense; the live lenses' scores.
