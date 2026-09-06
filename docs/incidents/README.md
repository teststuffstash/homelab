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

## When to write one

The contract below is about *shape*; this is about whether the file should exist at all. Write an
incident when **any** of these hold, and not otherwise:

- **Cascade** — one cause produced failures in ≥2 components or namespaces. The expensive kind, and
  the kind no single alert can show you.
- **Third occurrence** — the same subject has failed three times. Twice is bad luck; the third says
  the earlier fixes were treating symptoms, and *that* reasoning is what the doc preserves.
- **Silent failure** — it broke in a way the monitoring didn't show, or a probe reported success
  while doing nothing.
- **A fix shipped on a diagnosis later proven wrong** — the wrong diagnosis is the artifact worth
  keeping. The right one is just a commit.

**Not** for a single alert with an obvious fix, however urgent — that is what the issue is for. A
postmortem nobody needed dilutes the ones that matter.

Two of those triggers are recurrence-shaped, so they only fire if someone can *see* the recurrence.
That is the weak point today: "this is the third time" has so far only ever been noticed by a human
reading old issue titles — the alert lane files one issue per alert and links nothing.

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
| 2026-07-27 | [The ghcr mirror filled four times in eight days — three mechanisms, five peer issues](2026-07-27-ghcr-mirror-recurring-fill.md) | FU-093 |
| 2026-07-27 | [Responder deferred an alert into silence](2026-07-27-responder-silent-defer.md) | FU-113 |
| 2026-07-29 | [`agent-finalize` bookkeeping fragility (PATH loss + unauthed `gh`)](2026-07-29-agent-finalize-bookkeeping.md) | FU-120, FU-123 |
| 2026-07-31 | [Last PR in a batch hung BEHIND on an unreliable GitHub cron](2026-07-31-last-pr-behind-hang.md) | FU-124 |
| 2026-08-07 | [CI stayed down 5h after GitHub recovered: a listener chasing a deleted runner set](2026-08-07-arc-listener-wedge.md) | — |
| 2026-08-11 | [wk-metal-02 lost its IPv4 default route; fleet-wide "WAN class" reds + runner starvation](2026-08-11-wk-metal-02-default-route-loss.md) | FU-150 |
| 2026-08-24 | [pve thin pool 100% (third fill) — wk-01 froze twice, Garage metadata wiped](2026-08-24-pve-thin-pool-garage-meta-wipe.md) | FU-093, FU-137 |
| 2026-09-03 | [pve thin pool 100% (FOURTH fill) — cp-01/wk-01/wk-02 paused on io-error, API down ~8 min; triggered by the runner-image pre-puller](2026-09-03-pve-thin-pool-fourth-fill-prepull.md) | FU-093, FU-207, FU-208 |
| 2026-09-06 | [The switchboard OOMKilled 153 times in a row (doorbell-collapse listed the whole retained workflow history), and nothing alerted](2026-09-06-switchboard-oom-silent-failures.md) | FU-188, FU-219 |
