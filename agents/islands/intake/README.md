# The intake island — what reaches the loop, and in which state

The agent loop's front end: the three machines that turn something nobody has read yet into a
state the loop already understands. The **responder** triages an acute (`triage: now`) alert
within minutes and leaves at most one inert issue carrying a `fix-verdict:`; the **deep dig**
investigates the `triage: dig` alerts that stood or recurred, once a day, grouped, and leaves a
`dig-finding/v1` record per group in the transcripts bucket; **island intake** reads an island's
unruled issues and the dig's `cause-found` findings and leaves each in exactly one loop-readable
state — queued with key rows written into the body, a Goal tree, closed with evidence, `standing`,
or `blocked-on: human` naming the one missing fact. Nothing in this island dispatches a ride: it
writes issues, labels, comments and bucket records, and the scan reads them
([context-and-autonomy.md §C8](../../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01)
row "dig + intake + responder" — 25 commits, 28 % cross, the least-coupled piece of the loop).
Terms: [specs/glossary.md](specs/glossary.md), platform terms in
[docs/glossary.md](../../../docs/glossary.md).

## Membership

Code stays where it is; this list is the island. ⚠ marks a file a pod or script reads at
runtime — it never moves, the spec cites it.

| Part | Files |
|---|---|
| island intake — the rules | ⚠ [`gateway/intake.md`](../../../gateway/intake.md) (the sitting's brief, read IN FULL by every sitting and by the CronWorkflow's prompt) · ⚠ [`docs/intake/*.md`](../../../docs/intake/) (per-island facts: [agent-loop](../../../docs/intake/agent-loop.md), [substrate](../../../docs/intake/substrate.md), [dependency-upgrades](../../../docs/intake/dependency-upgrades.md), [mgmt-box](../../../docs/intake/mgmt-box.md), [router-pair](../../../docs/intake/router-pair.md)) |
| island intake — the selector | ⚠ [`gateway/scripts/intake-select.sh`](../../../gateway/scripts/intake-select.sh) (`island_members` / `island_pattern` = the island table every island's sitting is selected by) |
| island intake — the wired run | [`agents/coordinator/island-intake-argo.yaml`](../../coordinator/island-intake-argo.yaml) (CronWorkflow `island-intake`, daily 05:00Z, dig source) · [`agents/island-intake-test.sh`](../../island-intake-test.sh) (run by `devbox run deep-dig-test`) |
| deep dig | [`agents/deep-dig-select.sh`](../../deep-dig-select.sh) (`select` · `group-keys` · `harvest`) · [`agents/deep-dig-test.sh`](../../deep-dig-test.sh) · [`agents/coordinator/deep-dig-argo.yaml`](../../coordinator/deep-dig-argo.yaml) (CronWorkflow `deep-dig`, daily 03:30Z) |
| responder | [`agents/coordinator/responder-argo.yaml`](../../coordinator/responder-argo.yaml) (Sensor `responder` + WorkflowTemplate `respond`; 13 `>>>REPLAY:` blocks) · [`agents/responder-budget.sh`](../../responder-budget.sh) · [`agents/coordinator/responder-budget-alerts.yaml`](../../coordinator/responder-budget-alerts.yaml) · [`agents/coordinator/responder-budget-dashboard.yaml`](../../coordinator/responder-budget-dashboard.yaml) · [`agents/coordinator/responder-behaviour-test.sh`](../../coordinator/responder-behaviour-test.sh) (`devbox run responder-behaviour-test`, a required `ci` step) |
| responder replays | [`agents/responder-graduation-replay.sh`](../../responder-graduation-replay.sh) · [`agents/responder-remediation-would-replay.sh`](../../responder-remediation-would-replay.sh) · [`agents/responder-touches-classify-replay.sh`](../../responder-touches-classify-replay.sh) |
| replay fixtures | `agents/replay/fixtures/responder-{behaviour,capture,cause-line,decided-once,engagement,graduation,reopen,remediation-would,seat-window,selfref,subject,touches-classify}/` — 12 families, 48 fixtures; the island's evidence today (the harness is the shared one, [`agents/replay/README.md`](../../replay/README.md)) |
| belts (rows in shared files) | `DeepDigStale`, `IslandIntakeStale` in `argocd/resources/pushgateway/prometheusrule.yaml`; `ResponderTriageBudgetExhausted` in `responder-budget-alerts.yaml` |
| owned docs | [`docs/remediation-would-scoreboard.md`](docs/remediation-would-scoreboard.md) (moved here from `docs/agents/`) |

**Not members, though named near them:** `agents/research-fanout.sh` and
`docs/agents/research-and-specs.md` are the research-mission lane (FU-126; a fan-out of worker
rides over `POST /route`), not the dig — they belong with launch. `agents/coordinator/fix-debounce-argo.yaml`
is the queue half of the responder's fix-verdict path (the responder rings it; it applies
`agent/queued`) — a membership question for the primary (§Open). `agents/seat-window.sh` writes the
`responder-window` ConfigMap both lanes read; it is the seat's tool (and the management box reads
the same ConfigMap), so it is consumed here, not owned.

