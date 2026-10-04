---
name: design-agents
description: >
  Full-corpus design mode for the AGENT PLATFORM (docs/agents/ + agents/): reads the ENTIRE
  agents corpus (~300–350k tokens) before answering. OPERATOR-TYPED ONLY — runs when the
  operator types "/design-agents <question>"; never self-invoke it, never pick it for a question
  that merely touches the agent platform (a hook denies model-initiated calls). If a task seems
  to need the corpus and the operator did not type it: stop and ask (full / a named slice / none).
---

# design-agents — read the whole damn thing first

> **Glance first**: [`../GAPS.md`](../GAPS.md) §design-agents — unpromoted sightings apply
> until closed (contract: [`../README.md`](../README.md)).

> **Operator-typed only (2026-09-27).** This skill loads when the operator types
> `/design-agents <question>` — the seat never self-invokes it (the harness denies a
> model-initiated `Skill(design-agents)` call via `.claude/hooks/design-agents-gate.sh`), and
> the workaround — reading `docs/agents/` wholesale without the skill — is equally off-limits.
> A question that turns out to need the corpus mid-session is a stop-and-ask, not a read: the
> operator decides between the full load, a named slice, or no corpus read. Rule home:
> `agents/jail-seat-card.md` §Design questions.

The sibling of [`../design/SKILL.md`](../design/SKILL.md), specialized for the agent platform.
Why it exists (operator ruling, 2026-08-10): the agents subsystem is so tightly coupled that any
major change requires the full context anyway — selective closure kept under-reading (the FSM
`replay:` fields, `model-routing.md` §M1a: both misses were claims about files not read), and the
per-file grounding list had grown into an audit burden the operator had to verify by memory.
Fixed cost beats itemized honesty here: **~300–350k tokens measured** (the measurement and its
history: [`docs/spikes/doc-heat.md`](../../../docs/spikes/doc-heat.md); the static read-plan size
is `bash scripts/session-ctx.sh --startup`), paid ONCE per session (prompt caching amortizes every
follow-up question) — and since 2026-09-27 paid only when the operator types the command.

## The read plan

1. **Base layer, in full**: `CONTEXT.md` + `ARCHITECTURE.md` (skip if already read this session).
2. **The agents corpus, in full, FIRST — one pass, before forming any opinion**:
   - `docs/agents/*.md` — every file. **The FSM YAMLs are NOT read** (trim, 2026-08-18): since
     the orphan gate landed (2026-08-10) the generated `*-fsm.md` views render the `replay:` /
     `unreplayed:` fields and the gap registers — the exact miss that once justified reading the
     sources. The YAMLs add only code anchors (file+regex); read one on demand when EDITING a
     guard/transition, never for a design sitting.
   - `agents/README.md` (launcher) + `agents/coordinator/README.md` (the brief — ~30k tokens (107 KB) and
     load-bearing; a docs/agents glob misses it)
   - `agents/replay/README.md` **through the generated index only** (doctrine + cleanup contract
     + index, ≈ the first third). The per-family essays below the index are touch-time reference
     — grep-only, the retros rule applied (trim, 2026-08-18).
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
- **Live-state claims are verified, never quoted from the corpus** (promoted from
  design-agents-G1, two sightings 2026-08-11 + 2026-08-23): a STATUS ("still queued") or a
  CONFIG CONSTANT ("default 3") lifted from corpus/transient prose is re-read from its live
  authority — the board, the deployment env, the ConfigMap — before being reported, or is
  explicitly marked as-of-doc-date. Corpus prose describing live config is a claim about the
  world, and the world moves between doc edits (the cap read "3" for two weeks after the
  deployment pinned 5). **The class includes RELAYED ASKS (design-agents-G3, 2026-08-30): a
  machine-filed issue's demanded operator action is itself a live-state claim — verify it
  against the domain's DECLARED record (App permissions: `docs/github-apps.yaml` + the `/apps`
  matrix, where a quiet drift alert means declared == live) before repeating it as the
  operator's to-do.** An escalation you forward unverified is an escalation you authored.
- Everything else is inherited: state the negative on tracker greps, "no owning doc covers X" is
  a finding, assessments until the operator says land it.
