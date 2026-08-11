---
name: skill-retro
description: >
  Batched retrospective over past JAIL session transcripts that used skills — the jail twin of
  the cluster retro (docs/agents/observability-and-retro.md §B2, ADR-105). Finds
  skill-attributable gaps (operator corrections after skill-guided output, improvised steps a
  skill lacks, wrong-skill routing) and files/extends FU-shaped entries in the GAPS ledger.
  Use on "/skill-retro", "retro the skills", or after a stretch of skill-heavy sessions.
---

# skill-retro — mine the transcripts, feed the ledger

A session cannot see its own mistakes at invocation time; corrections arrive later, in the
operator's words. This skill reads FINISHED sessions in hindsight — where attribution is easy —
and turns corrections into [`../GAPS.md`](../GAPS.md) entries. Filing/extension/promotion rules
and the public-repo scrub rule: [`../README.md`](../README.md) §Improvement contract.

## The pass

1. **Score the previous run first** (the B2 rule — self-improvement that measures itself):
   for each `promoted→` line closed since the last watermark, check whether its class recurs
   in the slices below. Recurrence = the promotion failed; reopen the entry with the new date.
2. **`devbox run skill-retro-scan`** — renders dialogue-only slices (user + assistant text, no
   tool dumps) of every skill-using session since the watermark into
   `~/.claude/skill-retro/slices/`, skipping the still-active session.
3. **Read each slice** and hunt exactly four shapes:
   - operator pushback following skill-guided output (the primary signal);
   - a step the session improvised that the skill's procedure lacks;
   - wrong routing — a skill invoked off-topic, or NOT invoked though its triggers matched;
   - the skill said X, the session did Y.
4. **File/extend GAPS entries** — extend-on-resighting (add the date to the matching entry,
   never a duplicate line); the one-sighting bar applies: file, don't promote. Scrub — the
   ledger is public.
5. **Report + advance the watermark** (`date -Iseconds > ~/.claude/skill-retro/watermark`,
   only AFTER the ledger is written): new/extended entries, promotion proposals (entries with
   ≥2 dates), and step 1's scoring. Promotions land only on the operator's nod.

## Guardrails

- Dialogue-only slices — never pull tool outputs into the analysis or the ledger.
- This skill edits ONLY `GAPS.md` (+ its report); skill files change at promotion, gated.
- An operator correction counts as a sighting even when the session recovered — the recovery
  cost is the point.
- Slices are derived caches — delete `~/.claude/skill-retro/slices/` freely; the transcripts
  are the source.