## Consumer contracts

**Exposes** — each a contract page under [specs/](specs/README.md):

| To | What | Page |
|---|---|---|
| every island's sitting (seat-run `/intake`, the CronWorkflow) | the island table and the candidate list; the dig source's selection document | [intake-select](specs/intake-select.md) |
| scan (reads intake's states), launch (rides `queue`d items), the board / operator digest (reads `seat` rulings) | the ruling written to GitHub — the `intake:` comment, the labels per outcome, the queue-ready body with its key rows | [intake-ruling](specs/intake-ruling.md) |
| the next sitting, the seat | the receipt that says which inputs were ruled; the `island_intake_*` gauges; one `/coordinate` ring | [intake-receipt](specs/intake-receipt.md) |
| the responder (`group-keys`), the dig session | the digest — candidates, the explained set, groups | [dig-digest](specs/dig-digest.md) |
| island intake (`--source dig`), the seat, the next dig | the `dig-finding/v1` record per group | [dig-finding](specs/dig-finding.md) |
| the responder's own gates | the budget latch, decided-once, the subject, the declared window, the self-referential gate | [responder-gates](specs/responder-gates.md) |
| fix-debounce (queues), the scan (reads `fix-verdict`/`Touches` through the parser), `/board-sweep` (scores) | the alert issue's grammar, the fix-verdict path, the resolve leg, `responder-finding/v1` | [responder-verdict](specs/responder-verdict.md) |

**Consumes:** the gateway island's [`POST /sessions`](../../../gateway/specs/endpoints/sessions.md)
(through `agents/gateway-admit.sh` `gw_admit_lane` — every LLM session of the island is admitted
there; the old self-routing fallback is a `⚑ gap`,
[INTAKE-LANE-ADMISSION](specs/intake-receipt.md#intake-lane-admission)); the shared body parser
`agents/issue_body.py` and `agents/footprint.sh` `classify_touches` (P3's shared libraries — read,
never re-derived); the claim island's AgentStack claims + `agents/stacks.json` (the responder's
route) and its Composition's `spec.responder` render (the graduation dial); Alertmanager,
Prometheus, Loki and the triage relabel map
(`argocd/platform/values/kube-prometheus-stack-triage.yaml`); the seat's `responder-window`
ConfigMap, `dig-explained:` lines in `docs/agents/meta-state.md` and the open items of
`docs/follow-ups.md` (read-only — the dig's explanation ledger); the agent-transcripts bucket
(write key everywhere, reader key in the dig and the intake run).

## Read set

A session working on this island loads, in order: this README → [specs/README.md](specs/README.md)
→ the contract page(s) its change touches (+ that page's schema) → the clause it edits (the
`>>>REPLAY:` block, or the selector function) → for intake work, `gateway/intake.md` in full.
The owning prose for the responder and the deep dig is still
[`docs/agents/roles.md`](../../../docs/agents/roles.md) §responder and §deep dig (parent-owned —
§Open 1); read those two bullets, never the rest of `docs/agents/`. History, not read set:
[`docs/spikes/island-intake.md`](../../../docs/spikes/island-intake.md),
[`docs/spikes/responder-week-audit.md`](../../../docs/spikes/responder-week-audit.md).

## Revert class

All three lanes `git clone --depth 1 master` inside their pods and run the scripts from the
clone; the manifests are ArgoCD-synced from `agents/coordinator/`. A merge IS the deploy, and the
revert is a revert PR. The pods run the shared `agent-coordinator` image, pinned in
`agents/images.env` by the image-pin stream; this island pins nothing of its own. The detectors that would drive an automatic revert (P4(c)) are not built:
the belts say a lane stopped running (`DeepDigStale`, `IslandIntakeStale`) or stopped spending
(`ResponderTriageBudgetExhausted`), not that it did harm — `⚑ gap` on
[INTAKE-RUN-BELT](specs/intake-receipt.md#intake-run-belt).

## Open

1. The responder and deep-dig design prose lives in `docs/agents/roles.md` (two long bullets) and
   two rows + two bullets of `docs/agents/observability-and-retro.md` §A1; both files are shared.
   Moving them here is the parent's edit.
2. The intake rules and selector live under `gateway/` because the gateway was the first island
   to run a sitting; they are island-agnostic and runtime-read, so they stay put. A later move is
   a path change in four readers (the CronWorkflow prompt, the skill, every facts file, the
   alert annotation).
3. `fix-debounce-argo.yaml` — this island's (the second half of the fix-verdict path) or the
   scan's (it writes `agent/queued`, a scan-owned state)?
4. The intake-written key rows map one to one onto fixture dirs
   ([UC-1](specs/use-cases/uc-1-key-rows-to-fixtures.md)), but nothing checks it: no reader joins a
   `## Key rows` table to the fixture dirs the closing PR shipped.
5. `gateway/scripts/intake-select.sh`'s header names `gateway/scripts/intake-select-test.sh`; no
   such file exists — the selector's harness is `agents/island-intake-test.sh`.
