# Incidents

Postmortems: **it broke, here is the timeline, here is why**. One file per incident,
`YYYY-MM-DD-<slug>.md`, dated by first symptom.

**Why this is its own genre.** An incident and a follow-up are different things that were being
written in the same place. A postmortem is a *permanent* learning artifact — the failure mode, the
evidence, the collateral, the probe lesson — and it stays useful long after the fix ships. A
follow-up is a *pointer to work not yet done*, and it dies when the work lands. Filing postmortems
as `FU-NNN` items meant the record was deleted the moment it was resolved, and meanwhile the
tracker carried multi-screen narratives that no longer had an action in them.

So: **the incident doc owns the story; the FU owns whatever is still undone.** When every residual
is closed, the FU archives and this file stays.

## Contract

- **Timeline with timestamps** (UTC) — what fired, what was observed, in what order.
- **Root cause**, and explicitly what was *ruled out*. If it's unconfirmed, say so — a
  best-guess labelled as one is worth keeping; a guess written as fact is not.
- **Collateral** — what else broke because of this. Cross-incident cascades are the expensive kind.
- **Fixes**, with commit/PR refs and whether each is a root-cause fix or a belt.
- **Probe lesson** — how to observe this class next time, especially what *looked* fine and wasn't.
- **Residual** — link the `FU-NNN` that carries the remaining work, if any.
- Backlink every `FU-NNN` the incident relates to, so `follow-ups-lint` can verify the pointer.

References here are historical: they record what was true at the time and are **never scrubbed**,
the same exemption the TICK-LOG and ADRs carry.

## Index

| Date | Incident | Residual |
|---|---|---|
| 2026-07-27 | [Kata ride OOM cascade — agents killed platform daemons on three nodes](2026-07-27-kata-ride-oom-cascade.md) | FU-112, FU-116 |
| 2026-07-27 | [Responder deferred an alert into silence](2026-07-27-responder-silent-defer.md) | FU-113 |
| 2026-07-29 | [`agent-finalize` bookkeeping fragility (PATH loss + unauthed `gh`)](2026-07-29-agent-finalize-bookkeeping.md) | FU-120, FU-123 |
| 2026-07-31 | [Last PR in a batch hung BEHIND on an unreliable GitHub cron](2026-07-31-last-pr-behind-hang.md) | FU-124 |
