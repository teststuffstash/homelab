# Spike: where a ride's wall-clock actually goes (one fully-reconstructed specimen)

**Specimen**: oracle-iac#361 → PR#362 (`suspend: true` flip, a two-line diff), 2026-08-09,
filed 17:24:47Z → merged 17:33:33Z = **8m46s**. Chosen because it is the *floor* case — a
trivially small change on the fastest lane (CI-only gate, no reviewer) — so nearly all of its
time is platform overhead, not work.

**Evidence** (all durable): the ring-woken scan pod log (`coordinate-perstack-mnhzm`), the item
coordinator session log (`coordinator-172525`), PR metadata (commit/PR/CI/merge timestamps), the
pod's own run-stats line (358s, $0.0085, deepseek-v4-flash), and the ride transcript in
`s3://agent-transcripts/oracle-iac/issue-361/`. The standing metrics + alert this asked for
shipped 2026-08-12 (`agent_run_phase_seconds`, launcher + in-pod halves —
[observability-and-retro.md](../agents/observability-and-retro.md) §Part A′); the shave
candidates below remain this spike's living content.

## Dispatch: 2m16s (file → coordinator claim)

| segment | time | evidence & notes |
|---|---|---|
| ring → scan pod cloning | 8s | doorbell → EventSource → Sensor → pod; effectively free |
| scan pod: clone homelab + deterministic scan | 30s | ~25s is the depth-1 homelab clone; the classification itself (queued-dispatch, class fix, wip 1) is instant |
| coordinator pod spin-up | **51s** | pure scheduling+image+start — the single biggest dispatch cost |
| coordinator session | 47s | 4 repo clones = 7s total (depth-1); ~40s LLM: read issue, dup-check, budget tier (xs, $0.09), key mint, worker launch |

## Worker: 5m18s (claim → PR open) + 72s to merge

| segment | time | evidence & notes |
|---|---|---|
| worker pod spin-up | ~34s | launch ~17:27:05; pod clock starts ~17:27:37 (back-computed from the 358s stats) |
| clone oracle-iac | ~3s | depth-1, small repo |
| LLM loop → commit+push | ~3m37s | goose/deepseek: read issue, find file, context reads (git log, open-PR check, labels), breaker checks, the edit, ONE combined checkout+add+commit+push call (17:31:14). ~10–14 tool-call round-trips |
| post-push | ~67s | `devbox run ci` in-pod (yamllint/kubeconform/argo lint, warm), scan-secrets, `gh pr create` |
| after PR | 15s sleep + checks poll + finalize | deliberate |
| CI | 30s | |
| merge latency | 38s | CI-only lane: the pod merges directly (no GitHub auto-merge, no reviewer) |

## Findings

- **Clones are NOT a cost.** Everything is `--depth 1`; stack repos land in ~0.5s. A mounted
  pre-clone + pull-diff would save ~nothing and add staleness risk. The one exception: the
  scan's homelab clone (~25s) — a sparse checkout (the scan needs `agents/` + `stacks.json`,
  not the tree) could cut ~15–20s.
- **Pod spin-up ×2 (51s + 34s) is the dominant fixed overhead** (~16% of total). Whether the
  image was node-cached was UNKNOWN for this specimen (events aged out before capture; the
  shipped `pod-spinup` phase metric makes a cold pull visible as a NUMBER — the cache FACT
  itself is still unemitted, see §shipped below). Adjacent hazard observed the same evening:
  a fleet ride pulled `devbox-cache:latest` fresh — a `:latest` tag defeats the node cache
  (the agents/README pinned-versions warning, live).
- **The coordinator added no value on this item** — claim, dup-check, tier estimate, key mint
  are all rule-derivable; the scan had already classified. ~90 of the 136 dispatch seconds.
  BUT the counter-example was 6h earlier the same day: the #107 dispatch session refused a
  meta mis-queue (fix already merged). Right shape: a **guarded mechanical fast-path**
  (fix-class ∧ round 1 ∧ no open PR ∧ no breaker signals → deterministic claim/mint/launch,
  ~10s; anything else → LLM session). Same family as the launcher-owned-params doctrine
  (ADR-094) and the long migration of decisions out of the LLM; needs its own design pass.
