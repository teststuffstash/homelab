# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## ✅ 2026-08-07 ARC wedge: fully closed out (details: the incident doc + FU-150)

All post-recovery expectations verified by the 2026-08-07 ~21:00Z meta session: queues drained,
circles PR#44/#45 + circles-iac #30/#31 merged, agent-runtime PR#37 admin-merged 03:48Z,
`oracle-fleet/update-pr-branch` green on schedule (20:55Z success). homelab#111 closed. FU-150
carries the ours-side alert gap; the incident doc carries the story.

## ⏳ OPERATOR ACTION PENDING — first-party deploy pins still need one `tofu apply`

**Committed, NOT applied.** `tofu/github/actions_secrets.tf` now adds homelab to
`local.reviewer_repos`; it takes effect only after **`devbox run github-tofu apply` from the HOST**
(tofu/github is operator-only — the org-admin PAT is deliberately outside the jail).

**Why they stall:** homelab is `require_approval = true` (FU-068, 2026-08-04) but was excluded from
`reviewer_repos` as "CI-only" — true when written, false since the flip. So the `renovate-approve`
reflex has no `REVIEWER_APP_ID` and takes its skip-gracefully branch: **`approve` reports GREEN
while doing nothing**, and the PR waits on a human forever. Fourth occurrence: #104, #105, #109,
#112. Same class as oracle-fleet's 2026-07-25 parity audit — the invariant is now written into the
locals block: `reviewer_repos == { repos with require_approval = true }`.

⚠ **It widens nothing.** The reflex still requires `user.type == 'Bot'` AND `automerge` AND
`dependencies`, so agent PRs (`agent/*` labels) never qualify; and `require_code_owner_review` is
untouched — a bot approval cannot satisfy an OWNED path, so only the CODEOWNERS carve-outs
(`agents/images.env`, the arc-runner pins, the openrouter-operator chart pin) can merge on it.
⚠ **Until it is applied, each pin needs `gh pr merge <n> --admin`** (the jail is the OrgAdmin
bypass). #112 was merged that way 05:59Z — verified first that `f77880d417da` is agent-runtime's
master HEAD and that `build-image` succeeded on that sha, so it was not a stale tag.

## ✅ SUBSCRIPTION LATCH CLEARED 2026-08-07 — plan upgraded, windows refreshed by hand

The 2026-08-07 09:15Z `utilization-7d = 0.95` deferral is over: the operator upgraded the
subscription plan, and one manual request through the proxy's `/anthropic` leg harvested fresh
headers — `7d = 0.01`, `5h = 0.06`, `limited: false`. Dispatch resumes on its own (level-triggered).
⚠ **Lesson: the window harvest is PASSIVE and the latch defers the only traffic that refreshes
it.** After an out-of-band capacity change (plan upgrade), the stale ≥-threshold reading persists
until the reset epoch unless someone pushes one 2xx through: port-forward
`agent-egress/openrouter-proxy`, then a 1-token haiku POST to `/anthropic/v1/messages` with
`Authorization: Bearer ref:agent-coordinator/coordinator-claude` (proxy injects token + oauth
beta). Verify via `GET /anthropic-limit`.

## ✅ The assembly review DID cover the whole branch (watch satisfied 2026-08-07)

PR#54 (`goal/29-p0-complete` → master) got a real assembly review: the 20:31Z goal-review
arbitration records the `homelab-reviewer` verdict confirming the coverage map (91/91 CIR-* ids
owned/deferred, CI exercises the kind gate) — specs included, NOT the PR#25 code-only failure
mode. Watch closed. **FU-154** (rounds reset on PR re-creation) remains the related open item.

## Where goal #29 stands (2026-08-07 ~21:00Z)

- **Assembly PR#54 open, CHANGES_REQUESTED**: the review found ONE blocking gap, routed as child
  **#57** (bake step into the real Docker image build) — worker r1 riding since 20:36Z.
- **#42 r4 riding** (20:52Z; its 20:21Z re-queue was the pre-sync debouncer bug, but dispatch is
  legitimate — the ADR-097 hold no longer bites since #19 closed). **pr-56** (#42's earlier PR)
  got a changes-requested round dispatched 21:0xZ.
- **#19 done** (PR#51 poll-until-ready merged). #30/#31/#32/#40/#18/#41/#48 done.
- ⚠ PR#54 sits **BEHIND** and `update-pr-branch` cannot update a `goal/**`-headed PR —
  **homelab#118** (queued, platform fixer) is the fix; its PR needs a HOST-side
  `github-tofu apply`. Not blocking while children ride; becomes blocking when #54 arms.

