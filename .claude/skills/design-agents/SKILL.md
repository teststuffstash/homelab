---
name: design-agents
description: >
  Full-corpus design mode for the AGENT PLATFORM — the /design variant for anything under
  docs/agents/ or agents/. Reads the ENTIRE agents corpus upfront (no per-file selection, no
  per-file grounding list), because the subsystem is tightly coupled enough that any major change
  needs full context anyway (operator ruling 2026-08-10). Use on "/design-agents <question>",
  "design agents ...", or any /design-shaped question whose topic is the agent platform
  (coordinator, reviewer, fixer, scan, replay, goal lane, model routing, retro, responder, …).
---

# design-agents — read the whole damn thing first

> **Glance first**: [`../GAPS.md`](../GAPS.md) §design-agents — unpromoted sightings apply
> until closed (contract: [`../README.md`](../README.md)).

The sibling of [`../design/SKILL.md`](../design/SKILL.md), specialized for the agent platform.
Why it exists (operator ruling, 2026-08-10): the agents subsystem is so tightly coupled that any
major change requires the full context anyway — selective closure kept under-reading (the FSM
`replay:` fields, `model-routing.md` §M1a: both misses were claims about files not read), and the
per-file grounding list had grown into an audit burden the operator had to verify by memory.
Fixed cost beats itemized honesty here: ~145k tokens, pre-authorized, paid ONCE per session
(prompt caching amortizes every follow-up question).

## The read plan

1. **Base layer, in full**: `CONTEXT.md` + `ARCHITECTURE.md` (skip if already read this session).
2. **The agents corpus, in full, FIRST — one pass, before forming any opinion**:
   - `docs/agents/*.md` and `docs/agents/*.yaml` — every file, including the FSM YAML sources
     (the `replay:`/gap fields live there, not in the generated views)
   - `agents/README.md` (launcher) + `agents/replay/README.md` (harness) +
     `agents/coordinator/README.md` (the brief — 19k tokens and load-bearing; a docs/agents glob
     misses it)
   - **EXCLUDED: `docs/agents/retros/`** — sediment, grep-only, "history is read when history is
     the subject" (the base skill's layer 4 stands unchanged).
3. **Glossary** — [`docs/glossary.md`](../../../docs/glossary.md) rules this corpus's vocabulary
   (Goal/mission, canary vs contract probe, the platform stack) — consult before coining or
   interpreting a term.
4. **Tracker layer** — as in the base skill: grep `docs/follow-ups.md` + archive + `docs/adr.md`
   + `docs/spikes/` by topic keywords, read matches in full.
5. **Outside homelab** — NOT auto-read: `../teststuff` docs, circles/oracle-fleet and other stack
   repos are in scope but operator-pointed (@-mention or named in the question). Say when the
   question leans on one that wasn't provided.

## The output contract (the delta from the base skill)

- **The grounding statement names ONLY what lies outside the corpus**: cross-repo reads, tracker
  items, live probes (`ci.yaml`, cluster state, fixture listings), and anything operator-supplied.
  The corpus itself is one standing line — "full agents corpus" — never an enumeration; the
  operator should not have to diff a file list against their memory of the subtree.
- Everything else is inherited: state the negative on tracker greps, "no owning doc covers X" is
  a finding, assessments until the operator says land it.
