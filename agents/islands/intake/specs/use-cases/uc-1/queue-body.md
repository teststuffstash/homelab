---
Touches: agents/coordinator-scan.sh, agents/replay/fixtures/fleet-fault-unlatch-issue-no-pr, agents/replay/run.sh
Origin: teststuffstash/homelab#3048
Class: fix

---
## Deliverable

The fleet-fault un-latch clause clears an **issue**-side `agent/error` latch that has no referencing open PR once its cited cause is CLOSED. A PR-less issue has no CI to be red, so the CI leg is vacuously satisfied. Today the clause HOLDs that case forever.

## Acceptance

1. `agents/coordinator-scan.sh`, block `fleet-fault-unlatch`: an issue that carries the `fleet-fault cause=` marker, whose cause is CLOSED, and that no open PR references (the same sibling-match the clause uses today) gets `agent/error` removed. It gets one un-latch comment that says the CI leg was vacuous because there is no PR. It must not say "CI is green".
2. The vacuous leg fires only when the open-PR list (`$prsjson`) was **read successfully**. An unreadable or failed PR-list read is still a HOLD with no label write (rule #6: never fail INTO a write). The PR must show which line carries that distinction.
3. A new replay fixture `agents/replay/fixtures/fleet-fault-unlatch-issue-no-pr` (`block:fleet-fault-unlatch`, modelled on `fleet-fault-unlatch-issue-cause-closed-green`) pins the rows below. The five existing `fleet-fault-unlatch-*` fixtures stay green byte for byte.
4. `devbox run diff-ci` green.

## Key rows

| description | marker | cause state | open PR referencing the issue | PR-list read || expected |
|---|---|---|---|---||---|
| "PR-less strike latch, cause closed ⇒ un-latch" ⚖ | yes | CLOSED | none | ok || `agent/error` removed; comment names the vacuous CI leg |
| "PR-less strike latch, cause still open ⇒ hold" | yes | OPEN | none | ok || no write (today's `continue`) |
| "PR list unreadable ⇒ hold" | yes | CLOSED | — | failed || HOLD line, no label write |
| "issue with a referencing PR ⇒ today's CI leg" | yes | CLOSED | #N, CI green | ok || unchanged (`issue-cause-closed-green`) |

⚖ on row 1: the filing names a second leg too, "nothing committed (the strike's 'no resumable branch' line) ⇒ satisfied". That leg would clear the latch while the cause is still OPEN, which drops the cause gate. This body takes the narrower leg, which keeps the cause gate. Verify during implementation whether the `$prsjson` read in scope of this block can fail silently into `[]`.

## Out of scope

- Whether an environment-class cause (`rate-limit`, a drained pool that resets on a timer) should be named as `cause=` at all. That is a strike-channel design question for the seat, not this clause's leg.
- homelab#2588, the live instance, was un-latched by hand on 2026-10-31. homelab#2601 (its cited cause) is ruled separately.
- Lands through the ADR-110 seat read (`agents/**` is codeowner-merge). The PR parks for that read, and the park is not a stall.

Filed by the janitor tick 2026-10-31. Rewritten queue-ready by island intake (agent-loop).