## Platform queue (homelab issues — the platform fixer lane owns queued ones; meta owns the rest)

- **#118** — fixer PR#119 **MERGED 22:20Z** (haiku fixer off the opus item-session's trap notes;
  meta-reviewed: bypasses `homelab-merge` on the two 422-producing rulesets only, master gate
  untouched, `ignore_changes` no-op trap disarmed on all three; `tofu validate` clean in-jail).
  **⏳ OPERATOR: one HOST-side `devbox run github-tofu apply`** — covers this AND the pending
  `actions_secrets.tf` reviewer_repos change below. Acceptance: one green `update-pr-branch`
  run against a `goal/**`-headed PR; watch the first plan for bypass_actors ordering noise.
  History (resolve-leg close on a latent defect, 21:25Z → reopen): the issue + TICK-LOG.
- **#117** — ✅ diagnosed 2026-08-07 (meta comment): NIC link-flap storm on wk-metal-02
  (`carrier_changes` 2→3778, no reboot, flat plug power) — the thinkcentre bad-cable class.
  **Operator, physical:** reseat/replace cable / switch port. FU-032 updated.
- **#103** — `NodeSystemSaturation` on wk-01. OPEN, containment shipped (`fc7e9fb`). Real shape =
  concurrent COORDINATOR Jobs across stacks/items. ⚠ Do NOT tighten `activeDeadlineSeconds`
  (1800 is right; tail reaches 1458s). ⚠ Do NOT implement "reject `unit=-`" — `-` is the
  legitimate full-scan default. (Debouncer re-queued it 20:21Z pre-scoping-fix; harmless.)
- ✅ **#110 / #101 / #65 / #63 / #68 all CLOSED 2026-08-07 ~21:20Z** (meta, each with verified
  evidence): #110 fixed by `8da2825` (512Mi live, 0 restarts); #101 forensic window lost (wk-02
  rebooted 13:26Z today) but the sd-reset at 18:08Z supports the storage-stall read; #68's scope
  ceiling was ALREADY SHIPPED (the coordinator refused the unit — the FU-133 first-ride
  finding); #63/#65 were its shared-fate collateral. The PSI-stall residual class → **FU-155**.
- **#116** — still open: the mirror-capacity decision (operator: grow the volume per the
  oversize-caches doctrine).
- ⚠ **A human comment on a responder issue disables its auto-close** — every issue you comment on
  becomes yours to close by hand (#117 is now such).

## Oracle goal lane — STARTED 2026-08-07 20:48Z

Operator queued **oracle-fleet#174** (goal: act resolution without knowing the lyhend;
task/goal + agent-fix + agent/queued, labeled by RasmusSoot 20:48:52Z). The human-labelling
doorbell gap (FU-144) means the 21:00Z `coordinate-oracle` cron is the pickup — goal-decompose
(opus, `1b4bda5`) should fire there. #175/#176 are follow-on goals, NOT queued. 🌱 #160 + #170
await the operator's FU-090 gate. PR#171/#172/#173 merged 20:37–42Z (goal-lane CI precondition +
TRACKS wording + the FU-129/FU-151 recipe ports — oracle-fleet is now the up-to-date donor).
⏳ Once decompose names the goal branch, arm the oracle loop watch with that `BASE_EXPECT`.

## ✅ RESPONDER BUDGET — live, binding, and it fired within minutes (ADR-099, FU-149)

Both halves proven end to end on 2026-08-06, faster than expected because the day was already over
budget. `ResponderTriageBudgetExhausted` fired at ~19:40Z with `probe_ok=1` (a genuinely spent
budget, NOT the fail-closed path), gauges live in Prometheus, push age 24s — so the pushgateway
rail works and the "invisible blocking" risk is retired.

**The measurement, and it is the whole argument for the change: 30 sessions spawned today against a
nominal ceiling of 12 — and 26 of them were ONE incident** (`GithubWorkflowRunFailed/monitoring`,
the Actions outage). Same incident → `INC_SEEN != 0` → the old cap never applied. 8 `budget-`
markers written since deploy, so the latch is actively blocking.
✅ **The midnight rollover + day-gate are PROVEN (2026-08-07 05:18Z):** `sessions_today` went
30 → **1**, `blocked` → 0, and `responder_triage_day_start` = **1786060800** = today 00:00Z exactly.
The count resets with no reset job because it is DERIVED from date-keyed ledger entries, and the
day gate (`(time() - day_start) < 86400`) replaced a 3h freshness gate that let a 23:21Z sample
report "no triage today" 65 min into the next day.
⚠ **Do NOT raise the cap in response to a firing** — it is the alert doing its job on an
anomalous day. Triage resumes at 00:00Z on its own; alerts still reach Home Assistant meanwhile.
⚠ **Effect cannot yet be split between the two fixes.** No session has spawned since the subject
dedup shipped (the budget has blocked every one), so zero `subj-` keys exist — that is an absence
of samples, not evidence the dedup does nothing. FU-149's read needs ordinary days.

