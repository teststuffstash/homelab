# Islands — agent-loop components to be built fresh

**Each directory here is the starting contract of a component to be built new, beside the old
code it replaces** — the way [`gateway/`](../gateway/README.md) replaced the old router. A README
(what it replaces, consumer contracts, read set, revert class) and a `specs/` root in the
[allure-behavior-snippets v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)
shape; no code yet. **The `islands/` location is provisional** — the final home is the operator's
call. It sits outside `agents/` on purpose: the rules that bind that tree stay on the old code while
old and new run side by side. **Nothing in the running loop reads or calls anything under
`islands/`**; the old members each README names are live and authoritative until a separate
switch-over change (a `seat` decision per island).

The pages were carved from the spike PR #3147 (`agents/islands/`, 2026-11-07/08), which rendered
what that branch's [`context-and-autonomy.md`](../docs/spikes/context-and-autonomy.md) (its C8
section — not on master) measured as separable pieces of the agent loop. They are written against the REDRAWN contracts
(§Interfaces — gateway `POST /sessions`, ADR-122's one machine block); every old-contract site is a
`⚑ gap` row, every unbuilt one `🚧 WIP`. What an island is: [docs/glossary.md](../docs/glossary.md)
("island"). Intake facts per island: [`docs/intake/`](../docs/intake/) — not yet rows in
`gateway/scripts/intake-select.sh` (a separate change).

| Island | Prefix | Specs | Intake facts | What it will own |
|---|---|---|---|---|
| [scan](scan/README.md) | `SCAN-` | [specs/](scan/specs/README.md) | [scan.md](../docs/intake/scan.md) | the coordinator scan's decision + dispatch, the GitHub grammar, the updater, the review reflex, the major handoff, liveness signals |
| [launch](launch/README.md) | `LAUNCH-` | [specs/](launch/specs/README.md) | [launch.md](../docs/intake/launch.md) | the ride: dispatch params × recipe × claim → gateway admission → context bundle → pod env → outcome |
| [retro](retro/README.md) | `RETRO-` | [specs/](retro/specs/README.md) | [retro.md](../docs/intake/retro.md) | the weekly retro series: guard, pipeline, activity, cells, harvest, findings |

Not started: `review` (the code and specs reviewers, the IAC-G04 sentinel) and `intake` (island
intake, the deep dig, the responder) — the spike drafted both; they wait.

## What every island shares (and what is not built)

- **No evidence.** The replay harness (`agents/replay/`) is the oracle — most rows name the fixture
  dir that would prove them — but replay emits no `rule()` labels and no Allure stories, so every
  requirement is `🚧 WIP — no evidence pipeline yet`. A tests root with rule-labelled tests driven
  by those fixtures is each island's first deliverable.
- **A rows review, no evidence.** homelab's claim lists each island's `specs/` under `extraSpecs`
  (#3379): a PR touching `islands/<island>/specs` gets the specs reviewer's rows review over that
  root, and a worker whose `Touches:` reaches it gets the pinned spec process mounted, versioned by
  that root's `README.md`. No tests root is declared and the pack carries no evidence, so an
  unproven row needs its `🚧 WIP → #<issue>` or `⚑ gap` mark.
- **No spec gate / join ratchet** over these roots (`gateway/scripts/spec_gate.py` resolves its
  root from its own location — `gateway/specs` only).
- **Write tier:** `classify_touches islands/…` = `machine-merge` (verified 2026-11-14).
