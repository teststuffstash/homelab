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

- **FU-290** *(archived 2026-11-23)* — **homelab-agents pool drains.** Detectors live (#1979 graphql, #2442 core);
      label writes → REST (#2483/#2484), loop storms fixed (#2204/#2366). No drain in the 18 d Prometheus held on
      11-23 (coordinator-git min graphql 1215 / core 2157). Build the per-consumer meter on the next
      `GithubRateLimitLow{token=~".*-git"}`.
- **FU-324** *(archived 2026-11-23)* — **Coordinator double launch under `timeout 590`.** Not built — moved to the
      launch island (LAUNCH-POD-IDENTITY beyond pod create): homelab#3713.
- **FU-174** *(archived 2026-11-23)* — **Reasoning effort unmodeled.** Not built — moved to the gateway (policy, not
      the old `model-classes.json`): homelab#3714.
- **FU-170** *(archived 2026-11-23)* — **Go-rail spend/limit residual belts.** Window-draw admission (0.80, gateway
      `policy.json`) covers the near-limit leg; the account-headroom read that makes the jail-ingest gauge moot is
      the gateway's: Goal #3118 (post-launch) + #3538 (console read 403s — `GoCatalogStale`).
- **FU-181** *(archived 2026-11-23)* — **Go-rail meter-vs-console parity.** Moot once the gateway reads the account's
      own headroom — same home as FU-170: Goal #3118 + #3538.
- **FU-307** *(archived 2026-11-23)* — **No belt for "the pair's MASTER has no WAN".** Not built — moved to
      its island: homelab#3711 (router-pair intake; `RouterMasterWanDark` from the gate's carrier export).
- **FU-310** *(archived 2026-11-23)* — **dind tries HTTPS first against the HTTP-only mirrors.** Not built — moved
      to the launch island (rebuilding the launcher): homelab#3712, means decided by its intake.
- **FU-286** *(archived 2026-11-23)* — **Box talosctl flake-ref pin reverted to `latest`.** PR#1963's nixpkgs-rev
      pin (devbox index stuck at 1.13.8) switched back by #2899 (10-24, `latest` = 1.14.2; lock resolves nixpkgs
      e126e9e7, 11-13). `mgmt_probe_check{check="talos"}` = 1, 30-day minimum 1.
- **FU-186** *(archived 2026-11-23)* — **Provider selection priced per successful job (ADR-115).** Step 1
      (Exacto suffix on paid OpenRouter picks, PR#1639) stood on the old router; #1238 closed superseded
      2026-11-01 and per-job provider pricing is now the gateway's tier evidence (GW-MODEL-TIERS). Design
      record: [`spikes/model-routing-history.md`](spikes/model-routing-history.md) §M14.
- **FU-313** *(archived 2026-11-16)* — **OpenCode Go key: 30-day key → service-account key.** The operator minted a 1-year
      service-account key (permission `models: request` only) and rolled it 2026-11-16 (ExternalSecret synced 18:43:59Z,
      `agent-gateway` + `openrouter-proxy` restarted 18:44Z). Probed with the deployed key: `GET /console/api/v2/config` 200,
      `/zen/go/v1/chat/completions` 200. Expiry ≈ 2027-11; the pre-expiry warning stays FU-156's declared half.
- **FU-218** *(archived 2026-11-02)* — **ARC runner memory: a node-sized limit, not node removal.** Closed on the static
      class pair (#3132, LIVE 2026-11-01: `normal` 3Gi + 1Gi dind, `large` 12Gi on nx-01 max 2, oracle-fleet `ci` on
      large) — ADR-159; option A's resize controller (spiked PR#2185) is not built, nx-01's free DIMM slots retire the
      spare-memory question. Record: [`spikes/arc-runner-memory-budget.md`](spikes/arc-runner-memory-budget.md).
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