⏳ **Cheap check after 00:00Z: is the alert's own `triage: none` guard real?** The alert is
`severity: warning` now, so the route genuinely delivers it to `agent-responder` — and the ONLY
thing stopping a session being spent to report that sessions are not being spent is that label.
It has NOT been exercised: every delivery so far was stopped by the budget gate, which runs first
(9 `budget-` markers, 0 for this fingerprint via the `none-` path). The mechanism works generally
(`none-` markers exist for other alerts), so this is a spot-check, not a suspicion. **After the
budget resets, confirm the fingerprint gets a `none-<date>` marker and no respond pod spawns a
session.** If it instead spawns one, the label is not being read and that is a recursion to fix
before the next busy day.

## LIVE CHAIN — circles#29, the P0-complete goal

**Terminus:** assembly PR#54 (`goal/29-p0-complete` → master) merges after the CODEOWNERS gate
on `/specs/` — an OrgAdmin merge. **If it stops anywhere short of that, treat it as a platform
bug, not a model failure.** Current state: "Where goal #29 stands" above. Harvest sprouts #38 +
#33/#34/#35 stay inert awaiting the operator's FU-090 gate.

**Work-vs-wait ledger** lives in [`observability-and-retro.md`](observability-and-retro.md)
§Part A″ — keep appending there, not here.

✅ **FU-143: ARCHIVED 2026-08-07** (proof: #40 machine-only closure + #48 via PR#53; the
`12e7fcf` hold KEPT by decision — ~zero cost now links are guaranteed, still catches genuine
abandonment). Archive entry has the detail.

## Frozen — from goal #17, do not touch (the comparison is the operator's)

- **circles FAN-OUT vs ONE-SHOT on goal #17.** Fan-out arm merged on `goal/17-p0-mvp` (#22 + #23).
  One-shot arm is **PR#21, FROZEN** (`major/awaiting-human`, `CHANGES_REQUESTED`, DIRTY) — do not
  push to it, dispatch a fix round on it, or merge it; a repair destroys the comparison.
- **PR#25 (`goal/17-p0-mvp` → master) is a DELIBERATE DRAFT** — the only thing holding the branch
  off master; un-drafting is an operator act. Reviewer-APPROVED + codeowner-judged by comment (meta
  authored it, so self-approval is worthless). ⚠ The bot's approval covers CODE only; the 13 spec
  files were judged separately in that comment.
- **circles #18/#19 were held** pending that comparison; #18 is now riding under goal #29.
- ⚠ **A goal small enough for one ride is not a goal** (operator, 2026-08-05).

## Unverified / soak watches (each gates a later operator flip)

- **`goal-decompose` → opus** (`1b4bda5`), `goal-review` stays sonnet. Axis is **AUTHORING vs
  CHECKING**, not goal vs routine. ⚠ Escalate a specific hard goal with `GOAL_MODEL`; don't move
  the floor.
- iac-sentinel shadow violations (→ G01 flip, FU-106); router shadow decisions (→ P4, FU-095);
  Monday 05:00 retro (= FU-058 run 3). (FU-111 retirement DONE 2026-08-07 — edges proven, reader
  removed.)
- ⚠ Garage still has no offsite backup (FU-137) and now carries tofu state.

## Open, not mine

