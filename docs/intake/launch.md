# Island facts — the launch island (fresh build)

> The §Island facts block for the **launch** island — a component to be BUILT FRESH under
> [`islands/launch/`](../../islands/launch/README.md) beside the old code it replaces; nothing live
> reads that directory. The rules are ONE home — [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md); this
> file holds only the island's facts, under `## Sources` the island's own rows of its §What you read
> table, and under `## What a ride can do` the recipe, write tier, gates and reach. Island index:
> [`islands/README.md`](../../islands/README.md).

Body shape: spec

- **Repo** `teststuffstash/homelab`; island root `islands/launch/` (provisional location — the
  operator picks the final home); specs `islands/launch/specs/` (`LAUNCH-` ids, contract pages +
  sibling `*.schema.json`, worlds under `specs/worlds/`, the spine use case under
  `specs/use-cases/`). A tests root (`tests/`), its suite (`scripts/ci.sh`) and a first library file (`lib/`) exist; no deploy surface exists — what is there today is the third row of `## Sources` below.
- **Membership** — every `Touches` entry under `islands/launch/`, or a title starting
  `launch island:`. An item on the OLD launcher (`agent-session.sh`) — its `Touches` under
  `agents/` — is the agent-loop island's ([agent-loop.md](agent-loop.md)), not this one.
- **Selectable**: `islands/intake/scripts/intake-select.sh` has the row — `--island launch` selects on the
  title and the `islands/launch/` prefix, ahead of agent-loop in precedence.
