# intake — island intake, in one directory (island)

**This directory is running code, not a contract for a fresh build.** Island intake
([docs/glossary.md](../../docs/glossary.md) "island intake") is the island-scoped admission
sitting: once a day it reads an island's unshaped inputs — the deep dig's findings, the issue
pile and its waits, spec gap rows, review escapes — and leaves each in exactly one loop-readable
state. Its files lived in three places (`gateway/`, `gateway/scripts/`, `agents/`) and its
launcher inline in a workflow manifest; Goal #3574 gives it one home. The location is
**provisional**, like its siblings ([islands/README.md](../README.md)). Tracker: FU-320; design
and evidence: [docs/spikes/island-intake.md](../../docs/spikes/island-intake.md).

| Path | What it is |
|---|---|
| [`rules/intake.md`](rules/intake.md) | the brief every sitting reads in full — outcomes, procedure, hard limits |
| [`rules/intake-escape.md`](rules/intake-escape.md), [`rules/intake-wait.md`](rules/intake-wait.md) | step E (the escape read) and step W (the wait read) of the brief |
| [`rules/intake-review-unit.md`](rules/intake-review-unit.md), [`rules/intake-review-rows.md`](rules/intake-review-rows.md) | the two lenses of the brief's §Review and repair, each its own session |
| [`scripts/intake-select.sh`](scripts/intake-select.sh) | the selector — the deterministic half; it also holds the island table (which island an issue, a path or a dig finding belongs to) and prints the islands the scheduled run walks (`--list-islands`) |
| [`scripts/sitting.sh`](scripts/sitting.sh) | the launcher script: select → admit → the author session → rulings → lenses and repair → the label belt → receipt → the `/coordinate` ring |
| [`scripts/intake-wait-ledger.py`](scripts/intake-wait-ledger.py), [`scripts/intake-wait-cases.py`](scripts/intake-wait-cases.py) | the wait read's tally (which rule line is at the bar) and the recorded wait cases' validator |
| `devbox.json`, `devbox.lock` | the two tools the pod image lacks — promtool, yq — which the manifest's bootstrap installs and runs the launcher with (`devbox run`); the pod image (the worker base image, agent-base) pre-bakes claude, git, curl, jq, gh, kubectl, s5cmd, python3, uv and devbox itself |
| [`tests/island-intake-test.sh`](tests/island-intake-test.sh), `tests/fixtures/` | the hermetic harness and its recorded inputs (real dig and responder findings, the wait cases) |

The per-island facts stay in [`docs/intake/`](../../docs/intake/) (ADR-160): one rules home here,
one facts file per island there.

## Schedule, and one island by hand

The CronWorkflow `island-intake` (ns `agent-coordinator`) runs daily at **05:00Z**, after the
03:30Z deep dig, and holds a sitting for **every island** `scripts/intake-select.sh --list-islands`
prints: each island that has a membership row in the selector's table and a facts file
`docs/intake/<island>.md`, in the table's order, the gateway first. A new island therefore needs
a selector row and a facts file, and no manifest edit; `commons` has no facts file and gets no
sitting.

- **One sitting at a time.** The workflow's `list-islands` step emits the list, then the
  `intake-retry` template runs once per name, one pod per island; `workflowSpec.parallelism: 1`
  keeps them in sequence and every sitting still takes the `subscription-capacity` semaphore.
- **A quiet island costs no session.** An empty selection prints
  `island-intake: <island> — no inputs`, pushes its metrics and exits 0.
- **Each island keeps its own records and caps**: receipts under
  `s3://agent-transcripts/homelab/intake-<island>-<day>/`, `island_intake_*` metrics with its own
  `island` label, `INTAKE_DAILY_MAX` apply sittings a day and ≤ 3 `queue` outcomes a sitting.
- **One island's failure does not stop the others**; the workflow ends Failed if any island did.
  `IslandIntakeStale` is per island: it fires for an island that ran before and has not for 2 days.
