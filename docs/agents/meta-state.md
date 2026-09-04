# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-25 evening, the sweep-pipeline session — history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ 2026-09-03 ~18:40Z (the #532 pre-merge support session — TICK-LOG has the arc). Fresh-session
  pickup:**
  - oracle-fleet **#414** filed under bucket #386 (the #410 platform-read fixes: absolute /status fetch,
    Cache-Control per asset, 429/403 wording) — inert (`agent-fix`+`task/fix`), operator queues.
  - **2026-09-04 ~08:30Z — the three incident pickups are DONE (this session): FU-093 pool meter
    LIVE (pve node_exporter textfile + `pve-metrics` app, PR#1367), ci-runner-01 RECREATED
    (FU-207 archived; both slots registered), pre-puller UN-PAUSED in its FU-208 shape (9/9 ready;
    FU-208 re-headed to the image-size leg). Pool **71 %** with ci-runner-01 back — the first
    `PveThinPoolFillingUp` (80 %) may fire within days; the answer is the fstrim jobs + FU-093's
    next act (Longhorn filesystem-trim), not a threshold bump. Longhorn healthy; PR#1365 merged.
  - **#1334 check 1 OBSERVED** (api 429 served on Free, Retry-After 10; handoff task from the oracle seat
    relayed + closed) → **PR#1365** flips the docs; merge when the bot approves. #1334 state: 1+2 ✅, 3 ✗ RUM
    residual — the human's `goal/validated` verdict on #1302 is now unblocked on evidence.
  - **Handoff inbox (oracle) still holds two older tasks** — `20260903-1245-ci-red-data-point-391…` (data
    point + suggestions, "not an ask"; read for a new class, answer) and `20260903-1815-in-pod-kind-unrunnable-issue-399-r1`
    (pointer: kind node segfault in a kata pod + mirror pull path; needs the ride's transcripts). Next `/handoff`.
  - **Sentinel latency root-caused + fixed direct (cfb98bbb):** the runner-image auto-bump named
    reflexes-argo.yaml (no pin) so sentinel-argo.yaml sat on the 2026-08-17 bake and re-copied every
    lock drift per run (~3.5 min of 4–5); pin → 2026.9.3 + bump list corrected. Template synced 21:10Z;
    verify the next runs' bootstrap ≈ 0 `copying path` lines and the iac-sentinel status floor ≈ scan+queue.
  - **Apex flipped 21:22:44Z** (tunnel config v2 → static-site); gotcha 7 recorded (PR#1363 merged):
    502 window = Workspace reconcile, cache window = silent origin + no Cache Purge token (operator
    purged via dashboard). Decision open: mint `Cache Purge` onto tofu-apply, or rely on #414's Cache-Control.
  - ~~Request map v2~~ MERGED (PR#1361): applies_to, CTR-CACHE, depends_on, static-site template;
    addendum posted on oracle-fleet#176.
  - ~~Request-map pattern~~ MERGED (PR#1360 → 7747ecfa, CI step included); template pointer posted
    on oracle-fleet#176 (the oracle repo owns its real map). Platform legs left: **FU-206** (ops paths
    blocked at the edge), **S5** (Skip drops the Free managed WAF — live evidence: the managed WAF is
    blocking /wp-config.php scanners on the apex today), **S4** (ddos_l7 outside the Skip — verify
    the Free override) — cloudflare.md completion table; `CTR-ACCESSLOG` (ray + stage id access
    line) proposed as the next contract row; Tempo deferred until an emitter exists (assessment in
    this session's transcript, no FU filed — file one if the operator wants it staged).
  - **PR#1359 (records: ADR-123 operational paths non-public by default + FU-206 build + glossary
    row)** — merge when the bot approves; FU-206 is the next platform build on the edge (one more
    rule in the merged custom-phase ruleset, both profiles, dry-run through the proxy first).
  - ~~PR#1358~~ MERGED + APPLIED (operator token modify 18:5xZ, jail redirect apply 19:00Z):
    `www.minutark.ee` → 301 apex, verified; evidence on PR#1358 + fleet#360. Shared tree back on master.
  - ~~PR#1357~~ MERGED + `publicroute` Synced 5ceecdd5 (18:45Z): the platform precondition for
    oracle-iac#532 is met (told on #532). PR#1356 MERGED: probes Ready, all four alerts cleared,
    `cloudflare_edge_probe_ok` live. **PR#1357 (composition: api profile Free-plan shape) MUST merge + `publicroute` app Synced
    BEFORE oracle-iac#532 merges** — else `mcp.minutark.ee` serves with no rate limit/Skip
    (evidence on #532). Then, once #532 lands: verify Workspace `pr-oracle-fleet-mcp-minutark`
    Synced=True (three rulesets on minutark.ee: ratelimit + firewall_custom + cache), run
    **#1334 check 1** (≥200 req/10 s from one IP → 429 with the JSON body, no interstitial),
    and **re-point the jail's `~/.claude.json` oracle connector to `https://mcp.oracle.teststuff.net/`**
    (endpointPath moved to the root; the agentstack.yaml re-point is asked for in #532).
  - **PR#1356 (probe status line + #1340 residual)**: on merge verify both probe pods Ready,
    the four alerts resolve, and `cloudflare_edge_requests_total` appears — that is #1334's
    edge-series evidence source.
  - Operator reads surfaced, not owned here: public `/metrics` on the api hostname (fleet);
    `www.minutark.ee` HTTP-404 (fleet #360 consumer half; tunnel config routes only the apex).
- **⚑ 2026-09-03 ~13:00Z WIND-DOWN (the goal-stalls design-agents sitting — TICK-LOG has
  the arc). Fresh-session pickup:**
  - **ADR-122 landed (PR#1344; verify merged)** — filing inert / walk retired / one parser /
    container-written disposition; **S8 re-headed** (ROADMAP). Build order: the walk
    retirement is hotfix-class and may land BEFORE the stint — nothing filed for it yet
    (operator's call whether the seat cuts it next sitting or S8 opens with it).
  - **Codeowner reads done**: #1343 #1339 #1273 merged/approved; **#1290 + #1289 carry seat
    in-diff fixes** (deferral-not-refusal on a gh outage; one home for the `ci-cause:` spec) —
    approve once the bot re-approves at the new heads (`gh pr view` reviewDecision). **#1295
    HELD for the operator**: under ADR-122 it is one more grammar reader (report-only,
    harmless) — merge as an interim belt or close as superseded.
  - **Oracle un-wedge**: PR#391/#392 carry the seat's hand-applied round-4 directives (CI is
    the judge; arbitrate labels stripped, #356 → review); #394's CI rerun re-armed its ci-red
    fingerprint; **oracle-iac#531** (the #530 two-liner, CI-only lane) → on merge verify the
    apex XR binds and the consumer profile renders (cache ruleset + RUM on minutark.ee), then
    #1334's checks 2/3 become observable; #360 (fleet) then wants the `mcp` api claim
    (oracle-iac#485 — oracle jail's). **homelab#1342 QUEUED** (router→opencode unprefixed
    model; agents/** → parks on the seat). #1338 CLOSED with the pointer. The state-fp
    debounce issue filed + queued (FU-199 face). #1334 stays `agent-fix`+`agent/error` until
    #1249/ADR-122 land (the damper).
  - **G-G's SECOND LAYER was never widened — the token.** After oracle-iac#531 landed: the
    composite refused on `claimRef` v1alpha1 (seat patched the XR — docs gotcha 5, PR#1346);
    cf-api-proxy served the pre-G-G allowlist (FU-190 fourth sighting; `rollout restart`);
    then Cloudflare 403 "Authentication error" — `homelab-ingress-write` is v1 (DNS+Tunnel).
    **PR#1348 merged + APPLIED (operator, 12:11Z/12:19Z; plan "No changes" after the seat matched
    the file to the API's read-back — the policy order FLIPS on every modify, recorded in the
    file header, committed `588c8e11`).** Token value unchanged, so no re-store. With it live the
    apply moved to the PAYLOAD: cache rule 400 (20107, `respect_origin` takes no `default`) →
    **PR#1353** (composition + docs); RUM 403 stays — **no Web Analytics/RUM WRITE permission
    group exists for a user token** (395-group list + docs), so the consumer profile's RUM
    half is undeliverable through this token: design residual for #1311 (dashboard RUM /
    account-owned token / drop RUM from the profile) — the Workspace stays Synced=False on it
    while the cache rule lands independently. **VERIFIED 12:3xZ after #1353 synced: cache-phase ruleset live on minutark.ee, apex
    `cf-cache-status: HIT` (max-age 14400) — #1334 check 2 OBSERVED (evidence comment on #1334);
    check 3 = the RUM residual above; check 1 waits on the api claim (oracle-iac#485).**
  - **Oracle hand fixes REFUTED both coordinator diagnoses**: PR#391 still "Deployment not
    Ready" with probe/warm-up untimed (evidence dump added to e2e-serve.sh on that branch —
    the next red carries pod logs); PR#392 still 403 with the live-pod forward (seat's own
    port slip fixed → 8080; CI re-running). Both ride the ordinary ci-red path again; if
    they arbitrate once more it is the oracle jail's read, not another flash round.
  - Not done, named: #176's stale blockedBy on stint #269 (holds nothing; misleads); the two
    Error coordinator pods in `oracle-agents` (throttle-era noise); FU-084/FU-098 stale-archive
    entries (next docs-cleanup). **Reviewer STEP-0 false anomaly (PR#1289, 11:42Z):** the arm
    compared its 09-02 approval's commit date against an updater-rewritten date and latched
    `agent/error` on a plain human push — cleared by the seat; a FU-199-shaped face for the
    state-fp issue's neighbour (not filed; one instance).
- **⚑ 2026-09-03 ~10:05Z WIND-DOWN (the #1315 gate + git-throttle + G-G merge session — TICK-LOG
  has the arc). Fresh-session pickup:**
  - **G-G merged (#1336 → 7cde3dd4, seat as codeowner); #1302 is post-launch.** The verdict
    (#1334) waits on THREE queued fixes the rollout exposed: **oracle-iac#530** (apex claim →
    v1alpha2 + `profile: consumer` — landing it IS the live cache+RUM change), **#1340**
    (edge-probe GraphQL query schema-invalid live; verified shapes in the issue; the
    `cloudflare-exporter` app is Degraded until then), **#1335** (dead proxy location). Design
    residual **#1338** (one claim per profile per zone). Live un-wedge done: the Composition
    was `kubectl replace --force`d (compositeTypeRef immutable — doc gotcha 4, #1341 merged).
  - **Git-throttle watch**: PR#1333 (+72dcf12e) made every loop clone preemptively
    authenticated. The first full day decides whether the WAN IP stays clear; a recurrence
    with zero anonymous requests = FU-007 push-mirror becomes the next deliverable
    (incident record §Recurrence; memory `git-preemptive-auth`).
  - **PR gate queue (ADR-110 corpus read)**: **#1273, #1289, #1290, #1295** still parked —
    this session never loaded the corpus and did not execute the gate.
  - **#1200 residual named**: no ArgoCD sync-failed/OutOfSync alert exists (the coordinator
    CNP sat un-applied 35h unnoticed; fixed #1337) — a belt to add, beside the CNP schema.
  - Operator-owed unchanged: #1308 queue call, FU-205 design pass.
- **⚑ 2026-09-02 ~16:00Z FINAL WIND-DOWN (the ADR-121 + three-incidents session — TICK-LOG has
  the full arc). Everything VERIFIED closed: registry cutover production-proven (wk-01 LAN pull
  6m31s; dual-publish run green both targets); loop healed (composition was the third home of
  the anonymous-clone idiom — `0c6d00f7`; trapped tick green 13:04Z); kind/inotify incident
  closed (e2e green post-fix; janitor live+templated; ⚠ ci-runner `debian@` SSH = the FORGEJO
  keypair, tofu/ci-runner.tf). Fresh-session pickup:**
  - **PR gate queue (ADR-110 corpus read)**: master-bound machine PRs **#1295, #1290, #1289**
    parked open; #1313 (kind-ci pattern, seat) auto-merges. G-G is EXECUTING — child PR#1312
    already open onto `goal/1302-public-edge` (feature→goal automated; **goal→master stays
    operator**).
  - **Operator-owed**: #1308 queue call (BuildKit mirrors); FU-205 design pass (WAN accounting
    — family-privacy VLAN-vs-router-local fork + CI-VM counters); eventually the G-G
    goal-branch merge + #1302 verdict.
  - **Residuals tracked**: FU-203 (registry retention), FU-204 (C4/C5 limbo), #1297 (per-blob
    detection), OTLP-spam env cleanup (registry + 3 mirrors), garage resync worker tuning is
    EPHEMERAL (resets on garage-0 restart).
  - **(superseded pickup below kept for provenance)**
  - **Seed retry gate**: garage resync drain monitor was running at session end (jail task
    `bvwh4d6wa`, retry when queue <300). Retry = skopeo push of `oci-layout` in the session
    scratchpad → `registry.teststuff.net/oracle-fleet/ert-corpus:2026-09-01` (creds: Infisical
    `REGISTRY_PUSH_TOKEN`, user `releaser`); expect digest `cb735ff…`. Failure mode seen twice:
    Garage `Missing block` on the commit-time multipart copy (dedup'd blocks raced deletions
    from killed attempts — debris since cleared, worker tuning resync-worker-count=4/tranq=1
    set EPHEMERALLY on garage-0, resets on pod restart).
  - **Pin flip READY, unpushed**: oracle-iac branch `fix/corpus-pin-local-registry` (local
    commit) — push + PR ONLY after the seed verifies (else the rollout pulls a 404).
  - **OPERATOR console step owed**: `REGISTRY_PUSH_TOKEN` repo Actions secret on oracle-fleet
    (value in Infisical) — until set, release-corpus dual-push loud-skips (PR#352 merged).
  - **Cleanup queue**: OTLP trace-export spam (`localhost:4318 refused` every 5s) in registry
    AND all three mirrors — add `OTEL_SDK_DISABLED`-class env; the ingester rollout resolved
    itself via mirror (~11:0xZ) so no urgency; FU-203 (registry retention) + #1297 (per-blob
    detection gap, filed at the PR#1292 gate read) queued.
- **⚑ 2026-09-02 OPERATOR SITTING WIND-DOWN (~09:30Z) — batch-1 verdicts + G-B rulings + two
  grants landed (TICK-LOG entry has the arc). The fresh-session pickup set:**
  - **Verdicts applied**: #1039 + #775 `goal/validated` (operator via seat; #778 released to
    FU-181). VERIFY next session: the IL-T19 close sweeps actually closed both trees.
    **#1162 holds ~24h**: validate when #1247's soak-to-zero reads clean (~09-03; drops were
    0/4h at 06:30Z); its close sweep disposes store entries 28–30 + bucket #1170/#1200.
  - **#818 HELD with a posted verdict condition** (4 clauses on the goal): teeth drills DEFERRED
    to oracle's production launch (first-week no-users experimentation window, operator ruling);
    lens posture RULED advisory-steady-state (roles.md §Lenses; future = MORE oft-triggering
    lenses); responder = shadow (#1274 → PR#1278 MERGED, REMEDIATION-WOULD live — read STACK
    rows only; oracle-first arming later); prober = #1275 (S3 sink, queued) → oracle-fleet#344
    (class-1 adoption, blockedBy #1275 — the rollout-procedure PILOT; #289 closed re-homed).
    Class-2 stays operator-manual (consumer-model cells, GPT-5.2-Luna-class).
  - **#1095 grant LIVE + PROVEN**: PR#1287 merged — per-stack `loop-intake-git-*` (issues-only
    on homelab, role=intake); proof comment on #1095 posted WITH oracle's own intake token.
    #1288 queued (env-dependent proxy self-test — false-red in jail runs, the FU-153 class).
  - **opencode MCP arm MERGED (PR#1284) + live canary PASSED** (1.18.21 × shipped config ×
    live oracle server, statute round-trip — evidence on #1276). Harness matrix closed on all
    three → **the dispatch-declared `requires:` FU is now sanctioned to file** (operator's
    conditional — next session files it). ⚠ INCIDENT owned: the seat's first canary attempt
    deleted live pod `agent-oracle-fleet-issue-321-r2` (newest-pod pick after a refused
    dispatch) — attribution comment on #321; loop re-dispatches; never delete a pod you did
    not verifiably create.
  - **ADR-103 gate false-positive class CLOSED** (operator-direct `326ce6e7`): comment-only
    diffs exempt (#1215), stacked-base = warn-never-verdict (#1225 faces 1+2), contract doc'd
    in workflow.md; #1215/#1225 closed, **#1224 (parts-coverage) = the remaining item, future
    operator sitting**. `#1255 done` — `.agents/build.yaml` on master (`a0fc3347`).
  - **#1280 HELD-FOR-EVIDENCE** (operator: kind-timing suspicion needs a distribution first);
    **#1286** (ci-cause marker + ledger column — the CI-failure database leg) queued.
  - **/handoff ×2 processed → done/**: e2e-blind-rounds → #1280 + #1281(closed, re-routed
    stack-side Allure) + ar#116 (stale-evidence check); ghcr mirror BOUNCED (poisoned blob now
    200) + #1282 queued (narrowed to alert+runbook).
  - **Oracle**: #345's bolded `**Touches:**` repaired (was serializing the repo — #347 held,
    #348 behind its edge); **#1294 queued** (TOUCHES-MALFORMED scan detector, the G4 surface
    fix). ⚠ MERGE ORDER: #347 → #348 land into `goal/326-dashboard-as-code` FIRST, then the
    operator's codeowner merge of assembly PR#346 (bot-approved, parked) — merging early
    strands their `Base:` at a dead ref (the #211 class).
  - **Riding at wind-down**: #1268/PR#1273 review cycle (round ~6, nearing the 8-verdict
    arbitration ceiling — un-armed human-merge tier, the seat merges at green+approved);
    queued rides #1222 #1282 #1286 #1288 #1294 + #1275 flowing on the platform loop.
  - **Tracker debt for the next sweep** (goals-first plan now discharged): 81 open FUs,
    6 OVERSIZE, 17 stale-archive entries; FU-200/201/202 archive candidates; then
    board→fu→docs pipeline (last full run 08-25).
- **⚑ 2026-09-02 ~05:15Z WIND-DOWN — WAVE 2 + ROUTER GOAL MACHINE SET BOTH COMPLETE (the
  unattended corpus session, ~8h).** Belts assembly **PR#1272 MERGED** (seat-opened under the
  manual pilot — checkpoint store sat 2<5, the S8 delta-4 gap; one surface-widening round =
  store-entry-19 recurring, S8 delta-2 evidence; adoption readout = store entry 30 on #1162);
  theme #1239 closed → **Goal #1162 tree = bucket #1170 + operator legs — the operator's
  `goal/validated` read is NEXT**. Sprout tail: #1265/#1270/#1271 read+approved serially
  (#1271 merge confirm pending at wind-down); **#1269 (#1266 ref-cache punch) mid fix-round**
  on a vacuous-pin CHANGES_REQUESTED — its park is the NEXT session's read; #1268/ar#115
  (G3 provider attribution dead in prod — /report sends no session ref) inert, checkpoint
  disposes. ⚠ STANDING: the #1249 damper (agent-fix-only on #1237/#1238/#1239 — #1239 now
  CLOSED so moot there) must outlive until the walk exclusions land; #1255 (.agents/build.yaml
  paste) = operator sitting. FU-201 COMPLETE end-to-end (a: PR#1265 enforcement, b: PR#1241
  carrier); FU-200 (PR#1258) + FU-202 (PR#1253) delivered — all three archive candidates at
  the next fu-sweep.
- **⚑ 2026-09-01 LATE NIGHT — WAVE-2 QUEUE ACT EXECUTED (the unattended corpus session).**
  PR#1228 (scan assembly, theme #1163) MERGED `846c0f76` ~22:20Z after the seat's ADR-110 read;
  #1163 closed; PR#1208 (#1151 Touches-classifier lint) merged first (blocking-class, unparked
  #1153 — which rode r2 same hour). Bookkeeping pushed (`c500394f`), top hop landed (master →
  `goal/1162-belts`, `30859bde`), **all 7 wave-2 members queued** (#1240 #1198 #1199 #1211
  #1212 #1223 #1229) + platform rung. PR#1241 (G1 #1232, FU-201 a+b carrier) codeowner-read +
  approved + merged (#1232 closed; post-launch bucket #1243 auto-minted). **#1213 + #1242 both
  MERGED ~22:35–22:42Z after serial re-park approvals — the park pile is DRAINED**
  (CodeownerParkWaiting cleared): themes #1163/#1164/#1165 all closed, #1153 closed. Goal
  #1162 stays OPEN on wave-2 theme #1239 (members riding: #1198 done r1, #1211/#1199 riding,
  rest queued+serializing); the operator's `goal/validated` read comes at tree-empty. #1210
  closed via PR#1221 (PR#1216 = anomaly duplicate). FU-171 header repair + 3rd resight
  (reviewer token died mid-31-min review on #1228; 46-min pod-key stall) recorded `c500394f`.
  Egress-dial monitor CNPs now LIVE in agent-coordinator + loop namespaces (via #1213) —
  acceptance-3's enforce flip comes AFTER clean harvested rides, a later sitting.
- **⚑ 2026-09-01 NIGHT — GOAL #1231 LIVE (router-first, operator-launched; the NEXT session's
  role is MONITOR + GATE-READ).** Tree: G1 #1232 (label_map md/lg + re-grade plays, FU-201 a+b)
  · G2 #1233 (key-class re-mint, FU-202) · G3 #1234 (provider-attributed strikes +
  pair-exclusion, blockedBy #1233) · G4 #1235 (fleet-strike reader, FU-200) · G5 #1236
  (provider_policy/exacto, FU-186 step 1) — all queued, platform rung; E1 #1237 (FU-174
  effort spike) + E2 #1238 (0731 matrix run + model_tiers verdict PR) = OPERATOR/SEAT legs,
  deliberately unqueued (goal-lint's 4 WARNs are these two). Monitor duties: standing watch
  set + board; ADR-110 gate reads on the parks (G1–G4 touch `agents/**` → codeowner-park at
  bot approval; G5 bot-merges — unowned proxy surface); hold G4↔G2 coherent at review
  (key-class rows are NOT strikes once G2 lands); run E1/E2 in a seat sitting; verdict =
  operator at tree-empty per the Production-leg. **Wave-2 roster change: FU-200 + FU-201
  legs MOVED into #1231** — remaining wave-2 = #1211, #1212, FU-199 residue, #1198, #1199
  (+ #1224/#1225 operator-lane), still minted at #1162's close sweep, AFTER #1231
  (router-first, PR#1226). **MACHINE SET G1–G5 ALL LANDED by 2026-09-02 ~04:00Z**
  (seat codeowner reads on G1 PR#1241, G2 PR#1253, G3 PR#1257, G4 PR#1258; G5 bot-merged via
  PR#1254's fix round): escalation carrier + KEY-RETRY split + provider-attributed strikes w/
  pair-exclusion (STRIKE_ENFORCE stays OFF — recording precedes policy) + fleet-strike reader
  (key-class excluded both structurally and historically) + provider_policy/exacto. Sprout tail
  (#1259 tier-floor enforcement — FU-201's remaining leg, #1261 taxonomy coherence) queued/riding
  under the goal grant; bucket #1243 auto-minted. **Remaining before verdict: E1 #1237 + E2
  #1238 (operator/seat sittings — damped agent-fix-only pending #1249) + tree-empty → operator's
  goal/validated read.** ⚠ #1249 (bare-member walk queues containers/operator legs — #1242's
  walk misfire, damper = agent-fix-without-queued on #1237/#1238/#1239, verified holding): fix
  the walk's exclusions before stripping the damper. FU-202 core delivered (archive candidate
  at next fu-sweep). #1255 (homelab lacks .agents/build.yaml — build rides degrade loudly to
  fix.yaml) = operator recipe-paste sitting.
- **⚑ 2026-09-01 LATE SITTING — v1.3.1 BANKED (operator: "deserves a place when it works");
  PR#1220 armed (banked block + S8 row).** Pickups: (1) at #1162's `goal/validated` close
  sweep, batch-release the bucket residue and **mint WAVE 2 = the dispatch-belts theme**
  (#1211, #1212, FU-199 residue, FU-200, FU-201 a+b, #1198, #1199; #1190 → coordinator-tier
  probe, #1200 + #1224 (parts-coverage ratchet) + #1225 (pin-vacuity refinements) →
  operator-direct) — read it on the adoption gate: ≤5 interventions / 0 out-of-sitting
  summonses / 1 owned assembly read. (2) #887 now carries the updater skip-clause build +
  the deliberate dismissal probe as its acceptance (commented). (3) `Origin:` line + typed
  defer/release + checkpoint theme-FORMATION are S8 originals — do not build piecemeal
  ahead of S8; delta 1 (park economics) may land independently. (4) **ROUTER-FIRST
  (operator ruling, 2026-09-01 evening — PR#1226, chainless-redesign.md ⚖):** the router
  follow-up set (FU-201, FU-174, FU-186/ADR-115, §M8 feed-4 per-job pricing) builds BEFORE
  further process machinery — within wave 2, FU-201 a+b lead; rung-0 mechanical
  re-dispatch BANKED (stack CI runtime caps retry economics); the ROUNDS_MAX=3 +
  escalate-to-human shape re-reads once good workers exist.

- **⚑ 2026-09-01 EVENING design-agents sitting (freeze read + drain) — the fresh-session pickups:**
  - **Goal #1162 endgame**: egress assembly **PR#1213** open+armed; it was RED on ADR-103
    pin-vacuity (comment-only fixture touch) — seat child **PR#1217** armed into
    `goal/1162-egress` restores master's `non-opencode` fixture byte-exact; its merge lands on
    #1213's own head → CI re-runs → bot verdict → **the codeowner read is the pickup** (coverage
    map verified sound this sitting). Scan theme held on **#1210** (queued: pin PR#1206's
    repo-qualified key, salvage `agent/20260901-165514`); when it lands the checkpoint re-rules
    → scan assembly (`Fixes #1163`) → second codeowner read → tree-empty → **operator's
    `goal/validated` read**. ⚠ the 18:53Z checkpoint's live exposure STANDS until the scan theme
    lands: master's ci-red selector lacks the goal/**-head exclusion (#1148's fix rides the scan
    branch) — if #1213 reds again, rule the misfire (precedent comment on the PR).
  - **PR#1208** (#1151 Touches-classifier lint) round-1 CHANGES_REQUESTED — machine round 2.
  - Oracle: **PR#340** (#329's sonnet resume — the FU-199 strike-hold arc's delivery) + **PR#338**
    (#337 r2) riding review; #326 `Budget:` 8→12 (jail cap-sum artifact; rationale on the goal).
  - **FU-201 build wave** (operator-ruled): size-label re-grade carrier + label_map md/lg rows +
    brief vocabulary section + served-provider column on strikes / (model, provider)
    pair-exclusion on serving-shaped re-picks — folds with FU-186. FU-200 = the fleet-strike
    deterministic reader. FU-199 fix merged (PR#1206) + the #1210 pin; residue legs in the FU.
  - openrouter-operator **PR#55 deploy VERIFIED LIVE 2026-09-01 ~22:27Z** (image `2026.9.1`):
    the legacy `oracle-fleet-openrouter` Secret normalized correctly — GUARDRAIL + KEY_HASH +
    non-empty OPENROUTER_API_KEY, session-key label intact. Residue = or-op#57/#58 (harvested,
    inert; #58 = empty-write on the value-key-missing drift case, explicitly not a live
    regression) — ordinary board flow.
- **⚑ SOAK — which goals/stints are past it (read 2026-09-01 ~08:10Z, the corpus session's
  wind-down; verdicts are the OPERATOR's, the seat only recommends):**
  - **#818 G-B — `goal/validated` looks DUE.** Post-launch since 08-30 20:39Z; tree = the
    bucket #840 only; Production-leg evidence live: `probe-platform` 3 consecutive Succeeded
    ticks (08-31 18:41Z, 09-01 00:41Z, 06:41Z), SLO teeth + lens knob + responder dial
    shipped. Apply the label from the jail (User type passes IL-T22); the scan's terminal
    leg runs the close sweep.
  - **#741 S7 (updater-in-cluster) — closeout-1 OVERDUE by a week.** 5/5 originals done, cutover
    executed 08-26, container untouched since 08-21 and NO closeout comment ever posted. Needs
    the closeout-1 sitting (docs-cleanup over merge-path.md/FSM + `agents/update-pr-branch.sh`
    surfaces, FU sweep, built-vs-left comment), then its ≥72h quiet window, then close.
  - #775 G-A: validated once #778 (operator-held scout residue, FU-181's) is RELEASED to its
    tracker — it is residue, not a defect, so rule 4 does not bind it; bucket #787 stays.
  - #1039 G-F: claim FLIPPED (oracle-iac#455, 09-01 08:35Z) and the first rides exposed both
    harness attach arms as invented (#1041) — fixed in PR#1186 (09-01 09:29Z, `5fe75b28`).
    Verdict now waits on **oracle-fleet#330 round 3** = the production-leg live validation
    (transcript lists `statute`/`search`/`give_feedback`; ≥1 MCP-filed row in the sink). The
    seat re-armed it (`agent/queued`, circular blockedBy→#1039 removed, rung); it is HELD on
    #328's `scripts/**` footprint until that ride opens a PR or its session ends (pod deadline
    ~10:20Z). Pickup: confirm r3 dispatched from post-#1186 master, read
    `s3://agent-transcripts/oracle-fleet/issue-330/worker-r*-…` for the tool list, then the G-F
    validated read. If r3 strikes on the attach again, it is a NEW defect — bring the log.
    **10:20Z: BOTH halves observed** — tool list in the live ride + two MCP-filed rows
    (oracle-fleet#333, transcript `…/issue-330/worker-r1-20260901T102118Z/`), relayed to
    #1039 (comment 5492494412). **Operator: take the G-F `goal/validated` read** (oracle
    verifies the rows in `oracle-pg` on its side). Reviewer arm ALSO proven live 11:12Z
    (Claude Code's MCP log in `reviewer-oracle-fleet-334-…`: connected, hasTools) — nothing
    platform-side remains open on G-F; #330 closed `agent/done` (PR#333 merged).
- **⚑ 2026-09-01 mechanical session — operator pickups:** (1) **`tofu plan` (main root) shows
  pre-existing drift: `proxmox_virtual_environment_file.ci_runner_cloud_init[0]` +
  `proxmox_virtual_environment_vm.ci_runner[0]` "must be replaced"** (cloud-init snippet
  differs) — a full apply would DESTROY+recreate ci-runner-01; the seat applied PR#1193's kubelet
  change TARGETED around it. Decide: re-adopt the live snippet into tofu, or accept the replace
  at a quiet moment. (2) Bulk-tier image GC now 60/50 on the four kata nodes (PR#1193) — first
  time `LonghornDiskBelowSchedulingFloor` stays clear ≥24h, this bullet can go; if it re-fires,
  the tier is undersized, not the threshold (ADR-114 build-out).
  - #979 S5: quiet window ends **09-02 06:39Z** → close at the next sweep after.
  - #949 / #1101 retro batches: close at the post-r3 sweep (r3 fires Mon 09-07).
  - None of the three open Goals carries a `Production-leg:` line (pre-card) — evidence is
    read live, as above; `devbox run goal-lint -- teststuffstash/homelab <n>` now names it.
- **⚑ 2026-09-01 CORPUS SESSION — other pickups:** PR#1183 (goal-lint + card rules 7–9) was
  auto-merging at wind-down — confirm landed. **#1175 r1 in flight** (launcher pre-read → its
  PR will codeowner-park on `agents/**`; acceptance = row 1 only, the widened prefetch table is
  the follow-on child at closeout). **#1095** (oracle coordinator token creates but cannot
  mutate homelab issues) = a broker-mint scope widening — ADR-110 "big", operator's call.
  Garage: the `backups/garage-meta-20260825-prerebuild/` (20 GB) + forensics deletion came due
  ~09-01 — operator-owned. FU-137's ~08-31 build-out deadline is PAST (meta volume rf=1 on
  wk-02) — an infra sitting. Two PR watchers may still be alive by process (`pgrep -f 'gh pr
  view 118'`) — kill before re-arming.

- **⚑ 2026-09-01 — v1.3 THEMED-GOAL MANUAL PILOT LIVE: Goal #1162 (wave 1) — the S8 dogfood
  datapoint.** Themes: #1163 `goal/1162-scan` (#1148 #1149 #1011) · #1164 `goal/1162-exporter`
  (#459 #1138 #1137; #1137 blockedBy #1138; both keep parent #1115 — absorbed by reference) ·
  #1165 `goal/1162-egress` (#1056 #107). All members queued with `Base:` theme lines; intake
  rules for mid-drain arrivals are in the Goal body (manual waves 1–2 → then #1153's
  grant-consult leg). Park convoy DRAINED same sitting: PR#1157 05:53Z, #1161 05:57Z, #1160
  06:02Z — zero approval dismissals across two updater refreshes (datapoint commented on
  #887); theme branches fast-forwarded to post-merge master @ `0ba158b2`. NEXT-SESSION
  VERIFY: (a) DONE 09-01 07:40Z — 4 of 9 members merged+closed within 90 min of the mint
  (#1011 #1138 #1137 #107), PR#1173 (#1148) armed into `goal/1162-scan`; #459 re-scoped
  (clause-labelled wake-source metric) + moved to the scan theme; #1166 joined the exporter
  theme (ledger rows 2–5 on #1162); (b) known pilot gaps accepted: checkpoint may misfire an assembly ruling at
  the master-based Goal (report-only, park it); theme assemblies are ordinary `Fixes`-closing
  PRs — NO `Assembly-for:` anywhere. S8 readout baseline on the Goal's mint comment
  (per-child ≈9 reads → target 3). The serial park-merge cycle is #887's live datapoint.

- **⚑ 2026-08-31 EVENING CORPUS SESSION WIND-DOWN — the fresh-session pickup set (TICK-LOG has
  the arc):**
  - **[Switchboard](../glossary.md) cutover VERIFIED LIVE at wind-down** (ADR-120; PR#1158 + eae8c51f, #994
    closed): template synced + old pruned + cron gone, and a live probe ring produced
    `switchboard-wnl7b` — 31s, the #994 routed-ring drop line, no board sweep. Nothing left to
    verify; watch only for a repo-dumb emitter surprise (a Renovate/devbox-update ring should
    show a switchboard run that fans out, then the per-stack run).
  - Gate-read the next park convoy: queued set riding = #1148 #1149 #1151 #1153(blockedBy #1151);
    #1152 DONE (PR#1155 merged 20:22Z with the codeowner breaker-correction) #1006-tail + agent-runtime #104 #105 #107 (finalize,
    footprint-serialized). #1150 inert (assembly-CR→checkpoint edge — needs an ADR-110 read).
  - #946/A5 CLOSED-shaped: seed 4/4 + free-tier comparison posted (no free reviewer; big-pickle
    shadow-only, tolerant parse + one retry). Durable rec unfiled as issue: opencode-harness
    branch in re-review.sh for opencode/* models (small seat PR when wanted).
  - Oracle handoff done/ (2 tasks 2026-08-31) is disposable once read.
  - Monitor hygiene for watch scripts: gh --jq takes NO --arg; reviewDecision never changes
    across CR→CR re-verdicts (key on newest-verdict timestamp) — both bit this session.

- **⚑ 2026-08-31 CORPUS SESSION WIND-DOWN (~11:45Z) — the fresh-session pickup set:**
  - **Goal #1039 assembly MERGED 11:39Z (PR#1119, full codeowner read done)** → VERIFY the next
    scan pass: `goal/post-launch` lands via IL-T18 (`Assembly-for:` trailer verified
    line-anchored pre-merge), #1117/#1118 close via the Base:-keyed C6 (their fixes are on the
    merged branch — PR#1128/#1130). ArgoCD syncs the MCP claim knob + composition; the oracle
    jail can then claim `spec.mcp`.
  - ~~#1134~~ **CLOSED 2026-09-01** (`94954f01`): root cause = kyverno ≥1.19 panics on the 2nd
    nameless Kustomization doc (`--exceptions` refuted); unpinned at 1.19.0; `sentinel-smoke`
    CI gate landed. Nothing left to verify.
  - **#1136 residue**: anonymous-clone throttling (47 failed workflows ~10:45–11:10Z) — all 14
    homelab workflow clone sites now authenticate (`13e51ddc`, verified in-cluster). Residue
    CLOSED 09-01: inflow stayed zero (the only failed run today was a genuine worker-PR red);
    template sweep — the coordinator templates embed the token via `_cu`, the Composition
    renders no anonymous clone; ONE site remained, `deploy-revert-argo.yaml:204` (anonymous
    clone AND push — private oracle-iac cannot even be cloned) → filed + queued as **#1180**
    (egress theme, wave 1).
  - **oracle-fleet#285 stays wedged on #1108** (queued; rerun-red wake gap; blockedBy edge
    wired — the BLOCKPARK watch flags its fix PR's park). Queued convoy still riding: #975
    #1011 #1006 #828 #1056 #1113 #1116 #1124 #1125 (DNS belt) #1108 + sprouts #1137/#1138
    (inert) — next corpus session gate-reads the parks; agent-runtime #97/#98/#99 all merged.
  - Watch upgrades LIVE in the re-armed monitor: BLOCKPARK source (Prometheus-primary),
    stable FAMINE key, container exclusion — the three noise classes are code now.
  - probe-platform verified past auth (#1085 live; the one finding = known loki OutOfSync
    papercut — don't re-derive). #946 seed: 3 cells (Zen weather). #994 operator-held.
    #1133 closed unmerged, superseded by PR#1143 (pin `g0b16ec104713` on master) — verified 09-01.
  - Retro r3 (Mon 09-07) runs under the NEW cost-model ranking (PR#1127); its
    predecessor-scoring is the r2-batch closeout read (#949 + #1101 close at the sweep after).
- **⚑ 2026-08-31 CORPUS SESSION rulings (the drainage-economics discussion — operator-ruled,
  TICK-LOG entry has the arc):** the drainage round/branch/triage design is **BANKED** —
  measured 1 stack-blocking : 16 nice-to-have on the live pile, and the seat gate-reads every
  diff anyway (ADR-110 is the binding resource), so meta-coordination economics win at current
  volume. Standing policy: **(1)** blocking defects (incoming blockedBy from a stuck stack
  issue / live wedge / 🚨) queue immediately, master-lane, hotfix-class — and every filing door
  including the seat WIRES the edge; **(2)** the nice-to-have pile is corpus-session batch work
  (board aggregate is the reader; queue a handful, gate-read the parks in the same sitting) —
  no new machinery; **(3)** the Touches classifier (one-home owned/deny tables) survives as a
  LINT (stops burned rides on operator-lane touches, feeds the operator slice) — #1102 to be
  re-scoped to exactly that + the edge discipline. Banked-design trigger: revisit if parked-PR
  volume actually freezes dispatch or session-cadence drain visibly stops sufficing. Also
  ruled en route: post-launch goal fixes target MASTER (v1.2 stands); goal-tree members' queue
  gap (filing doors don't consult the IL-T15 grant — #1060/#1028 evidence) folds into the same
  re-scope. **CONFIRMED verbatim by the operator 08-31 + one addition: the jail watches
  blocking-class codeowner parks ACTIVELY** — jail half BUILT (meta-events `BLOCKPARK` source,
  PR#1114, verified on the live #1108→#285 edge), no-seat belt half queued (#1115, exporter
  blocking-count + `BlockingCodeownerParkWaiting`, machine-merge path). Second banked idea,
  operator's own words "not yet": an AUTOMATED design-agents corpus read on codeowner-parked
  BLOCKING issues — revisit when blocking-park volume makes seat-cadence reads the bottleneck.
- **⚑ 2026-08-31 BOARD DRAIN (operator-ordered "clear/queue the board more") — the batch:**
  QUEUED homelab #975 #1011(+Touches authored) #1006 #828 #1015 #972 #968 #1113 #1056(+Touches
  authored, FU-020 monitor-first noted) #1117 #1118 + agent-runtime #97 #98(fold note: same
  file, first ride may cover both) + agent-runtime#99 (the #1069 split: typed input-unreadable
  finalize exit; blockedBy edge #1069→ar#99; #1069 keeps only the per-repo recipe paste).
  #1116 arrived pre-queued (defect in PR#1112's own regex). CLOSED: #1098 + #966 (scout intake
  reads — no graduation, rulings on the issues), #1109 (seat quickfix `76fcbcda`).
  **#938 FIXED seat-direct `eb638b21`** (sentinel doorbell-collapse absorb — live probe pending
  at the note's writing). LEFT with owners: #887 (observe/soak) · #107 #114 #459 (soak calendar)
  · #946 (Zen weather) · #949 (quiet window) · #628 (container) · #857 (maintenance-session
  class) · #518 (runner infra) · #289 (oracle's) · or-op#34 (soak) · #1036 #1028 #1107 #1102
  (operator-lane sittings). Gate reads for the resulting parks: this session while it lives,
  then the next corpus session — expect a park convoy on the scan-touching set (#975 #1011
  #1006 #828 #968 serialize on coordinator-scan.sh footprints). Lint debt noted at the push:
  FU-196 oversize + 4 stale-archive entries (FU-073/084/089/098) — next docs-cleanup.
- **⚑ 2026-08-30/31 OVERNIGHT UNATTENDED SESSION (codeowner+board, TICK-LOG entry) — the pickup set:**
  - ~~OPERATOR: OpenRouter credit~~ TOPPED UP 2026-08-31 ($5.66 → $15.66); the 00:37Z alert was
    the runway rule (credit < 2× trailing-24h burn), gauge read true throughout. Drain autopsy:
    ~$4/day rides per-(issue,round) session keys — the standing $5-weekly stack keys sit idle
    (homelab lifetime $0), so no aggregate per-stack brake exists; that gap is FU-180's charter.
  - Board fully drained: the 15 queued individual issues + 5 sprouts all merged+closed (11 seat
    codeowner reads, rationale on each approval). G-B verify items DONE: **#818 wears
    goal/post-launch** (unblocked by PR#1062 — the >100-char label descriptions had frozen every
    *-labels MR since the goal labels were added), #775 hand-labeled to match its real state.
  - **First probe-platform tick FAILED (cred-unresolved) → #1085 filed+fixed+merged same night**
    (loop-ns proxy session-keys Role was never rendered). VERIFY the next tick (06:41Z / 12:41Z —
    `41 */6`) gets past auth; read the report from Loki tenant `platform-agents` by pod name
    (podGC eats stdout — the prober's no-durable-sink gap, now proven; roles.md already lists
    🌱-filing as missing).
  - #946 (A5 seed): 1 of 4 cells DONE 2026-08-31 (pr-440 shadow report produced in a Zen
    capacity window); the other 3 re-429'd on review-size prompts — free tier admits trickle,
    not sustained. Retry recipe on the issue; partial result commented there.
  - oracle-fleet#304 → homelab#1093 RESOLVED 2026-08-31 (seat): 5 strikes' `cred-unresolved`
    was the UNLABELED legacy `oracle-fleet-openrouter` Secret (proxy requires the session-key
    label; operator never heals Secret drift → openrouter-operator#53). Hand-labeled, verified
    200 `[+cred]` through the exact ref; #304 un-blocked, #1092 hand-closed. Coordinator
    TOOL_GAP (create-but-not-comment on homelab) → #1095.
  - Watch-noise candidates (next meta-events/needs-meta touch): FAMINE emits per count-delta not
    threshold-crossing (dozens of noise pairs/night); "unlabeled >24h" false-flags containers
    (#949 retro-batch, #840/#787 buckets) — wants the sprout-report-skips-buckets exclusion.
  - #1069 (workers silently no-op when App GraphQL pool exhausted — measured on #969 r2) sits
    inert for 🌱 triage; fix shape spans recipe + agent-runtime exit contract.
  - goal/1039 (G-F): #1058 terminal resolved as option 1 BY HAND (`f776ebc3`) → reviewer
    re-approved + **MERGED 05:43Z**. #1041 hand-closed agent/done (goal-branch merge fires no
    Fixes keyword — the sleep#123 shape); parent #1039's stale `agent/blocked` removed (it was
    gating the scan off the whole tree — the "children not queueing" symptom). All 4 originals
    now done → goal checkpoint/assembly fires on the next scan (#933's fixed clause).
    #938/#994 stay operator-routed.
- **⚑ 2026-08-30 EVENING SESSION OUTPUTS — the pickup set:**
  - **G-B COMPLETE to post-launch**: assembly merged as PR#1037 (reopened from #1030 under the
    operator identity — the governance-lint author trap, filed #1036 operator-lane; one
    hardening commit `ce4bbbcc` closed the responder-dial comma-splice past the secrets
    carve-out). `probe-platform` CronWorkflow rendered; #1026/#1027 queued at merge → fixed
    same day (PR#1047/#1050, codeowner-read + approved at wind-down, with #1032).
    **VERIFY next session: #818 wears `goal/post-launch`** (the scan's IL-T18 leg was pending
    at wind-down) + the first `probe-platform` tick report.
  - **#1038 (reviewer 403s on every issue read) FIXED `ca87b799`**: the App grant existed since
    FU-069(b) — both MINT sites omitted `issues`; re-minted + verified 200, sleep#137/#135
    un-wedged (stale verdict dismissed, agent/error cleared). Durables: ground-rules
    escalation-verify + GitHub-signature bullets (PR#1044, fixture-fixed), github-apps.yaml
    symptom index, GAPS design-agents-G3 promoted (asks-are-claims).
  - **G-F LAUNCHED → homelab#1039** (stack MCP attachment; branch `goal/1039-stack-mcp`,
    decompose rung). #289 un-parked (oracle owns its deliverables). Work-map rows G-F + G-G.
  - **ADR-119 landed via PR#1052** (capability-request lane w/ intent grammar +
    secure-by-default + the file-direct escalation terminal + coordinator-brief filing
    contract + `platform-request` claim label + glossary rows); the Goal consumer card via
    PR#1051. Build residue queued: #1053 (Base:-mandatory decompose lint), #1054 (board
    fingerprint slice), #1055 (reviewer L1 capability card + never-fail-into-a-verdict).
    **Open residue of the sitting: the PR-shaped re-entry edge** (a review mid-flight blocked
    on a platform fault has no blockedBy-style resume; the issue-shaped path rides FU-087).
  - **Oracle-side next (the oracle jail's, per the cross-stack ruling)**: the seed batch as
    TWO intent requests (`public-edge.anonymous-safe-serving` #175, `public-edge.
    client-observability` #176) — WAF moved into G-G's default-hardening; the #176 rescope +
    blockedBy edges; oracle-fleet#293's codeowner read; the prober class-1 brief (#289).
  - PRs #1044/#1051/#1052 landed 08-30 19:52–20:05Z (verified 09-01).

- **⚑ DESIGN QUESTION (operator, 2026-08-30) — LARGELY DISCHARGED 2026-08-30 evening
  (ADR-119): stack→platform communication — how a stack routes
  a problem/request TO the platform instead of into the undifferentiated human bucket.**
  `agent/blocked` ("needs a human") is correct on the platform repo — one context — but on a
  stack it conflates two destinations: platform/infra (homelab jail's problem) vs business
  logic (the stack jail's). Root pattern the operator named: too much platform development has
  run with the PLATFORM as client/driver, not the stacks. Motivating cases: sleep-tracking
  PR#133/#123 (arbitrate's own terminal ruling says "infra, not logic" — a platform env var,
  `REGISTRY_MIRROR_MCR`, leaked into stack CI — yet lands as plain `agent/blocked` with nowhere
  to route); the two oracle-fleet `uploads/PROPOSAL-*.md` (gitignored — minutark cross-stack
  launch, which itself sketches a §3 "capability-request lane"; goal consumer card, hand-routed
  "via the mono seat — this jail has no homelab write path"). The `tools/handoff.md` channel is
  human-at-keyboard + host-file-only — machine lane can't reach it. Candidate shapes: stacks
  labelling their own issues by escalation destination (e.g. split `agent/blocked` platform/stack
  at arbitrate time), and/or a lane for stacks to file issues/proposals/requests on the platform
  repo. Deliberately NOT an FU (operator direction) — pick up in a design-agents session.
  **Third instance (2026-08-30, operator): stack ACCESS/SERVICE gaps have no tracked inventory.**
  Case: the oracle jail had no read on its own transcripts (verified: `garage-workspace.yaml`
  mints exactly writer=write-only for every session + reader="platform-side only" for the
  viewer sync — NO coordinator anywhere holds transcript read, platform included; the brief's
  "reads freely … transcripts" has no built mechanism, A2 MCP slices unbuilt/FU-058 leg); Loki
  read was just granted via the ADR-118 door — the ONE service with a stack-scoped read, and
  the donor shape for transcripts (per-project prefixes ≈ tenants; Garage keys are per-bucket,
  so scoped read = per-stack buckets or an ADR-118-style proxy). No role×stack×service
  inventory exists (grep negative: FU/ADR/GAPS); pieces = trust-boundary table + roles.md
  boundaries (coarse prose), egress dial table (network only), `agent-read-rbac.yaml` rulings,
  loki-tenant-grants + consumer card, oracle-iac `workbench.yaml`. Demand-side gap: TOOL_GAP
  markers exist ONLY for cluster sessions (zero hits in jail cards/ground-rules) — the jail
  lane, where this gap was felt, has no channel. Design direction to weigh: generate any
  matrix from grant sources (never hand-author — FU-049's pattern), consumer-card + grants
  file per LIVE service (loki-tenancy shape), TOOL_GAP extended to jail sessions, and the
  capability-request lane as the routing (same door as instance 1's proposals).
  **Fourth instance (2026-08-30, the #133/#293 day):** (a) a fix landed on a `goal/**` branch
  protects NOTHING on master until assembly (oracle PR#280's venv guard — master PR#293 hit the
  same class next day; ported as oracle-fleet PR#294); (b) long-lived RUNNER state is untracked
  platform surface — ci-runner-01's dockerd insecure-registries lacked the new MCR VIP (first
  HOST-level mirror pull ever, sleep#133), and its devbox venvs go stale (the y/n prompt class).

- **⚑ PICKUP (the #133 tail — items 1+3 DONE 2026-08-30 midday session):**
  1. ~~ci-runner-01 docker restart~~ DONE — restarted at idle, `docker pull
     192.168.40.31/playwright/python:v1.62.0` verified on the runner (⚠ the suggested
     `pgrep -f Runner.Worker` busy-check SELF-MATCHES its own ssh command line — bracket the
     pattern: `pgrep -f "[R]unner.Worker"`; the first read was a false BUSY).
  2. sleep-tracking PR#133 rerun DONE — the environmental half is FIXED (mirror pull green in
     CI); the surviving red is CONTENT: `playwright/python:v1.62.0` ships browsers but NOT the
     `playwright` pip package (verified in the pristine image; diagnosis commented on the PR,
     fix shape = in-container `pip install playwright==1.62.0`). Deterministic — rerunning
     never greens it; the ci-red machinery owns the fix round. At merge, HAND-CLOSE issue
     #123 with `agent/done` (its PR link is `Implements`, not a closing keyword).
  3. ~~oracle-fleet PR#294~~ MERGED 11:14Z.
  4. oracle PR#293: the ci-red machinery FIXED its content red — now bot-approved + green,
     **codeowner-parked 30m+** (CodeownerParkWaiting firing, seen by the 2026-08-30 mechanical
     sweep trial) — a corpus session's ADR-110 read.
  ⚠ probe gotcha re-proven ×2 today: `statusCheckRollup` in any gh query hard-fails on this
  PAT (a 2h watch ran blind) — read CI via `gh run list`.

- **⚑ ADR-118 Loki tenancy — STEPS 1+2 SHIPPED, STEP 3 IS THE NEXT SESSION'S** (2026-08-27;
  design [`loki-tenancy.md`](../loki-tenancy.md), rollout table there is authoritative).
  Merged: #1008 (proxy + grants + write half), #1009 (the `stage.tenant` correction).
  **Step 2 = PR#1010, MERGED 17:17:24Z and VERIFIED LIVE 17:17–17:20Z** — `auth_enabled: true`,
  the #811 belt moved out of the ruler, both writers' headers, Grafana's enumerated datasource.
  Operator ruled both open questions (belt → PrometheusRule + drop the ruler; `ingestion_rate_mb`
  stays 8 + document + FU). Verified at the failure points, not by a green sync: per-namespace
  tenants at the distributor with no `fake`; **zero rejected pushes** (`loki_api_v1_push`
  203×204, `otlp_v1_logs` 7×204, `loki_discarded_samples_total` empty); multi-tenant read returns
  logs; no header = **401**; Grafana datasource reloaded 200 OK. Evidence in
  [`loki-tenancy.md`](../loki-tenancy.md) §Rollout.
  **THREE near-misses this rollout, all caught by verifying at the sender rather than trusting a
  green sync** — the un-bumped `config-hash` (`0270ab10`, FU-190), `__tenant_id__`-in-relabel
  sending no header at all (#1009), and **the OTel collector as an unnoticed SECOND Loki writer**
  (#1010; would have 400'd the A0 telemetry rail while Alloy kept working). Each would have
  stopped cluster-wide log ingest had the rollout been one step instead of three.
  ⚠ `StatefulSet/loki` reads permanently OutOfSync (pre-existing ArgoCD `volumeClaimTemplates`
  papercut) — **"Synced" is not a usable verification signal**; read the live pod.
  **Step 3 = PR#1012, MERGED and VERIFIED AT THE REAL VIP** — `192.168.40.32:8443` is reachable
  from the jail (BGP advertised, TLS OK) and all seven signatures reproduce there: granted
  `oracle-fleet`/`oracle-agents` **200**; `platform-agents`/`agent-coordinator`/**`fake`** **403**;
  no header **400**; no token **401**; `POST .../push` **404**. **ADR-118 IS COMPLETE.**
  **CONFIRMED FROM THE ORACLE STACK JAIL** (operator relay, 2026-08-27 evening): the workbench SA
  reads tenant `oracle-fleet` (series + range both return) and gets a clean 403 on `fake` — the
  door works from the consumer side, not just from the seat's probe. Operator accepts that
  pre-flip history is out of reach; the requirement was **log access during the NEXT delta run**,
  which is met — `oracle-fleet` and `oracle-agents` are both ingesting post-flip (31.4 KB / 31.6 KB
  at wind-down) and both are granted. `oracle-iac` reads 0 only because it runs no pods.
  **⚠ ONE MOTIVATING CLAIM DID NOT SURVIVE THE TEST → FU-194:** homelab#541 promises "any session
  with LogQL access reads kernel-log lines", and that is STILL false for a jail — `kmsg-reader`
  sits in ns `loki`, so kernel lines are tenant `loki`, which no jail is granted and none should
  be. Either move the DaemonSet to its own namespace or fix the carve-out's text; it currently
  promises a capability nothing provides. Found by testing the claim, not restating it.
  Residues: **FU-192** (Grafana's snapshot tenant list; per-tenant ingest sizing, due
  ~2026-09-03 — the one with a date; the OTel rail's static tenant) and **FU-193** (the door's
  self-signed, unpinnable cert). Also fixed in step 3: the `kubectl auth can-i` grant-audit recipe
  in `loki-tenant-grants.yaml` answered **no for every namespace including granted ones** (pseudo-
  resource, no CRD → RESTMapper cannot resolve it); replaced with an explicit SubjectAccessReview.

- **⚑ Two open items from the same session, both filed, neither started:** FU-190 (a mounted
  ConfigMap change does not roll its workload — hand-bumped annotation, silent when forgotten)
  and FU-191 (the admission-controller seat is an OPEN Kyverno-vs-Gatekeeper choice; operator
  wants a SECOND use case before deciding — use case 1 is tenant labelling, which is what would
  let ADR-118 go tenant==stack). The #1003 arbitrate observation is now **FILED as #1011** — and
  the original sighting was WRONG: the three fingerprints differ, so the state was not
  byte-identical and #198's debounce held. The real cause, verified from #1003's check timeline,
  is that `STATE_FP_JQ` keys on every check's conclusion, so checks arriving/completing one at a
  time re-arm arbitration (3 opus rides, all ruling "escalate, human is next mover"). #198's
  symptom through a different door.

- **⚑ S5 (corpus diet) [stint](chainless-redesign.md) #979: ORIGINALS 4/4 DONE 2026-08-30 —
  closeout 1 posted on the parent; it
  sits in its ≥72h quiet window (close at a later sweep).** #984 (the deep comb) landed as
  PR#1017: lint set drained, ~35 files truth-synced, FU-052 archived, FU counter 189→195,
  **docs-graph-lint check #4 FLIPPED shadow→FAIL** (the comb was the clean run), and
  `.agents/review.md` gained the docs/ needs-a-human tier line (operator-direct post-merge).
  Stint history: Park-drain DONE
  (outage set + #964/#965 landed; #963 MERGED after the seat's `:free`-fallback round — ⚠ its
  first push was CLOBBERED by the updater race, filed+queued as **#986**: update-branch without
  `expected_head_sha` overwrote a verified push on PR#963; the fix is one API field). **#967**
  (ADR-115 + §M14 + the Exacto↔caching caveat) bot-APPROVED + armed, lands on its cycle.
  **#981 MERGED as PR#985 (20:42Z)**: ADR-116 + the 29-entry sweep; round-2 classifier bug
  (TODO-shape extraction swept every id on the matched line — FU-142 was a phantom) fixed
  in-PR. The TODO-ARCHIVED warn's **4** real stale pointers (FU-068/FU-133/FU-143 gap
  registers + FU-160 spike) → **#984**. **#982 MERGED as PR#999 (20:55Z)**: ADR-117 §-code
  heading anchors + docs-graph-lint check #4 SHADOW (ANCHOR-UNRESOLVED/-AMBIGUOUS; flip to
  FAIL after a recorded clean run — the #984 comb is the natural flip read).
  **#983 MERGED as PR#1001 (21:38Z)**: 3 heat-cited trims (−214 lines from the corpus hot set,
  incl. an ADR-111 staleness heat found that lints can't) + settle-test run 1 recorded in the
  doc-heat spike — ≥3 bar MET; **the FU-164 promote-vs-close call is the operator's** (serve
  the report + wire into docs-cleanup, or close the spike).
  **Queued-list RECONCILED 2026-08-30 (midday session):** #928 #929 #932 #933 #937 #888 #456 +
  agent-runtime#95 all CLOSED by the machine lane; #936 merged + UNPINNED. The two survivors had
  structural causes, both fixed/routed 2026-08-30: **#110** was INVISIBLE (the scan's `gh issue
  list` calls silently capped at 30 — fixed direct-master `088ac3b9`, ISSUE_LIST_LIMIT + loud
  truncation warn; #110 now the platform loop's actionable unit) and **#938** was scan-refused
  every tick (guarded-path Touches) — de-queued + de-suitabilized to the operator lane, comment
  on the issue. **#946 is UNBLOCKED (#945 merged as PR#996)** — the A5 evidence seed is a seat
  run of `re-review.sh --shadow --model opencode/big-pickle` over #923's set, ready any sitting;
  #953 queued (docs-lint gate behaviour).

- **⚑ ORACLE AND SLEEP ARE CHAINLESS (oracle: oracle-iac#387; sleep: sleep-iac#77 + mirror
  homelab#976 MERGED; 0731 out of model_tiers, homelab#960).** **Sleep is PROVEN end-to-end:**
  #123 (the 9-day agent/error latch, seat-cleared) rode chainless r1 → **PR#133** (the
  Playwright render gate), ci-red machinery dispatched r2, riding at wind-down — the loop is
  healthy. **Oracle's #272 is the hard case:** the first chainless draw (opencode×flash)
  WEDGED pre-LLM — opencode's un-suppressible SDK-init fetches have no timeout under oracle's
  enforce:true (filed **#990**, queued; durable workaround = **PR#991**: enforced-egress rides
  never DEFAULT to opencode, replay-pinned, in review); the goose×flash hand-ride then struck
  **http-401-storm** (recurrence CONFIRMED — 3× in ~3h, machine-filed as **#1004** via the
  fleet-fault rule; DIAGNOSED 2026-08-30 seat triage:
  PROXY-side `cred-unresolved` — the proxy forwards credential-less when its k8s ref-read fails,
  latching the auth circuit; the mint/PATCH hypothesis refuted. #1004 queued with
  `Touches: argocd/resources/openrouter-proxy/**`; sibling #1018 (machine-filed same morning)
  root-causes the continuous 403 half as a MISSING FU-138 Role in agent-coordinator — land
  together. The storm's three latches (oracle-fleet#283/#279/#278) seat-cleared + re-queued
  2026-08-30, un-corking the #281 delta chain and goal-270's tail. **#1004 FIXED same day —
  PR#1019 (loop-authored: fail-closed ref resolution + short negative TTL) merged 07:15Z,
  issue auto-closed; #1018 (the missing FU-138 Role in agent-coordinator, the 403 half) is
  QUEUED and codeowner-parks at merge (`Touches: agents/coordinator/rbac.yaml`)**); the operator hand-dispatch **claude/haiku r1 DELIVERED:
  oracle-fleet PR#277** (opened 2026-08-26 19:00Z, #272 → `agent/review`, riding the loop —
  no FU-143 hold). #272 carries a blocked-by edge on #990 so the SCAN won't burn 4h slots
  on the opencode draw; the edge dies when #990 closes. **⚠ FU-188 (found on #277's review,
  2026-08-26 evening): the review plane was DEAD on every authoritative stack** — `/route
  role=reviewer` served `xiaomi/mimo-v2.5 [market]` (openrouter rail) to the subscription-only
  reviewer → instant Anthropic 404, no verdict, no strike, router re-picks forever (72
  dispatches/24h, zero generations; two dead rounds on #277 pre-fix, 19:47Z + 20:00Z).
  **Incident pin LIVE (`1596e395`, direct-master):** reviewer-session downgrades
  authoritative→shadow for itself; workers untouched (chainless-guard REQUIRES authoritative
  — a claim flip would FATAL oracle/sleep worker dispatches). **VERIFIED 2026-08-26 20:22Z
  (the S5-continuation session): the pin works live** — the 20:15Z tick logged `authoritative
  DOWNGRADED to shadow for the reviewer (FU-188 incident pin)` (shadow would-be:
  `xiaomi/mimo-v2.5 [market]`), served sonnet, and PR#277 got a real CHANGES_REQUESTED
  verdict at 20:22:54Z — the review plane is back; #277's fix round is the oracle loop's.
  Durable legs = FU-188 (a/b/c); the pin comes out with (a)+(b). Two 4h burns today
  were FU-187's class (quiet stall, reap skips finalize — tracker extended with the reap half).
  **MCR mirror LIVE** (PR#992 merged 2026-08-26 19:33Z; pull-through verified via the VIP,
  `playwright/python` tags served; sleep#123 commented with the image-redirect option — it
  stands if the nix-chromium browser-launch grind on sleep PR#133 continues). **NEXT PHASE = FU-186
  (ADR-115, ruled 2026-08-26):** step 1 the `provider_policy` knob + no-pin/Exacto flip for
  cheap coding, step 2 the 0731 matrix run (intake mode + `@` arms are BUILT, PR#963 —
  arms: default-pin / no-pin-exacto / @deepseek / @relace control, rung-2 task, both
  harnesses), verdict = the model_tiers re-admission PR. Full design + evidence:
  model-routing.md §M14. First intake digest = homelab#966 (both rung-1 cells CLEAN on
  bottom-quartile providers — rung 1 does not discriminate).

- **⚑ G-B #818 WEDGED on homelab#933 (found + filed by the 2026-08-25 sweep, queued):** all 5
  originals closed, 1 store finding, but the goal-checkpoint's child-set-complete trigger
  counts the OPEN post-launch bucket (#840) as an open child — assembly can never fire for a
  goal that harvested pre-assembly. The fixed clause emits the checkpoint on its first scan;
  then the morning-read items stand (assembly PR → codeowner tax → `probe-platform` first
  tick — the platform prober enablement rides the assembly, FU-102).

- **⚑ G-A #775 post-launch, 2 open descendants:** #778 (operator — Go posture RULED 2026-08-25:
  janitorial/failover permanently, P4 de-gated from Sep-13, big-pickle shadow arm = #923
  queued; FU-181 holds the post-reset hygiene legs) + #787 (container). **The FU-095 flip
  child is minted at the ~2026-09-03 paid-flash revert** (sequencing ruled A, 2026-08-25 —
  acceptance: zero chain-exhausted defers on subscription-only classes).

- **⚑ S7/#745 COMPLETE 2026-08-26** (callers ×10 + reusable deleted, org secrets destroyed,
  MP-T02 re-anchored). Acceptance watch: no BEHIND PR >30m anywhere; hosted updater runs
  structurally 0. ⚠ Both S7 silences were WIPED by the 2026-08-25 Alertmanager restart
  (silences sit on emptyDir — FU-195): `a3628730` is moot (callers disabled at source);
  `5400ed94` re-created as `1ac4049c` to 09-01 (the #698 minutes mute, was re-firing). **S8 (merge
  lanes) is on the work map** — (repo, base) serialization + goal v1.3 themes as ONE stint
  after S5; #829 absorbed at its authoring (de-queued, agent-fix kept).

- **⚑ Retro (FU-058): r2 landed END-TO-END 08-31, batch largely DRAINED same day.** Reports
  merged (PR#1094, human gate = arbitration option 2); harvest extractor fixed (#1096 →
  PR#1099 merged: awk last-block + `retro-cell-report/multi-block` fixture). **Batch container
  #1101 (`retro-batch: platform-r2`, the #949 shape)** — children: #1103 (F2) DONE
  operator-direct `255b0edc`; #1104 (F3) → PR#1110 MERGED; #1105 (F4+F6) → PR#1111 MERGED;
  #1106 (F5, agent/done reconciler) queued, riding; **#1102 (F1) DE-QUEUED + to be RE-SCOPED**
  per the drainage-economics ruling (see the 08-31 rulings bullet) into the Touches-classifier
  LINT + the blockedBy filing-edge discipline + the goal-grant consult; #1107 (pin-vacuity
  gate, operator-lane) inert. Also merged at the same gate sitting: PR#1100 (#1097's
  agent/blocked exclusion), PR#1091 (#1055's capability card + unreadable-input terminal),
  PR#1112 (#1060's closing-keyword refs — seat resolved its conflict on-branch, MERGED 07:57Z,
  #1060 closed). Correction from the live read: r1 residue #930/#931 both
  CLOSED (landed 08-30 evening). Clean-acceptance watch moves to r3 (Mon 09-07); containers
  #949 + #1101 close at post-r3 sweeps (predecessor-scoring is the closeout read).

- **⚑ GARAGE, operator-owned residue (recovery COMPLETE + env rebuilt, #884/FU-184 archived):**
  the `garage repair blocks` hold can come off (reclaims ≈nothing now) · **do NOT delete the 3
  ERT giants** (the 2026-07-12 corpus is the first delta job's stale base — rationale in
  docs/garage.md §Durability) · delete `backups/garage-meta-20260825-prerebuild/` (20 GB) +
  `backups/garage-meta-forensics/` evidence after ~2026-09-01 · **meta volume rides rf=1 on
  wk-02** — redundancy returns with the ADR-114 build-out, FU-137's ~08-31 deadline is
  load-bearing.

- **⚑ FU-168 soak read FAILED 2026-08-25:** cron-woken dispatches persist
  (`changes(agent_dispatch_cron_woken_timestamp[24h])` = 2 and 5) — #459 fires legitimately,
  a dead doorbell edge remains. The emitter hunt (the scan states wake source per dispatch)
  is the next concrete action, tracked on #459 + FU-168.

- **#974 FIXED — PR#1000 merged 21:18Z (ADR-110 read):** coordinate WorkflowTemplate limit
  512Mi→1Gi (measured: 442Mi survivor peak; requests untouched), the global scan plane
  recovers from the next sync. **#994 still holds the routing decision** the operator owes
  (scan-side early exit recommended — its cost goes UP now that #974 landed; diagnosis
  comment on the issue, 2026-08-26). Related sighting on **#938** (sentinel edge convoy,
  recurrence comment 2026-08-26 ~21:17Z): head-blind `{wake: edge}` payloads confirmed, 17
  pending identical sweeps at peak, arrival source = updater head churn after merge bursts.
- **CI-wall trial SETTLED 2026-08-30: `minRunners: 1` KEPT** — readout (ci.yaml pickup latency,
  n=40/window): median 22s→3s, p90 300s→3s, max 648s→7s; comments settled in arc-runners.yaml.
  Residual setup cost = homelab#518 (its promtool child #936 merged — the loop-health fixture
  lint cost).
- **Small live residue:** wk-metal-04 `kubernetes_labels.longhorn_bulk_zone` field-manager
  CONFLICT kills FULL tofu applies (targeted fine) — chase before the next broad apply
  (probed 2026-08-26: live managedFields show `Terraform` owning
  `topology.kubernetes.io/zone` CLEANLY, no rival manager on the label — likely cleared by
  the last targeted apply; unreproducible read-only, verdict = the next full apply) ·
  ~~proxy zen leg live-smoke~~ DONE 2026-08-30 (200 `[zen-leg+zen+zen-auth-swap]` through the
  in-cluster proxy, real nemotron completion; ⚠ free-rail latency ~68s — smoke probes need
  >60s timeouts) · the openrouter-proxy FU-021 comment repoint rides the next functional
  proxy change · hp-01 `install_disk: /dev/sda` is still a NAME with two identical disks
  (repin to WWID, FU-076's neighbourhood) · stack leftovers: circles#77 ci-red triage,
  oracle-fleet#259 rework per the seat read, circles-iac deploy-bump generator fix before
  the next circles build (circles-iac#71/#68).
- **Soaks** (each owned by an FU/issue — this line is only the calendar): retro Mon 09-07
  unattended fire (FU-058 clean acceptance — r2 close-but-not-clean, the #1096 class now
  fixture-pinned) ·
  minRunners readout · FU-148 first organic environmental-red retry · or-op#34 first
  daily-429 · renovate-approve one-approval-per-head (#114) ·
  CiDispatchStalled quiet-month window opens ~09-11 (FU-150) · **paid-flash REVERT
  ~2026-09-03 / fixup-end / OR depletion, whichever first** (PR#715; the claim comment
  carries the record; the FU-095 flip child mints at the revert; Go re-flip = FU-181).

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
  (~470k-equiv cache write) costs only ~6–10 turns' worth of high-ctx re-reads, while every turn
  re-reads the WHOLE context at 0.1× — so at ctx ≥ ~500k a NEW stint always starts a FRESH
  session (break-even turns ≈ 470k / ((ctx−400k)×0.1): 500k→~47, 600k→~23, 800k→~12; a real
  stint is 150–300+ turns and stints EXPAND). Trailing work of a few dozen turns may stay warm.
  Measured basis: the 2026-08-19 night session — 459 turns, 275.8M cache-read = ~92% of spend.
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
- **oracle-specs quota** (either jail, after oracle-iac#446 merges — auto-merge armed, CI green):
  verify `garage bucket info oracle-specs` shows 5Gi, then any fleet CI re-publish
  re-materializes the specs sites; close-purge of dead pr-*/ prefixes tracked oracle-fleet#318.
