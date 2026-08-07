# 2026-08-07 — CI stayed down for 5h after GitHub recovered: a listener chasing a deleted runner set

**Residual:** FU-150 (nothing alerts on "CI cannot dispatch").
**Related:** homelab#111 (the GitHub outage this hid behind), homelab#77 (same subsystem, different
fingerprint: runner pods stuck `Init:0/2`), `argocd/platform/arc-runners.yaml`.

A GitHub Actions major outage ran from ~15:36Z on 2026-08-06 to ~01:00Z on 08-07. **It cleared, and
our CI did not.** For five more hours every workflow run sat `queued`, `in_progress` stayed 0
fleet-wide, and nothing said a word — because at 22:11:49Z, *during* the outage, the ARC controller
tore its own runner scale set down and never rebuilt it.

## Timeline

| When (UTC) | What |
|---|---|
| 08-06 ~15:36 | GitHub Actions major outage begins. Runners alive but cannot acquire jobs (`acquirejob → ServiceUnavailable`). This part is genuinely GitHub's. |
| 08-06 18:33 | Responder files homelab#111, diagnosing `maxRunners: 4` capacity contention. Corrected to the outage; 4 runner pods aged 42–98m had acquired **zero** jobs. |
| 08-06 **22:11:49** | ARC controller runs a full teardown: deletes the listener, the ephemeral runner sets, **and the runner scale set from the Actions service**. Then logs nothing for five hours. |
| 08-07 ~01:00 | GitHub recovers. `update-pr-branch` goes green at 01:07 and 01:11 (it uses hosted runners, so it was never blocked by our ARC). |
| 08-07 01:05–03:05 | Every ARC-backed job queues. `in_progress=0`, homelab's queue grows 3 → 7. **No alert fires.** |
| 08-07 03:05 | Meta heartbeat sweep reads `Actions -> operational` **against** `in_progress=0` and flips the diagnosis from GitHub to us. |
| 08-07 03:07 | Controller restart. Replays the identical teardown, stops at the same line, no error. |
| 08-07 03:11 | Annotation nudge → same deterministic delete path. Credentials, `deletionTimestamp`, events all ruled out. |
| 08-07 03:12 | `AutoscalingRunnerSet` deleted; ArgoCD `selfHeal` rebuilds it. Fresh `EphemeralRunnerSet` `homelab-ephemeral-dk77x` appears. |
| 08-07 03:13–03:22 | Listener pod crashloops: created, `Error`, recreated, ~every 6s. |
| 08-07 03:22 | Listener's own log gives the cause (below). |
| 08-07 ~03:25 | Stale `AutoscalingListener` deleted → rebuilt against the current ERS. **Listener 1/1, 4 runners `2/2 Running`, `in_progress=2`.** Queues drain. |

## Root cause

**A rebuilt listener held the name of an `EphemeralRunnerSet` that no longer existed.** From the
listener container's own log — the only place it was visible:

```
Application returned an error: handling initial message failed: could not patch ephemeral runner set,
patch JSON: {"spec":{"patchID":0,"replicas":null}},
error: ephemeralrunnersets.actions.github.com "homelab-ephemeral-67zqb" not found
```

Auth was never the problem: it authenticated as the GitHub App, took a registration token, and
opened a session on scale set `2`. It then tried to patch `homelab-ephemeral-67zqb`, destroyed in
the 22:11:49Z teardown, exited 1, and the controller recreated it forever. Meanwhile the current
set was `homelab-ephemeral-dk77x` — **the two were created two seconds apart and still disagreed**,
which is why restarting the controller could not help: every reconcile faithfully rebuilt a listener
around a stale reference.

Why the controller tore down at 22:11:49Z is **not established**. It sits mid-outage, and the
teardown path it took (`Ephemeral runner set is outdated` → delete listener → delete ERS → delete
the scale set from the Actions service) is ARC's drain-and-recreate, which it began and never
finished. Whether the outage caused it or merely coincided with it is unproven, and this document
does not guess.

## What made it a five-hour incident rather than a five-minute one

**Nothing alerts on "CI cannot dispatch."** The alert inventory has `GithubWorkflowRunFailed`, which
needs a run to FAIL. A run that sits `queued` forever never fails, so it never fires. Every belt was
green throughout: ArgoCD reported `arc-runners` **Synced/Healthy** (the chart was applied correctly
— the CR's *status* was the problem), the alert crosscheck reported belts healthy, and the loop
watch saw no change because a stalled world produces none.

It surfaced only because the heartbeat compares a **throughput** signal against a **status** one.
That is the same rule that resolved homelab#111 twelve hours earlier: *a saturated pool has jobs
RUNNING, a broken one has workers WAITING* — applied there to exonerate a capacity cap, and here to
convict us after GitHub was cleared.

## Lessons

- **A vendor outage clearing is not your outage clearing.** The natural read of "GitHub is back" is
  that the queue drains itself. Ours did not, and the failure it left behind was locally caused,
  locally fixable, and invisible to every check that had been watching the vendor.
- **`Synced/Healthy` describes the manifest, not the machine.** ArgoCD was right the whole time.
- **The diagnosis was in the crashing container's log, not in the controller's.** The controller
  logged INFO-level normality (`Creating a listener pod`, `Listener pod is terminated, reason:
  Error`) with the actual error only inside the pod it kept replacing — and that pod lived ~6
  seconds, so reading it required polling for a live one.
- **Escalate remedies, and verify each before the next.** Restart → nudge → rule out credentials →
  rebuild the runner set → rebuild the listener. Three of those did nothing, and knowing *which*
  three is what made the fourth and fifth defensible rather than thrashing.
