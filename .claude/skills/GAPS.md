# GAPS — the skill gap ledger (ADR-105)

Sightings of skill shortcomings, FU-shaped. The contract lives in [`README.md`](README.md)
§Improvement contract: file on sighting · extend with a date on re-sighting (never a duplicate
line) · close in the same commit that edits the skill · ≲5-min factual fixes skip the ledger
and edit the skill directly · ≥2 dates on one entry = a class → propose promotion. This file
is in a PUBLIC repo — dialogue-level facts only, never tool output.

## design

- [ ] design-G1 — the read plan is reader-side only: an answer that proposes DOC EDITS never
      pulls in the writer-side rules (`docs/README.md` §Conventions, the docs-cleanup Hard
      rules). Fix: closure gains "proposing doc changes ⇒ read §Conventions + Hard rules".
      Sighted 2026-08-11.

## meta-coordinate

- [x] meta-coordinate-G1 — platform-lane PR review read the diff but truncated the BODY; the
      worker's "Findings" section (no machine harvester on this lane) was merged past unread —
      one finding was live on the PR's own issue. Sighted 2026-08-11 (operator catch).
      **promoted→** the skill's review duty gains the you-are-the-harvester rule, same commit.
      **RESIGHT 2026-08-11 (operator catch, same day)** — the promoted rule under-covered: it
      named the PR body, and the seat then read bot REVIEW bodies at a 200-char head (PR#311's
      approve posted on the summary alone; no finding lost, by luck). Rule widened same commit:
      the read is the body AND every review's FULL body, no truncated slices.

## design-agents

- [x] design-agents-G1 — a STATUS read from `meta-state.md`/tracker was repeated in the answer
      ("agent-runtime#62 still queued") although the session's own live board probe contradicted
      it in-context (#62 closed 30 min after meta-state's consolidation stamp). Fix: the output
      contract gains "status claims lifted from transient docs are live-verified (or marked
      as-of-doc-date) before being reported" — the never-repeat-a-remembered-status rule applied
      to the corpus itself. Sighted 2026-08-11 (operator catch).
      **RESIGHT 2026-08-23 (operator catch)** — the class extends to CONFIG constants, not just
      statuses: the seat quoted workflow.md's "SUBSCRIPTION_MAX_RUNNING default 3" while the
      deployed value had been 5 for two weeks (the operator's own dashboard said /5 in the same
      conversation). A number in corpus prose describing live config is a status claim; the
      deployment/ConfigMap is the authority. **promoted→** the skill's output contract gains
      the live-state-claims-verified rule (statuses AND config constants), same commit.
- [ ] design-G2 — "multiple passes gave different answers to the same question" wasn't
      recognized as a design-shaped trigger; the first pass ran as grep-triage and missed
      tracker-held facts (FU-157's user-token nature; the live legacy token outside the
      matrix). Fix: add the inconsistent-answers cue to the skill's trigger list.
      Sighted 2026-08-11.
