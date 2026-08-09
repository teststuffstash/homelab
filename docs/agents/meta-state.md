# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (2026-08-09 ~12:45Z consolidation — everything below is CURRENT; history is TICK-LOG's)

- **ADR-102/103 PROGRAM — clause set COMPLETE** (#206/#207/#208/#209/#212/#215 all merged,
  replay-gated; ratchet v2 live). **#210 homelab leg MERGED ~12:50Z (PR#219** — union stats_ts
  reader + machine-comment.sh; codeowner-reviewed by execution: jq union verified on a mixed
  world, reader-sweep negative re-proven; spot-check the merged-closeout flip/harvest on #210).
  REMAINING: **agent-runtime#62** (primary emitter twin, QUEUED) + **homelab#217 spend belt**
  (queued). Old-shape branch deletes only after #62 ships AND no open PR carries it. **Monday
  retro 08-10 05:00Z scores the two ADR-103 KPIs first — CHECK ITS REPORT.**
- **minutark.ee LIVE + SERVING** (verified 12:19Z: http=200 via Cloudflare; a 20m-deadline
  monitor fired http=000 but that was the JAIL's Unbound negative-cache from before the A
  records existed — self-expires, site fine). ONE step remains, OPERATOR: add the DS at zone.ee —
  `2371 13 2 B6C05FC87C68195F40C98F4A2099E3DFFF02447920A84A0A633CF11DA4B48D79`
  then authoritative-verify (`dig DS minutark.ee @ns.tld.ee +norecurse` shows the digest) and
  close oracle-iac#351. NO LB (ladder rung 1); MCP exposure waits on the gateway (T3c).
  Design + boundaries: docs/cloudflare.md. FU-157 account-token migration opportunistic.
  Host-side: next `tofu/cloudflare-token` apply is PREPPED (account-first policy order + two-zone
  ingress token) — operator runs it outside the jail. **ADDED 13:45Z (PR#220 live-verify): with
  the admin token first run `GET /user/tokens/permission_groups | grep -i argo` — the argo/
  smart_routing setting 1015-refuses BOTH Zone Settings Read and Write, so the spend-probe's argo
  leg is BLIND (CloudflareSpendProbeBlind firing is EXPECTED + known-cause, don't re-triage) until
  a group is found + added to observability-read.tf; if no group exists, re-scope the argo leg +
  the doctrine's write-vector claim (docs/cloudflare.md §Spend surface has the ⚠).**
- **ert-verify-2026089-mpws5**: still Running (5h+), waiting out riigiteataja's weekly
  regeneration (LOEMIND.txt sentinel); backoff hourly; completes when upstream publishes.
  oracle-iac#343 corrected+de-queued (do NOT re-queue unless proxy 504s while in-pod curl works
  AFTER the files return). This is the #217/#235 fix-cycle verification tail.
- **homelab#107 CLOSED 13:05Z** — the 12:23Z queue was a meta mis-queue (fix already on master
  e5f568e; triaged from a truncated thread read — TICK-LOG has the lesson); dispatch refused the
  no-op, all defect legs fixed, fingerprint re-fire is the net.
- **BOARD DRAINED ~15:30Z**: #103 DONE (PR#225 — BestEffort Sensors got requests, soft hostname
  spread via podSpecPatch/Exists-selector; ride corrected BOTH the issue body and my ⚖ — the
  workflow templates already had requests; live pod check backgrounded, result → #103 comment).
  #61/#62/#25/#217 all DONE same day. or-op#34 SOAKS (needs first daily-429 datum). Possible
  trailing echo: or-op chart deploy bump self-merges via first-party lane (like #222).
- **TOMORROW (meta, ~30 min): #103 residual leg — Composition podSpecPatch.** PR#225's spread
  constraint covers agents/coordinator objects only; the per-stack cron CronWorkflows are
  Crossplane-rendered (AgentStack Composition, argocd/resources/) and their tick pods verified
  WITHOUT the constraint (15:30Z pod, tsc null). Mirror the merged podSpecPatch shape into the
  Composition's CronWorkflow template + verify a fresh tick per stack. Composition = meta lane.
- **TOMORROW (operator, ~5 min): mint `homelab-jail-read-all`** — dashboard "Read all resources"
  template, all accounts/all zones, **plus user-scope API Tokens Read** (lets the jail list the
  permission-group catalog — the admin token can't, it has creation rights only). No IP filter,
  long/no TTL. Hand the value to the jail session once → it stores wallet string +
  ~/.claude/cloudflare/ cache (wallet-files.sh), adds to docs/cloudflare.md token matrix, then
  IMMEDIATELY runs `GET /user/tokens/permission_groups | grep -i argo` → either names the group
  for observability-read.tf in the prepped host-side apply, or proves the argo leg
  unimplementable → re-scope #223 + the doctrine ⚠. Rationale: strictly below existing
  write-key privilege; endpoint-first doctrine needs a probe credential (hit the wall twice
  2026-08-09).
- **HA #221 (meta lane, resumable)**: 3 tuya_local devices wedged since 08-08 restart. pve +
  laptop4: devices HEALTHY (jail tinytuya sessions work with devices.json versions) but HA-side
  wedge survives reload ×2, WS disable/enable AND a core restart (14:48Z, clean) — leading
  hypothesis: protocol_version mismatch in the tuya_local config entries vs. what the devices
  now negotiate; next probe = compare entry versions against tinytuya negotiation, fix entries.
  aquarium: DEVICE-side (refuses jail sessions too, Err 901) — physical cycle cuts aquarium
  power, operator's call. Most of the 18 'stale' sensors were static-value FALSE POSITIVES
  (details on the issue); consider a rule-side exclusion later.
- **circles**: PR#21/#25 frozen (unchanged, operator's). **e2e-outage arc CLOSED**: PR#239
  (with the #228 cancel-leak belt) + PR#234 merged; #228/#190/or-op#33 closed.
- **Operator physical**: wk-metal-01 raised for cooling (verdict = tomorrow's daily peak vs
  94–98°C baseline); zone.ee DS hand-back (above).
- **tuya frozen-accepted** (silence c73baef2 → ~08-22 auto re-triage).
- **Soaks**: iac-sentinel shadow (FU-106); router shadow (FU-095); Monday retro (FU-058);
  FU-149 spot-check; FU-148 acceptance (first organic environmental-red self-retry); first
  concurrent double-e2e contention glance; M11 shadow lines once #159 lands; ~5 stale local
  branches in the oracle-iac checkout worth a checked sweep.

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
