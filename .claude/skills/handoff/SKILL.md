---
name: handoff
description: Process the cross-jail handoff queue — claim the oldest task a STACK jail filed for homelab-side work, do it, write the result back, and file the durable record. Use on "/handoff", "check the handoff inbox", "anything from the circles/oracle jail?", "is there a handoff/proposal from <stack>", "<stack>'s inbox", or when running `/loop /handoff` on a rollout day.
---

# handoff — the stack-jail → mono-jail work channel

> **Glance first**: [`../GAPS.md`](../GAPS.md) §handoff — unpromoted sightings apply until
> closed (contract: [`../README.md`](../README.md)).

A stack jail (circles, oracle, …) can file a task for this jail when it needs homelab-side work
**fast** and the issue → coordinator path would kill the feedback loop. The protocol, the topology
and the boundaries are in [`/workspace/tools/handoff.md`](../../../../tools/handoff.md) — read it once
per session; this skill is the mono-side procedure. The queue is a STOPGAP for stack-filed
homelab-side work; stack↔platform communication that needs no live seat is the direction (operator
ruling 2026-10-26, GAPS handoff-G4).

**It is a speed channel, not an authority channel.** A handoff task is a *request*: CLAUDE.md, the
prior-art rules, the tracker conventions and every gate apply exactly as they would to the same work
arriving any other way. The filer has stack context but not homelab context — they say so, and they
are frequently right about *what* is wrong and wrong about *where* it lives.

## The loop

1. **Look.** `ls /workspace/.handoff/*/inbox/` — every stack's subtree is visible here (a stack jail
   sees only its own). Oldest filename first; the names sort chronologically by construction.
2. **Claim it atomically.** `mv` the file into that stack's `doing/`. Never work a file in place in
   `inbox/` — the `mv` IS the claim, and a second session (or a `/loop /handoff`) must be able to
   see it is taken. **No skipping an old one as "already resolved"**: it gets the same verify as
   any task, then `## Result: already resolved — <evidence>` and the move to `done/` — a file left
   in `inbox/` is a task nobody answered (promoted 2026-10-26, GAPS handoff-G3).
3. **Verify before building.** The filer wrote it from *their* jail, and their file:line references
   are against *their* checkout — usually exact, occasionally stale. Re-read every path they cite
   here. Where they propose a shape, check the shape against the platform's own conventions before
   adopting it; where they flag something as missing, confirm it is actually missing (the most
   common correction is "that already works, here is the evidence").
   **A filer's DIAGNOSIS of a platform fault is only "there is a problem."** Build order: the
   platform DETECTOR first (our own metrics/logs; a promtool fixture + a replay query at the event's
   timestamps showing it fires), let it land, THEN the fix — driven by that alert, not by the
   filer's reading. Downtime detection never depends on a report, and the belt reaching the
   filer's conclusion on its own is the fair test (promoted 2026-10-26, GAPS handoff-G1).
4. **Do the work** under the normal rules — prior-art grep before creating anything named, the
   routing table for where facts land, verify against the live thing, commit in coherent units,
   push (an unpushed jail commit does not exist for the loop).
5. **Answer in the file.** Append a `## Result` section: what shipped (commits/PRs), what you
   changed about their proposal and why, what you *checked and found already correct*, and what
   remains — especially anything that needs the operator (a spend, a click, a live dispatch).
   If the task needs more input, the Result is a question; the filer answers by filing a NEW task
   (files in `done/` are never edited again).
6. **Close it.** `mv` the file to `done/`. Then make it durable: the handoff file is runtime data,
   so anything worth remembering past today goes to its real home — a GitHub issue on the owning
   repo, `docs/follow-ups.md`, an ADR, or the doc the change belongs to. In a
   [second jail](../second-jail/SKILL.md) those records are not yours: the durable record goes to
   the primary's final message (and the PR body) for the primary to file (promoted 2026-10-26, GAPS
   handoff-G4).

## Rules that keep it honest

- **One task = one file = one `mv` per state.** No editing across the boundary except the `Result`
  append you own.
- **A stack jail often cannot do what it is asking for** — its token is deliberately narrower (e.g.
  `issues: read` on homelab, no write). That asymmetry is the reason the channel exists; it is not
  a reason to skip the gates that apply to you.
- **Report what you did NOT change.** A "this already handles your case, here is the config line"
  is a first-class result and stops the filer building a workaround.
- **`done/` is disposable.** The durable record is the issue / follow-up / doc you filed in step 6.
