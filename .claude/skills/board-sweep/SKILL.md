---
name: board-sweep
description: >
  Sweep the recent LIVE board — alerts, issues, responder/fixer activity, and especially the
  items where nothing was done — across the claim-derived repo universe (every AgentStack's
  repos; never "homelab" by name). Machine truth first: the first stage of the
  board-sweep → fu-sweep → docs-cleanup pipeline. Use on "/board-sweep", "what happened while
  I was away", "sweep the board", "what did the loop do / miss", or after any meta stand-down.
---

# board-sweep — machine truth first

> **Glance first**: [`../GAPS.md`](../GAPS.md) §board-sweep — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

The gap this owns (founding evidence 2026-08-11, homelab#237): every terminal escalation
surface — `agent/error`, `agent/blocked`, 🌱 piles, digests, a failed retro — is read only by a
live meta session, so a stand-down leaves the machine correctly escalating into silence. The
FU-133 corpus audit (27 issues → 5 root causes, 2026-08-04) is the founding example of this
sweep, done once by hand. This skill makes it repeatable; the reflex it may become is
deliberately deferred (§Graduation).

## Hard rules

- **Corpus preload.** Run the [`design-agents`](../design-agents/SKILL.md) read plan first
  (skip if already read this session). The core judgment here — STUCK-MACHINE vs HANDLED — is
  "did the machinery behave as *intended*", and intent lives in the corpus; classifying
  homelab#237's `queued`+`blocked`+`error` pile required breaker #1, the fix-debounce contract
  and the self-referential gate. Guessing instead is actively harmful (clearing `agent/error`
  un-latches a breaker).
- **Live-verify every status claim** (GAPS design-agents-G1): transient docs — `meta-state.md`,
  the tracker, TICK-LOG — state what was true at their stamp. The board is the truth; `gh`/
  `kubectl` before repeating anything. The corpus prevents comprehension errors, live probes
  prevent staleness errors; this sweep needs both.
- **The repo universe is CLAIM-DERIVED**: `stacks_json()` semantics — cluster AgentStack claims
  merged over `agents/stacks.json` — enumerating every stack's repos including context-only
  entries. Never a hand list, never "homelab" (the repo ≠ [the platform stack](../../../docs/glossary.md) ≠ the
  lab). "Platform-lane" always resolves through the platform claim's repo list.
- **Classify first, act second.** Every item leaves the pass in exactly one bucket with a
  reason; only then act on do-nows (≲5-min rule, each with its own end-state check —
  CLAUDE.md §Safety). Never "tidy" machine state you have not root-caused.

## The pass

1. **Window** = since the last sweep's TICK-LOG entry (or the operator names X days).
2. **Gather — all durable sources**: org-wide issues created+updated in the window
   (`gh search issues --owner teststuffstash`); all OPEN issues carrying `agent/*` labels or 🚨
   markers across the claim universe; Alertmanager's firing set vs the responder-seen ledger
   (`bash agents/meta-alert-crosscheck.sh` — its UNTRIAGED diff is bucket 5's input); merged +
   open PRs in the window; `AGENT_STRIKE:` / `<!-- agent-summary -->` evidence on touched
   items; janitor-tick reports from the transcripts bucket when a stack looks quiet; **the
   ADR-148 lanes' records in the window** — every `dig-<date>/*/finding-*.json` and every
   `alert-<fp>/responder-r1-*/triage.log` (`devbox run garage-s3 s3 ls s3://agent-transcripts/homelab/`;
   the `now` lane's `finding.json` is metadata only — its reasoning is the `triage.log` prose).
   This pass IS their reader (operator 2026-10-09, FU-249 (c)); nothing else surfaces them.
3. **Classify every item**:

   | bucket | test | action |
   |---|---|---|
   | **HANDLED** | machine closed it end-to-end — verified by SUBSTANCE (diff/closure vs the item's text), never by its own label | record; feeds fu-sweep's reconcile |
   | **CORRECTLY-WAITING** | a NAMED human/operator gate holds it (blocked-on-session, attended-first-run, digest awaiting review) | report age; silence is correct |
   | **ESCALATED-UNSEEN** | terminal human-surface state nobody has read: `agent/error`, stale `agent/blocked` whose gate resolved, 🌱 piles, unread digests | the headline list — act on what is meta-lane, hand the operator the rest |
   | **STUCK-MACHINE** | behavior contradicting corpus intent: dispatch loops, contradictory labels, report-only leaks, gate misses | root-cause, then file (prior-art grep + state the negative; a NEW name clears `docs/glossary.md` first) or fix under the 5-min rule |
   | **SILENT** | alert fired, no triage anywhere (the crosscheck's UNTRIAGED class) | the responder MACHINERY is broken — investigate the chain first, never hand-triage the alert |

   Lane records classify like any item: a dig `cause-found`/`fix-proposed`/`unexplained` finding
   or a `now` triage naming a cause nobody recorded = ESCALATED-UNSEEN; a finding that names an
   existing FU/issue = HANDLED **only if that record names the alert** — the dig's `explain_fu`
   matches the literal alert name, so a finding reading "explained by FU-X" whose FU-X lacks the
   name is re-dug every night. **Live-verify a finding's claims before acting** — both lanes still
   state wrong causes with confidence (spike `responder-week-audit.md` §2026-10-09).
4. **Act**: do-nows with end-state checks; filings through existing seams (issues on the owning
   repo, GAPS for skill gaps, FU only for genuine deferrals — prior-art grep first, always).
   **Close the dig's loop in git:** for each "explained by FU-X / issue #N" finding, add the alert
   name (and its subject) to that record — the next nightly selection then reads it as explained.
   The board, the tracker and the dig converge through these writes, not through a new store.
5. **Report + TICK-LOG entry** (condition → command). That entry IS the next sweep's watermark.
   The operator list is short or it will not be read (the fu-sweep rule).

## Pipeline

**board-sweep → [`fu-sweep`](../fu-sweep/SKILL.md) → [`docs-cleanup`](../docs-cleanup/SKILL.md).**
This pass establishes machine truth; fu-sweep's step-2 machine-lane reconcile consumes the
HANDLED bucket instead of re-deriving it; docs-cleanup propagates what both changed. One session
running all three amortizes the corpus preload across the pipeline.

## Graduation (deliberately not built)

Run by hand ≥2–3 times, then decide the reflex shape from what the reports actually contain
(contracts emerge from patterns): (a) a board slice added to the Monday retro brief
(observability-and-retro.md §B2), or (b) a durable escalation digest — ESCALATED-UNSEEN as one
dated issue / Home Assistant notification, making the human surface survive stand-downs.
The founding-day evidence (2026-08-11) leaned (b) — the retro was broken that morning (it ran
green the same day, so re-weigh (a) at graduation); a belt whose only consumer is the thing it
watches remains the FU-108 class either way. **Dig findings** have their own graduation
(operator 2026-10-09): a retro-like batch reader over several nights of dig results, so the
operator reads the digest of digests rather than each finding — decide its shape after this
pass has read them by hand a few times (FU-249 (c)).
