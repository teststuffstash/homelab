---
name: docs-cleanup
description: >
  Fine-comb grooming pass over ALL homelab markdown (except retros; TICK-LOG/incidents/ADRs are
  historical — fix their references, never their content): sync every doc with recently
  archived/updated follow-ups, fix stale statuses/dates/links, collapse duplicated facts to one
  home, pointer-ize oversize FU items, expire old archive entries. Use on "clean up the docs",
  "docs grooming", "go over the documentation", or after a big FU-closure sweep.
---

# docs-cleanup — the fine comb

> **Glance first**: [`../GAPS.md`](../GAPS.md) §docs-cleanup — unpromoted sightings apply
> until closed (contract: [`../README.md`](../README.md)).

The docs are the platform's memory; this pass keeps them TRUE, not just tidy. The failure class
it hunts: **a fact that changed in one place and not the other** — the tracker archived an FU
but a doc still says "pending"; a "Next:" line that shipped; a status table that drifted from
the cluster; the copy nobody edits being the one somebody reads.

## Hard rules (before touching anything)

- **Historical records are read-only in content**: `docs/agents/retros/**` is fully out of
  scope; `agents/coordinator/TICK-LOG.md` is append-only; `docs/incidents/*` and `docs/adr.md`
  entries record what WAS — fix dead links/renamed paths in them, never re-litigate their
  claims. Same for archived FU *entries* (they say what shipped; only their freshness window
  expires them).
- **One home per fact** (CLAUDE.md routing table): when the same paragraph lives twice, decide
  the authoritative home from the routing table, keep it there, and turn the copy into a
  pointer. Never "sync" a duplicate — that preserves the drift bug.
- **Status lives with the pointer; mechanism with the detail.** An FU line owns is-it-done;
  its doc owns evidence/history. Fix violations in whichever direction is wrong.
- **Judgment calls are reported, not made.** A comb pass fixes facts. Anything that smells like
  policy (retire this doc? was this deferral overtaken by events?) goes in the final report for
  the operator.

## The pass

1. **Change-set first** — what moved recently drives where docs are stale:
   `git log --since='4 weeks ago' -p -- docs/follow-ups.md docs/follow-ups-archive.md`
   → the set of FU ids archived, resolved-in-place, or rewritten. For EACH id:
   `git grep -n 'FU-NNN'` across the repo and judge every living-doc reference against the new
   state (shipped things described as pending, dead "Next:" steps, superseded designs).
2. **Lint-driven targets** — `devbox run follow-ups-lint`: every OVERSIZE item gets
   pointer-ized (detail moves to the doc named in the item or the routing table; the item keeps
   status + next action, ≤10 lines); stale archive entries (>≈1 month) get deleted with their
   remaining living references scrubbed (TICK-LOG/ADR refs exempt).
3. **The comb** — inventory `git ls-files '*.md'` minus exclusions, walk in directory chunks
   (docs/, docs/agents/, agents/, argocd/**/README, root files, machines/, esphome/…). Per file:
   - **statuses vs reality**: SERVICES.md LIVE/PLANNED against the cluster; "pending/planned/
     TODO" claims against git history and the tracker; dates that say "current" but aren't.
   - **references resolve**: relative md links (`test -f` the target), script/file names that
     were renamed, FU ids that exist (the lint catches dangling — also catch *misleading*:
     an id cited for a claim its entry no longer supports).
   - **free-floating TODOs** → convert to `FU-NNN:` (file the FU if genuinely deferred, or
     just do it under the ≲5-min rule).
   - **doc-vs-code spot checks where cheap**: a doc quoting a flag/env/threshold — grep the
     code for it.
4. **Verify**: `devbox run follow-ups-lint` green; the link pass re-run clean; `git diff` re-read
   specifically for accidental history edits (rule 1).
5. **Deliver**: commits grouped by area (tracker-sync / statuses / links / pointer-izing), each
   message naming its evidence; then ONE report — files touched per class, and the judgment
   calls found-but-not-made, each with the operator question stated plainly.

## Scale note

This reads the whole repo's markdown — chunk the comb by directory across multiple turns, or
fan subagents/a workflow over the directory list if available (findings come back; edits stay
in the main session so the one-home-per-fact judgment is applied consistently).
