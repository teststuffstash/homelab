# Agent-loop islands — the draft cut (spike, PR #3147)

**Status: a spike, not a decision.** These directories render what
[`context-and-autonomy.md` §C8](../../docs/spikes/context-and-autonomy.md#c8-the-agent-loop-island-re-measured-on-the-october-window-second-jail-2026-11-01)
measured as five separable pieces of the agent loop, each written up the way the
[gateway island](../../gateway/README.md) is: a README (membership, consumer contracts, read set,
revert class) and a `specs/` root in the
[allure-behavior-snippets v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)
shape. Code stays where it is; each README names its members. The specs are written against the
REDRAWN contracts (§Interfaces — gateway `POST /sessions`, ADR-122's one machine block); every
old-contract site is a `⚑ gap` row, every unbuilt one `🚧 WIP`.

| Island | Prefix | Specs | What it owns |
|---|---|---|---|
| [scan](scan/README.md) | `SCAN-` | [specs/](scan/specs/README.md) | the coordinator scan's decision + dispatch, the GitHub grammar, the updater, the review reflex, the major handoff, liveness signals |
| [launch](launch/README.md) | `LAUNCH-` | [specs/](launch/specs/README.md) | the ride: dispatch params × recipe × claim → gateway admission → context bundle → pod env → outcome |
| [review](review/README.md) | `REVIEW-` | [specs/](review/specs/README.md) | the code reviewer, the specs reviewer, lenses, the IAC-G04 sentinel, re-review |
| [intake](intake/README.md) | `INTAKE-` | [specs/](intake/specs/README.md) | island intake (select → ruling → receipt), the [deep dig](../../docs/glossary.md), the responder's gates + verdict |
| [retro](retro/README.md) | `RETRO-` | [specs/](retro/specs/README.md) | the weekly retro series: guard, pipeline, activity, cells, harvest, findings |

## What every island shares (and what this spike did not build)

- **No evidence.** The replay harness (`agents/replay/`) is the tests root candidate, and most rows
  name the fixture dir that would prove them — but replay emits no `rule()` labels and no Allure
  stories, so every requirement is `🚧 WIP — no evidence pipeline yet`. That harness change is the
  first deliverable that would make these pages real (§The plan P4/P5).
- **No gate.** The claim's `specs` field admits one `{root, tests}` pair per repo and homelab's names
  `gateway/specs`; a PR touching `agents/islands/*/specs` gets a mechanical specs-reviewer approval.
  The redrawn list contract is drafted in [review/specs/specs-gate.md](review/specs/specs-gate.md).
- **No spec gate / join ratchet** over these roots (`gateway/scripts/spec_gate.py` reads
  `gateway/specs` only).
