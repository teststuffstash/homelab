# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (2026-08-09 ~09:40Z consolidation — everything below is CURRENT; history is TICK-LOG's)

- **ADR-102/103 PROGRAM — first tranche mostly LANDED 08-09 morning**: ✓#206 harness (agents/
  replay/, 12-fixture suite) ✓clause-replay CI gate + RATCHET (v2 — files API; v1 died shallow,
  see TICK-LOG) ✓#209 panel ✓#207 harvest→post-launch-bucket (PR#216) ✓#212 optout shared read
  ✓#215. REMAINING: **#208 verdict terminals** (dispatches now #207's footprint freed — review
  like a hawk, replay fixtures are the acceptance) + **#210 channel separation**. Monday retro
  (08-10 05:00Z) scores the two ADR-103 KPIs first — CHECK ITS REPORT. ADR-102 clause set
  COMPLETE (PR#216+#218); remaining program: #210 channels (riding, homelab leg + agent-
  runtime#62), #217 spend belt (queued).
- **minutark.ee LIVE + SERVING** (placeholder, 2026-08-09 ~12:45Z) through the full new chain:
  cf-api-proxy (allowlist = the permission model, reconciler tokenless) + PublicRoute product-
  zone class + zone bootstrap applied (TLS 1.2 / always-HTTPS / SPF+DMARC / DNSSEC). ONE step
  remains, OPERATOR: add the DS at zone.ee —
  `2371 13 2 B6C05FC87C68195F40C98F4A2099E3DFFF02447920A84A0A633CF11DA4B48D79`
  then authoritative-verify (`dig DS minutark.ee @ns.tld.ee +norecurse` shows the digest) and
  close oracle-iac#351. NO LB (ladder rung 1); MCP exposure waits on the gateway (T3c).
  Design + boundaries: docs/cloudflare.md. Spend belt queued homelab#217; FU-157 account-token
  migration opportunistic.
- **ert-verify-2026089-mpws5**: waiting out riigiteataja's weekly regeneration (LOEMIND.txt
  sentinel); backoff hourly; monitor armed; completes when upstream publishes. oracle-iac#343
  corrected+de-queued (wrong premise — do NOT re-queue unless proxy 504s while in-pod curl
  works AFTER the files return).

