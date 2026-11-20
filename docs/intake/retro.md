# Island facts — the retro island (fresh build)

> The §Island facts block for the **retro** island — a component to be BUILT FRESH under
> [`islands/retro/`](../../islands/retro/README.md) beside the old code it replaces; nothing live
> reads that directory. The rules are ONE home — [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md); this
> file replaces only its §Island facts and the island rows of its §What you read table. Island index:
> [`islands/README.md`](../../islands/README.md).

Body shape: spec

- **Repo** `teststuffstash/homelab`; island root `islands/retro/` (provisional location — the
  operator picks the final home); specs `islands/retro/specs/` (`RETRO-` ids, contract pages +
  sibling `*.schema.json`, worlds under `specs/worlds/`, the spine use case under
  `specs/use-cases/`). No code, tests root or deploy surface exists yet — creating them is the work.
- **Membership** — every `Touches` entry under `islands/retro/`, or a title starting
  `retro island:`. An item on the OLD retro (`retro_*.py`, `retro-session.sh`) — its `Touches` under
  `agents/` — is the agent-loop island's ([agent-loop.md](agent-loop.md)), not this one.
- **Selectable**: `islands/intake/scripts/intake-select.sh` has the row — `--island retro` selects on the
  title and the `islands/retro/` prefix, ahead of agent-loop in precedence.
- **Read set** = [`islands/retro/README.md`](../../islands/retro/README.md) +
  [`islands/retro/specs/README.md`](../../islands/retro/specs/README.md) + the page an item names
  (+ its schema). The old member the item replaces (`agents/retro_activity.py`, `retro_pipeline.py`, `retro_findings.py`, `retro_queue.py`, `retro_guard_expr.py`, `retro-session.sh`, …) may be read to explain a
  difference the comparison shows — never as the source of a component, and never edited. Never `docs/agents/` as a corpus (the design-agents read is operator-typed
  only; [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Design questions) — a design
  doc a page links on first use is read at that section only. A fact outside this set that the
  decision stands on is read with the narrowest GET (intake.md §What you read); any other goes
  under `Unverified`, never a wider read.
- **Write tier** (`classify_touches`, run 2026-11-14): `islands/**` = `machine-merge`;
  `docs/intake/**` = `machine-merge`. Anything under `agents/**` is `codeowner-merge` and **out of
  this island's scope** — the old members are never edited from an island item.
- **Built from the specs, never copied** — the four rules are [islands/README.md §Built from the specs](../../islands/README.md#built-from-the-specs-never-copied):
  the page's rows are the test source, worlds are recorded whole, new components are Python, and
  replay is a comparison. A `queue`/`goal` body that asks a worker to match, port or carry over an
  old member is not queue-ready.
- **The comparison** = the replay families the island's specs name per requirement
  (`retro-quiet-guard`, `retro-gateway-cell`, `retro-key/*`, `retro-cell-report/*`, `retro-harvest`, `retro-harvest-push`, `retro-push-belt`, `retro-activity-window`) — `agents/replay/fixtures/**`, **read-only** — plus the in-process suites `agents/retro-{activity,pipeline,findings}-test.py` (standalone test scripts of the OLD members, not fixtures: they are part of the comparison, never edited from here): each is run against the old member
  and the new component, and every difference gets a ruling (`spec` / `old` / `new`); equality is not
  required and is not the acceptance. A build item never edits a fixture (an existing
  assertion changed is a red flag, `agents/jail-subagent-card.md`). The runtime-read templates `docs/agents/retros/{BRIEF,CROSS-REVIEW,SERIES-BRIEF}.md` stay in place; reports under `docs/agents/retros/` are historical.
- **Evidence first**: every requirement is `🚧 WIP — no evidence pipeline yet`. The first
  deliverable is a tests root under `islands/retro/` whose `rule("RETRO-…")`-labelled tests take
  their cases from the page's rows over recorded worlds; a component row is queue-ready only once the evidence it would turn green
  can exist. Rows are COPIED from the page into the issue (`## Spec changes`), never re-authored.
- **Gate / deploy**: CI + the code reviewer, then the specs reviewer: homelab's claim lists
  `islands/retro/specs` under `extraSpecs` (#3379), so a PR touching it gets a rows review over
  this root. No tests root is declared and no evidence exists, so the review sees none: an
  unproven row needs its `🚧 WIP → #<issue>` or `⚑ gap` mark. `gateway/scripts/spec_gate.py`
  reads `gateway/specs` only (no spec gate or join ratchet here). A worker whose `Touches:`
  reaches this root gets the pinned spec process mounted, versioned by `islands/retro/specs/README.md`. **Nothing deploys**: no pod, manifest or image reads `islands/`.
- **Switch-over is `seat`**, never `queue`/`goal`: making any live caller (a scan, a workflow, a
  launcher, a Sensor) read or call the new component — or retiring an old member — is a separate
  change the seat designs against the old component's slice.
- **Operator-only**: the island's final location; the switch-over decision; Goal admission
  (breaker #1); credential/App-permission changes; model/rail rulings; anything `.agents/**`,
  `.github/**`, `tofu/github/**` or CODEOWNERS.
