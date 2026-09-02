# 2026-09-02 — GitHub 401-throttles anonymous git from the WAN IP; the oracle loop is down ~4h through one unfixed clone site

**Impact:** every oracle coordinator item session failed at its PREP clone from ~09:15Z to
~13:05Z (issues 345/347/348/362 + the coordinate ticks that raced token gaps); oracle-fleet
PR#351's CI evidence step failed twice on the same class. No data loss; work queued, nothing
wrong was merged. Secondary casualty: fleet#345 sat in the C4/C5 silent-stall limbo (below).

## Timeline (UTC)

- **~09:10–09:50** — the ADR-121 morning: mirror-ghcr burned ~25GB of failed 6.4GB corpus
  pulls against ghcr (three `PROTOCOL_ERROR` laps, homelab#1282 recurrence; separate incident
  arc, fixed by ADR-121 same day).
- **~09:15** — first coordinate-perstack workflows fail. Root signal (established later):
  GitHub starts answering **anonymous `POST git-upload-pack` with 401** for the WAN IP —
  IP-wide (reproduced against `torvalds/linux`), while `GET info/refs` stays 200. git surfaces
  it as `could not read Username` + `expected flush after ref listing`, exit 128.
- **09:35** — fleet#345's worker r1 dies (`AGENT_STRIKE error_class=rate-limit`) — unrelated
  model rate-limit, but the label stays `agent/in-progress`.
- **~10:0x–10:45** — seat probes establish the throttle (jail curl/git discriminators;
  evidence comment on fleet PR#351). ⚠ the comment claims "loop pods unaffected" — wrong, see
  root cause 2.
- **10:x–13:0x** — oracle item pods fail at `Cloning into '/work/homelab'` repeatedly; each
  half-hourly tick's anonymous retry plausibly RE-TRIPS the throttle (it never decays).
- **12:5x** — operator points at #345; seat pulls the thread → the failing pods' logs name the
  clone; the wf clone sites are found already hardened (homelab#1136, the 2026-08-31 incident:
  47 failed workflows, same class) — `coordinator-session.sh`'s PREP clone is the ONE site
  #1136 missed.
- **13:0x** — fix pushed (`46c079cb`): the #1136 token-in-URL pattern in PREP (GH_TOKEN is
  exported by LOOP_FETCH immediately before — it was always present, just unused by bare git).
  fleet#345 re-queued with an audit comment.

## Root causes

1. **External:** GitHub's per-IP anonymous-git throttle (401 on upload-pack). Whether the
   morning's ghcr storm tripped it is unproven (those pulls were authenticated via the FU-196
   v0 PAT); once tripped, the loop's own anonymous retries every 30 min kept it tripped.
2. **Ours:** one anonymous clone site survived #1136 — the launcher PREP in
   `coordinator-session.sh` (the wf manifests were fixed; the script the wf dispatches was
   not). Single-site fixes to a repeated idiom rot; the idiom needed a sweep, not a patch.
3. **Amplifier:** the C4/C5 stall belt's conservative bare-mention exclusion — assembly PR#346
   bare-mentions #345, so the belt could neither re-queue it nor flip it to review. Documented
   limbo, first live sighting.

## What held

- The #1136-fixed wf clones (authenticated) kept SUCCEEDING whenever GH_TOKEN minted — which
  is also the healing path: master's fixed script reaches item pods through the wf's own
  authenticated clone.
- Worker/reviewer rides: authenticated by the agent-base credential helper throughout.
- Rule #6 discipline: no belt failed INTO a write.

## Residuals

- **The bare-mention limbo** (root cause 3): an `agent/in-progress` issue bare-mentioned by
  any open PR is invisible to both the stall wake and the review flip — needs a design ruling
  (wake with a distinguishing marker? age-bound the exclusion?). → filed as the next
  fu-sweep/board item; first sighting evidence is #345's timeline.
- Anonymous-idiom sweep: `agent-session.sh`'s context clones (`_CTXU`, WARN-tolerant) are
  helper-covered in-pod but the idiom deserves the same grep-audit #1136 should have run:
  `grep -rn "git clone" agents/` with an auth story per site.
- My PR#351 comment's wrong claim is corrected on-thread (asks-are-claims applies to the seat's
  own assertions — the design-agents-G1 class, self-caught late).
