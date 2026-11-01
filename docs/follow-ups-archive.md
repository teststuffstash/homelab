# Follow-ups archive (rolling)

Resolved `FU-NNN` items land here, **trimmed to the grep residue**: what shipped, when, the
acceptance evidence, any gotcha. This is a *rolling* buffer, not a permanent record — an entry
stays while the work is fresh (≈a month) so in-flight sessions can still `git grep` the id, then
gets deleted; after that, `git log -S FU-NNN` is the record. `devbox run follow-ups-lint` treats
ids here as still defined (references elsewhere stay legal while archived) and warns when an
entry is past its freshness window. Deleting an expired entry (ADR-116, the name-anchor ruling):
scrub only the **TODO-shaped** references (`FU: FU-NNN` gap-register cells, `Tracked by` lines —
the lint reds them as TODO-RETIRED); every other reference is a **provenance name** — a stable
coordinate in a never-reused namespace — and stays untouched, forever.

- **FU-161** *(archived 2026-11-01)* — **Scout v3.** The model scout is RETIRED (#3124 + the cron's seat-direct
      removal): new-model discovery, canaries and tiers are the gateway's (GW-CATALOG-OR entry canary,
      GW-MODEL-TIERS). Design history: [`model-routing-history.md`](spikes/model-routing-history.md) §M7.
- **FU-316** *(archived 2026-10-31)* — **Cold-blob `blob-warmer` on the ghcr + docker-io mirrors.** PR #3049 (master
  `94e889e7`) added the mcr-style sidecar to `mirror-ghcr` + `mirror-docker-io`; ArgoCD rolled both 2026-10-31 12:45:30Z
  and the warmer logs show blobs warmed on each. Origin: mcr episode #2892, detector `RegistryMirrorColdBlobAbandoned` (#2888).
- **FU-152** *(archived 2026-10-24)* — **One version file for the agent-coordinator image.** agent-coordinator#27
  (10-15, deploy-pin sweeps the Composition + gc-mirrors) + homelab#2593 (equality check in `manifest-lint.sh`, closes
  #2566); first bump PR #2751 (10-20) moved kustomization + images.env + all 5 Composition literals + gc-mirrors
  together, CI green; live: every per-stack CronWorkflow runs `2026.10.20-g950b7f0b8201`.
- **FU-202** *(archived 2026-10-24)* — **Key-class failure struck the MODEL.** Built #1253 (09-02); organic proof
  homelab#2181 10-06: `KEY-RETRY: … error_class=budget-exhausted-key` → same round re-dispatched with a fresh
  per-session key on the salvaged branch → PR#2309, merged.
