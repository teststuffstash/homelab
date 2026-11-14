# Island facts — the scan island (fresh build)

> The §Island facts block for the **scan** island — a component to be BUILT FRESH under
> [`islands/scan/`](../../islands/scan/README.md) beside the old code it replaces; nothing live
> reads that directory. The rules are ONE home — [`gateway/intake.md`](../../gateway/intake.md); this
> file replaces only its §Island facts and the island rows of its §What you read table. Island index:
> [`islands/README.md`](../../islands/README.md).

- **Repo** `teststuffstash/homelab`; island root `islands/scan/` (provisional location — the
  operator picks the final home); specs `islands/scan/specs/` (`SCAN-` ids, contract pages +
  sibling `*.schema.json`, worlds under `specs/worlds/`, the spine use case under
  `specs/use-cases/`). No code, tests root or deploy surface exists yet — creating them is the work.
- **Membership** — every `Touches` entry under `islands/scan/`, or a title starting
  `scan island:`. An item on the OLD scan (`coordinator-scan.sh`) — its `Touches` under
  `agents/` — is the agent-loop island's ([agent-loop.md](agent-loop.md)), not this one.
- **Not yet selectable**: `gateway/scripts/intake-select.sh` has no row for this island on master
  (2026-11-14) — `--island scan` exits 2, a Touches-only item under `islands/` lands in `none` (or
  agent-loop attribution), and agent-loop's title ERE `^(scan|…)\b` also matches `scan island:`.
  Until the selector rows land (a separate change), a sitting on this island is the seat's, run with
  this file by hand.
- **Read set** = [`islands/scan/README.md`](../../islands/scan/README.md) +
  [`islands/scan/specs/README.md`](../../islands/scan/specs/README.md) + the page an item names
  (+ its schema). The old member the item replaces (`agents/coordinator-scan.sh`, `coordinator-session.sh`, `update-pr-branch.sh`, `review-reflex.sh`, `major-handoff.sh`, … — the list in the README) may be read as **the behaviour to
  match**, never edited. Never `docs/agents/` as a corpus (the design-agents read is operator-typed
  only; [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Design questions) — a design
  doc a page links on first use is read at that section only. A fact outside this set is a `seat`
  finding, not a wider read.
- **Write tier** (`classify_touches`, run 2026-11-14): `islands/**` = `machine-merge`;
  `docs/intake/**` = `machine-merge`. Anything under `agents/**` is `codeowner-merge` and **out of
  this island's scope** — the old members are never edited from an island item.
- **The oracle for correctness** = the replay families the island's specs name per requirement
  (`clause-coverage`, `queued-*`, `scan-*`, `c4c5-*`, `ci-red-*`, `changes-requested*`, `merge-conflict`, `arbitrate`, `fleet-*`, `goal*`, `doorbell`, `dispatch-phase`, `session-*`, `coordinator-*`, `updater`, `review-pick`, `reflex-*`, `c9-rearm`, `major-handoff`, `item-class*`, `scan-phase-marker`, `scan-wedge-alert`, `state-fp`, …) — `agents/replay/fixtures/**`, **read-only**: the new build's tests drive those
  worlds and match their expected streams; a build item never edits a fixture (an existing
  assertion changed is a red flag, `agents/jail-subagent-card.md`). The brief clauses the pages cite (`agents/coordinator/README.md`) stay the decision text.
- **Evidence first**: every requirement is `🚧 WIP — no evidence pipeline yet`. The first
  deliverable is a tests root under `islands/scan/` whose `rule("SCAN-…")`-labelled tests run
  the named fixtures; a component row is queue-ready only once the evidence it would turn green
  can exist. Rows are COPIED from the page into the issue (`## Key rows`), never re-authored.
- **Gate / deploy**: CI + the code reviewer, then the specs reviewer: homelab's claim lists
  `islands/scan/specs` under `extraSpecs` (#3379), so a PR touching it gets a rows review over
  this root. No tests root is declared and no evidence exists, so the review sees none: an
  unproven row needs its `🚧 WIP → #<issue>` or `⚑ gap` mark. `gateway/scripts/spec_gate.py`
  reads `gateway/specs` only (no spec gate or join ratchet here). A worker whose `Touches:`
  reaches this root gets the pinned spec process mounted, versioned by `islands/scan/specs/README.md`. **Nothing deploys**: no pod, manifest or image reads `islands/`.
- **Switch-over is `seat`**, never `queue`/`goal`: making any live caller (a scan, a workflow, a
  launcher, a Sensor) read or call the new component — or retiring an old member — is a separate
  change the seat designs against the old component's slice.
- **Operator-only**: the island's final location; the switch-over decision; Goal admission
  (breaker #1); credential/App-permission changes; model/rail rulings; anything `.agents/**`,
  `.github/**`, `tofu/github/**` or CODEOWNERS.
