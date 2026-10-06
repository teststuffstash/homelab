# Wiring CNPG backups into running clusters left grafana-pg and forgejo-pg without a writable primary (~10 min each), and nothing alerted

**Date:** 2026-10-03 · **Duration:** grafana-pg 10:23–10:33Z, forgejo-pg 10:35–10:45Z (write path down;
reads on the old primary kept working) · **Trigger:** the seat, rolling out ADR-147 · **Residual:** FU-299

## Timeline (UTC)

- **10:21** — inside maintenance window `seat-1791022866-8424`, grafana-pg is annotated so the new
  `pg-backup-default` admission policy injects the Barman Cloud plugin (PR#2190). The injection works.
- **10:21–10:23** — CNPG rolls the replica (`grafana-pg-4`) with the plugin sidecar, then starts a
  switchover to it: `targetPrimary=grafana-pg-4` and the old primary (`grafana-pg-3`) is labelled
  `unhealthy`. From here **`grafana-pg-rw` has no endpoint**.
- **10:23–10:31** — the operator logs *"There is a switchover or a failover in progress, waiting"*
  537 times. `grafana-pg-3` logs *"wal archive plugin is not available"*. Every instance stays
  Ready; no alert fires; the window check is clean.
- **10:31** — the seat finds the deadlock. Replica LSN = primary LSN (`2A/DA0002B0`). It deletes
  `grafana-pg-3`; CNPG promotes `-4`, and `-3` returns with the sidecar. Healthy, archiving True.
- **10:35** — forgejo-pg is wired by a script written to wait for the replica *before* failing over.
  The wait itself is the outage, because `-rw` emptied when the switchover started (~10:35). At
  10:45 the seat sees `forgejo-pg-rw` with no endpoints, checks LSN `76/BC054840` = `76/BC054840`,
  and fails over by hand.
- **10:48 / 10:50** — oracle-pg and infisical-pg go through the corrected script, which fails over
  the moment the switchover starts. `-rw` gaps: **17 s** and **16 s**. oracle-pg's *replica* also
  hung in its shutdown, on the same archive, until it was restarted. That cost reads only.

## Root cause

Adding the plugin to a RUNNING cluster changes the primary's `archive_command` at once, through a
config reload. That primary's pod has no plugin sidecar until it is recreated, so every archive
attempt fails. CNPG's rolling update restarts the replicas first, then switches over. The
switchover demotes the old primary only after it archives its last WAL, which it cannot do. The
wait is bounded only by `switchoverDelay` (default 3600 s). CNPG empties the `-rw` Service as soon
as the switchover starts.

**Ruled out:**

- **Data loss.** Every forced failover was taken only after the target replica's replay LSN equalled
  the old primary's current LSN.
- **The plugin or the store.** Archiving worked the moment a pod had the sidecar: all four clusters
  report `ContinuousArchiving=True`, and the first backups completed 4/4.

## Collateral

Grafana and Forgejo could not write for ~10 min each. Both answered HTTP 200 afterwards. Nothing
else was affected. The Infisical and oracle-fleet databases were wired with sub-20-second gaps.

## Fixes

- **Root-cause fix:** the admission policy no longer wires a running cluster on an arbitrary update.
  It wires only on CREATE, re-asserts already-wired clusters, and acts on the explicit
  `homelab.io/pg-backup: wire` request. That request is made by `devbox run pg-backup-wire`, whose
  LSN-checked failover replaces the deadlocked wait. PR#2192.
- **Belt:** `CNPGNoWritablePrimary` fires when a `-rw` EndpointSlice is empty for 3 min. Replayed
  over 7 days, it hits exactly the two windows above and nothing else. PR#2192.

## Probe lesson

"All instances Ready" and a clean maintenance-window check said nothing about the write path. A
database's availability is its **`-rw` Service having an endpoint**, not its pods being Ready. A
change that makes an operator act on its own (a rolling update, a switchover) needs the *service*
read during the act. Instance health is not that read.

Second lesson, from the same rollout: a standby backup is not a restore point. One reported
`completed` minutes before its WAL reached the store. One taken from a standby that had just
rejoined after a failover was unrestorable (*"unexpected timeline ID 20"*). Backups now target the
primary, and the drill restored from one in 85 s ([`postgres.md`](../postgres.md) §Backups).
