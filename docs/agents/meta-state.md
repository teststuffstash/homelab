# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)

**`dig-explained: <Alert>[, <Alert>…] — <reason>`** is the ONLY line here the deep dig (ADR-148,
`agents/deep-dig-select.sh`) reads as "this alert is explained"; a bare mention — the standing-alerts
list every wind-down writes — does NOT count (#2526, 2026-10-12: `RegistryMirrorDanglingLinks` hid from the
dig for days by being listed). Write the marker only when the cause is known; the reason rides into the dig's record.


dig-explained: RouterRunModelUnverifiable — ad-hoc probe rides with no served-side evidence in the OLD router's 7-day run_reports window (the class = #2555): the two 2026-10-11 probes (platform/worker v4-flash) plus, read 10-18 19:40Z, platform/worker v4-flash=4 / v4.1-flash=2 and oracle/worker v4-flash=1 — the 10-17 gateway canaries + v4.1-flash admissions (#2694/#2707) ride the gateway, which the proxy's harvest never sees (mechanism from TICK-LOG 10-17/18, NOT from the run_reports rows — a dig may confirm). Ages out ~2026-10-24. Delete this line once it clears.

## Live state (pruned 2026-09-26 by the fu-sweep — every bullet re-verified against GitHub/the cluster that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ PICKUP (2026-10-20 ~15:25Z) — wk-metal-04 BACK on new hardware (Big Data, #2758).** The dead i5-3570K's 7600p
  pair + 2×8G moved into the retired router (HP i5-2500, 24GB); Talos on its MX500 (wwn pin), node Ready, BGP up,
  garage-0 rejoined with its old node id (1-replica PVCs auto-salvaged from intel1), registry-data rebuilding.
  Open: (a) the MX500 reads 34 % lifetime used (attr 202) — fine for a system disk, watch it; (b) `sata500` Longhorn
  disk is now the MX500's /var/lib/longhorn (fenced slow-bulk, 0 replicas — name kept, longhorn-tag-disks.sh owns
  it); (c) operator: switch port (docs/network-physical.md) + whether `sensor.plug_opnsense_power` still meters the
  box (router-move.md:62 retires it); (d) NodeCPUHighUsage cp-01 since 15:00Z handed to the responder.
- **⚑ PICKUP (2026-10-19 ~21:55Z — the overnight gateway session; TICK-LOG 10-19 20:30–21:55Z): #2741 + #2742 MERGED
  as #2744 (294c7b81, four specs-review rounds, all test/spec-text); #2743 NOT started.** What landed: provider
  attribution / own selection / request-level failover on the openrouter rail (`providers.py`, the proxy attempt loop,
  `strikes`/`requests.provider`, `rails.openrouter.providers`), and GW-CATALOG-OR (`orcatalog.py`: the MCP weekly ranking
  ∩ AA-benched → endpoints per candidate, the persisted snapshot, cells candidate/eligible/excluded, the `canary: {model,
  provider}` admission, `canary-budget`/`canary-not-due`, nine families, three alerts + promtool fixture,
  `gateway/scripts/canary-entrants.sh`, `AGENT_GATEWAY_ROLE`/`AGENT_GATEWAY_CANARY` + the `dispatch-canary` replay row).
  **Verify after the deploy (the image for 294c7b81 built 21:52Z; its auto-bump PR #2746 is the machine lane's; the policy ConfigMap roll follows):**
  `kubectl -n agent-egress logs deploy/agent-gateway | grep orcatalog:` shows the first refresh (the account key resolves
  through the new agent-egress Role; the MCP answers; N models with endpoints), `gateway_openrouter_catalog_models > 0`,
  `gateway_openrouter_cells{state="candidate"}` > 0, no `OpenRouterCatalogStale`; **the data plane changes nothing by
  itself** — every cell is `candidate`, every openrouter request rides unpinned until canaries make cells eligible:
  `bash gateway/scripts/canary-entrants.sh --dry-run` lists them, without `--dry-run` rides them (jail, port-forward, the
  prober role; ⚑ gap: no in-cluster trigger). **Lesson:** a PR stacked on a feature branch here auto-merges INTO it
  unreviewed (no protection on a feature base) — #2745 did; base everything on master. **#2743 next (fresh session,
  island context = `gateway/specs` + `gateway/src` + the issue + the #2718 plan comment):** the Go side's price (⚖ a policy
  `plan_fee_usd_month` ÷ the gateway's metered monthly Go tokens; the window draw as the headroom gate — both in
  capacity.py), Go quantization undeclared → ⚑ gap row, cost per clean ride per cell = price × (1 / clean rate from
  `store.cell_outcomes`) + a ⚖ policy strike-overhead term, `tiers.py` ordering candidates across BOTH rails by it (the
  openrouter candidates switch from `model-classes.json` to `GET /catalog/openrouter`'s `selected` endpoint — #2718 item 4
  closes there; production has zero eligible cells until canaries run, so the re-cut waits on them), the
  `(opencode-go/<id>, <vendor>/<id>)` same-model join by the GW-MODEL-TIERS tail rule, the admission answer's reason +
  `gateway_rail_choice_total{model,rail,reason}`, the rows the issue lists. The specs reviewer's recurring asks this
  session: every judgment row ⚖ + listed under `Spec changes:`; ≤ 8 attachments PER CASE (each then_eq is one); a
  parametrize value must appear in a step text; a glossary term redefined must be re-read on every page that names it.
  **Operator-only, untouched:** FU-313 Go key mint, the codex login (leg E), the canary window; #2741 item 4's
  "sessions dashboard" does not exist in the repo (no dashboard carries a `gateway_*` series) — filing one is the
  operator's call.
