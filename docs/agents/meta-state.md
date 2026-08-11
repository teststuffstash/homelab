# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (2026-08-11 end-of-pipeline consolidation — history is TICK-LOG's)

- **minutark.ee LIVE + DNSSEC COMPLETE**; oracle-iac#351 OPEN — deliverable = the bootstrap AS
  IaC, blocked on the host-side ingress-token re-mint (the host session below); acceptance =
  drift-free re-plan through the two-zone token. FU-157 opportunistic. ⚠ `dig +short` wraps
  long DS digests — `tr -d ' '` before grepping.
- **HA #221 (meta lane, resumable)**: 3 tuya_local devices wedged since 08-08. Devices HEALTHY
  via jail tinytuya; HA wedge survives reload/WS-cycle/core-restart — leading hypothesis:
  protocol_version mismatch in config entries vs negotiation; next probe = compare + fix
  entries. aquarium = DEVICE-side (physical cycle, operator). tuya frozen-accepted otherwise
  (silence c73baef2 → ~08-22 re-triage).
- **Soaks**: iac-sentinel shadow (FU-106); router shadow (FU-095); retro first UNATTENDED fire
  2026-08-17 (FU-058); FU-148 acceptance (first organic env-red self-retry); FU-149 datum
  ~08-20; or-op#34 (first daily-429); renovate-approve fix (#114) = next Renovate wave shows
  ONE approval per head; check-#3 shadow warnings stay zero.

## NEXT SESSION — the worklog (updated 2026-08-11 midday)

1. **PR queue DRAINED 2026-08-11 (~11:30Z)**: #250/#251/#254/#255/#260 all merged (findings
   harvested; residues: FSM dup keys + fixture registration + FU-106 third residue — all in the
   same-day jail batch). The day's "FU-130 WAN class" reds were actually **wk-metal-02 losing
   its IPv4 default route** — postmortem
   [`docs/incidents/2026-08-11-wk-metal-02-default-route-loss.md`](../incidents/2026-08-11-wk-metal-02-default-route-loss.md);
   node rebooted + verified, ARC runner spread/requests shipped (arc-runners.yaml).
2. **Board CLEAN per operator directive** (queue/fix/close all agents/infra issues; HA may
   remain): closed #107/#131/#223(→#231)/#241; #235/#240/#244/#245 closed by merges; QUEUED
   #242/#248 (+ already-queued #249/#252/#253/#256-259) — the loop drains them. Remaining open
   by sanction: #221 (HA, meta chain above), #231 (single Cloudflare anchor — host session).
3. **snore-recorder#15**: CI GREEN after the m02 fix (the "environmental red" was the route
   loss). Remaining: address the review verdict (FU-051 deploy-pin enablement).
4. **THE FU BUILD-OUT GOAL IS LIVE: homelab#278** (launched 2026-08-11 ~15:30Z). **5 of 10
   children MERGED+verified by ~18:30Z**: #282 (scout legs), #286 (crash-net — incl. the
   batch/cronjobs RBAC grant the closeout caught missing, all claims re-verified Synced),
   #291 (inventory-yaml — generated blocks live in README/CLAUDE), #284 (CiDispatchStalled
   queued-age), #283 (FU-145 re-key). Queued: #285/#287/#288/#290; #289 parked with oracle.
   FU-151 meta-delivered for sleep-tracking (`5b8c384`). Jail seat: quiet-goal backstop +
   closing sweep (per-child live re-probe + the two authoring lessons → issue-authoring §Touches:
   ratchet-clause files bring agents/replay/** [done]; Composition-new-kind brings rbac.yaml [at
   sweep]).
4b. **⚠ Pre-existing UNAPPLIED tofu drift on master** (found exercising #296's plan gate):
   `ci-runner-01` plans as a REPLACE (cloud-init `source_raw.data` drifted since last apply —
   wants an attended window, it rebuilds the ADR-082 runner VM) and wk-metal-04's ephemeral/kata
   taint (`kubernetes_node_taint.ephemeral["wk-metal-04"]`) was never applied. Neither is
   today's work; operator decides the apply window.
   **Decompose rulings (operator, 2026-08-11): the decompose runs IN THE JAIL
   with the design-agents corpus loaded — the cluster goal-decompose clause reads only the
   goal body and would make a mess on a platform-machinery goal; and the goal COORDINATION
   seat is FABLE (the meta seat authors+queues children, holds goal-review's quiet-goal
   backstop; `GOAL_MODEL=fable` if the cluster clause ever re-decomposes).** Extra child noted
   2026-08-11: fold the `SubscriptionWeeklyPoolLow` restart-silence fix (`max_over_time` —
   the durable warning below, no FU of its own) into the FU-158 behaviour-half child.
   Design-complete children, roughly ascending effort:
   FU-161 legs 1–2 (scout filter + benchmark columns → hand-fire, retire #235's premise) ·
   FU-151 next (automerge labels → 3 repos) · FU-145 (ScanWedged re-key on scan phase) ·
   FU-150 OURS half (AutoscalingListener-zero alert) · FU-144 (emitter {stack,loop_ns}
   fan-out; kill the dead coordinate-now row) · FU-140 (Composition crash-net; write-only key
   ⇒ unconditional PUT) · FU-160 (agent_run_phase_seconds + panel + deviation alert) ·
   FU-158 behaviour half (promtool test fixtures, spend/agent-loop files first) · FU-102
   (oracle probe.md from UC-1 + flip prober.enabled) · FU-162 (draw verb + pools, ADR-104) ·
   **inventory-yaml unification** (operator, 2026-08-11: ONE inventory yaml — machines.yaml
   extended — consumed by tofu via `yamldecode` for the metal flags AND by `generate.py` for
   marker-delimited generated blocks in README/CLAUDE host tables + the version triple; kills
   the hand-copy drift class proven today. SERVICES.md's generated successor stays FU-049,
   separate).
   Judge at decompose (bigger): FU-095 legs, FU-090(b), FU-106 G01 flip post-soak + G06 lens,
   FU-104 teeth, FU-101 ASVS/e-ITS.
5. **docs-cleanup residue** (the comb ran + ~55 findings APPLIED 2026-08-11; what remains):
   (a) cloudflare.md's two zone-classes sections merge (structural, one home); (b) the
   network-physical re-capture (banner placed); (c) FU-001 ref scrubs when its archive entry
   expires (~08-13); (d) the openrouter-proxy.py FU-021 comment repoint — rides the NEXT
   functional proxy change (a comment-only sync restarts the proxy and resets every for:
   window); (e) the five EXPIRY-HELD archive ids (FU-014/021/022/025/041) need their own
   scrub pass or a ruling that foundational shorthand keeps its archive residue.
6. **Standing from 08-10** (⚠ circles/oracle PARKED by operator 2026-08-11 — leave their
   gates/parks alone until re-opened; incl. circles#77 ci-red park + oracle-fleet#259
   codeowner park + oracle-fleet#225 ERT snapshot re-run, upstream healthy again):
   Composition podSpecPatch mirror (#103 residual leg, ~30 min) ·
   oracle-fleet#255 rework (attended-download constraint stands) · **HOST-SIDE session**:
   the 4-step jail-read-all sequence (admin-token edit → argo-group probe →
   homelab-jail-read-all as .tf → DELETE the legacy "Read all resources" token) — also
   unblocks #223 and settles #231's blind leg.

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