agent-runtime **#13** (watchdog misses silent loops), **#33** (resumed round reports "no resumable
branch"), **#35** (a failed `:latest` push skips `deploy-pin`), **#36** (a fix round that dies
mid-session reports `exit_status=clean`; the mechanism is `succeeded = bool(stats.get("pr_url"))`
returning clean BEFORE any failure signature is consulted, so only round 1 can strike a model).
**#36 is now PINNED BY A STRICT XFAIL** in the merged suite — fixing it makes the suite fail on
`XPASS(strict)`, so the marker deletion is the fix's own acceptance test.
⚠ **openrouter-operator's deploy-pin job has the identical #109 label gap and is NOT fixed.**
⛔ **ANSWERED 2026-08-07: the router does NOT route away from a struck model.** `deepseek-v4-flash`
has now died THREE times on `goose-32602-truncation` (circles#32 r1+r3 on 08-06, circles#19 r1 on
08-07 05:31Z) — and #19's round 2 was dispatched **onto the same model**, `GOOSE_MODEL=
deepseek/deepseek-v4-flash`, read off the live pod spec. `AGENT_STRIKE:` comments are posted
correctly, so the signal exists and nothing consumes it. ⚠ **CORRECTED with the 4th sample — it is STOCHASTIC, not a size limit.** #19 r2 ran the SAME
model on the SAME lg task and finished clean (2073s, $0.0795, PR#50). Tally: 3 deaths (circles#32
r1+r3, #19 r1) vs 3 clean (#18 r2+r3, #19 r2) — so `goose-32602-truncation` is roughly a coin-flip
on lg work, not a wall. **RETRY IS AN EFFECTIVE REMEDY and no model override is warranted** — I had
said I would override if r2 died the same way; it did not. What stays true is the routing gap: a
struck model is re-picked immediately. That is now *tolerable* rather than urgent, because a retry
costs ~$0.04 and one meta re-queue. **Next:** take the gap to ADR-096/FU-095 with these six samples
— the ask is a cooldown that survives one strike, not a deny.
⚠ **Its TESTS assert presence, not the property — 3 instances in ONE PR** (#39). One PR is not a
fleet pattern; if it recurs on another stack it is a model-selection fact, not prompt tuning.

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
  genuinely closes since these PRs target master. ⚠ Still no bot reviewer (`reviewer.enabled=false`
  for the `platform` stack), so a PR there merges via the OrgAdmin bypass — `gh pr merge --admin` —
  never by waiting. ⚠ First `unit` run took **16m** on a cold nix cache; that is not a hang.
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
- **⚠ Shell/API traps that each cost real time:** `gh --jq` takes NO `--arg/--argjson`; an
  APOSTROPHE inside a jq program kills review-reflex FLEET-WIDE and `bash -n` cannot see it
  (EXECUTE the block — stub the expensive callee and assert the assembled string); `gh pr view` has
  no `merged` field (use `state == "MERGED"`); GitHub caps label descriptions at 100 chars; a branch
  rename CLOSES the PR whose HEAD it is; `python3` in the jail has NO `yaml` module (use the pinned
  `devbox run -- yq`).

## Re-arm on a fresh session

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=goal/29-p0-complete bash agents/meta-watch-loop.sh`
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + a 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`.
  ⚠ `BASE_EXPECT` is the GOAL branch currently in flight — **update it when the goal changes**, or
  the drift clause alarms on every healthy ride of the new goal.
  ⚠ `major/awaiting-human` PRs are excluded from the drift set (`6b29a08`) — circles#21, the frozen
  #17 benchmark arm, would otherwise match every later `BASE_EXPECT` permanently.
  ⚠ **Monitors SURVIVE a `/clear`** and are invisible to `TaskList` (it reports "No tasks found"
  while several run). Find them with `ps aux | grep -E 'meta-watch-loop|meta-handoff-watch'` and
  kill by PID before re-arming; a survivor runs the script as it was PARSED and never picks up
  edits, and its events go to the DEAD session, not yours.
  ⚠ **Killing those PIDs can get YOUR OWN fresh monitors reaped.** On 2026-08-06 the harness's
  orphan reconciliation ran after the old PIDs were killed and marked all three just-armed monitors
  "stopped — from the previous session", quoting THIS session's task ids. They were genuinely dead
  (`ps` count 0), not a bookkeeping artifact. **`Monitor` returning "started" is not evidence a
  watch is running** — confirm by process after arming, and re-check if you killed orphans in the
  same turn. A watch that was reaped is indistinguishable from a quiet one.
  ⚠ **Check PER-WATCH presence, never a total count** — the total is not fixed. `meta-watch-loop.sh`
  spawns a transient subshell during its poll cycle, so the total legitimately flaps 6↔7 and a
  `wc -l`-against-an-expected-number check raises a false alarm (it did, 23:05Z the same day).
  Use: `for w in 'meta-watch-loop.sh' 'meta-handoff-watch.sh' 'sleep 7200'; do echo "$w ->
  $(ps aux | grep -F "$w" | grep -v grep | wc -l)"; done` — each should be ≥1, wrapper + child.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; make probes print `PROBE-FAIL` rather than fall through to empty state.
