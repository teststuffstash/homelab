# 2026-07-29/31 — `agent-finalize` bookkeeping fragility: a lost PATH, then an unauthed `gh`

**Residual:** FU-120 (PATH loss — root cause unconfirmed, belt shipped), FU-123 (unauthed `gh` in
finalize — open, hypothesis only).
**Related:** ADR-096 §Addendum 3, FU-062 (strike bookkeeping), FU-064/043 (in-pod bookkeeping),
FU-089 (broker token, no standing secret), FU-116 (kata storage).

Two independent defects in the same component, found a day apart, both with the same shape: **the
in-pod bookkeeping step fails, a fallback silently covers for it, and the loop looks healthy while
losing data.** Recorded together because the second was found while building the belt for the
first, and the first's belt is a suspect in the second.

## Part 1 — finalize crashed on `env: python3: not found` (FU-120)

**The original diagnosis was wrong.** It was recorded as "the project's python lives inside the
devbox env" — it does not. `python@3.11` **is** baked into agent-base and on the container PATH
(`/opt/agent/.devbox`, `agent-base/devbox.json`); finalize runs on agent-base's python, always,
outside any `devbox run`.

Proof it was not a systematic break: finalize ran fine for #71's sibling rides r3/r6/r7/r8 (they
uploaded transcripts). The crash was **#71-r2-specific** — the auth-storm ride, 140× 401 on
`laguna:free`.

**The exact cause is unconfirmed and will stay that way**: the crash meant no transcript, so r2's
pod log is gone. Best guess is a transient PATH/mount loss on that storming kata pod (see
[the OOM cascade](2026-07-27-kata-ride-oom-cascade.md) for the storage-side sibling).

**Cost was real.** No auto strike, no `/report`, no salvage — the coordinator posted the strike by
hand, and ADR-096's `strikes` table was **empty across the whole #71 window**. Only the passive
`provider_events` caught the 140 401s. This is precisely why ADR-096 bases provider health on
passive data-plane events rather than on `/report`.

**Belt shipped 2026-07-31** (`agents/agent-session.sh`): the launcher pins
`PATH=/opt/agent/.devbox/nix/profile/default/bin` on the finalize call, so finalize's shebang and
its `git`/`gh` subprocesses resolve regardless of PATH weirdness. Bookkeeping can no longer be lost
to this class. Interpreter ownership is now documented (agent-runtime#25: base scripts run on
agent-base's python, not the project's).

Root cause remains unconfirmed and is now **masked by the belt**. Reopen a root-cause dig only if a
**non-finalize** symptom of the same PATH/mount loss appears.

## Part 2 — in-pod arm-auto-merge fails systemically (FU-123)

**Verified 2026-07-31 across 4/4 sleep workers** (#58/#51/#66/#68). Finalize logs:

```
bookkeeping: arm FAILED: To get started with GitHub CLI … gh auth login …
populate the GH_TOKEN environment variable (launcher/reflex re-arms)
```

Non-fatal in effect — every PR still merged, because `agent-session.sh:864` (launcher) and
`review-reflex.sh:168` re-arm un-armed PRs. **But it defeats the entire point of FU-064/043**
(in-pod bookkeeping surviving an early launcher exit) and hides a hard dependency on the fallback:
if the reflex breaker ever latches, PRs silently never arm and therefore never merge.

**This is a regression** — archived FU-119a recorded in-pod arming as "perfect 3/3".

**Hypothesis — unconfirmed, do not assert it without reading `agent-finalize` in agent-runtime and
the broker token flow.** The worker's git token is broker-fetched at runtime (FU-089 deleted the
standing `agent-git-token` Secret) and may not be present in `agent-finalize`'s env / `gh` config.
This possibly interacts with **Part 1's own belt**: the
`PATH=/opt/agent/.devbox/nix/profile/default/bin:$PATH` prefix (`agent-session.sh:472`) resolves
finalize's `gh` to agent-base's binary, which reads auth from a location the session's token never
populated.

**Next:** confirm whether the pod exports `GH_TOKEN` / persists `gh auth` for finalize, and whether
**pre-FU-120** workers armed in-pod (compare an oracle-fleet worker's finalize — that separates
"always broken" from "broken by the belt").

**Acceptance:** `armed_by_pod=true` on the `AGENT_RUN_STATS` line, so the launcher/reflex re-arm is
the belt it was designed to be, not the primary path.

## Probe lesson

- **A working fallback hides a broken primary indefinitely.** Both defects were invisible at the
  outcome level — PRs merged, the loop looked green. The only reason either surfaced was reading
  finalize's own log lines. Emit the primary's success as data (`armed_by_pod`), or you are
  measuring the belt.
- **A belt can be the next bug's cause.** Part 1's PATH pin is a suspect in Part 2. When adding a
  belt that changes resolution order, note what it might shadow.
- **When the crash destroys the evidence** (no transcript → no pod log), accept "unconfirmed",
  write the belt, and name the symptom that would justify reopening. Do not back-fill a
  confident-sounding root cause — the original FU-120 diagnosis was exactly that, and it was wrong.