- **FU-281** *(archived 2026-10-24)* — **Goal-checkpoint trigger side woke on nothing.** Holds (b) #2574 + (c) #2594
  (10-15). `goal-checkpoint` wakes: 37 in the 9 d before → 1 in the 8.7 d after (a real new member, #2601), while the
  other clauses kept firing.
- **FU-131** *(archived 2026-10-24)* — **Cost-ledger accuracy: DONE.** Harvest backoff + `openrouter_generation_harvest_total`;
  the T+1 sweep dropped (10-14) for the belt `OpenRouterGenerationHarvestMissing` (PR#2575, homelab#2564 closed), which
  fired on day one of the 10-15 upstream `/generation` 404 outage. agent-runtime#173 fixed by agent-runtime PR#175
  (a standing-key ride publishes no `cost_usd`; in agent-base 2026.10.23). Live 7 d: missed 0, stored 77.
- **FU-210** *(archived 2026-10-24)* — **Responder transcripts: acceptance MET.** PR#1749 capture + the ADR-148 `now`
  lane: `homelab/alert-e9dd1b29d198f98d/responder-r1-20261020T073953Z/` holds a report-only triage (verdict `none`)
  whose `triage.log` is a readable decision (Verified/Assumed/Fix surface/Next step) beside its `finding.json`.
  Mechanism: observability-and-retro.md §A1.
- **FU-204** *(archived 2026-10-24)* — **C4/C5 bare-mention exclusion (silent-stall limbo, fleet#345).** Shipped
  homelab#2562 → PR#2582 (df4a6105, 2026-10-15): `C4C5_SEL`'s open-PR test, the IL-T27 belt and the c4c5-derivations
  report read `STRONG_LINK_JQ` (the #1720 precedent); replay family `c4c5-open-pr-link` reds on the bare-mention base.
- **FU-051** *(archived 2026-10-24)* — **Dep bump flows E2E for every shape.** Last leg (openrouter-operator) PROVEN
  2026-10-13: Renovate #90 (python:3.15-slim) → deploy build failed (`uv sync`, aiohttp has no cp315 wheel) → fix #93 →
  homelab#2529 deploy PR bot-reviewed + bot-merged in 6 min. Gotcha: a base-image major can need a human dep
  fix-forward; the pipe itself held.
- **FU-198** *(archived 2026-10-15)* — **Argo lock-plane wedge: the retry backoff no longer holds a subscription slot.**
  Belt `ArgoLockPlaneWedged` (PR#1722) + upstream leak fixes (v4.1.4, 10-05) stood; the 10-09 five-slot
  wedge was retry backoff holding the semaphore. Ruled 10-14 (retry on a wrapper, lock on the leaf) →
  #2573 (`respond`) + #2581 (`deep-dig`), merged 10-15. Proof: a semaphore-1 toy + control on #2563 —
  the sibling ran inside the backoff on the new shape, queued ~2 min behind it on the old.
  Postmortem: `incidents/2026-08-31-argo-semaphore-leak.md`.

- **FU-279** *(archived 2026-10-14)* — **Garage-side incomplete multipart uploads in the `registry` bucket, uncollected.**
  Operator ruling 10-14 (the 08-24 ☠ was about a bucket under recovery): 6 MPUs aborted by upload id (S3
  AbortMultipartUpload; one held 410 parts / 4.3 GB), then the 16 objects (21 GB) deleted and the bucket destroyed
  with FU-280. Order matters: Garage's DeleteBucket ignores MPUs. 0 block resync errors on all 3 nodes after.
- **FU-032** *(archived 2026-10-14)* — **wk-metal-02's flaky wired link: closed — the 10-12 "recurrence" was deliberate.**
  2026-08-07 (homelab#117): a 4.5 h flap storm (`carrier_changes` 2→3778), bad-cable class. The 2026-10-12
  16:30–16:52Z flaps (carrier 2→6, kube-controller-manager restart 16:56Z) were the operator moving every laptop to a
  new switch, power + network pulled with NO declared window, to watch the behaviour: the CP came back at once.
- **FU-260** *(archived 2026-10-14)* — **Argo controller configmap-watcher hot-loop on an apiserver restart**
  (v4.0.7, 96 % of Loki). Live v4.1.4 (chart 2.0.11). Apiserver restarts 10-07/10-09/10-12 → 0 "invalid config
  map" lines, controller ≤0.03 core over 10 d. The fast-strap question went with the cause.
- **FU-296** *(archived 2026-10-14)* — **governance-lint's worker match had no self-test (drill D3 #2092).**
  Test + task + diff-ci row PR#2201; ci.yaml step ce3fcfb3 (10-10); gate-drift reads BASE ci.yaml + MAP, so
  legs A/B select `governance-lint-test` for any `scripts/governance-lint*` change. No PR has exercised it yet.
- **FU-312** *(archived 2026-10-14)* — **Bulk pulls through HAProxy stalled on pf `BAD state` (pfsync echo, FreeBSD 15.1).**
  Both legs off pfsync: client #2532, router→backend #2535 (applied both nodes 2026-10-13 ~16:50Z). Proof: 0 `BAD state`,
  stale/state-mismatch flat; oracle's 8.5 GB ert-corpus pull finished on one connection (17:22Z). No cause-level belt
  (pf counters not exported). Residual slowness = the registry volume (FU-280). Evidence: router-move.md, the **pfsync** paragraph (`nopfsync`).
- **FU-304** *(archived 2026-10-14)* — **wk-metal-02 holds the apiserver under GOMEMLIMIT; the CP role stays.**
  2026-10-05 OOM-kill (argo-workflows CRD re-apply) → GOMEMLIMIT=3200MiB on all CPs (PR#2268) + helm
  `max_history = 3` (PR#2267). Week soak 10-05→10-14: `ControlPlaneNodeMemoryLow` never fired (pending 3×, min
  MemAvailable 33.7 % vs 35 %), apiserver peak 3.07 GiB. Thin margin — a CRD-heavy chart sync is the trigger.
- **FU-046** *(archived 2026-10-12)* — **The reviewable-dep-bump path, end to end: PROVEN on both lanes.**
  Majors rode the `unarmed-major` unit since 09-28 (~30 PRs through `major/awaiting-human`; #2033 adapted on its
  Renovate branch). The non-major lane flew 2026-10-12 after the operator's ruling ("it should just work until it
  cannot — worker fixes like a major, five rounds then a human"): #2521 widened the unit to an armed `deps-review` PR
  that is red or changes-requested (the reflex is green-only, the ci-red dispatcher loop-author-only), five
  `state-fp:unarmed-major:` markers → `agent/arbitrate` (the budget re-opens on a ruling). sleep-tracking#191 (lock
  refresh carrying ruff 0.17, red for days): ridden at the 19:00Z tick, the worker pushed the fix to
  `renovate/lock-file-maintenance` in 155 s, reflex APPROVED 19:13Z, updater current 19:14Z, MERGED 20:01Z (the one
  red in between was the #184 render-gate flake, fixed in sleep-tracking#193). Both open clauses held: Renovate let
  the edited branch go, the worker pushed to `renovate/*`. Relates ADR-141, ADR-153, FU-058's retro lane.
- **FU-301** *(archived 2026-10-11)* — **`helm_release` applies on the box: evidence first → the box applies them on its own.**
  Ruled 2026-10-10 (forward only, evidence-bracketed, stop + alert, never revert); the 1-replica refusal became the
  HOLD (#2490 → #2491, operator 2026-10-11: "box + Argo do it on their own"). **Closed by the first CONFIRMED Longhorn
  bracket, unattended end to end, 2026-10-11:** chart 1.12.1 → 1.13.0 applied 07:04:57→07:17:46Z (15/15 rolled, BGP
  26/26, robustness unchanged, verdict `ok`), then `mgmt-helm-engines` 07:22:33→09:00:14Z: 42/42 engine moves, 9 holds
  (garage ×3, CNPG ×5 incl. primaries failing over — 187–195 s detaches, forgejo/infisical/grafana), 33 consumer checks
  whole, 42 lease renewals, CONFIRMED, lease deleted, window closed, no STOP marker. Records
  `s3://helm-evidence/20261011T070302Z-box-longhorn-1.13.0/` + `…T072216Z-box-longhorn-engines-1.13.0/`. Defect found
  by the run: the apply loop misread the running oneshot (#2495). Ruling the run produced (operator 2026-10-11, recorded
  in management-box.md §Helm release applies): progress/outcome alerts read CLUSTER truth, the box emits lifecycle only —
  built as the EngineImage/Volume KSM belt + the cluster-side lease reader (S9). Ledger row: management-box.md §The
  capability ledger.
- **FU-302** *(archived 2026-10-10)* — **The box's own Prometheus-free view of the cluster: built.** PR #2452:
  `mgmt/scripts/mgmt-verdict.sh` (`devbox run mgmt-verdict`, JSON, exit 0/2/3) — Talos API, kube API via
  the CP VIP, cilium BGP + probe 3 by exec, LAN HTTP to the BGP VIPs, node Ready, ArgoCD health,
  Prometheus/Alertmanager `/-/ready`; ANDed into `mgmt-apply` (DOWN defers, Talos post-check) and
  `mgmt-reconcile` (DOWN refuses a sync), not into the lease loop. Live on the box: `ok` agreeing with
  Prometheus; `--prom` dead → `degraded`, direct reads intact. FU-301's helm swap point calls `mgmt_verdict` + `mgmt_verdict_poll` (the swap is that lane's).
  [`management-box.md`](management-box.md) §The box verdict.
- **FU-308** *(archived 2026-10-09)* — **An unattended router proof can sever the seat's own path and nobody
  reverts.** PR#2399: `carp-maintenance <node> enter` arms a sleeper ON the node (pidfile + `kill -0`) that
  runs the maintenance toggle after `DEADMAN` s (default 900) iff demotion ≥ 240; `leave` disarms, `status`
  shows it. Drilled live 2026-10-09 in the window-2 WAN leg: fired at 360 s, nx-02 MASTER + WAN back in ~2 s.
  Gotcha: never `pgrep -f` the sleeper's path (matches the ssh `sh -c`). GAPS maintenance-window-G6 keeps
  the skill-side half (the "does your session ride what you move?" question).
- **FU-295** *(archived 2026-10-06)* — **The box sentinel never reported on goal/** PRs.** PR#2299: goal/**
  heads get an immediate base-pass `success` ("box surface judged at the assembly PR to master"); assembly PRs
  to master are still fully planned. Verified live on Goal #2273's children (7/7 success, merges resumed).
- **FU-151** *(archived 2026-10-04)* — **First-party `-iac` deploy bumps skipped LLM review by TIMING, not
  design.** Every deploy-pin now labels its -iac PR `automerge`+`dependencies` on every run: sleep-tracking
  (`5b8c384`), snore-recorder#43, circles#97 (+ its `specs-pr-route.sh` route PRs, the reviewer's catch).
- **FU-097** *(archived 2026-10-03)* — **The box's capability ledger.** Ledger (#1893, [`management-box.md`](management-box.md)
  §The capability ledger), first toggle (Talos config, `no_reboot`), the intent-review instruction in
  `.agents/review.md` (c8e38675) and the generated dependency-class table (#1992/PR#2028) all live.
- **FU-224** *(archived 2026-10-03)* — **transcripts-viewer bucket-sync CFS throttling.** PR#1519 fixed
  longhorn-manager + cilium-agent; bucket-sync stays ~51 % throttled at any limit, but its measured cycle is
  344–374 s against the loop's 300 s sleep (~45–75 s of work) — the lag is the sleep, not CPU; no raise.
- **FU-150** *(archived 2026-10-03)* — **"CI cannot dispatch" alerting:** `GithubVendorOutage` + `CiDispatchStalled`
  live; CiDispatchStalled fired on a real stall (the 2026-09-13 zombie run 34748702282 in the GitHub outage) and
  resolved. Analysis: [`incidents/2026-08-07-arc-listener-wedge.md`](incidents/2026-08-07-arc-listener-wedge.md).
- **FU-148** *(archived 2026-10-03)* — **The environmental CI-red retry terminal** (App `actions:write`, retry
  once with a stated diagnosis) passed its first organic case: homelab PR#1538 (2026-09-10) diagnosis → rerun
  → green, auto-merge intact; a dozen `class=environment|infra` rulings since.
- **FU-154** *(archived 2026-10-03)* — **Close-and-re-PR reset `RED_ROUNDS_MAX`.** The round count is
  issue-keyed, summed across every PR referencing the issue (homelab#156), in both the scan's ci-red clause
  and review-reflex's verdict ceiling — live on master since August.
- **FU-219** *(archived 2026-10-03)* — **`coordinate-perstack` exit 141 (SIGPIPE)** = the `coordinator-scan.sh`
  parity-assertion `| head -1` under pipefail (responder #1547). Fixed PR#1576 (09-14); 10-03 Loki read: 0
  Failed/Error/141 against 4025 Succeeded perstack runs in 7d.
- **FU-129** *(archived 2026-10-03)* — **`gh issue view --comments` printed nothing for zero-comment issues** —
  a comments-only view (gh semantics, not image/token). Every stack recipe now reads `--json title,body,comments`;
  sleep-tracking was the last (sleep-tracking#168), so the next `new-stack --from` donor is clean.
- **FU-212** *(archived 2026-10-03)* — **respond-* runs Errored on `configmaps is forbidden`.** The write
  was Argo v4.0 offloading an oversized pod template into a ConfigMap; granted cluster-wide by
  `controller.rbac.writeConfigMaps` (PR#1678, 2026-09-14). Verified `auth can-i` across 5 namespaces;
  0 forbidden Workflows among 155 live.
- **FU-246** *(archived 2026-10-03)* — **Talos ≥ v1.13.10 on the workers (`page_table_check`, siderolabs/talos#13496).**
  Fleet on v1.14.1 since the 2026-09-22 rollout; PXE/USB pins lint-held (2026-09-23). Soak clean:
  no `NodeRebootingRepeatedly` after 09-23 14:05Z (nx-01's pre-rollout boots aging out), zero
  `page_table_check|Oops:` lines in Loki 09-26→10-03. Incident: [`2026-09-16-page-table-check-reboots.md`](incidents/2026-09-16-page-table-check-reboots.md).
- **FU-300** *(archived 2026-10-02)* — **The box's apply loop is window-blind: fixed.** PR#2183 (built by a
  background subagent the same day): `mgmt-apply.sh` defers (no plan/apply/stamp/refusal) while a live
  declared window holds it; `--admit-apply` lets the box through; an unreadable registry defers as a
  PROBE-FAIL; gauges `mgmt_apply_deferred_window*` + `MgmtApplyDeferredByWindow` (6 h). Gotcha: the
  reconciler's node windows hold the apply loop by design. [`management-box.md`](management-box.md) §MB3.
- **FU-294** *(archived 2026-09-29)* — **A vulnerable transitive via Renovate, caught only by an LLM
  reviewer (#2032, lodash-es@4.17.23 under mermaid 12): fixed structurally.** [ADR-143](adr.md): PR#2098
  (mermaid-lint on Deno, zero permissions) + `lock-intake-lint` in `ci`; PROVEN live on Renovate's
  #2100 (red on the lodash-es intake, no reviewer). Ride drill PR#2101: Deno cannot use an IP registry
  → `npm-cache.teststuff.net`; kill-switch dropped. #2100 waits for mermaid-js/mermaid#8278 — no pin.
- **FU-125** *(archived 2026-09-27)* — **Renovate's silent zero-PR regression: root cause fixed, the
  homelab acceptance MET.** Cause: the App never held `statuses` (403 on read → `integration-unauthorized`,
  on write → `repository-changed`); declared PR#1969, granted 2026-09-25 → 20 PRs on 10 repos in the first
  run. Acceptance ("one `renovate/*` PR opened, gated, merged in homelab") met 2026-09-27 through the S9
  lanes (homelab#1985): #2008/#2021 (Actions, grouped mechanical), #2012 (npm), #1983/#1996/#1997
  (providers, human plan). Per-class proofs: `docs/dependency-upgrades.md` §"Last proven end to end".
  Residue owned elsewhere: the liveness gauge + coverage table → #1992; `NIX_VERSION` manager hygiene →
  that doc's §Next steps. `dependencyDashboard: false` stands (ruling 2026-08-18).

