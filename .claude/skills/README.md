# Jail skills — index + the improvement contract (ADR-105)

The procedures this jail runs as `/<name>`. Each skill is doctrine distilled from paid lessons;
treat a skill edit like a doc edit (routing table, one home per fact).

| Skill | What it is |
|---|---|
| [design](design/SKILL.md) | Full-context mode for design questions (owning doc + link closure) |
| [design-agents](design-agents/SKILL.md) | `/design` for the agent platform — full-corpus read |
| [board-sweep](board-sweep/SKILL.md) | Sweep the live board: what the loop did, and what escalated unseen |
| [docs-cleanup](docs-cleanup/SKILL.md) | Fine-comb grooming: sync every doc with tracker truth |
| [fu-sweep](fu-sweep/SKILL.md) | Triage every open FU and act (pipeline: board-sweep → this → docs-cleanup) |
| [meta-coordinate](meta-coordinate/SKILL.md) | Resume the meta-coordinator role in a fresh session |
| [handoff](handoff/SKILL.md) | Process the stack-jail → mono-jail work queue |
| [onboard-metal-node](onboard-metal-node/SKILL.md) | PXE-onboard a bare-metal Talos worker |
| [opnsense-as-code](opnsense-as-code/SKILL.md) | Router changes as code (Unbound/HAProxy/ACME/BGP/DHCP) |
| [tofu-apply](tofu-apply/SKILL.md) | Run tofu correctly (secrets, `-chdir`, plan-first) |
| [skill-retro](skill-retro/SKILL.md) | Batched retro over jail transcripts → the GAPS ledger |

## Improvement contract

Skills improve from evidence on the FU tracker's mechanics — never from single-session
conviction (the contracts-emerge-from-patterns rule) and never by self-editing mid-flight:

- **A sighting** (an operator correction to skill-guided work, a step the session improvised,
  wrong-skill routing) becomes one FU-shaped entry in [`GAPS.md`](GAPS.md) — at latest during
  the session's consolidation step. [`skill-retro`](skill-retro/SKILL.md) is the belt: it mines
  finished transcripts for the sightings nobody filed.
- **Re-sighting extends** the matching entry with a date — never a duplicate line. An entry
  with **≥2 dates is a class**: propose promotion.
- **Promotion** moves the distilled rule INTO the skill with dated provenance ("operator catch
  YYYY-MM-DD") and closes the entry in the same commit. Doctrine changes are operator-gated;
  plain factual wrongness (the "was never true" class) is fixed directly, no entry needed.
- **≲5-minute factual fixes skip the ledger** — edit the skill, done.
- An entry that grows into real deferred WORK graduates to a proper `FU-NNN`
  (`docs/follow-ups.md` stays the only tracker); the entry becomes a pointer line.
- **Glance-step**: every skill opens by glancing at its GAPS section (an absent section = no sightings yet) — unpromoted sightings
  apply until closed.
- GAPS.md is in a PUBLIC repo — dialogue-level facts only, never tool output.

## Writer-side doc rules (for any context editing docs)

The routing table and its three rules ride `CLAUDE.md` (auto-loaded everywhere). What is NOT
auto-loaded: `docs/README.md` §Conventions (formats) and the docs-cleanup Hard rules
(historical records are read-only in content) — read both before non-trivial doc edits.