- **Deadlines**: one sitting has 4 h (the `intake` template, = the script's `RUN_DEADLINE_S`); the
  whole walk has 23 h. An island the walk does not reach is read by the next run.

Run one island by hand (the parameter `island` defaults to `all`):

```bash
argo -n agent-coordinator submit --from cronworkflow/island-intake -p island=scan
argo -n agent-coordinator submit --from cronworkflow/island-intake -p island=scan -p mode=dry-run   # writes nothing to GitHub
argo -n agent-coordinator submit --from cronworkflow/island-intake                                  # every island, now
```

## What this replaces

Nothing. It is the same code, moved (homelab#3575): no rule sentence, selector regex, outcome,
label or schedule changed with the move. Old homes → new: the five `intake*.md` briefs in
`gateway/` → `rules/`; the three `intake-*` scripts in `gateway/scripts/` → `scripts/`; the
harness and its fixtures directory in `agents/` → `tests/`; the `args:` script of the `intake` template in
[`agents/coordinator/island-intake-argo.yaml`](../../agents/coordinator/island-intake-argo.yaml)
→ `scripts/sitting.sh`. Records written before the move keep their old paths: the wait ledger
reads a rule key on the old rules path as the new one (`canon_file` in the ledger), and a recorded
wait case names the rules file at the commit it was recorded on.

## Consumer contracts

**Read or called by:**

| Consumer | What it uses |
|---|---|
| [`agents/coordinator/island-intake-argo.yaml`](../../agents/coordinator/island-intake-argo.yaml) (CronWorkflow `island-intake`, ns `agent-coordinator`, synced by the `agent-coordinator` ArgoCD app) | its `list-islands` step runs `scripts/intake-select.sh --list-islands` in a clone of homelab `master` (parameter `island=all`, the default) and the walk starts one pod per name; each pod's bootstrap clones homelab `master` to `/work/homelab`, installs this directory's devbox and runs `exec bash islands/intake/scripts/sitting.sh` inside it (`devbox run`), as ServiceAccount `island-intake` — read-only on the kube API ([`agents/coordinator/rbac.yaml`](../../agents/coordinator/rbac.yaml)). The script takes its inputs from the container's environment: `MODE`, `REVIEW` (the workflow's parameters) and `ISLAND` (the walk's item), all set as `env` in the manifest, the `INTAKE_*` knobs, the transcripts-bucket keys, `PUSHGATEWAY`. It holds no Argo template tag |
| [`agents/island_rules.py`](../../agents/island_rules.py) (the island rules digest) | evaluates the island table from `scripts/intake-select.sh` (the block between its `# ── the island table` and `# ── --source dig` markers), and finds the rule files by following the manifest's `exec bash …/sitting.sh` line |
| [`agents/deep-dig-test.sh`](../../agents/deep-dig-test.sh) (`devbox run deep-dig-test`) | runs `tests/island-intake-test.sh` — intake is the dig's consumer, so its harness rides the dig's gate |
| [`.claude/skills/intake/SKILL.md`](../../.claude/skills/intake/SKILL.md) (the seat's `/intake`) | `scripts/intake-select.sh --island <i> --json` and `rules/intake.md` as each sitting subagent's brief |
| the facts files [`docs/intake/*.md`](../../docs/intake/) | each names `rules/intake.md` as the one rules home it supplies §Island facts for |
| `IslandIntakeStale` ([`argocd/resources/pushgateway/prometheusrule.yaml`](../../argocd/resources/pushgateway/prometheusrule.yaml)) | `island_intake_last_run_timestamp_seconds` per `island` label, among the `island_intake_*` gauges `scripts/sitting.sh` pushes on every exit path (job `island_intake`, grouping label `island`); the manifest's bootstrap pushes the same series at 0 for its island when the clone or the devbox install fails |
| the next sitting | the receipts under `s3://agent-transcripts/homelab/intake-<island>-<day>/`, read back by the selector as the record of what was ruled |

**Consumes** (unchanged by the move, all read from the same clone): `agents/gateway-admit.sh`
(every session's admission), `agents/subscription-latch.sh`, `agents/resolve-model.sh` and
`agents/model_id.py` (the old path's rail and model), `agents/machine-comment.sh` (the label
write), `agents/issue_body.py` (the `Touches` parser), `agents/coordinator-scan.sh` (the
`blocked-on:` definition the selector copies), `gateway/scripts/lib/snippets.sh` (the pinned
snippets wheel for the rows lens), and each island's alert-rule file and specs index.

## Read set

A session changing this island loads, in order: this README → the file its change touches
(`rules/…` or `scripts/…`) → for a script change, the header of
[`agents/coordinator/island-intake-argo.yaml`](../../agents/coordinator/island-intake-argo.yaml)
(the machinery inventory: predicate, key, capacity, belts) and the harness section that covers
the changed step → for a rule change, [docs/spikes/island-intake.md](../../docs/spikes/island-intake.md)
at the run the rule cites. A facts question reads the one `docs/intake/<island>.md`. Never
`docs/agents/` wholesale.

## Revert class

Every sitting runs from a fresh clone of homelab `master`, so a change here is live at the next
run (daily 05:00Z, or a hand-submitted one — §Schedule above) and a revert PR on `master` reverts it the same way —
no image, no sync. The manifest's bootstrap syncs through ArgoCD (`agent-coordinator` app); a
revert PR reverts that too. A bootstrap and a script from different commits can only meet for the
length of one ArgoCD sync: the bootstrap's whole contract with the script is its path and the
container's environment.

Write tier (`classify_touches`, run 2026-11-20): `islands/intake/**` = `machine-merge`. Before the
move the launcher script (inside `agents/coordinator/island-intake-argo.yaml`) and the harness
(`agents/`) were `codeowner-merge`; the rules and the selector (`gateway/`) were `machine-merge`
already.
