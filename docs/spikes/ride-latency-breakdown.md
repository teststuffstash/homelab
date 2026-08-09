# Spike: where a ride's wall-clock actually goes (one fully-reconstructed specimen)

**Specimen**: oracle-iac#361 → PR#362 (`suspend: true` flip, a two-line diff), 2026-08-09,
filed 17:24:47Z → merged 17:33:33Z = **8m46s**. Chosen because it is the *floor* case — a
trivially small change on the fastest lane (CI-only gate, no reviewer) — so nearly all of its
time is platform overhead, not work.

**Evidence** (all durable): the ring-woken scan pod log (`coordinate-perstack-mnhzm`), the item
coordinator session log (`coordinator-172525`), PR metadata (commit/PR/CI/merge timestamps), the
pod's own run-stats line (358s, $0.0085, deepseek-v4-flash), and the ride transcript in
`s3://agent-transcripts/oracle-iac/issue-361/`. Tracked by: **FU-160** (turn this one-off
reconstruction into standing metrics + an alert).

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
  image was node-cached is UNKNOWN for this specimen (events aged out before capture — FU-160
  makes this a metric so it stops being unknowable). Adjacent hazard observed the same evening:
  a fleet ride pulled `devbox-cache:latest` fresh — a `:latest` tag defeats the node cache
  (the agents/README pinned-versions warning, live).
- **The coordinator added no value on this item** — claim, dup-check, tier estimate, key mint
  are all rule-derivable; the scan had already classified. ~90 of the 136 dispatch seconds.
  BUT the counter-example was 6h earlier the same day: the #107 dispatch session refused a
  meta mis-queue (fix already merged). Right shape: a **guarded mechanical fast-path**
  (fix-class ∧ round 1 ∧ no open PR ∧ no breaker signals → deterministic claim/mint/launch,
  ~10s; anything else → LLM session). FU-045-adjacent; needs its own design pass.
- **Push + PR-open are LLM tool calls** (model-assembled `git push`, `gh pr create` heredoc).
  A deterministic `pr-open` finalize step (model supplies title/body; script does
  branch-push-PR-arm) shaves ~2–4 round-trips (~30–60s) and removes the heredoc-assembly
  failure class — the ADR-094 "launcher-owned params" move applied to the exit path.
- **Realistic composite shave**: mechanical fast-path (−~90s) + image pin/pre-warm (−~30s) +
  leaner xs-tier recipe & pr-open script (−~45s) ≈ **8m46s → ~5m30s** for the floor case.
  Below that: pod scheduling and model round-trip latency — structural unless workers stay
  warm, which is a cost trade to price deliberately.

## What would settle it (→ FU-160)

Phase timings as standing metrics, not archaeology: emit per-ride
`agent_run_phase_seconds{phase=dispatch-wait|pod-spinup|clone|llm-loop|gates|pr-open|ci|merge-wait}`
(launcher + agent-finalize both hold the needed timestamps), a Grafana breakdown panel next to
the existing `agent_run_*` cost panels, and a degradation alert — e.g. p50 of a phase over 1h
exceeding its baseline by minutes (a cold/bad cache shows up as pod-spinup/gates inflation long
before anyone notices rides "feel slow"). One specimen is a spike; a time series is a belt.
