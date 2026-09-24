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

- **FU-215** *(archived 2026-09-24)* — **Unbound's `github.com` SERVFAILs: root cause fixed, soak PROVEN.**
  Every SERVFAIL was "exceeded the maximum number of sends" — `do-ip6` on a v4-only WAN burned the send
  budget on unreachable v6 authoritatives. Fix 2026-09-16 17:55Z: OPNsense *Turn off IPv6* (GUI-only,
  `docs/runbook.md` §OPNsense as code) + the `prefetch`/`serveexpired` belt (`ansible/group_vars/opnsense.yml`).
  Acceptance: `UnboundGithubServfail` last fired 09-16 17:00Z (pre-fix), none in the 8 days since.
- **FU-203** *(archived 2026-09-24)* — **the first-party registry's retention: both halves live, the
  daily collector PROVEN.** Policy = oracle-fleet's nightly `retention` untag (02:30Z); collector =
  `registry-garbage-collect` daily 03:00Z (#1902). Acceptance: the 2026-09-23 03:00Z run took the
  `registry` bucket 19.6 → 9.8 GiB, and `RegistryBucketCommitHeadroomLow` has not fired since 09-22 20:41Z.
  The registry left Garage for the filesystem store 2026-09-24 — its GC and the S3 half's removal are
  **FU-280**; the rule lives in the header of `argocd/resources/registry/garage-workspace.yaml`.
- **FU-076** *(archived 2026-09-24)* — **"is `install.image` honoured from maintenance mode?" is now a
  detector, not a manual re-check.** The box belt's `schematic`/`ephemeral_disk` axes
  (`mgmt_node_drift`, FU-235) compare declared against live on every tick, and `MgmtNodeInstallDrift`
  fires on the plain-schematic outcome this item watched for. Read 2026-09-24, after wk-metal-02's
  09-20 maintenance-mode reinstall and the 09-22 rollout: all seven axes 0 on all 13 nodes.
- **FU-254** *(archived 2026-09-23)* — **the belt now asks whether the DECLARATION itself is stale.**
  `check_substrate` (`scripts/mgmt-probe.sh`) compares `tofu/variables.tf`'s declared Talos / Kubernetes /
  Cilium versions against each project's GitHub releases (cached 6 h — the belt ticks every 15 min) and
  publishes `mgmt_substrate_minors_behind` + `mgmt_substrate_supported`; `MgmtSubstrateBehind` (7 d, still
  supported) / `MgmtSubstrateUnsupported` (1 h) in `argocd/resources/mgmt-metrics/`. ⚠ The support windows
  are hand-encoded constants — mechanism and that caveat: [`management-box.md`](management-box.md) §MB2.
  First live read: talos current, kubernetes and cilium one minor behind, none out of support.
- **FU-261** *(archived 2026-09-23)* — **the PXE chainload's boot files are staged and PROBED.**
  `roles/matchbox-ipxe-tftp` no longer installs/configures/starts tftpd-hpa (dnsmasq owns :69 and masks
  it — that last task was what killed every run, leaving the copy before it unverified and
  `undionly.kpxe` absent for months). The role now ends by fetching all three files back over TFTP and
  comparing the served byte count with the staged file; `--tags verify` runs that probe alone. Applied
  2026-09-23: `undionly.kpxe` 74213B / `ipxe.efi` 850528B / `snponly.efi` 173792B served, second run
  `changed=0`. Recipe: [`provisioning.md`](provisioning.md) §The PXE pipeline.
- **FU-248** *(archived 2026-09-22)* — (b) `mgmt-tf apply` takes a plan id only (#1827); (a) the VM-recreate
  recipe, `-exclude`-shaped, never `-target` a config apply while a VM replace is pending: runbook.md
  §Recreating a Talos VM (#1893).
- **FU-238** *(archived 2026-09-22)* — external-provider roots plan READ-ONLY on the box: github (read-only
  PAT + App keys) and cloudflare (`cloudflare-mgmt-read`, verified 2026-09-22 as the box's ONLY Cloudflare
  credential, same hash as the wallet, active to 2027-01-01). The operator's host run exposed a `set -e`
  exit before the store step in `cloudflare-token-tf.sh` — fixed in #1893.
- **FU-278** *(archived 2026-09-22)* — rollout workload-health hold (#1891): rollout-start snapshot keyed by
  top owner + revision; a new unhealthy platform workload, or an important stack workload (≥2 replicas/
  instances or a PDB) on its same revision, holds (never reverts); ack file; `MgmtRolloutHeldOnWorkloadHealth`.
  Replay of 2026-09-22 holds on forgejo before cp-01. Operator ruling; §MB4 "Default forward" amended.
- **FU-264** *(archived 2026-09-22)* — **Talos API CA rotated in production; the leaked `os:admin`
  identity is dead.** Scope `--talos` only (spike's reasoning), per [`spikes/talos-ca-rotation.md`](spikes/talos-ca-rotation.md)
  §The recipe (#1888), run from the box 14:55–15:14Z: rotate-ca exit 0 on 13/13; state candidate A
  (bundle rebuilt from the 3 CP configs, identical; import byte-matched), P2 15 in-place, then `No changes`.
  Proof: every node answers the leaked cert with TLS `alert unknown ca` (server-side, verification off).
- **FU-276** *(archived 2026-09-22)* — failed-verb park clears only on `node-maintenance.sh verify`; the
  reconciler closes the verb's own window at park time (option i); Talos fallback-removal fact in §MB4. #1887.
- **FU-195** *(archived 2026-09-22)* — Alertmanager silences on a Longhorn PVC (`alertmanagerSpec.storage`),
  #1890 by the fixer lane. End-state probe: a silence created, pod deleted, silence still `active` after.
- **FU-033** *(archived 2026-09-22)* — **Talos 1.14 gate set: done, fleet on v1.14.1.** (a) `VolumeConfig
  EPHEMERAL mount.secure=false` on every node (VMs #1866, metal #1874 — `/var` exec verified on wk-03 and
  wk-metal-03); (b) contract pinned `talos_config_contract = v1.13.10` (#1874). Canary + rollback drill on
  wk-03 (#1866/#1872/#1873), then the first box-run fleet rollout (#1879) 09:43→13:17Z.
- **FU-273** *(archived 2026-09-22)* — **Rollout policy BUILT and proven**: §MB4 "The rollout policy" + "The
  rollout as built" (#1868/#1876/#1877/#1881). First rollout: 4 canaries, evidence-gated, 13 nodes incl. 3
  CPs unattended. Residuals: #1884 (FU-276), #1885 (FU-195), Garage PDB #1882 (hold), FU-097's ledger.
- **FU-267** *(archived 2026-09-22)* — **cilium-agent Burstable: 150m request / no CPU limit / 512Mi→1Gi
  memory.** Materialized in the first box-run Talos rollout: nx-01's restarted agent hung at 510/512 Mi,
  100 % throttled at 500m, no pod network. Guaranteed was unnecessary for its protections (kubelet
  -997 for system-node-critical; Talos OOM ranks memory-limited cgroups 0) — rationale in `tofu/cilium.tf`.
- **FU-275** *(archived 2026-09-22)* — **A canary override no longer downloads/deletes seed images.**
  `tofu/image.tf` splits the key: `vm_seed_key` (ROLE version) keys `proxmox_download_file` on pve +
  nx-02 and the VMs' ignored `file_id`; `vm_image_key` (declared version) keeps the installer URL.
  The override's `longhorn-v1.14.1` download pair left state in the same PR (fix/talos-apply-prereqs).
- **FU-243** *(archived 2026-09-22)* — **Three control planes behind the Talos VIP (ADR-133/-136).**
  cp-01, cp-02, wk-metal-02: three etcd members, the `cluster_endpoint` on the `.50` VIP, all three
  at v1.13.10 (live-verified 2026-09-22; operator: "three-cp program is done"). Doc survives:
  [`controlplane-ha.md`](controlplane-ha.md). Enables: CPs as a reconciler question (ADR-132 layer 3).
- **FU-242** *(archived 2026-09-21)* — **Spike: tofu-controller as the box's substrate — NO, keep
  hand-rolling.** Run on throwaway VM 9420 on nx-02 (deleted). Fails Q1 (runner tofu 1.12.1 vs pin,
  `upgradeOnInit` ignores the lock), Q2 (`backendConfig.disable` breaks saved plans), Q3 (in-repo
  `approvePlan` re-plans forever), Q5 (unreachable provider silent 36+ min). Idle RSS ~1.4 GiB. Side
  finding: a loopback-bound k3s API breaks in-cluster clients (§MB4 layer 7). #1862, spike doc §Verdict.
- **FU-265** *(archived 2026-09-21)* — **wk-metal-04's unparseable firmware boot entry: handled by
  `upgrade`.** The firmware re-writes `Boot0008` "UEFI OS" with 2 bytes after its end node on every
  firmware boot; upgrades reboot by kexec, so `node-maintenance upgrade` now runs `efi-scrub` between
  drain and install (deletes only entries whose path list does not parse; fails closed). Proven
  18:47–18:59Z: scrub deleted it, installer passed, node declared. Fleet DRY: only this entry flagged.
  Upstream issue deferred until the fleet is on the latest Talos (operator).
- **FU-252** *(archived 2026-09-21)* — **A standing `management-apply` refusal is DETECTED.** Residue-age
  belt `MgmtApplyResidueStanding` (github-exporter, from master's commit status, cdf01961 09-18);
  box-side belts for what a status cannot show — `MgmtApplyLoopStale`/`MetricsAbsent`/`MgmtBoxDown`
  on node_exporter + textfile, static job `mgmt-node` (#1850, #1851). Verified live 18:03Z: target
  up, `mgmt_apply_*` series present, no Mgmt* alert. Mechanism: management-box.md §standing refusal.
- **FU-266** *(archived 2026-09-21)* — **Second CI runner VM — DONE.** `ci-runner-02` on nx-02
  (`tofu/ci-runner.tf`, PR#1841, 192.168.2.66, VMID 9002), same labels as ci-runner-01; both slots
  "Listening for Jobs" 13:42Z. A pve outage is no longer a CI outage. nx-02 got `snippets` on `local`.
- **FU-263** *(archived 2026-09-21)* — **Nocloud VMs could not be version-bumped — CLOSED by the
  rollout.** #1829 made the disk image a birth seed (ADR-138), #1836 declared the CPs v1.13.10
  (applied: 0 replacements, 0 PKI), and `upgrade-behind cp` (#1837) moved cp-02 then cp-01 in place
  on the box — etcd 3/3 throughout, cilium backend 13/13. Two defects the first real run found:
  a pure CP has no Longhorn to wait for (#1838), and single-replica WARNs needed FORCE (#1839).

- **FU-253** *(archived 2026-09-21)* — **VMs declared a generic, stale `install.image` — FIXED and applied.**
  All six VMs carried the provider default `ghcr.io/siderolabs/installer:v1.13.0` (wrong platform —
  it reinstalls a nocloud VM as `metal` and ghosts it). #1829 sets it from
  `data.talos_image_factory_urls.vm[...]`, the URL the upgrade verb passes; applied 2026-09-21 in a
  window, wk-03 first (boot time unchanged, image == declared), then the rest (apiservers kept their
  start times, 0 restarts). Declared == passed == installed; ADR-138.

- **FU-259** *(archived 2026-09-21)* — **`talos_cluster_kubeconfig` renders a stale endpoint and
  `plan` never notices — FIXED and recovered the same day.** It captures the kubeconfig at create
  time and never re-reads it, so the ADR-133 VIP cutover left every client dialling `.51` while
  `plan` said `No changes`. Guards (#1825): a `check "kubeconfig_endpoint_current"` block that
  warns on every plan while the captured host disagrees with `local.cluster_endpoint` — verified
  firing on the live condition — and `client-configs.sh` refusing to write a mismatched kubeconfig
  *before* it reaches the box. `replace_triggered_by` was rejected: the fix cannot be planned
  unscoped, because the kubernetes/helm providers are configured FROM the resource. Recovery ran
  the same morning — scoped plan read first (exactly one resource), applied, `tofu/kubeconfig` and
  the box's copy now `https://192.168.2.50:6443`, 13 nodes Ready through it, full plan clean.
  Mechanism and the recipe: [`controlplane-ha.md`](controlplane-ha.md) §CP8.

- **FU-233** *(archived 2026-09-18)* — **Codeowner-gate trial week (ADR-128): re-read done, ruled.**
  Measurement: [`spikes/codeowner-catches.md`](spikes/codeowner-catches.md) §Re-read — 6
  freed-path-only machine PRs, 0 human touches, one real cost (worker PR#1700 archived FU-213 on a
  premise refuted 3 days later → FU-251). **Ruling (operator): leave the trial state AS IS and let
  it run** — the freed tier-2 paths are low-change and the management box moves them on its own once
  commit == rollout (FU-237/ADR-131). The residue landed with the ruling: the rubric's single-writer
  verb now blocks ANY worker write to the tracker, not only an append.

- **FU-206** *(archived 2026-09-17)* — **Operational paths are non-public on every PublicRoute
  (ADR-123).** Built after an oracle handoff showed Googlebot walking `mcp.minutark.ee` (a 404
  `robots.txt` = crawl everything) with `/metrics` answering 8.8 KB of Prometheus exposition —
  the risk moved from "readable" to "on course to be indexed". TWO legs, because the dry-run
  through cf-api-proxy turned up two facts ADR-123 did not have (cloudflare.md gotcha 8): a zone
  admits ONE ruleset per phase (20217 — observed live at last), so the edge rule can only serve
  the single claim per zone owning `http_request_firewall_custom`; and `block` + a custom
  response is not entitled in that phase on Free, so the body is Cloudflare's block page, not
  ADR-123's structured JSON. Leg 1 = the claim's own tunnel config refuses
  `^/(metrics|healthz)(/|$)` at the connector — per-claim, so it carries the default on EVERY
  claim and zone. Leg 2 = one more `block` rule, first in the api claim's custom-phase ruleset,
  keeping the traffic off the home connection. Opt-in: `.spec.operationalPaths.public`. Same
  change fixed a latent defect the probe exposed — #1304's CORS preflight rule carried the same
  illegal custom response and would have failed at apply for the first claim setting
  `.spec.origins`. Verified live on `mcp.minutark.ee`: `/metrics`, `/healthz` + subpaths → 403,
  `/metricsx` → origin 404, `/` → 405, in-cluster `/metrics` → 200. ADR-123 amended; the edge leg
  goes profile-agnostic with FU-039's zone-phase aggregation. Detail: `docs/cloudflare.md`
  §PublicRoute.

- **FU-232** *(archived 2026-09-16)* — **Reporter-keyed subject collapse: fixed at the cascade.**
  The responder's `subject:` — which IS an issue's identity under the #149 one-subject rule — was
  the metric's EXPORTER whenever the failing object had no pod dimension of its own, so 19 of 28
  triage comments in the 09-04→11 week grafted onto five reporter threads (#811/#882/#542
  kube-state-metrics, #241 pushgateway, #103 node-exporter, #884 `ns:monitoring`). Shipped in
  homelab#1733: the cascade reads the object's own labels (`daemonset`/`statefulset`/`deployment`/
  `job_name`) BEFORE `pod`, and skips `pod` entirely when `job` names a monitoring scrape job —
  structural rather than a pod-name regex, because kube-state-metrics is scraped with honorLabels,
  so a metric that HAS a pod dimension legitimately keeps it. With no object label the key falls to
  node, then `instance:` (the failing target, verbatim), then per-class `alert:<name>`. Evidence:
  the live 2026-09-16 label sets — `KubeDaemonSetRolloutStuck` arrives carrying
  `daemonset=runner-image-prepull-pve` AND `pod=…kube-state-metrics…`. Pinned by
  `agents/replay/fixtures/responder-subject/{daemonset-reporter-pod,node-exporter-instance,statefulset,witness-pod-owned}`
  and by `responder-behaviour-test.sh` §#149, whose graft scenario had been asserting the pre-fix
  subject as correct behaviour. ⚠ The re-key RETIRES the magnet threads: each affected
  (alert, object) files one fresh issue on its next fire and the magnets stop collecting.

- **FU-213** *(archived 2026-09-14)* — **opencode.ai un-parked: the client now sends
  `x-opencode-session`.** Parked 2026-09-04 (operator mail: our UA sent no such header, "may
  error" from 09-06) behind `OPENCODE_RAIL_DISABLED=1`; closed by homelab#1640 acceptance 2
  (homelab#1667). What shipped: `_forward_upstream` attaches `x-opencode-session: <the ride's
  session ref>` on BOTH opencode legs (never to OpenRouter), the value being `_cb_session()`'s
  opaque ref — the SAME id that keys the breaker and the (session, model) pin, so affinity is
  bound to the ride, not the installation (the hardcoded-id trap the thread named); the Go/Zen
  arms now compute `cb_session` (they left it `None`); `OPENCODE_RAIL_DISABLED` back to `"0"`
  (the knob stays as the operator's kill switch). Evidence: `devbox run proxy-self-test` — Go
  and Zen legs carry the header, a direct-key ride degrades to `direct:<hash>` (never `None`),
  OpenRouter never sees it. Gotcha: a direct-key ride's identity is a key-hash bucket, not a
  per-ride id — the remaining seam, not this fix. Prior art: earendil-works/pi#4847.

- **FU-236** *(archived 2026-09-13)* — **`homelab-sentinel` App cutover (ADR-130), all four steps
  the same day:** App 4929271 created/installed + ESO chain (`sentinel-git.yaml`); `sentinel-argo`
  switched direct (guarded file), first status under homelab-sentinel[bot] 11:17:58Z;
  `integration_id` pinned on 11 rulesets (`github-tofu apply`); reviewer `statuses` write→read
  (#1614). Gotcha: the console un-grant came BEFORE the mint narrowing merged → the reviewer
  mint 422'd at its 11:45 refresh; un-wedged by applying the narrowed generator by hand. For a
  NARROWING: merge first, click second (the reverse of a widening).
- **FU-225** *(archived 2026-09-08)* — **pve host RAM: no buy, no balloon, one belt.** Filed the
  same morning as "84 %/94 % used, ballooning off"; by evening the operator had ruled every lever:
  no RAM in this box (too much of homelab on it — the second hypervisor is the answer, ROADMAP §HA
  model, ADR pending), ballooning impossible (Talos ships no `virtio_balloon`, verified on wk-03),
  right-sizing done where it is not page cache (ci-runner-01 16→12 GB, funding wk-03's 16 GB for
  ARC — FU-218). What shipped: **`PveHostMemoryLow`** (MemAvailable < 3 GiB for 15 m; PR#1520) with
  a behaviour fixture, because the host now commits 65 GB on 62.7 GiB and lives on KSM (~11 GB
  shared, 7-day minimum 3.8 GiB available) with nothing watching. Supply side stays in the hardware
  repo (R8: the Micron RDIMM lot fits either box).

- **FU-222** *(archived 2026-09-07)* — **the fleet-disk probe is a recipe now**:
  `docs/runbook.md` §"Reading a fleet disk's identity and health" — an ephemeral privileged pod
  (`nodeName` + `tolerations: Exists` + `/dev` and `/sys` hostPaths, alpine + nvme-cli/smartmontools),
  with the fields that actually decide something (standardized `percentage_used` over Kingston's
  `SSD_Life_Left`; link speed/width + CRC count = cable, not drive; `oacs` says Opal-capable, not
  Opal-locked). Captured **from a live run, not reconstructed** — read the M70s's OEM Micron 2300 at
  its 2026-09-07 onboarding: 2 % used, 3 051 h, 0 media errors, PCIe 3.0 ×4. The onboarding skill now
  calls it as step 10, so the next disk is read at onboarding rather than when it is already suspect.

- **FU-207** *(archived 2026-09-04)* — **ci-runner-01 recreated from tofu** (`tofu apply`: the
  cloud-init snippet replaced + VM 9001 created, 1m57s), after FU-093's pool meter existed and the
  pool had ~120 GB headroom (66 %). Cloud-init re-registered both runner slots (`--replace`, "√
  Successfully replaced the runner" ×2), docker 29.8 up, `fstrim.timer` enabled+active, discard
  honoured (DISC-GRAN 4K). Pool 67 → 71 % once the guest had its images. ADR-082's lane is back.
- **FU-011** *(archived 2026-09-03)* — **provider-terraform pinned to a digest** (the running
  revision's resolved digest, `argocd/resources/crossplane/provider.yaml`), in the #1315 gate PR
  that also pinned the three Terraform provider versions in the ProviderConfig. Evidence: the
  digest is the pod's `imageID`; ArgoCD sync leaves the revision unchanged.
- **FU-196** *(archived 2026-09-02)* — **ghcr single-point-of-dependence for the oracle corpus:
  RESOLVED by ADR-121.** v0 (mirror creds) 2026-08-30; v1 (first-party push-mode registry on
  Garage, `registry.teststuff.net`) built + cut over in one operator-attended session 2026-09-02
  after the #1282 recurrence: PR#1296+quickfixes, oracle-fleet#352 dual-publish, oracle-iac#490
  pin flip, `REGISTRY_PUSH_TOKEN` via the new secrets-sync single-value row (PR#1298).
  Acceptance evidence: wk-01 pulled the 6.4GB corpus from the LAN registry in 6m31s in
  production; dispatch proof run released BOTH targets digest-verified. Residuals live on:
  FU-203 (retention), #1297 (per-blob detection), ingester-image migration = optional later
  (ADR-121 notes it). Gotcha trail in the ADR + the registry manifest headers (debug-port
  collision, ping-must-challenge, RELATIVEURLS, s3 redirect-disable).
- **FU-052** *(archived 2026-08-30)* — **Onboard the remaining app repos: nothing remains.**
  agent-runtime onboarded 2026-08-07/08 (PR#37 — recipes, tests, CODEOWNERS; the claim's fixer
  flip); snore-recorder 2026-08-02 (FU-051's leg — #15 recipes/CalVer/deploy-pin, sleep-iac#57
  fixer block); agent-coordinator stays CONTEXT-ONLY by the kept 2026-07-16 ruling (tier-3 loop
  machinery, no repo-side lane — recorded in the platform claim). New repos enter via
  `new-stack --from` (FU-070). ROADMAP §Onboard reflects the same state.
- **FU-173** *(archived 2026-08-25)* — **Grafana frser plugin pinned 4.0.6.** PR#935 + the
  same-evening syntax quickfix (8bd4dc67): Grafana's background installer parses `id@version`
  — the docs' legacy `id version` space form SPLIT, installed "4.0.6" as its own pluginId and
  crashlooped the new RS (old pod kept serving; the gotcha is now a ⚠ comment at the pin site).
  Verified end-to-end: 4.0.6 in-pod, app Synced/Healthy, `grafana.teststuff.net/api/health` 200.
  Renovate owns the bump from here.
- **FU-149** *(archived 2026-08-25)* — **Responder daily budget = 12: the soak answered LEAVE IT.**
  The 14d read (daily `max(responder_triage_sessions_today)`): ordinary days 0–6, the cap bound
  only on genuine storm days (08-18 the board-clearing/ARC day = 12, 08-24 the pve/Garage
  incident = 11) — which is what a storm cap is for. `RESPONDER_DAILY_MAX` stays 12; a non-storm
  exhaustion re-opens this as a new datum, not this id.
- **FU-184** — **Garage's metadata auto-snapshot never worked; env rebuilt.** `MDB_CP_COMPACT`
  refuses a page-leaked env by arithmetic (mdb.c "page leak or corrupt DB"), and the 08-24 torn
  write left 4,745,586 pages for ~550k live ones — plus 8 freelist records stranded in the main db,
  which is what broke `garage convert-db` too (it also rejects lmdb→lmdb outright, so the tracker's
  original recipe was wrong twice over). Rebuilt by insertion with
  `scripts/garage-forensics/lmdb-rebuild.py` (PR#911): **18.10 GiB → 1.57 GiB**, 67 trees /
  4,279,175 entries exact, every bucket count unchanged, meta volume 62% → 6%. Container limit
  512Mi → 2Gi — a healthy env makes the copy ~15 s instead of ~11 min and the first fast one
  OOM-killed Garage. **Acceptance PASSED same day**: a snapshot completed (1.68 GB, 67 trees,
  4,280,149 entries, zero junk keys, tracking live), no OOM, `restarts=0`. Mechanism:
  [`garage.md`](garage.md) §Durability. Pre-rebuild copies held in
  `backups/garage-meta-20260825-prerebuild/` — delete after ~2026-09-01. (archived 2026-08-25)
- **FU-179** *(archived 2026-08-23)* — strike policy RULED (operator, G-A child homelab#783):
  `ROUTER_STRIKE_ENFORCE` retired as a blacklist knob — 16-day store read = six strikes, five one
  goose-harness class; enforcement would have changed ~1 decision for cents. Strikes stay
  RECORDED; cooldowns carry the residual class. Code deletion rides the G-A legacy sweep
  (deletion site named in `model-routing.md` §M1a). Re-open = post-flip per-model class the
  cooldowns miss → new design with the provider dimension (the #783 thread's legs; future home =
  the ROADMAP G-E candidate). Fan-out → the free-model evidence lane, same candidate.

- **FU-117** *(archived 2026-08-23)* — context-delivery dedup: COMPLETE via stint S4 #762,
  all three legs same day. The role×context×source map lives at
  `docs/agents/roles.md` §Context delivery. #763: `agents/ground-rules.md` = the ONE universal
  source, launcher-injected with a loud degrade (the `-r && -s` guard + the missing/empty/
  unreadable replay trio). #764: homelab CLAUDE.md is facts-only; seat procedure =
  `agents/jail-seat-card.md`, composed by the mono jail's entrypoint into
  `/workspace/homelab/CLAUDE.local.md` (claude-jail#1 — two recipes; stack jails get a
  `STACK_*`-rendered env card and deliberately NO seat card). #765: meta-state durable
  warnings evicted to runbook/card/owned docs. Residual (NOT tracker-held): the fleet
  CLAUDE.md slim-down, inventoried + tiered on the claude-jail#1 thread, executable on the
  operator's word.
- **FU-163** *(archived 2026-08-23)* — glossary + vocabulary pruning: COMPLETE via stint S4
  #762. The glossary is live (`docs/glossary.md`, ⚓-anchored term list); the researcher
  `goal`→mission rename executed (#766/PR#771 — verified: no machine predicate ever read the
  bare label, the legacy labels were already deleted by the authoritative IssueLabels sync;
  `mission` reserved for FU-090(c) graduation); docs-graph-lint check #3 flipped warn→fail
  with anchors widened on measurement (#767/PR#772 — the shadow loop was a pipe-subshell, the
  flip required restructuring). Residual ambiguous-prose "goal" rewords ride docs-cleanup as
  standing practice, not a tracker item.
- **FU-183** *(archived 2026-08-23)* — GithubActionsMinutesHigh flat threshold → pro-rated
  burn expr: SHIPPED by the cluster loop (homelab#746 → PR#756, stint S7 #741) — fires when
  month-to-date usage exceeds the elapsed quota share with a start-of-month floor; promtool rows
  in loop-health.promtool-test. Residual (silence `5400ed94…` self-expires 2026-09-01; a normal
  month evaluates green post-cutover) is #741's acceptance, not a tracker item.