- **⚑ PICKUP (2026-10-18 ~20:00Z — seat, S9 self-serve while the operator sleeps; TICK-LOG 10-18 evening): the python
  3.15 Renovate wave is PARKED org-wide on nixpkgs** (`python315` = 3.15.0rc2 only): #2610 carries the oracle-fleet #883
  ruling + an `Un-park:` line (the seat, when nixpkgs ships a non-rc 3.15 — the four-member move is proven green on the rc in a
  dry run, uv.lock drops only typing-extensions); **circles#124 is the same wall, `agent/in-progress`** — stack-side, its
  worker will hit the set (the operator's read). Class fix **#2720** (gateway python version-set assertion, the oracle row-5
  shape; approved, auto-merging) — a one-member bump reds `ci` naming the odd members. **S9 #2014's seat consumer:
  claude-jail#10 merged** (Dockerfile pins claude-code to the stamp; the HOST REBUILD is the operator's — clears
  `VersionSetBehindPin`/`MembersDisagree`); docs #2721 (class 11 proposer ok, §Version SETS row, table regenerated).
  **Board, not S9:** `ArgoCDAppDegraded snore-recorder` since 12:40Z (sleep stack, no non-healthy resource listed —
  stack-side); `MgmtOpnsenseDrillScoreRegressed` 57 (FU-297's click-ops read); `LonghornDiskFillingUp` wk-metal-04/intel1
  88.9% (FU-093 class); `RetentionLedgerPruneRemnant` (oracle). No 3.15 handoff in either inbox (circles 1, oracle 9 unclaimed).
- **⚑ PICKUP (2026-10-18 ~19:30Z — seat wind-down; TICK-LOG 10-18): the gateway's tier lists are now DERIVED from
  benchmark evidence** (FU-270, #2716 — operator ruling: no hand-picked model ids; AA intelligence bands of the rail's best,
  cheapest-first, cap 3; `argocd/resources/agent-gateway/benchmarks.json` + `tiers check`; refresh = `gateway/scripts/benchmarks-snapshot.sh`
  → PR). Live light head on Go = `mimo-v2.6-flash`. Also landed: specs reviewer on its own SA (#2710, #2685 closed), session pod
  mounts the gateway caller token (#2713, inert), evidence hygiene zero (#2709), static Go fixture retired (#2712), responder
  scratch race fixed (#2717, #2600 closed). **Needs the operator:** (a) the openrouter candidate set — with ALL `model-classes`
  ids, heavy/standard = kimi-k3 alone ($11.94/1M out); the `coding` chain (2 deepseek ids) is the alternative, one script arg;
  (b) the `wrong-verdict` judge source (candidates: deploy-revert of an approved PR, a contradicting re-review on resight, the
  retro) — the spec already has the judge SA/role, nothing reports; (c) FU-313: mint an "Inference only" service-account key
  (scope settled, covers the only console call). **Next seat work:** the loop flip = `AGENT_GATEWAY=sessions` into the
  session-pod heredoc; `context_tokens` from the catalog's `context` (null for the new Go heads); #2718 gap rows; #2684 waits.
  **opencode 2.0 re-check (held, facts):** v2 is a NEW package (`@opencode/cli`, brew `opencode-v2`, docker
  `ghcr.io/anomalyco/opencode:2.0.0`), not in nixpkgs — the worker image's devbox `opencode@latest` = 1.18.18 and the 1.x line
  continues (1.19.3, 2026-10-16); v2 renames `provider`→`providers`, nests MCP under `mcp.servers` with `disabled` (no `enabled`),
  stores credentials in SQLite, documents no `OPENCODE_CONFIG_CONTENT` — every GW-SESSIONS-ENV opencode row would change; hold stands.
- **⚑ PICKUP (2026-10-16 ~16:00Z — seat; TICK-LOG same date): ADR-156 evidence pass LIVE** (snippets v0.5.2 pinned
  in `agents/specs-reviewer-session.sh` + `gateway/scripts/lib/snippets.sh` — bump TOGETHER; canary #2628 approved).
  **Next:** (a) step 5's measurement — per completed PR: tokens, worker rounds, invalid findings, coordinator
  interventions (design: `docs/agents/specs-reviewer.md` §The portable process); first wide PR will show whether
  14-rule packs fit the 600 s / context budget; (b) allure-behavior-snippets' 0-approval ruleset stays (operator,
  2026-10-16: "fine to have no review for now"); (c) oracle-fleet stays on its own process until the operator says the
  gateway has proven it; (d) FU-270 (1): live streamed usage reads `in=0 out=0`.
- **⚑ PICKUP (2026-10-16 ~22:40Z — seat, P2 overnight build; TICK-LOG same date): `agent-gateway` BUILT + LIVE in
  PARALLEL (#2606, `gateway/`, SERVICES row LIVE), three rails canaried; the old router untouched (operator, 10-15).**
  **NEXT:** FU-270's three next steps (launcher `/sessions` for one platform role; specs-lens wiring — identity
  question in `docs/agents/specs-reviewer.md`; the ladder as GW rows). Verify `gateway_tokens_total` appears after a
  200 (did not in the canary). The sonnet-class 429 seen 22:19Z was upstream (old proxy too; haiku fine) — recheck once.
- **⚑ PICKUP (2026-10-15 ~19:50Z — seat, design-agents "codeowner reads"; TICK-LOG same date): every read
  merged, FU-198 archived, all five agenda items ruled.** P2 DONE 10-16 (bullet above; access inventory =
  `gateway/specs/access.md`). P0 #2597 MERGED (#1935 closed). **#2588 QUEUED + riding** (updater: refresh a red PR whose newest run predates master's newest green — ONE predicate in the existing pick, operator 10-15) — its PR parks on the codeowner read. agent-runtime#176's
  finalize half goes live with the next agent-base deploy-pin (automatic). The per-stack loops jumped
  agent-coordinator 2026.8.7 → 2026.10.15 (#2592) — first suspect for any stack-loop oddity. **Open, inert, filed
  today:** #2589 (S8 entry 20 — stint #1418 NOT closable until it lands),
  #2600 (responder harness /tmp race). **OpenRouter `/generation` 404s account-wide since ~17:59Z** —
  `OpenRouterGenerationHarvestMissing` firing; upstream, nothing to fix; confirm it clears.
- **⚑ PICKUP (2026-10-14 ~21:30Z — seat, design-agents corpus session; TICK-LOG 2026-10-14 design-agents batch):
  the 19:45Z batch is DONE except its "operator decides" bucket.** **NEXT PRIORITY (operator): the new router —
  `agent-gateway` (FU-270/ADR-139): opencode-go + codex rails, a router that works as an ISLAND** — start it from
  FU-269/FU-270/FU-127 + `docs/spikes/codex-subscription-rail.md`; it is design-agents-shaped (ask full/slice).
  **Deferred by the operator, NOT today:** every Agents-block item needing an operator decision (FU-218/220/292/180/
  095-flip/174/311/256, FU-059 W2+, FU-094). **Rulings landed 10-14 → queued builds (watch, then the seat acts):**
  #2562 (FU-204, C4/C5 strong link), #2563 (FU-198 — then the seat's toy semaphore probe), #2564 (FU-131 belt),
  #2565 (FU-281 (c), blockedBy #2477), #2566 (FU-152 — merge only AFTER agent-coordinator#27), #2567 (FU-306 tofu
  half — then the seat adds the Renovate regex manager to `.github/renovate-global.json`, operator-direct).
  Admitted + queued: #2477, #2412, #2178 (narrowed to Half 1; Half 2 = #2561, blockedBy #2178 — must not land
  first), agent-runtime#173; #1669 unblocked + queued with the seat's read (STANDING — the Goal #1640 verdict is the
  operator's). Docs/skills comb = the `fix/agents-docs-comb-2026-10-14` PR (IAC-G01/G04 + IL-G04 closed, IL-G07
  re-disposed, meta-coordinate/board-sweep rulings). **Not agent-platform (seat, any session):** FU-280 — the
  operator picks the pve-uplink path fix; the `intel1` replica wants moving off in a window either way.
- **⚑ PICKUP (2026-10-13 17:20Z — seat; TICK-LOG 2026-10-13 15:45–17:20Z): FU-312's pf class CLOSED on both legs
  (#2532 + #2535), #2533 applied, #2534 closed, VIP ingress = wk-04 by FRR weight (#2536), router nodes named
  (#2537 + bd57ba5d).** The stall COUNTS of every A/B were FU-280's volume (4 MiB reads at 0.5–8 s, ~8–10 MB/s; 22/32
  trip with the router out of the path). **OPERATOR:** (1) the oracle ingester's 8.5 GB ert-corpus pull (`oracle-fleet-ingester-riigiteataja-mcp`, wk-01)
  finished at 17:22Z (2/2) after one kubelet cancel at 17:06Z (no progress 5 min while the seat's proof pulls starved
  the volume); one attempt ≈ 15 min at the volume's ~10 MB/s — FU-280, no longer pf. The four claimed alerts resolve
  with it. (2) FU-280's next step is now the registry's real bottleneck — the pull
  takes ≥15 min a node at the volume's ~9 MB/s. (3) GAPS `opnsense-as-code-G1`: the test-VM script's env line + its
  play set (opnsense-system never runs there; #2537's green report proved nothing). Standing alerts: unchanged from
  the 06:25Z pickup plus `CPUThrottlingHigh` longhorn-csi-plugin (handed off), `ErtPipelineStepFailed` (oracle's own
  `argo stop`, handed off).
- **⚑ PICKUP (2026-10-13 06:25Z — seat; TICK-LOG 2026-10-13 05:45–06:25Z): the platform repos' codeowner gate
  narrowed (ADR-154); #90's 3.15 image fixed forward and LIVE.** openrouter-operator#92, agent-coordinator#26 and
  agent-runtime#172 all MERGED on the bot approval (author == sole codeowner waiver, no admin act); agent-runtime's
  `ci.yaml` comment currency pushed direct (15c30b1, a workflow edit). **Proof owed (ADR-154 / dependency-upgrades §Last proven):** the next Renovate PR on
  each of the three repos merging unattended — openrouter-operator's deploy run after a Dockerfile bump is the real
  image test (PR CI builds no image). **OPERATOR:** (1) the ADR-154 known cost — the census's 4 src/ catches in 10 reads
  on openrouter-operator — is accepted by the ruling, not re-measured; (2) oracle-fleet#759 (python 3.15) will hit the
  same cp315-wheel sdist failure on its image build — stack jail's call. The 10-12 "watch next Renovate run" item is
  DONE (rebases seen 00:13Z/00:31Z, un-armed set drained to two stack PRs). Standing alerts: `GithubWorkflowRunFailed`
  openrouter-operator deploy clears on the 06:16Z success; the rest unchanged from 10-12.
- **⚑ PICKUP (2026-10-13 20:05Z — seat; TICK-LOG 2026-10-13 19:00–20:05Z): r8 F1–F5 EXECUTED, all merged.**
  **OPERATOR:** (1) ~~agent-runtime#173~~ DONE (closed). (2) **Re-rule F3's 402 line:** `add more credits` went
  to the residual `budget-403` arm, not `-account` (goose's one line for every provider 402); (3) **F1 is live on master
  (0aaa6898) untested on a real goal-base PR** — watch the first `goal/**` PR's ratchet step. Standing alerts: not
  surveyed this session (the seat ran the retro execution only; the 17:15Z pickup's set stands).
- **⚑ PICKUP (2026-10-12 20:00Z — seat; TICK-LOG 2026-10-12 17:00–20:00Z): r8 published after two class fixes;
  FU-046's non-major path flew; ADR-153 half landed.** **OPERATOR:** (1) **#2522** (r8 reports) auto-merged — FINE by ruling (operator 2026-10-15: retro PRs may merge on the bot review, the operator reads them after) — read it (`docs/agents/retros/2026-10-12-platform-r8-*.md`; the goose one has no findings
  block, recorded as a defect); (2) sleep-tracking#185 (the zombie) CLOSED by the seat 19:55Z with the reason, branch
  deleted — Renovate's own flagged intent; (3) **ADR-153 fully landed** — #2524 (updater + nudge: Renovate owns untouched PRs' currency,
  merge-ready exception) MERGED 19:48Z, 2bf9c792a. **Stack jails:** six
  `deps-review` Renovate PRs never armed (allure-behavior-snippets#11/#12/#25/#26, oracle-fleet#758/#759) — why Renovate
  never enabled auto-merge there is theirs; the homelab backstop fix is **#2527**, MERGED 20:31Z. **Watch next Renovate
  run (cron */6h):** every untouched Renovate PR gets rebased by Renovate for the first time under the new default;
  expect one CI run per open Renovate PR per master-moving period, approvals surviving. **FU-046 ARCHIVED** (sleep-tracking#191 merged 20:01Z). Standing alerts unchanged from the 10-11 pickup;
  `RetroReportOverdue` did not fire.
- **⚑ PICKUP (2026-10-11 18:45Z — seat; TICK-LOG 2026-10-11 17:30–18:45Z): three seat-residue items closed,
  one drill verdict pending.** **sleep-tracking#67 CLOSED** on a discriminating homelab-namespace probe ride —
  the first ride was NEGATIVE (nix dropped `flake-registry` with flakes off) → **#2502** (feature line first in
  NIX_CONFIG) → ride 2 clean (0 drops, 0 `channels.nixos.org` queries, `cache.nixos.org` > 0).
  **FU-305 lock-revert RERUN hands-off** (#2503 → #2504, 12 min, zero hand acts; register row #2505).
  **FU-297 drill:** the 17:36Z hand start FAILED (build) on the exact `SERIES=26.7.5` point vs the mirror's
  26.7.6_3 head → class fix **#2501** (series declared, converge on the head); run 2 died on my own lock plant
  (the box pulled both at once); **run 3 (18:21Z, HEAD `ad4dfdbc`): **PASS 18:34:54Z** (826 s: build 328 s at 26.7.6_3 — the #2501 head convergence — converge 440 s, every router-code unit applied, 3 config scripts rc=0; realism score **56** vs previous 117, `MgmtOpnsenseDrillFailed` CLEARED). The 56 click-ops rows are the PAIR's prod config vs the single-router rehearsal: `OPNsense/Kea` 36, `virtualip` 17, `hasync` 2 (+1) — FU-297's next read, not a drill defect.**.
  **OPERATOR:** prod routers read 26.7.5 with 26.7.6 pending on the official path (39 packages, no reboot) —
  an attended window (the D2/D3 shape); the probe-ride shape fires `RouterRunModelUnverifiable` (an ad-hoc
  `--run` needs `--model` to pass the chainless guard yet calls no LLM) — a launcher no-LLM probe flag is
  unbuilt, not filed. Board: `GithubCiWallTimeDrift` since 10-09 23:23Z is NOT transient (homelab `CI` push
  median 9m56s; one job `ci`, so the read is step-level — the sweep's, no responder issue). Standing, none S9:
  `LonghornDiskBelowSchedulingFloor` ×2 (FU-093), `MgmtSubstrateBehind`, `RegistryMirrorDanglingLinks`,
  `OpenRouterKeyBudgetLow` (resets Mon 00:00Z), `HomeAssistantPowerSensorStale` ×6, `AgentAttentionStanding`
  oracle-fleet issue-820, `VersionSetMembersDisagree` (the claude-jail host rebuild, operator-side).
- **⚑ PICKUP (2026-10-11 12:30Z — seat; TICK-LOG 2026-10-11 midday): the two parked majors rode through
  without a hand act; argo-cd chart majors ARMED.** **#2488 argo-cd 9.7.1 → 10.9.6 (ArgoCD v3.4.4 → v3.5.3)
  MERGED `061287a0`** by the Renovate rebase box (three rounds on a moving master; the lens APPROVED survived each,
  diff = `tofu/variables.tf` only) and the box applied it through the FU-301 bracket: lease
  `upgrade-lease-tofu-helm-argocd` 10:13:00Z, helm rev 13 deployed 10:13:22Z, **CONFIRMED — `management-apply`
  success 10:25:30Z** ("helm verdict clean"), 81/81 Applications Healthy+Synced, both argocd-metrics targets up.
  **`UpgradeLeaseInFlight` FIRED on that real lease 10:15Z** — the #2498 belt is proven live, not just loaded.
  **#2100 mermaid 11.17.2 → 12.1.0 MERGED `743f52d6`** (Renovate rebase + auto-merge; the parse lint was the gate)
  and **#2499** put mermaid majors on the mechanical automerge lane (`deno`+`mermaid`+major → automerge,
  `deno`+`!mermaid`+major stays un-armed: linkedom) — operator 2026-10-11: "here CI is the only gate needed".
  **#2500 `renovate/arm-argocd-chart-majors`: MERGED `216dfbad` 12:40Z (reviewer APPROVED 12:38Z, CI green, auto-merge; lane lint OK)** — argo-cd + argocd-apps chart majors keep `major`
  with no `automerge` label (the lens's APPROVED completes the merge), `rebaseWhen: behind-base-branch` so Renovate
  owns the rebase #2488 needed three hand ticks for; the box bracket is the deploy edge, forward only; longhorn
  majors stay human (no downgrade). Class-4 lane cell + a §Last proven row in dependency-upgrades.md. Standing
  alerts at wind-down, none S9: `LonghornDiskBelowSchedulingFloor` ×2 (FU-093), `MgmtSubstrateBehind`,
  `MgmtOpnsenseDrillFailed` (clears on the first PASSING drill — timer Sun 10-18 03:34Z), `RegistryMirrorDanglingLinks`,
  `OpenRouterKeyBudgetLow` (resets Mon 00:00Z), `HomeAssistantPowerSensorStale` ×6 (plugs laptop3/laptop4/pve,
  since 10-03 — Tuya plugs offline, not platform), `AgentAttentionStanding` oracle-fleet issue-820 (since 10-08,
  stack-side). Subagent clones under the seat scratchpad were deleted at wind-down.
- **⚑ PICKUP (2026-10-11 09:30Z — seat; TICK-LOG 2026-10-11 morning): FU-301 CLOSED by the first unattended
  Longhorn bracket; the cluster-truth belts are LIVE.** longhorn 1.12.1 → 1.13.0 (#2487) ran on the box with no
  hand act: chart bracket CONFIRMED 07:17:46Z, `mgmt-helm-engines` 42/42 moves + 9 holds CONFIRMED 09:00:14Z
  (records `s3://helm-evidence/20261011T07*`). End state checked: every volume on v1.13.0, robustness unchanged,
  Garage 3/3, CNPG 4/4 healthy, 13 nodes Ready, no STOP marker. **Operator ruling 2026-10-11 (recorded,
  management-box.md §Helm release applies, #2496): upgrade alerts read CLUSTER truth, the box emits lifecycle +
  what is in flight, survives the box gone 24 h** → built: the Longhorn engine belt (#2497, KSM EngineImage/Volume
  series, `LonghornVolumesOnOldEngine`/`LonghornEngineMoveStalled`) + the cluster-side lease reader (#2498, CronJob
  → pushgateway, `UpgradeLeaseInFlight/PastExpectedEnd/Orphaned/ProbeStale/ProbeAbsent`) — both verified in
  Prometheus. **Seen live 10:15Z the same day:** `UpgradeLeaseInFlight` on #2488's argo-cd lease.
  **Also landed:** #2492 (kps check (h) proof; #2486 closed), #2493 (the rebuild drill's preflight refuse — prod =
  the CARP MASTER; `MgmtOpnsenseDrillFailed` clears on the first PASSING run, timer Sun 10-18 03:34Z or a hand
  `systemctl start mgmt-opnsense-drill` on the box), #2494 (spike wave 1: class 9 split + ledger rows), #2495
  (apply loop misread the running oneshot). **⚠ #2219 (the operator-read context-engineering spike) MERGED by
  mistake** — a subagent's plain `pr-wait` armed it (card clause added); content = the rebased branch, the
  operator's read is still owed, `git revert 42ad3aec` if unwanted (GAPS board-sweep-G1 closed with the note).
  **Standing, not S9:** `LonghornDiskBelowSchedulingFloor` hp-01/hg5d + wk-metal-04/intel0 (FU-093's 57 GB
  snapshot; hg5d 77→82 % over 36 h), `MgmtSubstrateBehind`, `RegistryMirrorDanglingLinks` (ghcr 15 repaired
  04:01Z), `OpenRouterKeyBudgetLow` (resets Mon 00:00Z). `GarageClusterFlapping` cleared on its 1 h window
  (every probe failed 21:10→06:45Z — the garage-1 incident, not a new flap).
  **OPERATOR READ — the Argo half of the 10-11 direction ("box + Argo do it on their own"):** Garage's OWN
  updates have no Renovate lane — the image comes from the vendored chart's `appVersion`
  (`argocd/charts/garage/Chart.yaml`, v2.3.0), which no manager watches (`argocd` = Application chart pins,
  `kubernetes` = argocd/resources images; `docs/garage.md` §Updating = re-vendor by hand). ArgoCD auto-syncs
  (prune+selfHeal) once a bump lands, and a pod restart remounts on the same engine (no hold needed). Shape, if
  ruled: a regex customManager on that `appVersion` → docker `dxflrs/amd64_garage`, patch/minor through the
  existing `custom.regex` mechanical rule (Garage belts + the PDB controller are the net), majors human (Garage
  majors carry migrations) — the re-vendor of the chart templates stays a hand step. Not filed:
  `.github/renovate-global.json` is operator-gated and this arms unattended restarts of the one unrecoverable
  release — a ruling, not a seat call.
- **⚑ S9 — what is left (re-verified 2026-10-11 12:30Z against merged PRs; every 10-10 subagent lane LANDED: #2428,
  #2432–#2440, #2444, #2478→#2482, G4 #2436–#2460; #2488 + #2100 rode through 10-11 midday, see the PICKUP
  above).** Operator-side: (1) ✅ **the one-update-process spike CLOSED 2026-10-11 evening** — ADR-152 (#2510) records the
  decision + the router's four differences; the build program (the box applies ansible) is ROADMAP §Deploy paths with
  D3/D4/D8 as its own forks; the docs were trimmed first (#2508 dependency-upgrades 817→627, #2509 renovate 254→174,
  #2507 register rulings current). (2) the claude-jail HOST REBUILD (operator): the 3 workflow patches landed 10-11 (`version-sets-dispatch.yaml` +
  both consumers' `build-image.yaml`) and the jail Dockerfile reads the STAMP since claude-jail#10 (10-18 19:29Z) — the
  rebuild is the one act left; `VersionSetMembersDisagree` + `VersionSetBehindPin` (seat 2.1.301 vs stamp 2.1.293) clear on it. (3) the Argo-half ruling (Garage `appVersion` customManager shape in
  the 09:30Z PICKUP — arms unattended restarts of the one unrecoverable release). (4) ~~the #2219 read~~ DONE 2026-10-15: kept; status section in the spike (#2595). Seat-side residue (re-read 18:45Z): the kps lane's first lens-armed 92.x merge (no
  92.x upstream yet; check (h) PROVEN, #2492); FU-297's first green drill (class fix #2501 landed 10-11 evening —
  see the 18:45Z PICKUP for run 3). DONE 10-11 evening: FU-305's hands-off rerun (#2503→#2504), sleep-tracking#67
  (closed on ride 2 after #2502). The lock-revert "ruling owed" of 10-10 is MOOT — the drill ran that
  evening (#2478→#2480), the wedge was the box's devbox closure (#2457) + governance-lint (#2482), both fixed.
- **⚑ PICKUP (2026-10-09 11:40Z — seat; TICK-LOG 2026-10-09 midday).** **WINDOW 2 WAN LEG DONE — the
  router pair is complete** (window `seat-1791544351-8289`, closed clean): pve's WAN cable in, the proof
  served WAN from pve 6 min, the FU-308 dead-man (#2399, merged) fired the failback on time; nx-02's gate
  restarted while BACKUP (flood-off live on both). router-move §Status = #2400 (merged). **Reads:** (1) FU-297 next = the weekly rebuild drill RED since 10-04
  (`MgmtOpnsenseDrillFailed`, converge rc=2 in 9 s; next run Sun 10-11 03:37Z) — undiagnosed; (2) FU-307
  (`RouterMasterWanDark`) unblocked — the gate's carrier export rides a BACKUP-side restart; (3) **the FU-289 DIMM window is DONE (13:47Z, TICK-LOG 13:37–13:47Z): nx-02 125 GiB, nx-01 64 GB (mixed Hynix/Micron —
  register fact), both windows closed, #2402 landed.** Residue to re-read next session: wk-01/wk-02 at 3793/3888 of 3900 m CPU
  requests from wk-04's displaced pods → `fstrim-guard` OutOfcpu / `ArgoCDAppDegraded node-fstrim` (pods never move
  back); **DONE 15:05Z (TICK-LOG 14:05–15:05Z): #2403 exception, #2404 PriorityClass `node-maintenance` + affinity on the 10 fstrim
  CronJobs (live: two preemptions, guard green, alerts gone 14:38Z), #2405 Kyverno `pinned-pods-priority` (Enforce) +
  `cronjob-needs-priority` (Audit, 10 warnings, sentinel `--audit-warn`).** The descheduler is **FU-309** (operator-deferred, 15:10Z); open for the operator: whether the 10 Audit-warned CronJobs
  get a class each; `coordinator-sensor` crashlooping; HA plug sensors
  laptop3/laptop4/pve stale since 12:51Z; the RAM re-plan for nx-02's VMs is the operator's; (4) loose: both router nodes carry the hostname
  `opnsense-test.teststuff.net` (seed carry-over, cosmetic, not sent to the ISP).
- **⚑ PICKUP (2026-10-09 05:00Z — seat; TICK-LOG 2026-10-08 evening → 10-09 morning).** **Window 2 DONE:
  pve's node is the CARP BACKUP (Kea HA standby, BGP peer .71), WAN cable still OUT** — the WAN leg of the proof
  waits for the cable (then: `carp-maintenance nx02 enter` → pve serves WAN → `leave`; the verb, never the raw API —
  #2395). Reads: (1) the 19:40Z→04:46Z WAN-loss incident (operator-accepted) — postmortem owed once settled
  (`docs/incidents/`), residue to confirm cleared: `ArgoWorkflowsFailing`/`AgentLoopWorkflowsFailing` (6 h / 1 h
  rates), `IacSentinelSilent`, the rerun CI runs 37882053399/37855286664/37833387822 + oracle-fleet 37832770991;
  (2) nx-02's WAN gate still runs the pre-#2389 script — restart it in an attended slot (blips the MASTER's WAN
  ≤3 s); (3) the 10-02 blocker is CLOSED (relayed frame, flood-off — router-move.md §Status); (4) window
  seat-1791485956-9934 CLOSED 05:21Z (`--force`: the aging rate alerts were the only delta). (5) **Postmortem
  written** — `docs/incidents/2026-10-08-carp-maintenance-not-left.md` (PR `docs/incident-2026-10-08-carp-maintenance`,
  auto-merge armed; land it if the sentinel/updater race holds it: #2395 needed `--admin` for that reason). Its
  actions FILED 2026-10-09 05:45Z: **FU-307** (`RouterMasterWanDark` belt — waits on an attended gate restart),
  **FU-308** (dead-man `leave` for unattended proofs), FU-198 extended (retry backoff holds the subscription
  semaphore — design-agents), GAPS maintenance-window-G6 (the skill asks "does your session ride what you move?");
  Kea's two offers = a finding in router-move.md §Status, not tracked. Loose, unfiled: Kea answers one DISCOVER with two offers (binds `.70`
  and `.1`); a responder retry backoff of 4 h holds a subscription slot (`ArgoLockPlaneWedged` fired correctly —
  design-agents material); nx-02 free RAM ~6 GiB — the DIMM window (FU-289) is now unblocked by the router pair.
- **⚑ PICKUP (2026-10-07 21:00Z — seat; TICK-LOG same date).** (1) Confirm the box loops recovered after the
  venv move: a `management-sentinel` status on open PR heads, `MgmtLeaseLoopStale` cleared, no `MgmtApplyLoopStale`;
  then FU-305's detector — the loops DID recover (sentinel/apply/lease clean 20:55–20:58Z). (2) #2368 (goal-child
  twin) MERGED 21:07Z. (3) The SIGPIPE lint PR #2373 (`fix/sigpipe-lint`) — check it landed. (4) pve x16 NVMe test-fit rides the next pve window.
- **OPERATOR: oracle-fleet#798 item 6** (the privacy retention line) is still unfixed and needs a human — the
  issue sits `agent/blocked`, out of the loop since #2366 (2026-10-07), so nothing retries it. Delete this bullet
  when #798 closes.
- **⚑ PICKUP (2026-10-07 morning — S9 build list DONE overnight; TICK-LOG 2026-10-06 night has the arc).**
  Landed: #2345 (0: packaging-only chart majors ARM on `appVersion: unchanged`), #2344 (1: G17 second body
  section + fixture; ci step c757e178), #2348 (2: ADR-151 CRD owner app + group + belt), #2351 (3: G12
  postUpgradeTasks), #2347/#2349/#2355/#2359 + #2350 (4: ADR-150 lease, cluster + box — box timer LIVE
  21:28Z), #2346 (sentinel `contents: write` DECLARED). **kps 91.8.0 + CRDs 32.0.1 LIVE 23:34Z** (#2256; the
  lease armed→confirmed on a real bump after a seat renew — ordering hole fixed by #2359). Cloudflared
  2026.10.0 tofu half applied. **OPERATOR (morning):** (a) ✅ the `homelab-sentinel` permission click DONE (operator, 2026-10-07 — reported at the
  evening session's start) → NEXT the seat drills the
  REVERT half: a synthetic expired lease on the next merged pin-only kps bump (`agents/upgrade-lease.sh open
  --subject argocd/platform/kube-prometheus-stack.yaml --chart kube-prometheus-stack --sha <merged sha> --from
  <old> --to <new> --expect-min 0`, the #2276→#2279 shape) → `mgmt-lease` opens `revert-chart-lease-<sha8>` →
  reflex merges → ArgoCD back; only then **step (5)** the one `matchPackageNames` line arming kps majors (next
  to the argo-workflows rule). (b) ✅ **#2362 MERGED by the operator ~20:4xZ** (devbox major — #2260 closed + re-dispatched 17:41Z so the G17 section rendered on real data; lens APPROVED 18:56Z, parked `major/awaiting-human`) — the LAST lock major a human merges: **#2369 (merged 20:1xZ) arms class-7 majors** (operator ruling, `dependency-upgrades.md` §2 Review — no ADR edit; opentofu majors stay human via `HUMAN_PACKAGES`). Two proofs pending (§Next steps 10): the next lock major opening `lock-lane: arm` + merging on the lens; the lock revert drill (bad lock on `runner-image.yaml` → `revert-lock-<sha8>` → check (i) red). (c) **Goal #2273 production-leg
  finding:** theme 2 (#2333) put `lastEditedAt` in `gh pr list --json` — not a gh field — every stack's review
  ride FATAL'd 23:22–23:45Z; seat quickfix 914b2b3c dropped it — ✅ RESOLVED 2026-10-08 by #2383 (one GraphQL
  `lastEditedAt` read via `agents/pr-last-edited.sh`, both readers; the fake gh now refuses unknown `--json` fields). **Loose (S9,
  no new FUs):** `KernelOopsCaptured` counts OOM-kill dumps (`Call Trace:` in the Alloy regex — wk-04 23:25 was
  the PostSync Job OOM) → exclude the oom-killer dump or count it apart; `install-tool helm v4.3.0` in the G12
  rule has no proposer; `pr-wait-test`/clause-replay flake = `scan-guarded` `printf | grep -m1` broken pipe on a
  long body (G17 lane's read); G12's proof = the next kps bump's first CI run; #2256 was retitled "- abandoned"
  by Renovate when the group landed (merged anyway).
- **⚑ PICKUP (2026-10-06 evening — Goal #2273 BOTH THEMES ON MASTER; TICK-LOG 2026-10-06).** FU-295 fixed
  (#2299, box activated, archived 638095cd). Theme 1 scan-guards #2339 (f0b19f81) + theme 2 seam-parsers
  #2333 merged 19:23/19:34Z after seat codeowner reads (verdicts on the PRs). Goal now post-launch
  (bucket #2300); **verdict is the operator's** after the Production-leg window (bucket-A count vs 38).
  Operator reads: (1) seat raised `Budget: 30 → 36` (FU-131 full-cap charging inflated Σ; revert = re-scope);
  (2) #2324 lets the scan CLEAR `agent/error` when an `AGENT_INFEASIBLE:` verdict parks the issue — a breaker
  label removed by machinery for the first time; (3) `coordinatorModel` still `opencode-go/deepseek-v4-flash`
  (the 09-25 temporary). Open, filed today: #2307 (coordinator sleep-polls to the 3600s deadline). Not filed:
  the FU-143 goal-child closeout never fired for #2280 (strong `Fixes #2280`, PR merged 18:37Z, closed by hand
  19:10Z) — re-check on the next goal child now that theme 1 is on master; `agents/meta-needs-attention.sh:172`
  fails `bash -n` (jq filter, same on master).
  #2174 merged 2026-10-06 ~20:05Z after a seat master-refresh + codeowner read: a DUPLICATE-closed blocker now
  HOLDS (conservative — live it always takes the canonical-unreadable arm); fix-forward = #2341 (GraphQL
  `duplicateOf`, inert, sub-issue of #2167).

- **⚑ PICKUP (2026-10-05 morning — S9 backlog THROUGH, unattended; TICK-LOG 2026-10-05 morning has the
  arc).** Landed: #2234 (G11 second cut) + **G11 PROVEN** (#2228 2.3.6 and #2240 2.4.2 carried both lines,
  merged mechanically, Renovate rebased #2240 itself); #2232 cloudflared + the seat's `tofu/cloudflare`
  apply (window clean, state converged); **#2241 = G13** (cloudflared is a version set — regex manager +
  group); waves 3/4/5 all merged and live (eso 2.11.0, infisical 1.11.0, kps 86.3.2, nginx 1.31 ×2, otel
  0.161.0, python 3.14, kube-rbac-proxy 0.23.0, blackbox 0.28.0, registry 3.1.1). **#2257** drops
  `prHourlyLimit` 6 → 3 (MERGED 08:22Z); the status-rows docs PR **#2258** was in review at wind-down. **Operator reads:** (1) three MAJORS parked on the
  human lane — **#2254 argo-workflows chart 2.x** (lens APPROVED after a WORKER adapted it in-PR — the
  first machine-side worker-adapts on a Renovate PR; `major/awaiting-human`, un-armed), **#2256
  kube-prometheus-stack 91.x** (lens pending), #2100 mermaid 12; (2) **#2246 metrics-server 3.14.0 CLOSED
  unmerged** on the lens's catch (app v0.9.0, kubernetes-sigs/metrics-server#1868 — protobuf OpenAPI
  503, no fix); Renovate re-proposes the next chart only; (3) **FU-304 lever APPLIED** (evening, operator-ordered): GOMEMLIMIT=3200MiB on all three CPs live 15:50Z (PR#2268, windowed); orphaned helm history deleted; `max_history = 3` PR#2267 merged, its 4-release apply ran through `helm-evidence` (evidence dir `~/.claude/helm-evidence/*-max-history`); **#2254 argo-workflows 2.0.8 MERGED 16:48Z** inside a window (hook Job ran, +0.6 GiB spike, heartbeat clean); **`ArgoControllerSilent` live 16:40Z** (PR#2269, step 1 of arming argo-workflows chart majors). Pickup: watch `ControlPlaneNodeMemoryLow` on wk-metal-02 over the week. (The arming chain is DONE — ruled + built + drilled the same evening: ADR-149, `chart-revert` receiver #2271; dependency-upgrades.md §Next steps 9.) (4) **the Renovate cron IS firing** — the morning read was wrong: `schedule` runs land 1–5 h late (10-05 03:29Z, 13:16Z; one slot dropped), `gh run list --workflow renovate.yaml --json event,createdAt` is the check; the hand-dispatch question was DROPPED (operator 2026-10-10 — the wave is through). **Gap register** =
  `docs/dependency-upgrades.md` (G1–G13; the 10-05 status rows ride the docs PR named in TICK-LOG).
  Standing from 10-04: G7 (`dig` findings have no reader — FU-249 (c)), G8 (regen that
  rides the merge), G12 (the kps alert-list refresh — second hand sighting, #2245), G12b (red armed PR has
  no actor — but see #2254: the worker-adapts leg DID fire on CHANGES_REQUESTED), updater skip /
  `rebaseWhen` for Renovate branches.
- **⚑ PICKUP (2026-10-04 evening — provider MAJORS ARMED, default-backfill shape live; TICK-LOG 2026-10-04).**
  (1) First real proofs owed: (a) the next CHANGING main apply runs kubernetes 3.2.1 — `exercised-main.tsv`
  moves 2.38.0→3.2.1 on success, or `MgmtApplyErroredOnNewProvider` fires and the chain reverts #2047;
  (b) the first provider MAJOR merged on the lens's APPROVED alone (rule e1748261). (2) Updater churn on red/BLOCKED provider PRs (#2191: 29 master-merges, 32 box plans in 30 h) —
  ACCEPTED (operator 2026-10-10): the lever is merging them faster, not an updater skip. (3) Then S9 next step 7 (class 1/2
  proposers, `docs/dependency-upgrades.md`).
- **⚑ PICKUP (2026-10-02 night — helm provider 3.x applied under evidence; TICK-LOG 2026-10-02 evening).**
  (1) **#2183 merged unread by the operator** (author==codeowner waiver) — the box apply loop now DEFERS
  inside [declared windows](../glossary.md); operator to read its three calls: `MgmtApplyDeferredByWindow` at 6 h, the
  reconciler's node windows hold the apply loop, `--admit-apply` separate from `--admit-reconciler`.
  Confirm the box's next pull runs it (a `DEFERRED` line the first time a window is open). (2) The
  `fu-mint-gate` hook is a TRIAL (operator: replace it if it doesn't change behaviour). (3) FU-299: daily Longhorn job + UniFi
  `.unf` LIVE (PR#2196/#2197: schedule as code + UnifiAutobackupStale) — glance at the 10-04 01:00Z `.unf` +
  02:00Z run; off-site PARKED by the operator.
- **⚑ PICKUP (2026-10-04 evening — retro r7 prep; TICK-LOG 2026-10-04 evening).** **#2173** (rank
  fix: SHA fallback, issue-only credit, latches/rounds as pain — oracle-fleet#753 samples on the
  live store) and **#2215** (#2171: the in-pod `gh` wrapper overrode `RETRO_GH_TOKEN` with the
  one-repo broker token; file mount, no broker) MERGED 19:08/19:24Z — **r7 (Mon 10-05 05:00Z) is
  their first live test**: read the ride log for `gh repo view teststuffstash/oracle-fleet`
  resolving and the deep-dive set NOT being the S9 Renovate PRs. **ADR-146 ACCEPTED** (wording
  read; #2172 auto-merge armed) — build = FU-058's next: bundle + guard repo scope, per-stack
  CronWorkflow, the brief's escalation clause, the opt-out knob; oracle first, hand-fired AFTER
  r7 publishes. **#2174** = merge as a conservative hold, then fix forward (GitHub emits
  no `marked_as_duplicate` timeline event; the canonical is GraphQL `duplicateOf` — the
  canonical-follow path never fires live; a GraphQL replay stub has no precedent). The
  reconcile ran 10-03/10-04 with nothing to reconcile (store holds only `activity.json`).
  **ADR-142 re-read 10-05:** data pack in TICK-LOG 2026-10-04 evening (46 scripts PRs, 0
  worker-authored, 3 DIFFERS all lens-justified, no weakened gate; D2 never ran; FU-296 ci step
  unwired) — suggested: keep to 10-28.
- **⚑ PICKUP (2026-09-27 night — FU-289 hardware half DONE, unattended; TICK-LOG has the arc).** nx-02 boots
  from the SA400 (root+swap; `local-lvm` 700 G thin pool on it; the WD is a spare still in the bay), the
  LSI HBA now exposes 2 INT13 disks, ci-runner-02 is UNPARKED (#2048 applied 21:16Z), the window is closed.
  **Read (1):** run 36351320341 landed on ci-runner-02 — "Preparing nodes" **3.9 s** (failure 397/67 s,
  runner-01 2.5 s), e2e green 7m11s, swap 0 B, no `PveHostSwap*`/`PveNuma*` fire; …24933 was cancelled by
  the concurrency group, …30352 ran on ci-runner-01-2 (~0 s, image cached). One sample — the belts judge the
  week. (2) DONE 2026-09-28: the operator PULLED the WD spinner, so the SA400 is the only INT13 disk —
  the BIOS-priority question is moot. (3) Board, 2026-09-28 morning session: `LonghornNodeOverProvisioned`
  on wk-metal-01 CLEARED — it was registry-data's replica, replenished onto the mx500 at 19:01Z while wk-04
  (nx-02) was down in the FU-289 window (the runbook §Single worker maintenance 600 s class, not FU-285's
  co-location); the seat deleted that replica in a window and Longhorn rebuilt it on wk-04's sn530.
  `GithubStorageHeldHigh` = oracle-fleet's `unit-allure-results` artifacts on the 90-day default (853 ×
  2.1 MB); old ones deleted by API, oracle-fleet#763 sets `retention-days: 1` — expect the alert to clear
  as the 24 h average catches up. The `agent/error` trio #2037/#2046/#2047 was the 2026-09-28 process session's material — see the
  S9 bullet below. `MgmtBeltCheckFailing`×3 + `MgmtReconcileLoopStale` fired 13:17–19:56Z 09-27 on the #2043 class — un-wedged
  by hand, fixed by PR#2045 (init every run in probe + reconciler). **Retro r6 = PR#2050, merged 05:36Z
  by the agents App 6 s after the bot approval — the "HUMAN-GATED, auto-merge NOT armed" gate in
  `retro-argo.yaml` is defeated by `review-reflex.sh`'s C9 re-arm (worker-App author, no parking marker:
  C9 honours only `major/awaiting-human`, `major`, `agent/error`, `research/*`); r4 #1645 went the same
  way (8 min), r5 #1819 only waited because the reviewer requested changes. RULED 2026-10-15 (operator): merging is fine — the reviewer blocks the catastrophic, the operator reads after merge; no marker. (Residue: the body still says "read before merging".) Prior-art grep FU/GAPS/merge-path: nothing on retro PRs specifically.**
- **⚑ PICKUP (2026-09-29 evening — S9: #2033 merged + deployed, prod OPNsense on 26.7.4; TICK-LOG 2026-09-29).**
  **NEXT SESSION = ONE GOAL (operator): software-side prep for the router move — rehearse the
  from-git router VM on nx-02 IN ISOLATION** (WAN = `eno2` passed through but uncabled, LAN on a
  portless bridge; spoofs Big Data's `em0` MAC; WireGuard server key from the wallet; ACME re-issue
  or import) and score it vs prod ≈0 — after moving the drill's series + test-VM baseline to 26.7
  (`trial-26-7-4` on 9110) and a confirming master drill. Also inventory + parametrize everything
  wired for ONE static router at `192.168.2.1`/`opnsense-fw` (ansible inventory + wrapper, the
  backup CronJob target, the box's `OPN_API_*` belts, alerts/probes, the harness's prod guard,
  ddclient/WireGuard endpoints) so a big-bang move is a config flip + one window. **NO hardware
  change** until the switches are in hand (TL-SG1016D ordered, hardware `purchases.md`): the later
  visit = WAN switch (ONT → nx-02 `eno2` + Big Data `em0` powered-off fallback, its LAN cable out)
  + the management switch; Big Data stays intact 1–2 weeks before its card moves to pve.
  **Progress 2026-09-30:** the isolated rehearsal is BUILT + merged (#2131, `opnsense-drill.sh --router`;
  [`router-move.md`](../router-move.md)): PASS, 12/12 probes, score 6 at that point.
  Later 2026-09-30: WireGuard key carried (#2133, `wg_handshake` green), the WAN_GW rows accepted
  in their dead state → **score 0**; the (B) API address read from the inventory (#2132). Rehearsals
  2–4 "network blips" were the jail HOST's new cable + wifi (ARP flux, fixed host-side with
  arp_ignore/arp_announce) — not the rehearsal VM.
  Then (2026-09-30 midday): root = wallet `opnsense-root-password` (#2136); OPNsense 26.7.5 —
  SERIES bumped + 9110 baseline moved (#2134) and PROD updated in window seat-1790760478-4482
  (operator-approved; 16 s, no reboot, all checks baseline); **ADR-144** (#2135): the CARP pair is
  built beside Big Data — nx-02 node `.70`, pve node `.71` (operator buying a 1 GbE x1 card for
  pve: Realtek → host-bridged WAN, not passthrough), each managed at its own IP. **2026-09-30 afternoon:** the standby profile = **#2138**
  (`opnsense_standby`; rehearsal `--router --standby` PASS, 5 inert probes + real cert/WG green) —
  in review. nx-02 WAN **bridged** (operator: if no performance penalty) — the throughput read
  through a bridged rehearsal WAN is unbuilt. **pve's TG-3468 FITTED** (window
  seat-1790772187-4679): `06:00.0` `enp6s0` `ac:a7:f1:b3:25:95`, x1 2.5 GT/s, own IOMMU group,
  unconfigured; the onboard RTL8168 moved to `07:00.0` and is PINNED `nic0`
  (`pve-network-interface-pinning`; vmbr0 = nic0 — unpinned, pve would have booted offline).
  **2026-09-30 evening — nx-02 NODE STANDING + INERT at `.70`** (#2140 bridged WAN
  ~3 Gbit/s; #2141 `tofu/opnsense-router.tf` vmbr3 + VM 9170 applied in window
  seat-1790782366-5635; `bash scripts/opnsense-router-node.sh check nx02` = the read-only
  health read). **2026-09-30 night (goal session, #2142–#2150):** both nodes standing + reboot-proof,
  `/24` ruling (ADR-088 amended; trial VIP `.72`, HAProxy VIPs `lo0` for good), pfsync, the
  hypervisor WAN gate (`router-wangate@<vmid>`, QMP `set_link` keyed on CARP adverts), the belt
  (`RouterPairMasterCount`/`RouterWanGateSilent`); drills PASSED: failover/preempt, hard stop,
  rolling update (3 reboots, flows kept), split-brain (belt fired), cold start — numbers in
  router-move.md. The operator's cable nx-02 `eno2` ↔ pve `enp6s0` stays in (fake ISP:
  `router-node.sh fakeisp up`; a node REBUILD is refused while it gives carrier — correct).
  **2026-10-01 (ADR-145):** window-1 PREP LIST DONE (#2155 Kea-as-code, #2156 Kea HA drill,
  #2157 nx-02 host reboot, #2158 .72 retired + skews + router-ids, #2159 RouterPairMasterCount
  interim `> 1`, #2160 BGP alert per peer — auto-merge pending re-review; #2161 DRAFT = the
  Cilium peer .1→.70, apply IN window 1, plan id 20261001T190057Z-f06b997d, re-plan if stale).
  **⚑ WINDOW 1 DONE 2026-10-02 (window seat-1790960221-62) — nx-02 IS THE ROUTER.** #2166 (change set
  + LAN_GW drop) merged, #2161 (Cilium peer `.70`) applied; `.1` = CARP MASTER on nx-02, WAN
  `176.46.101.184`, BGP 13/13, Kea leasing, WG handshake, backup, HAProxy names, `check nx02/pve` green.
  The WAN loss was the old cable. **Big Data: RUNNING with BOTH cables OUT** — the API `core/system/halt`
  did NOT keep it down (it answered `.1` again within ~4 min → double `.1` until the operator pulled
  its cables). Fallback = router-move §Window 1 step 4 (stop nx-02's VM FIRST, then replug Big Data).
  **Next:** soak 1–2 weeks → window 2 (pve joins as BACKUP; its WAN already on the switch, gate dark);
  write the window's lessons into router-move §Status (halt ≠ off; the ddclient play hung on a
  `pkg update` stuck from the double-`.1` minutes; `mgmt-tf apply` prompts `y`; Kea served only
  after a re-run; `opnsense.teststuff.net` came from Big Data's hostname → static override 3cf5bd16).
  `OpnsenseConfigUnattributedRevision` fires on every jail converge (root key) — FU-013's class.
  **✅ WINDOW-2 BLOCKER CLOSED 2026-10-08 (a relayed frame, not a served lease — router-move.md §Status; window 2
  itself done 2026-10-08 evening, see the 10-09 pickup). Kept for the record:** kill switch tripped 17:14:43Z on
  `02:00:c0:a8:02:47 > mower  192.168.2.1.67 > 192.168.2.150.68 BOOTP Reply` → VM 9171 stopped,
  onboot latched 0 (WAN gate still active). `check pve` was green at 17:02 (DHCP off, switch armed).
  Cause unknown: the seat's 17:02–17:14 acts all targeted nx-02 (`--limit`/`OPN_HOST=.70`); suspect
  the #2166 inventory flip (plain playbook runs now hit BOTH nodes — the box's `--check` belt is the
  routine one) or a pfsync/Kea interaction. **Next:** `killswitch-arm pve` FIRST, boot 9171, read its
  Kea + dnsmasq config and config history 17:02–17:14Z; do NOT reset onboot until understood.
  Open beside it:
  `PveNumaNodeMemoryLow` fired 15:22Z on nx-02 node 0 (wk-04 16 GB pinned + ci-runner-02
  8.9 GB + cp-02 6.6 GB; the router VM sits on node 1) — FU-289's class. Read 2026-09-30 late: no swap, but nx-02 is fully booked (~60/62.5 GiB) → **budget the pve node and any further nx-02 VM against that**; fix = RAM (FU-289 item 3, operator watching for a lot). #2130
  (`experiment/retro-activity-window`, 06:49Z, not this seat's) sits CHANGES_REQUESTED + BEHIND.
  **Identity the new router must carry** (prod config read 2026-09-29): WireGuard server privkey
  (router-only by the role's design — export to the wallet + an import path, OR re-issue the two
  client configs, OR carry it from the backup: operator call); the 3 API pairs (wallet has them →
  seed renders them, so no consumer flips); root password (no wallet entry yet); the WAN MAC (spoof
  `em0`). **Certs + ACME account: IMPORT from the newest encrypted backup** (operator, 2026-09-29 —
  re-issuing 17 per rehearsal risks LE's per-domain weekly limit): decrypt with the wallet age
  identity at build time, carry `cert`/`ca` + the `AcmeClient` section with refids intact (HAProxy
  binds by refid); the registered account comes along, sidestepping FU-298's register-404; acme.sh
  renews on its 60-day interval. Nothing lands in git.
  **Open:** FU-013 next = playbooks onto the `automation` key (needs privileges for the system role's endpoints too);
  FU-298 = the upstream ACME register 404 (O-X-L issue = operator's call); prod LAN is `.1/22`, not
  the `/24` `ip-plan.md` states — the ADR-088 CARP ruling must settle it; the reviewer exit-contract
  keys a merge head differently from the reviewer's standing-aside (false NO TERMINAL; not filed).
  Firmware: official path, no Renovate (operator) — the daily-check belt is not built.
- **⚑ PICKUP (2026-09-28 late night — ADR-142 trial LIVE; TICK-LOG 2026-09-28 (evening → night)).**
  `scripts/` is un-owned + worker-authorable (except `mgmt/scripts/` + the three box verbs);
  the gate is the BLOCKING gate-change lens + ci's gate-drift report. Drills: 2 caught, control
  approved, 1 not run. **Re-reads (operator): 2026-10-05 and 2026-10-28** — count gate-change
  PRs, lens verdicts, DIFFERS lines, any weakened gate found after merge; revert = `/scripts/`
  in CODEOWNERS + `scripts/` in governance-lint GOVERNANCE. Box moved to `mgmt/` (PR#2088),
  re-activated by hand, green. Open from tonight: FU-295 (box sentinel vs goal/** PRs),
  FU-296 (governance-lint self-test). FU-294 CLOSED 2026-09-29 (ADR-143 — see the pickup below).
- **⚑ PICKUP (2026-09-29 morning — ADR-143 live; TICK-LOG 2026-09-29 has the record).**
  mermaid-lint runs on Deno with zero permissions (#2098); `lock-intake-lint` gates every PR's
  lockfile intake in `ci` (OSV incl. `MAL-`, 7-day floor, install-time code, transitive included).
  **#2100 (Renovate mermaid 12 on deno) is RED BY DESIGN** — waits for mermaid-js/mermaid#8278;
  the coordinator ruled no ride (state-fp debounced) — never pin/override it. The npm mirror is
  `npm-cache.teststuff.net` (Unbound, #2101 — Deno cannot use an IP registry). Parked on the
  ROADMAP supply-chain section: master/prod scan (Dependabot vs Dependency-Track + SBOM + Kyverno),
  then stacks via the consumer card — operator decision, homelab first.
- **⚑ PICKUP (2026-09-28 night — the Forgejo chain DONE end to end; TICK-LOG 2026-09-28
  (afternoon) + its Closing paragraph have the record).** Landed by the machine lane: #2078,
  #2082, #2084, #2087 (the drill's findings, four review rounds), drill #2085 → revert #2086
  (alert → merged revert 6.5 min), the box applied the revert 17:40Z, runner on `docker:27-dind`
  2/2. Direct: c18bfe3f (ci.yaml first-parent read via `cat-file` — the #2064 fix had never
  fired on a depth-1 checkout), the Renovate rule arming terraform docker-image majors (ADR-141
  amended). **First reads next session:** (1) #2037 — Renovate's next run should rebase it
  (`behind-base-branch`), the lens re-reviews at the new head, it merges on its own, the box
  applies the docker:29 tag with no rollout wait; if it sticks, the lane reverts it — read, don't
  click. (2) `KubeDeploymentRolloutStuck` on forgejo-runner should be RESOLVED (the drill pod
  was terminating at 17:41Z). (3) agent-runtime#161 parked on its `unit` job (devbox-install-action
  vs pre-installed nix, `.github/` operator-direct — a Renovate/Actions class item). (4) #1988:
  the row is commented; close it when the base-image half has its own home. **Shelf-life finding
  for the operator:** `major/awaiting-human` PRs (#2046/#2047 BEHIND; #2033 merged + deployed 2026-09-29; #2032 closed → #2100) rot
  within hours — decision (a) of the S9 bullet is the open one. **Operator decisions still open:**
  (a)–(e) of the S9 bullet + the retro r6 marker. **S9 closeout residue:** #1991, #2014.
  **Hygiene still standing:** `:dependencyDashboard` in sleep-tracking / sleep-iac / oracle-iac;
  agent-runtime's `deps-pin-guard.sh` pre-#83; dead `update-pr-branch.reusable.yml` callers;
  `coordinatorModel` on `opencode-go/deepseek-v4-flash` (revert to `opus` when the Anthropic 7d
  window resets); the Monday 06:00Z image rebuild did not fire (re-check next Monday).
  `automerge` label = Renovate-only.
- **⚑ PICKUP (2026-09-24 — registry2 / FU-280 CUT OVER).** `registry.teststuff.net` → `registry-fs` on
  the `registry-data` volume since 14:50Z (#1961/#1962); the S3 Deployment runs unrouted as the rollback.
  Next steps + the operator's disk-tag question are on **FU-280**. **FU-286:** PR#1963 (talosctl from a
  nixpkgs rev at 1.14.1) was in flight at the sweep. Once it merges, `MgmtBeltCheckFailing{check="talos"}`
  should clear on the box's next pull. If it still fires, read the box's devbox resolution.
- **⚑ RESPONDER — the ADR-148 lanes are LIVE since 10-04 (PR#2212); "disabled" = the OLD per-blip lane
  only (operator, 10-09).** Gaps + owners: FU-249 / FU-230, evidence spike §2026-10-09. Landed 10-09: dig dedup (#2415),
  claims-by-silence (#2418 — PROVE in the next window: grace/claim/no-session), remediation_would typed +
  scored (#2417, #2419). Reader = `/board-sweep` (operator 10-09,
  PR#2416); a retro-like batch reader over several nights later. oracle-fleet's 5 rules still lack `triage` (stack lane).
- **⚑ GOAL #1906 (retro r5 batch, themed).** #1908/#1909/#1911 done. **#1910 is authored and UNQUEUED
  on purpose.** The operator reads Goal pin 3, then either queues it or rules it deferred on the store.
  Theme #1907's assembly (`goal/1906-scan → master`) is the one codeowner read, and it has not been
  opened yet. **#1651** (under retro r2 #1101) closes by hand once #1908 reaches master via that
  assembly. After that, #1101 closes ≥72 h later.
- **⚑ OPEN GOALS / CONTAINERS (verdicts are the operator's):** #818 G-B HELD (4-clause verdict posted).
  #1302 G-G post-launch: check 3 = the RUM residual, #1311/#1334. The consumer Workspace stays red on it,
  and that is **FU-250**. #1640 router Goal. #1769 rails Goal. #1418 S8 [stint](chainless-redesign.md): #1649 landed 09-14, so it
  is due to close at a sweep.
- **⚑ OPERATOR-OWED (one list, verified open 2026-09-24):**
  ((1)/(1b) DONE — `.agents/review.md` carries the intent-review rule (c8e38675) and the standing-gate
  wording; verified by the 2026-10-03 fu-sweep.)
  (2) claude-jail `6f90815` (`DEVBOX_USE_VERSION=0.18.3`, FU-240) is still unpushed in `/workspace`.
  It needs your push + a jail rebuild, and the host profile wants the same export.
  (3) pop-os `~/.talos/config` may still hold the pre-rotation identity (FU-264 rotated the CA 09-22).
  #1882's "3 flagged choices" were never recorded.
  (4) pve's CMOS clear reset "Restore on AC Power Loss" — UNREADABLE headless (no GPU; the 09-30 card
  fit could not check it): a monitor/GPU visit or a deliberate plug-pull test. Until then pve may
  stay dark after a power cut.
  (5) Human-next-mover PRs: **circles-iac#108** (claim egress `none → python`, un-armed; flipping enforce
  under `none` hangs every uv call), sleep-iac#80, sleep-tracking#143.
  (6) Operator/seat sittings, open: #1237 (E1), #1238 (E2), #1224 (parts-coverage), #1280 (held for
  kind-timing evidence), #1370 (FU-171 resight), #1713 (pin-only-lint, operator lane), #1627 (unqueued),
  #1669 (blocked until theme 1 deploys).
  (7) Cloudflare `Cache Purge` onto tofu-apply vs relying on oracle-fleet#414's Cache-Control: undecided.
- **⚑ UNOBSERVED FIRSTS (read when they happen; no action until then):** #1621 is open for its live
  acceptance: the next oracle corpus publish should ring `/corpus-published` → `release-corpus.yaml`.
  `fixer.imageVolumes` (#1808, ADR-135): the first ride with `/corpus` mounted. The first oracle
  closeout under `.agents/closeout.md` (#1806, ADR-134). The first real `CronJobNotSucceeding` fire:
  is a weekly job's 21-day threshold tolerable? The origin mark's SERVE-TIME check (#1942), which is
  owed by oracle: a null `origin` column means the header does not survive the tunnel hop. Also check
  whether our platform-stack deny on `deepseek/deepseek-v4-flash-0731` was meant to cover the
  permaslug-spelled cell, against which it is INERT.
- **⚑ UNBUILT, NO HOME YET (single sightings — detector-first on a second):** `fstrim-guard-<node>`
  is nodeName-pinned ON PURPOSE (the manifest: "must still run when cordoned") — so while a node is
  OFF in a window its guard sits Pending and `CronJobNotSucceeding` fires (2026-09-27, wk-04): a window
  consequence for GAPS maintenance-window-G5's EXPECTED class, not a skip-on-cordon change. `KubeJobFailed`
  fired 45 series during the 09-16 window, and adding it to `DECLARED_ALERTS` was rejected as too broad.
  Separately, the registry exposes no scraped metric, so push throughput has no belt.
- **⚑ HYGIENE:** stale agent branches (homelab 11 as of 09-05, plus agent-runtime 1, oracle-fleet 4,
  circles 4, sleep 1): delete or resume. The ZOMBIE hosted runs 32217689970 and 34748702282 cannot be
  cancelled by API: operator UI, or ignore. Phantom `agent/done` closes: confirm or relabel
  oracle-fleet #25 #24 #22 #7, sleep #7.
- **⚑ DESIGN INPUTS WITH NO OTHER HOME (operator: deliberately not FUs — pick up in a
  design-agents sitting; re-ruled 2026-10-15):**
  - **Drainage economics RULING (2026-08-31, operator-confirmed; TICK-LOG 2026-08-31 has the arc)** — STANDS
    (re-confirmed 2026-10-15: batching works). (1) blocking defects (incoming blockedBy from a stuck stack issue /
    live wedge / 🚨) queue immediately, master-lane, hotfix-class, every filing door wires the edge; (2) the
    nice-to-have pile is corpus-session batch work — no new machinery; (3) the Touches classifier survives as a
    LINT (#1102). Clause 2's premise (gate reads are the binding resource) is revisited by the next admission
    spike, not by an ADR today (operator 2026-10-15). Banked, operator's own "not yet": an AUTOMATED design-agents
    corpus read on codeowner-parked BLOCKING issues — revisit if parked-PR volume freezes dispatch.
  - **v1.3.1 BANKED** (PR#1220, "deserves a place when it works"): `Origin:` line + typed defer/release +
    checkpoint theme-FORMATION are S8 originals — do not build piecemeal ahead of S8; delta 1 (park economics)
    landed independently (PR#1375/#1376/#1352).
  - Ruled 2026-10-15 and removed from this list: the role×stack×service access inventory (stack-transcript
    reads, jail `TOOL_GAP:`) is **P2 scope** (the gateway island); goal/**-fix-protects-nothing and
    long-lived-runner-state are DROPPED (dissolved by ADR-126 themes + hotfix master lane / runner cloud-init +
    replace); the dispatch-declared `requires:` FU is NOT filed (MCP on every harness was built to avoid the matrix).

## Durable warnings — EVICTED (S4 #765, 2026-08-23)

The section's content moved to its proper homes; this pointer is all that remains:

- Probe & triage discipline (absence-is-fake, deploy-silences-`for:`, info-suppressed,
  counter-vs-throughput, green-surface, bypass actors, written-is-not-applied,
  one-spec-page, operator-lane PRs) → **`docs/runbook.md` §Meta-session probe & triage
  discipline**.
- Shell/tool gotchas (zsh word-split, `--body-file`, `gh --jq`, `gh pr view` merged, python3
  yaml) → **`agents/jail-subagent-card.md`** (applies to the seat too); pipe-filter-push →
  CLAUDE.md §lanes; apostrophe-in-jq → mechanized in `prompt-transport-lint`.
- goal/-prefix arming → `docs/agents/issue-authoring.md` §Base (was a duplicate);
  label caps + branch-rename-closes-PR → same doc; two-readers → **FU-178**; the
  agent-runtime-fixer-lane status note was stable news and is dropped (the
  reviewer.enabled platform trap survives in the runbook bullet).

## Re-arm on a fresh session

⚑ **Per-SESSION-TYPE since 2026-08-19 (operator direction, the watches-for-codeowner-sessions
sitting).** Both jail session types — the mechanical MAINTENANCE session and the CORPUS session
(design-agents corpus loaded: codeowner reads + FU build + subagent waves) — arm the SAME
standing set below; what differs is cadence and the act rule:

- **ONE STINT PER CORPUS SESSION (operator rule, 2026-08-20).** The corpus bootstrap
  (measured 300–350k cache-creation tokens per load, 2026-09-03/04 — `session-ctx.sh --big`)
  costs only ~6–10 turns' worth of high-ctx re-reads, while every turn re-reads the WHOLE
  context at 0.1× — so at ctx ≥ ~500k a NEW stint always starts a FRESH session (break-even
  turns ≈ 470k / ((ctx−400k)×0.1): 500k→~47, 600k→~23, 800k→~12; a real stint is 150–300+
  turns and stints EXPAND). Trailing work of a few dozen turns may stay warm. Measured basis:
  the 2026-08-19 night session — 459 turns, 275.8M cache-read = ~92% of spend.
- **Ctx wind-down (operator, 2026-08-19): end ~50k tokens BEFORE the context cap — never ride
  into compaction** (a compacted corpus session is no longer a corpus session; a fresh one
  bootstraps from this file + TICK-LOG by design, mid-stint included). Measure with
  `bash scripts/session-ctx.sh` at heartbeats once past ~½ window; at the threshold run the full
  wind-down ritual regardless of in-flight work.
- **Cadence**: the corpus session's heartbeat runs UNDER the ~1h Anthropic cache TTL —
  **2700s**, not 7200 — so the belt that catches a stall is also what keeps the big context
  cache-warm (a wake within TTL is a ~0.1× cache read; past it, a full re-read — the Part A″
  arithmetic, [observability-and-retro.md](observability-and-retro.md) §Part A″). Maintenance
  sessions keep 7200s (light context, cold wakes are cheap). An expected wait past the TTL with
  nothing in flight = WIND DOWN deliberately (write the pickup, **push the batched direct
  commits — ONE master push through the githooks/pre-push lint gate, the 2026-08-30 batch
  rule (seat card §How changes land)** — kill monitors by process, run jail-transcripts-sync,
  exit).
- **Act rule**: a watch event outside the session's type is RECORDED for the other type (board /
  a meta-state row), never acted on — design-shaped events don't get improvised without the
  corpus (the /design ruling applied to watch events); agents-lane events don't derail a
  mechanical sweep.
- **Subagent waves**: the standing set is the level-triggered layer; ad-hoc per-PR watches are
  edge triggers on top and must cover EVERY terminal (new changes-requested, CI-red, breaker
  labels — not just merge). A subagent granted the PR flow owns its own cycle
  (`agents/jail-subagent-card.md`); the seat hears terminals only.

- **meta-events loop (REQUIRED, replaces the standalone needs-meta arm)**: `Monitor` (persistent)
  `bash agents/meta-events.sh` — the FU-166(b) consolidated 120s edge-detected loop (needs-meta
  absorbed as a source via `--once`, + goal-thread User comments, aggregated alert set, doorbell
  famine gauge). Cold state re-emits the standing set = the fresh-session bootstrap view. The
  SEATPR source is the anti-stall piece for seat PRs (PR#568 sat changes-requested overnight on
  2026-08-18 with only an ad-hoc watch armed — the standing set would have surfaced it in ≤120s).
- **needs-meta watch (legacy standalone — do NOT double-arm beside meta-events)**: `Monitor` (persistent) `bash agents/meta-needs-attention.sh`
  — unreviewed platform PRs, `agent/blocked` issues, unlabeled>24h, AND (clause 4, 2026-08-08)
  stack-repo codeowner parks (bot-approved+green+REVIEW_REQUIRED on oracle-fleet/circles — it
  caught circles PR#54 on its first pass; oracle PR#217 had sat 17h). ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — **2700 on a corpus session** (the per-type cadence rule above) — every
  sweep runs `bash agents/meta-throughput.sh` FIRST (queue-vs-movement; a THROUGHPUT-STALL line
  is an incident, not calm — 2026-08-09 operator catch), then
  `bash agents/meta-alert-crosscheck.sh` + the board/chain check against this file, then
  `bash scripts/jail-transcripts-sync.sh` (the §A1 jail leg, PR#580 — best-effort, loud skip
  while unreconciled; also run it once at wind-down).
- Handoff watch is NOT standing (operator 2026-08-09: special case) — arm `bash
  agents/meta-handoff-watch.sh` only on rollout days / when a stack jail is known active;
  `/handoff` processes the inbox on demand.
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