- **Read set** = [`islands/launch/README.md`](../../islands/launch/README.md) +
  [`islands/launch/specs/README.md`](../../islands/launch/specs/README.md) + the page an item names
  (+ its schema). The old member the item replaces (`agents/agent-session.sh`, `gateway-admit.sh`, `pr-open.sh`, `recipe-lint.sh`, `estimate_budget.py`, `model_id.py`) may be read to explain a
  difference the comparison shows — never as the source of a component, and never edited. Never `docs/agents/` as a corpus (the design-agents read is operator-typed
  only; [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Design questions) — a design
  doc a page links on first use is read at that section only. A fact outside this set that the
  decision stands on is read with the narrowest GET (intake.md §What you read); any other goes
  under `Unverified`, never a wider read.
- **Built from the specs, never copied** — the four rules are [islands/README.md §Built from the specs](../../islands/README.md#built-from-the-specs-never-copied):
  the page's rows are the test source, worlds are recorded whole, new components are Python, and
  replay is a comparison. A `queue`/`goal` body that asks a worker to match, port or carry over an
  old member is not queue-ready.
- **The comparison** = the replay families the island's specs name per requirement
  (`gateway-*`, `context-prefetch*`, `env-card-*`, `base-arm-*`, `major-arm-guard-*`, `goal-budget-*`, `harness-*`, `strike-*`, `argv-*`, `specs-process`, `image-volumes`, `run-phase-metric`, …) — `agents/replay/fixtures/**`, **read-only**: each is run against the old member
  and the new component, and every difference gets a ruling (`spec` / `old` / `new`); equality is not
  required and is not the acceptance. A build item never edits a fixture (an existing
  assertion changed is a red flag, `agents/jail-subagent-card.md`). The supplier contract is the gateway's ([`gateway/specs/endpoints/sessions.md`](../../gateway/specs/endpoints/sessions.md)) — consumed, never re-declared; `agents/ground-rules.md` and the `.agents/` recipes are read in place.
- **Evidence first**: no requirement is proven. Of the 31 in the spec index
  ([`islands/launch/specs/README.md`](../../islands/launch/specs/README.md)), 29 carry `🚧 WIP` on
  their page's Status cell — 26 as `no evidence pipeline yet`, 3 as `→ #3390` / `→ #3408` with rows
  that pass locally and nothing published — and 2 (`LAUNCH-ADMIT-NO-MODEL`, `LAUNCH-BUDGET-CR`)
  carry `⚑ gap` alone (counted 2026-11-20). The first
  deliverable is a tests root under `islands/launch/` whose `rule("LAUNCH-…")`-labelled tests take
  their cases from the page's rows over recorded worlds; a component row is queue-ready only once the evidence it would turn green
  can exist. Rows are COPIED from the page into the issue (`## Spec changes`), never re-authored.
- **Gate / deploy**: CI + the code reviewer, then the specs reviewer: homelab's claim lists
  `islands/launch/specs` under `extraSpecs` (#3379), so a PR touching it gets a rows review over
  this root. No tests root is declared and no evidence exists, so the review sees none: an
  unproven row needs its `🚧 WIP → #<issue>` or `⚑ gap` mark. `gateway/scripts/spec_gate.py`
  reads `gateway/specs` only (no spec gate or join ratchet here). A worker whose `Touches:`
  reaches this root gets the pinned spec process mounted, versioned by `islands/launch/specs/README.md`. **Nothing deploys**: no pod, manifest or image reads `islands/`.
- **Switch-over is `seat`**, never `queue`/`goal`: making any live caller (a scan, a workflow, a
  launcher, a Sensor) read or call the new component — or retiring an old member — is a separate
  change the seat designs against the old component's slice.
- **Operator-only**: the island's final location; the switch-over decision; Goal admission
  (breaker #1); credential/App-permission changes; model/rail rulings; anything `.agents/**`,
  `.github/**`, `tofu/github/**` or CODEOWNERS.

## Sources

| question | read | note |
|---|---|---|
| What a requirement says, and its mark (`🚧 WIP → #<issue>`, `⚑ gap`) | [`islands/launch/specs/README.md`](../../islands/launch/specs/README.md) §Index, then the page it links at the requirement's heading (+ its sibling `*.schema.json`) | rows are copied from the page, never re-authored |
| Which worlds are recorded | `ls islands/launch/specs/worlds/` and [`worlds/README.md`](../../islands/launch/specs/worlds/README.md) | a row names its world; a world nobody recorded is recorder work, never a hand-written one |
| What exists of the island's code and tests | `ls islands/launch/ islands/launch/tests/` and [`islands/launch/README.md`](../../islands/launch/README.md) §Open; the suite is `islands/launch/scripts/ci.sh` | a component row is queue-ready only once the evidence it would turn green can exist |
| What the old member does on the same case | the replay family the requirement's index row names: `bash agents/replay/run.sh agents/replay/fixtures/<family>` (families: [`agents/replay/families.tsv`](../../agents/replay/families.tsv)) | read-only; the old member is `agents/agent-session.sh` and the members the README lists |
| The island's limits, their live values, its alert rules, a capacity or grants ledger | none of its own — nothing under `islands/launch/` is deployed, read or scheduled. The old member's are the agent loop's: [agent-loop.md §Sources](agent-loop.md#sources) | an item that turns on a live value is about the old member, and is the agent-loop island's |

Never: `docs/agents/` as a corpus; an edit under `agents/**`.

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
  A `Touches` reaching `islands/launch/specs` gets the pinned spec process mounted (the claim's
  `extraSpecs`).
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  `islands/launch/**` and `docs/intake/**` = `machine-merge`. Anything under `agents/**` is
  `codeowner-merge` and **out of this island's scope** — the old members are never edited from
  an island item.
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  `islands/launch/**` selects the island's own suite (`islands/launch/scripts/ci.sh`, in the island's
  devbox), `py-compile-lint`, `docs-graph-lint` and `mermaid-lint`. Then CI, the code reviewer
  and the specs reviewer's rows review.
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  The island's `uv.lock` installs through `profile: python`; a `Touches` under `islands/launch/` is
  not a docker ride.
- **Not reachable, so intake reads it and writes it into the body**: anything live outside
  namespace `homelab`. A ride on this island works from the pages, the recorded worlds and the
  replay fixtures in its checkout; a cluster object or a wire answer the item needs is read by
  intake, or recording it is the item's own work.
