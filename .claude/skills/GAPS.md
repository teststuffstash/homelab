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
- [ ] design-G2 — "multiple passes gave different answers to the same question" wasn't
      recognized as a design-shaped trigger; the first pass ran as grep-triage and missed
      tracker-held facts (FU-157's user-token nature; the live legacy token outside the
      matrix). Fix: add the inconsistent-answers cue to the skill's trigger list.
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
- [x] design-agents-G3 — a machine-filed issue's DEMANDED OPERATOR ACTION was relayed verbatim
      ("grant Issues:Read on the reviewer App — console class, needs you") without checking the
      declared record one grep away (docs/github-apps.yaml carried issues:write since FU-069(b);
      the quiet GithubAppPermissionDrift alert alone refuted the ask — the real gap was the token
      MINT). The G1 class one ring out: an escalation ASK is a live-state claim too. Sighted
      2026-08-30 (operator catch: "still multiple rounds escalate to me doing a manual click
      instead of a simple grep/curl"). **promoted→** the skill's output contract gains
      asks-are-claims, same commit; the fleet half is the ground-rules bullet (PR#1044).
- [ ] design-agents-G4 — the seat proposed a PER-INSTANCE hand fix ("I can wire #326's two
      blockedBy edges and the task/build labels") where the operator wanted the CONSUMER
      SURFACE fixed: the consumer card gains the rules the instance tripped, and a deterministic
      `goal-lint` runnable from every jail catches them before queueing. "Wrong fix" — a
      malformed input from a documented authoring surface is evidence about the surface, not a
      chore. Sighted 2026-09-01 (operator catch); the same session had ALREADY applied the
      lesson once (#1069's recipe paste → the launcher prefetch mechanism) and still reverted to
      the instance fix on the next case. **RESIGHT 2026-09-01 (operator catch, third in 24h):**
      the seat executed PR#1192's ~10-line completion and presented it as the durable fix, while
      the operator wanted the SURFACE — the arbitrate "re-dispatch stronger" verdict has no
      carrier to the router ("they did not meet") → FU-201. The hand edit was sanctioned as the
      un-wedge; presenting it as the fix was the gap.
- [ ] design-agents-G5 — a Goal's verdict-readiness was relayed as DUE from SHIPPED machinery
      while its Production-leg's verbs (demoting/advising/probing) name OBSERVED events: on #818
      the operator's exercised-in-a-stack bar refuted 3 of 4 deliverables (teeth never fired —
      burnt-bool 30d max 0; blocking knob — no stack sets `lenses:`; dial — nothing rendered).
      Fix candidate: the live-state rule extends to ACCEPTANCE VERBS — a verdict recommendation
      verifies each Production-leg verb against an observed event, never a ship record.
      Sighted 2026-09-02 (operator catch: "most of it has not been exercised in a stack yet").
- [ ] design-agents-G2 — a lifecycle LABEL was reported as activity ("#833 is riding —
      in-progress") from a live `gh` read alone: the label is a CLAIM, and the state is the
      JOIN (label × live pod × PR state) — the issue's PR had merged 8h earlier with no pod
      running (the FU-143 held class). The promoted live-state rule covered doc-sourced claims;
      this extends it: a lifecycle label is never reported as activity without the pod/PR join
      (the seat-side twin of IL-T16's phantom-label lesson). Sighted 2026-08-24 (operator
      catch). Tooling half → the #628 observability-plane discussion.
