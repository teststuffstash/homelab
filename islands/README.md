# Islands — agent-loop components to be built fresh

**Each directory here is the starting contract of a component to be built new, beside the old
code it replaces** — the way [`gateway/`](../gateway/README.md) replaced the old router. A README
(what it replaces, consumer contracts, read set, revert class) and a `specs/` root in the
[allure-behavior-snippets v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)
shape. **The `islands/` location is provisional** — the final home is the operator's
call. It sits outside `agents/` on purpose: the rules that bind that tree stay on the old code while
old and new run side by side. **Nothing in the running loop reads or calls anything under
`islands/`** — except [`intake/`](intake/README.md), which is running code moved here, not a fresh
build; the old members each README names are live and authoritative until a separate
switch-over change (a `seat` decision per island).

The pages were carved from the spike PR #3147 (`agents/islands/`, 2026-11-07/08), which rendered
what that branch's [`context-and-autonomy.md`](../docs/spikes/context-and-autonomy.md) (its C8
section — not on master) measured as separable pieces of the agent loop. They are written against the REDRAWN contracts
(§Interfaces — gateway `POST /sessions`, ADR-122's one machine block); every old-contract site is a
`⚑ gap` row, every unbuilt one `🚧 WIP`. What an island is: [docs/glossary.md](../docs/glossary.md)
("island"). Intake facts per island: [`docs/intake/`](../docs/intake/) — each a row in
`islands/intake/scripts/intake-select.sh`. A stack that wants island intake on its own repo reads
[`intake/CONTRACT.md`](intake/CONTRACT.md).

| Island | Prefix | Specs | Intake facts | What it will own |
|---|---|---|---|---|
| [scan](scan/README.md) | `SCAN-` | [specs/](scan/specs/README.md) | [scan.md](../docs/intake/scan.md) | the coordinator scan's decision + dispatch, the GitHub grammar, the updater, the review reflex, the major handoff, liveness signals |
| [launch](launch/README.md) | `LAUNCH-` | [specs/](launch/specs/README.md) | [launch.md](../docs/intake/launch.md) | the ride: dispatch params × recipe × claim → gateway admission → context bundle → pod env → outcome |
| [retro](retro/README.md) | `RETRO-` | [specs/](retro/specs/README.md) | [retro.md](../docs/intake/retro.md) | the weekly retro series: guard, pipeline, activity, cells, harvest, findings |
| [intake](intake/README.md) | `INTAKE-` | [specs/](intake/specs/README.md) — one page, `access` (not under `extraSpecs` yet) | — (its items ride the gateway's sitting) | island intake as it runs today, moved into one directory (#3575): the rules, the selector, the launcher script, the tests; its spec root holds what the sitting's identity must and must not be able to do |

Not started: `review` (the code and specs reviewers, the IAC-G04 sentinel) and a fresh build of
`intake` (island intake, the deep dig, the responder) — the spike drafted both; they wait. The
[`intake/`](intake/README.md) row above is the running island intake in one place, not that build.

## What every island shares (and what is not built)

- **Evidence starts empty.** Replay (`agents/replay/`) emits no `rule()` labels and no Allure
  stories, so a requirement is `🚧 WIP — no evidence pipeline yet` until the island's own tests
  root proves it. That tests root is each island's first deliverable, built under the four rules
  below.
- **A rows review, no evidence.** homelab's claim lists each island's `specs/` under `extraSpecs`
  (#3379): a PR touching `islands/<island>/specs` gets the specs reviewer's rows review over that
  root, and a worker whose `Touches:` reaches it gets the pinned spec process mounted, versioned by
  that root's `README.md`. No tests root is declared and the pack carries no evidence, so an
  unproven row needs its `🚧 WIP → #<issue>` or `⚑ gap` mark.
- **A browsable site, for an island that opts in.** [`scripts/specs-site.sh`](scripts/specs-site.sh)
  renders an island's README + `specs/` the way the gateway's site does — each rule's tables joined
  to the island's own suite run, linking into that run's Allure report — and publishes it to
  `https://<island>-specs.homelab.teststuff.net` (LAN/VPN; PR previews at `/pr-<N>/`). Opting in is
  a `mkdocs.yml` beside `specs/`, a bucket and a route; scan is the first
  ([scan-specs.homelab.teststuff.net](https://scan-specs.homelab.teststuff.net)). The site is for
  readers: the specs reviewer's pack still carries no evidence for these roots.
- **No spec gate / join ratchet** over these roots (`gateway/scripts/spec_gate.py` resolves its
  root from its own location — `gateway/specs` only).
- **Write tier:** `classify_touches islands/…` = `machine-merge` (verified 2026-11-14).

## Built from the specs, never copied

An island is a rebuild, not a port. Four rules bind every item on every island:

1. **The page's rows are the test source.** One `rule()`-labelled case per requirement row, its
   inputs and expected cells taken from the page. A component's interface comes from the page's
   inputs and its schema — never from an old member's shell variables, function names or block
   layout. A new file that reproduces an old member's text is a blocking finding.
2. **Worlds are recorded whole.** A world holds the full answer of the surface it stands for
   (GitHub, the gateway, Prometheus), recorded from the live surface with credentials removed —
   from public repos only. The reader parses it strictly: a missing field is an error, never a
   default. The page renders only the fields a row reads. A hand-written supplier answer validates
   against the supplier's schema. Where no recording exists the row is `⚑ gap`, and the recorder
   or the world is the item that comes before the component.
3. **New components are Python** (ADR-113: logic is Python), with their own test hooks.
4. **Replay is a comparison, not the gate.** The replay families a page names
   (`agents/replay/fixtures/**`, read-only) run against the old member and the new component;
   every difference gets a ruling in the PR — `spec` (the page is wrong: fix the page), `old` (the
   old member is wrong: the page says so) or `new` (the component is wrong: fix it). An unruled
   difference blocks; equality with the old member is not required and is not the acceptance.

The old members are read to explain a difference, never as the source of a component.