- **IN FLIGHT — e2e-outage recovery (root cause: leaked kind clusters → inotify 116/128, fixed
  live + codified; TICK-LOG 2026-08-09)**: master e2e re-run GREEN 07:00Z. Pending, with
  deadlines: (a) PR#239 + PR#234 CI re-runs (monitor armed; expect green ≤25 min — if red, the
  diagnosis was incomplete, go back to the VM); then PR#239 → reviewer reflex → auto-merge, and
  PR#234 → reviewer re-approve → auto-merge (arbitrate ruled it mergeable-quality; its
  agent/blocked+arbitrate labels clear on merge). (b) `ert-verify-2026089-mpws5` in ns
  oracle-fleet on pin 2026.8.9-gcbcc2db04aa7 (monitor armed; expect Succeeded ≤40 min) — the
  #217/#235 fix-cycle verification. (c) LEAK CLASS still open: cancelled e2e jobs leak their kind
  cluster (PR#224's cancel-in-progress) — flagged with evidence on oracle-fleet#228 for a
  job-start stale-cluster sweep; verify it lands with PR#239 or gets its own issue.

- **#26 INCIDENT ARC FULLY CLOSED with live acceptance (01:40Z 08-09)**: park held (zero 429
  storm), BOTH wedge classes fixed+deployed (rpd park #28; idempotent 404-delete #30/PR#36),
  **drain verified to ZERO pending CRs**. The whole credit chain is instrumented end-to-end and
  LIVE-verified: operator gauge (#29/PR#35, NaN-not-omit) → proxy latch reading it cross-namespace
  (#180/PR#191, `router_openrouter_account_credit_usd 20.1672` observed on the proxy) →
  OpenRouterCapacityDown page (#163) → rail degrade (#158 family). REMAINING queued: homelab#190
  (launcher gate reads the proxy surface — edge on #180 now satisfied), or-op#33 (balance alert,
  edge on #29 satisfied), or-op#34 SOAKS until the first daily-class 429 datum.
- Reviewer outage (heredoc `$103.74`) fixed 00:30Z 08-09 + recovered; verdicts flowing since.
- **openrouter-operator has a BUILD lane since 01:00Z**: .agents/build.yaml (chart/+tests,
  render-first TDD) + review.md criterion-5 lane split (PR#31); first build PR#32 shipped the
  metrics Service/ServiceMonitor/key-ops alert with the no-alert-without-a-series constraint as
  a chart TEST. task/build label wired.
- **Cloudflare/PublicRoute: ARMED, zero consumers** — operator acts: echo claim → ha retrofit.
- CI-red arc resolved 20:30Z 08-08 (#151 root; issue closed with audit 08-09, ditto #133/#173).
  #153 re-scoped+queued (github-exporter duplicate-emission mechanism); #154 re-queued.
- **#162's proxy latch verified live post-roll**: router_openrouter_capacity_down{,_total} = 0 on
  the rolled pod. Alert for the latch = #163 (queued, ⚖ severity-warning note attached).
- **circles**: PR#54 assembly MERGED 2026-08-08 ~20:47Z via my delegated codeowner approve (specs
  delta = evidence-blocks only, 205 PASS, contract text untouched); goal #29 CLOSED; #47/#138
  hand-closed with audits (goal-branch Fixes never fires at the squash boundary). Frozen:
  PR#21/#25 (unchanged). **oracle**: #217 + #235 MERGED + agent/done flipped; deploy bump #340 +
  pin-follow landed (machine lane); verification = the ert-verify chain in the IN-FLIGHT bullet.
- **agent-runtime**: PR#54 reviewed-by-execution + admin-merged 07:02Z 08-09 (#43 closed);
  4 queued issues (#45/#46/#49/#50) now free to dispatch via wip caps — expect rides.
  ⚠ reviewer.enabled=false for the WHOLE platform stack (reviewer log 20:45Z) — the earlier
  "reviewer follows the fixer block" note is NOT what the claim says today: every platform-repo
  PR needs MY read + admin merge until that's reconciled (needs-meta clause 1/park covers).
- **Operator physical**: wk-metal-01 raised for cooling (verdict = tomorrow's daily peak vs
  94–98°C baseline); wk-metal-02 at 1 Gbps (fixed by the poke).
- **tuya frozen-accepted** (silence c73baef2 → ~08-22 auto re-triage).
- **Soaks**: iac-sentinel shadow (FU-106); router shadow (FU-095); Monday retro (FU-058);
  FU-149 spot-check; FU-148 acceptance (first organic environmental-red self-retry); first
  concurrent double-e2e contention glance; M11 shadow lines once #159 lands.

## Durable warnings — re-read before touching these files

- **⚠ ABSENCE IS THE EASIEST THING TO FAKE — three self-inflicted probe errors in one night, all
  the same shape: query a NARROWER view than the question, then read the empty result as fact.**
  (1) `ls ~/.claude/homelab-github-reviewer/ | head -5` hid `private-key.pem` → I reported the
  reviewer credential missing and nearly sent the operator hunting a non-existent blocker.
  (2) `spec.fixer` on an AgentStack returned `null` → I reported "circles has no fixer block"; it
  is **per-repo**, `spec.repos[].fixer`, and carried `docker: true` all along.
  (3) `.spec.containers` on a ride pod showed only `agent` → I reported "no dind"; a **native
  sidecar is an initContainer with `restartPolicy: Always`**, and it was there with kata +
  `DOCKER_HOST`. Each time the operator supplied the counter-evidence.
  **Rule: when a probe returns empty/absent and that absence would CHANGE a conclusion, re-query
  the whole object before believing it** — `-o json` and read the structure, never `get X -o
  jsonpath=…` for a field whose path you are inferring, and never `| head` a listing you are about
  to call complete. An empty result is a claim about your query, not about the world.
- **⚠ A DEPLOY CAN SILENCE AN ALERT FOR ITS WHOLE `for:` WINDOW.** `SubscriptionWeeklyPoolLow`
  dropped out of the firing set at 06:41Z on 2026-08-07 — not because utilization fell (it was
  **0.92**, fresh, single series) but because deploying `router.py` restarted the proxy
  (`8574bd8d9-r42tx` → `cdc58fc45-wm8kr`). The old per-pod series ended, a new one began, and the
  **`for: 1800s`** timer restarted from zero. Any ArgoCD sync touching the proxy buys 30 minutes of
  silence on a real capacity problem. ⚠ **I read the firing-set change as "cleared" and reported it
  as such without re-querying the gauge** — the operator caught it. A firing-set transition is an
  event, not a measurement: re-read the metric before claiming a condition ended.
  Candidate fix (unshipped, needs a decision): `max_over_time(...[10m])` so a restart gap cannot
  reset the window — aggregating away `pod` alone does NOT help at one replica, where the gap is
  real. Same class as the day-gate bug: the alert's identity was tied to something that churns.
- **⚠ `severity: info` alerts are SILENTLY SUPPRESSED in this cluster.** kube-prometheus-stack
  ships a stock inhibit_rule (`alertname=InfoInhibitor` → `severity=info`, equal `namespace`) and
  `values/kube-prometheus-stack.yaml` does not override `inhibit_rules`. An info alert reaches
  Prometheus and fires correctly, then sits `state: suppressed` in Alertmanager and is dispatched
  to NOTHING — not the responder, not the Home Assistant webhook. Shipped one on 2026-08-06; it was
  live for ~10 minutes as pure decoration. **Use `warning`.** Tell: all 27 other alerts here are
  warning/critical. Check with
  `curl -s 'http://192.168.40.14:9093/api/v2/alerts?inhibited=true' | jq '.[].status'` — Prometheus
  saying `firing` is NOT evidence anyone was told.
- **⚠ A steady-state COUNTER cannot separate "at capacity" from "cannot work."** `running: 4,
  pending: 0` reads identically either way. Capacity claims need a THROUGHPUT signal: a saturated
  pool has jobs RUNNING, a broken one has workers WAITING. Made twice on 2026-08-06 — by me and,
  independently, by a responder session. Now in the responder prompt (`ecb74bb`).
- **⚠ A green surface is not a green outcome.** A workflow "failure" that had already shipped its
  artifact; a ride pod `Succeeded` with its harness dead (`exit_status=harness-death`, nothing
  committed). The status field often answers a different question than the one being asked. The
  durable signal for a ride is the `AGENT_STRIKE:` comment on the issue — `meta-watch-loop.sh`'s
  clause is best-effort only (ride pods are GC'd within minutes, so **its silence proves nothing**).
- **⚠ Check the bypass ACTORS before calling anything a human gate.** A `required-approval` ruleset
  whose only bypass is `OrganizationAdmin: always` is NOT a human gate — **the jail credentials ARE
  that admin**; `gh pr merge --admin` is yours to run. Applies to every platform-lane repo
  (agent-runtime, agent-coordinator, homelab, openrouter-operator) where `reviewer.enabled=false`
  means no bot will ever approve. ⚠ Do NOT "fix" that by flipping `reviewer.enabled=true` for the
  `platform` stack — it would also point the bot at homelab and `agent-coordinator`, both tier-3.
- **⚠ agent-runtime now HAS a fixer lane** — PR#37 merged 2026-08-07 03:48Z, superseding the
  2026-08-06 "no `.agents/` by design" ruling. It ships `.agents/fix.yaml`, `tests/` + a `unit` CI
  job over `agent-finalize`, and a CODEOWNERS owning the governor paths (`.github/`, Dockerfile,
  lockfiles, `.agents/`) while leaving the fixer's lane unowned. Its recipe uses `Fixes #n`, which
  genuinely closes since these PRs target master. ⚠ CORRECTED 2026-08-08 (~15:00Z): **"no bot
  reviewer on platform repos" is STALE for FIXER-ENABLED ones** — reviewer coverage follows the
  fixer block, and agent-runtime PR#40 went worker→bot-APPROVE→auto-merge with no human, which is
  the DESIGN on the unowned lane paths (agent-base/*): the codeowner gate guards only the governor
  paths there. homelab/agent-coordinator PRs still need the meta read + OrgAdmin merge (homelab's
  gate is whole-repo by operator ruling). ⚠ First `unit` run took **16m** on a cold nix cache;
  that is not a hang.
- **⚠ Arming is keyed on the `goal/` PREFIX** (`agent-session.sh` + `review-reflex.sh` C9). NEVER
  widen to "any non-default base": the prefix is the only thing carrying the ruleset, and arming
  into an unprotected base merges ON OPEN.
- **⚠ An operator-lane PR has NO machine owner.** `changes-requested` is scoped to `WORKER_AUTHOR`,
  so a human-authored PR is skipped by design and the coordinator announces that to nobody.
  oracle-fleet#166 sat blocked three days on a real, correct, twice-repeated finding. Only a board
  sweep across EVERY active repo finds these — not just the stack in flight.
- **⚠ Two readers, one mirror.** `coordinator-scan.sh` reads the LIVE CLUSTER claim; the DOORBELLS
  (`coordinator-session.sh`, `agent-session.sh`) read `agents/stacks.json`. Sync the file on every
  claim change until the doorbells read the cluster too — that is the real repair, not done.
- **⚠ "Written is not applied" — the tell is always the CALLER, not the config.** A label
  description >100 chars that never reached GitHub; a required check on a branch pattern no workflow
  triggered on; a `units` entry no gate could reach; a router class whose only caller is the worker
  launcher; a review reflex that ran, matched nothing, and said so in a log nobody read until a
  deadline fired. **A deadline is what turns a plausible reading into a checked one.**
- **⚠ A reviewer that verifies CODE against ONE spec page is not verifying it against the
  CONTRACT.** Two agents reasoned correctly inside `render/colors.md` and reached a remedy
  `data/status-resolution.md` forbids (circles#32, ruled 2026-08-06).
- **⚠ The jail's Bash tool runs ZSH, which does NOT word-split unquoted variables.** The repo's
  `K="devbox run -- kubectl …"` … `$K get pod` idiom is a BASH idiom: in an ad-hoc Bash-tool probe
  it becomes ONE command word, fails, and behind `2>/dev/null` yields an empty capture that a `-z`
  test reads as "the object is gone". Wrap ad-hoc probes in `bash -c '…'`, or call the binary
  directly. Scripts under `agents/` are safe only because they are invoked as `bash <script>`.
- **⚠ NEVER pipe-filter `git push`; verify pushes by fetch-compare.** `push -q | grep | head`
  swallowed 11 consecutive non-fast-forward rejections (2026-08-08 — PR#123's squash had moved
  master) while the shared host/jail worktree kept every apply working, so nothing LOOKED wrong
  until ArgoCD couldn't see new files. After each push: `git fetch -q && [ "$(git rev-parse
  HEAD)" = "$(git rev-parse origin/master)" ]`. Auto-merge makes mid-session master movement
  routine.
- **⚠ Shell/API traps that each cost real time:** `gh --jq` takes NO `--arg/--argjson`; an
  APOSTROPHE inside a jq program kills review-reflex FLEET-WIDE and `bash -n` cannot see it
  (EXECUTE the block — stub the expensive callee and assert the assembled string); `gh pr view` has
  no `merged` field (use `state == "MERGED"`); GitHub caps label descriptions at 100 chars; a branch
  rename CLOSES the PR whose HEAD it is; `python3` in the jail has NO `yaml` module (use the pinned
  `devbox run -- yq`).

## Re-arm on a fresh session

- **needs-meta watch (REQUIRED)**: `Monitor` (persistent) `bash agents/meta-needs-attention.sh`
  — unreviewed platform PRs, `agent/blocked` issues, unlabeled>24h, AND (clause 4, 2026-08-08)
  stack-repo codeowner parks (bot-approved+green+REVIEW_REQUIRED on oracle-fleet/circles — it
  caught circles PR#54 on its first pass; oracle PR#217 had sat 17h). ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — every sweep runs `bash agents/meta-throughput.sh` FIRST (queue-vs-movement;
  a THROUGHPUT-STALL line is an incident, not calm — 2026-08-09 operator catch), then
  `bash agents/meta-alert-crosscheck.sh` + the board/chain check against this file.
- Handoff watch is NOT standing (operator 2026-08-09: special case) — arm `bash
  agents/meta-handoff-watch.sh` only on rollout days / when a stack jail is known active;
  `/handoff` processes the inbox on demand.
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
