---
name: design
description: >
  Full-context mode for design questions — assessing, critiquing, or proposing changes to any
  subsystem (platform or not). Reads are PRE-AUTHORIZED: acquire the founding docs + the owning
  doc's link closure BEFORE forming an opinion, then answer with the grounding named. Use on
  "/design <question>", "let's design ...", "is <subsystem> doing a good job", "should we change
  how <X> works" — any question where the deliverable is a judgment about intent, not a live-state
  diagnosis. NOT for triage/incident work (probe the live thing instead).
---

# design — don't hold back on reads

> **Glance first**: [`../GAPS.md`](../GAPS.md) §design — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

> **Agent-platform topic? Use [`design-agents`](../design-agents/SKILL.md) instead** — the agents
> subsystem is coupled enough that selective closure kept under-reading; that variant reads the
> whole corpus upfront and drops the per-file grounding list (operator ruling 2026-08-10).

The failure class this kills: **a confident design opinion formed three hops short of the owning
doc** (2026-08-10: the canary critique made without `model-routing.md`/`roles.md`; a secrets
proposal contradicting `docs/secrets.md` §Minting doctrine while quoting an FU that linked it).
It is the jail-side twin of the context-repos hypothesis (FU-117,
`docs/spikes/context-repos.md`): *mount as much context as possible — the failure class to
eliminate is "I did not know due to the environment."* Token cost is pre-authorized by the
operator; rework and breaches are the expensive thing, not reads.

## The read plan — four layers, in order

1. **Base layer — always, in full**: `CONTEXT.md` (principles/decision lens) +
   `ARCHITECTURE.md`. Small, stable, non-negotiable: every design answer stands on them.
2. **Topic layer — the owning doc + link closure**: find the owning doc via the CLAUDE.md
   routing table and the doc tables (`docs/agents/README.md` for the agent platform;
   `SERVICES.md` if service-shaped). Read it IN FULL — never keyword-grep a design doc for the
   symptom of the day. Then chase its links: follow a link whenever the answer will lean on a
   term or concept whose home is the linked doc (once `docs/glossary.md` exists — FU-163 — the
   glossary is the term→home index; until then, chase every load-bearing term). Cross-repo
   topics: the sibling repos under `/workspace/` and the private `../teststuff` docs are in
   scope.
3. **Decision/tracker layer — grep, then read matches**: `docs/follow-ups.md`,
   `docs/follow-ups-archive.md`, `docs/adr.md`, `docs/spikes/` by topic keywords; read the
   matching items/blocks in full (adr.md is an index of ≤20-line blocks, not a book).
4. **Sediment — grep-only by default**: `docs/agents/retros/`, `agents/coordinator/TICK-LOG.md`,
   `docs/incidents/`, `docs/follow-ups-archive.md`, transcript dirs. **History is read when
   history is the subject, grepped otherwise** (same line docs-cleanup draws). 160K of model
   transcripts is not context — unbounded reading of the sediment degrades answers while
   feeling thorough.

## The output contract

- **Name the grounding**: the answer states which docs ground it ("grounded in: <owning doc> +
  <closure docs>; no owning doc covers <X>"). A context-free opinion must be visibly
  context-free — this is the visibility guard, same shape as the prior-art rule's "state the
  negative".
- **"No owning doc" is a finding, not a shrug**: it means you are about to design against
  undocumented intent — say so, and whatever intent the operator supplies in-conversation gets
  written down afterwards (routing table decides where).
- Design questions are **assessments** until the operator says land it — report, don't apply.