- **Push + PR-open are LLM tool calls** (model-assembled `git push`, `gh pr create` heredoc).
  A deterministic `pr-open` finalize step (model supplies title/body; script does
  branch-push-PR-arm) shaves ~2–4 round-trips (~30–60s) and removes the heredoc-assembly
  failure class — the ADR-094 "launcher-owned params" move applied to the exit path.
- **Realistic composite shave**: mechanical fast-path (−~90s) + image pin/pre-warm (−~30s) +
  leaner xs-tier recipe & pr-open script (−~45s) ≈ **8m46s → ~5m30s** for the floor case.
  Below that: pod scheduling and model round-trip latency — structural unless workers stay
  warm, which is a cost trade to price deliberately.

## What settled it (FU-160, archived 2026-08-12)

Phase timings as standing metrics, not archaeology: emit per-ride
`agent_run_phase_seconds{phase=dispatch-wait|pod-spinup|clone|llm-loop|gates|pr-open|ci|merge-wait}`
(launcher + agent-finalize both hold the needed timestamps), a Grafana breakdown panel next to
the existing `agent_run_*` cost panels, and a degradation alert — e.g. p50 of a phase over 1h
exceeding its baseline by minutes (a cold/bad cache shows up as pod-spinup/gates inflation long
before anyone notices rides "feel slow"). One specimen is a spike; a time series is a belt.

### Standing metrics, shipped 2026-08-11 (homelab#287, #319, agent-runtime#66; corrected by #324)

`agent_run_phase_seconds{phase=…}` is pushed per ride, keyed like the run ledger
(project, issue, round, role) under its own pushgateway job `agent_run_phase`. **Two emitters
write it**, in two sibling groups told apart by one label:

| phase | `source` | emitter | what it measures | the specimen above |
|---|---|---|---|---|
| `dispatch-gates` | *(none)* | `agents/agent-session.sh` | router consult, rail probe, card + recipe build, pre-flight guards, subscription latch, credit gate, cache probe, argv ceiling — everything deterministic before a pod exists | part of the 47s "coordinator session" row |
| `pod-spinup` | *(none)* | `agents/agent-session.sh` | `create` → `condition=Ready`: schedule + image pull + container start | 34s (worker) / 51s (coordinator) |
| `clone` | `in-pod` | `agent-finalize` | the repo clone inside the pod | ~3s |
| `devbox-install` | `in-pod` | `agent-finalize` | `devbox install` against the nix-cache mirror | (not separated in the reconstruction) |
| `llm-loop` | `in-pod` | `agent-finalize` | end of prep → finalize's first statement: the harness/LLM loop, the model's own `devbox run ci` invocations included | ~3m37s + the ~67s post-push |
| `finalize` | `in-pod` | `agent-finalize` | usage settle, salvage push, PR arm + issue link, summary/strike comments | part of the 72s to merge |

The launcher's list **ends at pod-Ready, and that is the whole of it** (homelab#324). #287 shipped
a `ride` envelope and a `bookkeeping` phase here too, on the assumption that the launcher process
survives the ride. In the cluster dispatch path it usually does not — the seat running it is a
coordinator session whose shell invocation is time-bounded, so it is killed mid-follow. Measured on
the live gateway 2026-08-12, 24 ride groups:

- `ride` was present on **5 of 24**, and not the short ones (892s survived, 292s did not) — it is a
  race with the seat's remaining lifetime, not a threshold anyone can tune.
- on those 5, `ride` equalled **the sum of the in-pod rows to within 1.0–2.7s** (892 vs 889.3,
  339 vs 338.0, 268 vs 267.0, 215 vs 213.3, 200 vs 197.3). The delta is the Ready→container-clock
  seam; the envelope carried no fact the in-pod rows do not.
- `bookkeeping` was **0.0 on 5 of 5** — correct, not broken: FU-064/FU-043 moved arming, the stats
  comment and the strike into the pod, so what the launcher had left to time was the
  fallback-not-taken. That work is the `finalize` row now.

So the two were removed rather than taught to survive: a phase that lands one ride in five is not a
slow metric but a biased one, and the fleet p50 it fed was a median over the rides that happened to
let their launcher live. **What was given up**: a stall in the launcher's *own* exit path (router
report, doorbell) is no longer timed — the `*_by_pod` flags on the stats line say whether the
fallback ran, and the leg that can actually stall is inside `finalize`.

