# scan — the agent loop's deterministic scheduler (island)

The scan island is the loop's **cheap, deterministic half**: per stack, it re-lists the open
issues and PRs on every wake, decides which items a coordinator session would act on, holds or
reports everything else, and dispatches **at most one unit per (repo, base) lane** to an
item-scoped coordinator session — so no LLM is ever woken to discover "nothing to do"
([ADR-094](../../../docs/adr.md#adr-094--item-scoped-coordinator-dispatch-the-scan-schedules-the-llm-judges)).
Beside the scan sit its three merge-path reflexes — the **updater** (keep one merge-ready PR per
lane current), the **review reflex** (dispatch one reviewer per lane for an armed, green,
reviewable PR) and the **major handoff** (the only writer of `major/awaiting-human`) — plus the
phase and class signals the wedge alert and the board read. It is one of the pieces of the
agent-loop cut measured in
[context-and-autonomy.md §C8](../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01)
(83 commits in October, 47 % cross-component, top partner review). Code stays where it is; this
README names it. Terms: [specs/glossary.md](specs/glossary.md) (island-coined) and
[docs/glossary.md](../../../docs/glossary.md) (platform-wide).

## Membership

Code (stays in place; the island is this list):

| File | Role |
|---|---|
| [`agents/coordinator-scan.sh`](../../coordinator-scan.sh) | the scan — report, `--spawn` (per stack), `--switchboard` (global resolver, [ADR-120](../../../docs/adr.md#adr-120--the-global-coordinate-surface-is-the-switchboard-a-sensor-edge-resolver-its-cron-retired-2026-08-31)), the unit fast path, every clause, every hold, the lane walk, the signals |
| [`agents/coordinator-session.sh`](../../coordinator-session.sh) | the scan's dispatch arm: renders the item-keyed coordinator pod (`--item … --detach`), the atomic `(repo, item)` gate, and the `--launch` no-LLM re-run pod |
| [`agents/update-pr-branch.sh`](../../update-pr-branch.sh) | the updater (legs 1–3 + the Renovate carve-out) |
| [`agents/review-reflex.sh`](../../review-reflex.sh) | the review reflex backstop (pick, breakers, C9 re-arm) |
| [`agents/major-handoff.sh`](../../major-handoff.sh) | the `major` handoff gate |
| [`agents/goal-findings.sh`](../../goal-findings.sh) | the goal lane's findings-store helpers (sourced by the scan, CLI verbs for the session) |
| [`agents/renovate-currency.sh`](../../renovate-currency.sh), [`agents/pr-last-edited.sh`](../../pr-last-edited.sh) | predicates shared by the scan and the updater / the reflex only |
| [`agents/footprint.sh`](../../footprint.sh) + [`footprint-test.sh`](../../footprint-test.sh), [`agents/touches-check.sh`](../../touches-check.sh) + [`touches-check-test.sh`](../../touches-check-test.sh) | the ADR-097 footprint predicate — homed here, read by five other components (a seam, see Open) |
| [`agents/state-fp-replay.sh`](../../state-fp-replay.sh), [`agents/scan-wedge-alert-test.sh`](../../scan-wedge-alert-test.sh) | the state-fingerprint and wedge-alert belts |
| [`agents/coordinator/coordinate-argo.yaml`](../../coordinator/coordinate-argo.yaml) | `/coordinate` Sensor → per-stack scan / switchboard |
| [`agents/coordinator/reflexes-argo.yaml`](../../coordinator/reflexes-argo.yaml) | the `*/15` review-reflex backstop + the `subscription-capacity` semaphore (the ledger CronWorkflow in the same file is not the scan's) |
| [`agents/coordinator/update-pr-argo.yaml`](../../coordinator/update-pr-argo.yaml) | `/update-pr` Sensor + WorkflowTemplate + `*/15` sweep |
| [`agents/coordinator/README.md`](../../coordinator/README.md) | **the coordinator brief — runtime-read, never moved.** The specs cite its clauses: §State machine, §The `merged-closeout` clause, §The `goal-decompose` / `goal-checkpoint` clauses, §The `arbitrate` / `merge-conflict` / `ci-red` clauses, §Dependency major bumps, §Blocked-on marker |
| [`docs/agents/issue-lifecycle-fsm.yaml`](../../../docs/agents/issue-lifecycle-fsm.yaml) → generated [`.md`](../../../docs/agents/issue-lifecycle-fsm.md) | the issue machine the clauses implement (IL-T*; read by `scripts/merge-path-lint.py` — stays in place) |
| [`docs/agents/merge-path.md`](../../../docs/agents/merge-path.md) + [`merge-path-fsm.yaml`](../../../docs/agents/merge-path-fsm.yaml) | the PR machine (MP-T*); the updater/reflex mechanism sections moved to [docs/merge-path-mechanism.md](docs/merge-path-mechanism.md) |

Replay fixtures (`agents/replay/fixtures/<dir>/`, tests root candidate): the dirs whose
`fixture.yaml` sources a member above — about 95, listed per requirement in
[specs/README.md](specs/README.md#index). Families: `clause-coverage`, `queued-*`, `scan-*`,
`c4c5-*`, `ci-red-*`, `changes-requested*`, `merge-conflict`, `unarmed-major`, `arbitrate`,
`fleet-*`, `goal*`, `harvest`, `doorbell`, `dispatch-phase`, `fu146-*`, `session-*`,
`coordinator-*`, `updater`, `review-pick`, `reflex-*`, `c9-rearm`, `decorrelate-resolution`,
`major-handoff`, `item-class*`, `scan-phase-marker`, `scan-wedge-alert`, `state-fp`.

**Not members** (read for the decision, owned elsewhere): `agents/fix-debounce-argo.yaml`
(admission — the responder/intake piece; it writes the `agent/queued` the scan reads),
`agents/coordinator/deploy-revert-argo.yaml` (the revert guard), `corpus-dispatch-argo.yaml`
(oracle's doorbell to GitHub), `agents/goal-budget.sh` (the launcher enforces; the scan reads
advisorily), `agents/goal_graph.py` (seat tooling), the per-stack `coordinate-<stack>`
CronWorkflows (rendered by the AgentStack Composition — the claim island).

## Consumer contracts

**Exposes:**

| Interface | Consumer | Page |
|---|---|---|
| `POST /coordinate` doorbell (`{repo, unit, loop_ns, stack, source, rail}`) — at-least-once, never a work item | `agent-session.sh`, `reviewer-session.sh`, devbox-update, stack jails, `scripts/coordinate-ring.sh` | [specs/scan-decision.md](specs/scan-decision.md) |
| The item dispatch: `coordinator-session.sh --item "repo= item= clause= …" --wip N --detach` → one coordinator pod per `(repo, item)` | the coordinator brief (the session reads its `--item`), the launch island (the pod's LLM admits via `gateway-admit.sh` → gateway `POST /sessions`) | [specs/dispatch.md](specs/dispatch.md) |
| The GitHub grammar the scan family writes: lifecycle labels it reconciles, `merge-conflict`, `agent/arbitrate`, `agent/error`, `major/awaiting-human`, `state-fp:` and `agent-event` markers | the coordinator brief, the board, the review island, humans | [specs/github-grammar.md](specs/github-grammar.md) |
| PR currency (`update-branch`) and reviewer dispatch | GitHub auto-merge; the review island (`reviewer-session.sh <repo> <pr>`) | [specs/updater.md](specs/updater.md), [specs/review-reflex.md](specs/review-reflex.md) |
| `major-handoff.sh <slug> <pr>` exit codes 0/3/4/5 | the coordinator session (brief §Dependency major bumps step 5) | [specs/major-handoff.md](specs/major-handoff.md) |
| `agent_scan_phase_*`, `agent_dispatch_*`, `agent_item_class*` on the pushgateway | `AgentCoordinateScanWedged`, `AgentDispatchCronWoken`, `board.sh --machine` | [specs/signals.md](specs/signals.md) |

**Consumes:** the machine block parser `agents/issue_body.py` and the REST label transport
`agents/machine-comment.sh` (shared libraries, P3 of §The plan); the claim mirror
`agents/stacks.json`; the gateway island's `POST /sessions` **through the launch island's**
`agents/gateway-admit.sh` (platform stack only today — never `/route` in the redrawn contract;
today the other stacks' coordinator still resolves via `resolve-model.sh` → `/route`, and the scan
itself still probes `subscription-latch.sh --pick-rail`: ⚑ gaps on
[specs/dispatch.md](specs/dispatch.md)); `slo-teeth.sh` + `reviewer-optout.sh` (the review island's
knobs); `scripts/pin-only-lint.sh` / `scripts/governance-lint.sh` declarations (read, never
re-declared).

## Read set

A session working on this island loads, in order: this README → [specs/README.md](specs/README.md)
→ the one contract page its change touches (+ its schema) → the clause block(s) in
`coordinator-scan.sh` named by that page's requirement → the fixture dir(s) the requirement names
→ the brief clause the page cites. Only when the change crosses a consumer contract: the
consumer's page ([gateway/specs/endpoints/sessions.md](../../../gateway/specs/endpoints/sessions.md)
for admission; `agents/agent-session.sh`'s header for the launch). The design narrative of the
merge path, if the change is to the updater or the reflex:
[docs/merge-path-mechanism.md](docs/merge-path-mechanism.md). Never `docs/agents/` wholesale.

## Revert class

Pods clone `master` (the scan, the updater, the reflex and the coordinator pod all run from a
fresh homelab clone per run), so a bad change reverts with **a revert PR** — no image, no pin.
The Argo manifests sync through ArgoCD (`agent-coordinator` app) and revert the same way.
P4's detector + drill for this island are not built (⚑ on
[specs/signals.md](specs/signals.md)).

## Open

- **The spec root has no reader.** The claim's `specs` field admits one root pair per repo and
  homelab's names the gateway's ([§C8](../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01));
  these pages are reviewed by nobody until it becomes a list.
- **No evidence pipeline.** The replay harness asserts action streams, not Allure stories; every
  requirement is `🚧 WIP` until a `rule()`-labelled runner exists (P4/P5 of §The plan, #1224).
- **Self-routing still lives here** (9 sites in the scan per §Interfaces): `coordinator_rail`,
  `rail_model`, the goal-lane Go deferral, the reflex's tick gate, `/router-status` and
  `/report/latest` reads. Each is a ⚑ gap on its page; they leave with the gateway defer.
- **`coordinator-session.sh` is in neither §C8 row by name** — it is the scan's dispatch arm here;
  its LLM admission is the launch island's helper.
- **The footprint predicate is a seam, not scan code**: `footprint.sh` is read by the launcher,
  the reviewer, the responder, fix-debounce and `goal-lint.sh`.
- **A Python port of the updater exists as a pilot** under
  [pilot/updater/](pilot/updater/README.md): 43/43 against the replay family as oracle, one
  subprocess site, ~3× the bash in code lines, 12 bash findings, and the open fixture-shape
  question (sparse worlds vs full wire). Spike artifact for the ADR-113 revisit, not a member.
- **The per-stack scan's runtime manifest lives in the claim's Composition** (a mirror of
  `coordinate-argo.yaml`'s template), so a scan runtime change is a claim-island change too.
