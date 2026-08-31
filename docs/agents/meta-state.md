# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (pruned 2026-08-25 evening, the sweep-pipeline session — history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ 2026-08-31 morning verify tail — RESOLVED by the 07:00Z corpus session (retro-first):**
  - **oracle-fleet#285: NO round-2 landed off the 06:51Z rerun red, and it structurally cannot**
    — both wake paths are deaf to a same-head CI rerun (exporter red edge dedups per `head_sha`;
    the `state-fp` written 21:01Z hashes byte-identical when the rerun reds the same
    conclusions). Filed+queued **#1108** (fix shapes: `(head_sha, run_attempt)` dedup key, or a
    run-attempt input to the ci-red fp only — #1011 runs the opposite direction on arbitrate);
    blockedBy edge wired #285→#1108 (the ADR-119 un-park shape, seat door included now).
    **#285 stays wedged until #1108 lands**; the content fix itself is known (`BASE_LOEMIND`
    unbound, e2e-kind.sh:481).
  - PR#1094 + PR#1099 MERGED 07:05Z (seat codeowner reads; #1096 auto-closed by the merge).
    probe-platform's 06:41Z tick VERIFIED past auth (the #1085 fix live): 6 checks, 1 finding,
    0 probe-fails — the finding is the known-benign `logging` OutOfSync (the loki
    `volumeClaimTemplates` papercut); do not re-derive it on future probe reads.
  - #946 seed: 3 cells outstanding, recipe on the issue (Zen 429 weather). #994 operator-held.
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
  - PRs #1044/#1051/#1052 were auto-merging at wind-down — confirm landed.

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