Read them on the `agent-issue` dashboard (`Ride phase breakdown` + `Ride phase p50 — FLEET`);
`AgentRunPhaseSlow` (argocd/resources/pushgateway/prometheusrule.yaml) fires when a phase's
last-hour p50 doubles against its own older history, with a 60s floor and a ≥3-ride minimum — over
**both** sources, since it aggregates `by (phase)` and joins on labels that exclude `source`.

**The rows still NOT covered, and why.** The dispatch rows ABOVE the launcher — ring → scan pod,
scan pod, coordinator pod spin-up, coordinator session — are the coordinator's. They are measured
(homelab#319) but as a **separate family**, `agent_dispatch_phase_seconds`, keyed per STACK and
overwritten each dispatch, so they have their own panel and no alert: see the rule's comment for
why every guard in `AgentRunPhaseSlow` would misfire on them. Also unchanged by any of this:
**whether the image was node-cached** is still not a fact anyone emits — `pod-spinup` makes a cold
pull VISIBLE as a number, which is what the alert keys on, but attributing it still means reading
pod events while they exist.

## Second specimen (2026-09-05): a TEST-HEAVY ride — where the time goes when the model runs the suite

**Tracked by:** FU-216 (memory-backed `/tmp`), FU-217 (goose tool timeout vs suite), FU-218 (ARC
capacity honesty). Ideas parked 2026-09-05 for a slower day — nothing here is built.

The floor specimen above is a two-line diff on a lint-only lane. The other shape is a ride whose
model runs the project's full `devbox run ci` inside the pod, and it is bounded by different
things. Specimen: **oracle-fleet#370 round 2** → PR#460 (deepseek-v4-flash via goose, docker-mode
kata ride on `wk-metal-04`, 12:44–13:15Z, 1,866 s ride, 688 s queue wait). Transcript:
`s3://agent-transcripts/oracle-fleet/issue-370/worker-r2-20260905T131542Z/` (goose
`sessions.db`, message ids 53–58 are the two ci runs). Round 1 of the same issue has NO transcript:
it looped on `devbox run ci` timeouts (300 → 600 → 500 s) and died exit 255 before finalize.

| offset | segment | time |
|---|---|---|
| 0:00–4:52 | read issue + both e2e scripts + ci.yaml, two edits, commit, push | ~5 min |
| 4:56–14:59 | `devbox run ci` #1 — venv created (50 pkgs, 18 s), pytest started, **killed by goose's 600 s shell-tool timeout** | 10 min |
| 15:12–28:43 | `devbox run ci` #2 (model wrapped it in a 900 s poll loop) — 750 tests in 641 s + postgres test + mkdocs + helm + promtool | 13.5 min |
| 28:53–30:14 | scan-secrets, `gh pr create`, final output | ~1.5 min |

**24 of 30 minutes were the suite, run twice.** The same `ci` job on an ARC runner took 381–430 s
in three runs that day; inside the ride the pytest phase alone took 641 s.

### What bounded it (node readings for the ride window, `wk-metal-04`, 2-min steps)

- **Disk, not CPU.** IO pressure-stall (`node_pressure_io_waiting`) 82–91 % of wall time
  throughout, disk util 65–79 %; CPU busy 85–94 % but CPU pressure-stall only 4–8 %. The
  neighbours: the Longhorn instance-manager (bulk replicas + the Garage meta replica, 33 MB/s)
  and a homelab ride. The suite's slowest-20 are all build/delta tests at 17–27 s each — file
  writers.
- **Every ride write crosses virtiofs to the same disk.** The pod has NO volume for `/work` or
  `/tmp` (see `agents/agent-session.sh` volumes: only uv-cache / docker-run / docker-lib /
  context-bundle) — both live on the container rootfs, which kata serves to the guest over
  virtiofs from the host overlay on `/var`, the partition the replicas were hammering. ci.sh
  writes there: postgres `initdb` into `mktemp -d`, pytest `tmp_path` corpus sqlite fixtures,
  chart renders (`/tmp`), the uv venv (`/work/repo/.venv`, ~0.5 GB).
