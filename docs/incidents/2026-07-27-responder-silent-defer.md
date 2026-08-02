# 2026-07-27 — The responder deferred an alert into silence

**Residual:** FU-113.
**Related:** FU-088 (archived — the subscription latch), FU-109 (per-consumer tiers),
FU-103 (archived — the responder role), FU-093 (the sighting family this alert belongs to).

A correctly-delivered alert was silently dropped because the responder's capacity latch treated
"defer" as "someone will call again" — and nothing calls again. It was caught only by the
meta-alert-crosscheck, which is the second real catch of that belt.

## Timeline

| When (UTC) | What |
|---|---|
| 20:03 | `KubePersistentVolumeFillingUp` fires (fp `c7bd21a6`) — the ghcr mirror filling. |
| 20:03 | EventSource + Sensor deliver it correctly. The machinery is healthy. |
| 20:03 | `respond-8mwqw` hits the FU-088 subscription latch (utilization 0.83) and exits: *"triage deferred — the alert refires"*. |
| — | **It does not refire.** No ledger entry is written. The alert is gone. |
| 21:10 | `meta-alert-crosscheck` notices the gap by diffing fired alerts against the responder-seen ledger. |
| same hour | Alert content handled operator-lane (mirror cache wiped — second fill that day). |

## Root cause

**Webhook delivery is edge-triggered per Alertmanager `repeat_interval` (hours), so a deferral is
a drop.** The responder's exit message asserted a property the transport does not have. And because
the deferred path wrote **no `seen` marker**, the outcome was indistinguishable from a broken
sensor — invisible to everything except a ledger diff.

## The generalization (2026-07-28, meta-15)

The same root produced three *different* silent outcomes, all during the
[OOM cascade](2026-07-27-kata-ride-oom-cascade.md). The crosscheck flagged 4 `PodSigkilled`
fingerprints as untriaged while the responder was demonstrably **healthy** (respond jobs completing
every ~10–25m). Two benign causes, neither a stuck sensor:

1. **Daily-cap exhaustion** — the storm produced >12 distinct pod fingerprints, so respond exited
   *"daily cap reached — NOT triaged (loud)"* and wrote no `seen` entry.
2. **Report-only dedup** — `respond-zddj6` correctly **did** triage two fingerprints but declined
   to file (already scoped to FU-112b / homelab#68), making no GitHub write and no ledger marker.

Through the crosscheck's ledger-diff, all three look identical to a machinery break.

## Fix direction (open — FU-113)

- **(a) Marker on every outcome.** Generalize from "latch-deferred writes a marker" to *any
  non-triaging respond writes a ledger marker*: latch → `deferred`, cap-hit → `cap-deferred`,
  report-only → `seen-noop`. The crosscheck can then distinguish **loud-known** from
  **silently-broken**, which is the whole point of the belt.
- **(b) Self-requeue** instead of trusting the edge — Argo retry/backoff, or resubmit-on-defer.
- **(c)** FU-109's per-consumer tiering would have let this ~30s bounded triage run at 0.83
  anyway. The three fixes compose; none alone is sufficient.

## Probe lesson

- **"It will refire" is a claim about the transport, not about the alert.** Check it before
  relying on it. Edge-triggered delivery plus a deferral equals a drop, every time.
- **A cap that keys off raw fingerprint count starves unrelated alerts during a single incident.**
  One OOM cascade produced enough distinct pod fingerprints to exhaust a 12/day budget. The cap
  should key off **incident** (route + root), not fingerprint.
- A belt that can only see *absence* (ledger diff) cannot distinguish deliberate silence from
  failure. Make every deliberate silence write something.