- **The 2-CPU agent limit is not the lever (yet).** oracle-fleet's pytest is serial (no
  pytest-xdist); one process ≈ one CPU. Docker-mode limits are agent 2 + dind 2 = the whole
  4-thread laptop (kata sizes the VM to the limits' sum, capped at host CPUs; the host-side
  sandbox cgroup allows ≈4.25 CPUs incl. the 250m RuntimeClass overhead). Raising agent to 3
  only changes intra-VM sharing with dind. Worth revisiting as agent 3 / dind 1 ONLY once the
  suite is parallel (`-n auto` on 2C/4T ≈ 2.5 cores of throughput). Core services are not the
  risk: CFS shares from requests keep cilium/kubelet/longhorn-manager proportional; the
  CPU-sensitive neighbour is the Longhorn instance-manager's replica latency.
- **Goose's shell-tool timeout (600 s) is shorter than the suite** → the model re-runs or
  wraps it, and round 1 died on it. Not a strike class anyone names (model-routing.md lists
  `timeout` as a strike, not this).
- Network was irrelevant: uv resolved + installed 50 packages in ~30 s.

### Ideas parked here (operator, 2026-09-05 — "big wins in oracle's ci/e2e first")

1. **Memory-backed `/tmp` for rides** — `emptyDir: {medium: Memory, sizeLimit: …}` at `/tmp`
   catches postgres, pytest tmp_path and chart renders with zero ci.sh changes; a second step
   points `UV_PROJECT_ENVIRONMENT` at it for the venv. ⚠ In a kata guest tmpfs is guest RAM
   charged to the agent container's cgroup (2 Gi in docker mode; python+uv+pytest ≈ 0.5 GB
   resident → ~1–1.2 GiB usable). Precedent: [kata-ci-gate.md](kata-ci-gate.md) attempt 4 — a
   3 Gi tmpfs in a 5 Gi VM guest-OOMed. `sizeLimit` turns overflow into a legible eviction
   instead of a guest OOM. Memory requests == limits for rides (2026-07-27 rule), so on 8 GB
   laptops the room comes from shrinking dind (2560Mi) for test-heavy rides, or accepting the
   envelope; on `wk-metal-04` it fits today. **First act: one ride with `TMPDIR` on the
   emptyDir and `du -sh /tmp /work/repo/.venv` at exit — that number sets `sizeLimit`.**
2. **Tool timeout ≥ measured suite time, or scoped pytest** (touched paths / `-x -q`) in the
   worker recipe — removes the repeat-and-die class outright.
3. **Longhorn replicas off ride nodes** (the storage plan's third zone does this) — the disk
   stall was a neighbour, not the ride.
4. **Hardware ask, when oracle brings one:** ride count per node is set by MEMORY (a docker
   ride's kata VM grows to ~5 Gi → one per 8 GB laptop, two–three on the 16 GB desktop); cores
   set how fast each suite finishes. Rank: RAM per ride node, then physical cores, then a local
   disk carrying no Longhorn replicas. A 32 GB / 6–8-core mini-PC is five or six rides — the
   same box class [storage-ledger.md](../storage-ledger.md) §Requirements wants.

### CI side, same day (ARC pool)

Oracle-fleet `ci` on `homelab-ephemeral`: 387 s p50; the pool's 24 h queue p50 2 s / p90 ~10 min
/ max ~40 min over 1,103 jobs, utilisation 17 % avg / ~60 % in the busy 6 h, at the maxRunners
cap only 0–2 % of the time. The queue is placement, not slots: a runner pod requests 2.5 Gi and an
8 GB laptop has ~6.2 Gi allocatable minus ~1.3 Gi of DaemonSets → **one runner per node**, and only
`wk-03`, `wk-metal-01`, `wk-metal-02` carry the `homelab.io/ephemeral=true` LABEL the runner set
selects on (`wk-metal-03/-04` carry the taint only — reserved for kata rides BY DECISION,
`tofu/talos.tf`). Effective ARC capacity is 3; `maxRunners: 4` guarantees one pod pending on
memory. The `arc-runners.yaml` comment "≈2 dind runners per metal node" is arithmetic that no
longer holds. `e2e` on ci-runner-01 (449 s p50) is bound by nothing measurable: guest PSI since
boot 0.8 % CPU / 0.5 % IO — it is sequencing (kind bring-up, image loads, readiness waits).
