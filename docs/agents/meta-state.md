# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## ⛔ BLOCKING EVERYTHING — the GitHub Actions outage is STILL LIVE (from ~15:36Z; confirmed 18:5xZ)

`githubstatus.com/api/v2/components.json` → **`Actions: major_outage`**. GitHub's 18:11Z update:
*"Workflow runs are still failing or delayed in starting, and some queued jobs may time out.
Customers using self-hosted runners may see errors or rate limiting when runners register."*

Measured here: **`in_progress=0` in every repo** against `queued` 5 (circles) / 1 (agent-runtime) /
2 (homelab), while **4 ARC runner pods sit `2/2 Running` aged 42m–98m**. Ephemeral runners exit
after one job, so a 98-minute-old runner has acquired **nothing**.

**Do NOT re-run anything** — re-runs only deepen the dead queue. Everything below is waiting on
this and needs no action until Actions recovers:

- circles **PR#44** (#41 script-escape) and **PR#45** (#18 evidence chain) — both armed into
  `goal/29-p0-complete`, both `ci` pending. They merge themselves when CI returns.
- circles-iac **#30/#31** (specs-pr routes for #44/#45) — same.
- agent-runtime **PR#37** (test surface + fixer lane + the #109 deploy-pin label fix) — `ci`/`unit`
  pending. ⚠ `reviewer.enabled=false` for the `platform` stack, so **no bot will ever approve it**;
  merge it yourself with `gh pr merge --admin` once green (the jail IS the OrganizationAdmin bypass).
- circles **#42** and **#19** are correctly held on ADR-097 footprint overlap, not stuck.

**First action on recovery:** confirm `oracle-fleet/update-pr-branch` completes one green scheduled
run, then **close homelab#111**.

## Platform queue (homelab has no fixer loop — the meta-coordinator IS its fixer)

- **#111** — ✅ **CLOSED 2026-08-06** as not-ours (outage, not `maxRunners: 4` capacity — the
  responder's diagnosis was corrected). Two class fixes came out of it: `ecb74bb` (the prompt now
  names the saturated-vs-broken distinction) and `6affc63` (subject dedup — it had taken THREE
  sonnet triages in 33 min). ⚠ `maxRunners: 4` is neither exonerated nor indicted.
  ⏳ **Post-recovery check, tracked HERE not there:** one green `oracle-fleet/update-pr-branch`
  scheduled run. If it fails again after Actions recovers **with `in_progress > 0` elsewhere**,
  that is a real capacity question → file a FRESH issue, do not reopen #111.
  ⚠ **A human comment on a responder issue disables its auto-close** (the resolve leg closes only
  when no human engaged) — so every issue you comment on becomes yours to close by hand.
- **#103** — `NodeSystemSaturation` on wk-01. OPEN, containment shipped (`fc7e9fb`). **This goal is
  NOT its test** (the goal lane serializes on `Depends-on:`; wk-01 sat at 16% CPU mid-rollout). The
  real shape is concurrent COORDINATOR Jobs across stacks/items. ⚠ Do NOT tighten
  `activeDeadlineSeconds` (already 1800; legitimate tail reaches 1458s, so 600s kills ~9 real
  scans/week). ⚠ Do NOT implement the issue's "reject `unit=-`" candidate — `-` is the legitimate
  full-scan default.

## ✅ RESPONDER BUDGET — live, binding, and it fired within minutes (ADR-099, FU-149)

Both halves proven end to end on 2026-08-06, faster than expected because the day was already over
budget. `ResponderTriageBudgetExhausted` fired at ~19:40Z with `probe_ok=1` (a genuinely spent
budget, NOT the fail-closed path), gauges live in Prometheus, push age 24s — so the pushgateway
rail works and the "invisible blocking" risk is retired.

**The measurement, and it is the whole argument for the change: 30 sessions spawned today against a
nominal ceiling of 12 — and 26 of them were ONE incident** (`GithubWorkflowRunFailed/monitoring`,
the Actions outage). Same incident → `INC_SEEN != 0` → the old cap never applied. 8 `budget-`
markers written since deploy, so the latch is actively blocking.
⚠ **Do NOT raise the cap in response to this firing** — it is the alert doing its job on an
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

**Terminus:** an assembly PR `goal/29-p0-complete` → master, ARMED, blocked by the CODEOWNERS gate
on `/specs/`, waiting on an OrgAdmin merge. **If it stops anywhere short of that, treat it as a
platform bug, not a model failure.** `goal-review` re-judges on every child closure and opens the
assembly PR itself when the goal is met.

Done so far: #30, #31, #32, #40 all merged + closed. In flight: #41 (PR#44), #18 (PR#45). Queued/
held: #42, #19. Harvest sprouts #38 (inert, test hygiene outside P0 scope) and #33/#34/#35 (inert
deferrals) await the operator's FU-090 gate.

**Work-vs-wait ledger** lives in [`observability-and-retro.md`](observability-and-retro.md)
§Part A″ — keep appending there, not here.

✅ **FU-143 is fully proven and needs no more soaking.** Both paths now have live evidence: #32
(six rounds → ended `agent/in-progress`, the atypical path) and **#40 (one clean round → ended
`agent/review`, the REPRESENTATIVE path)**, which closed machine-only — `agent/queued → in-progress
→ review → done → closed`, every transition by `homelab-agents-1234[bot]`, no meta hand-close.
⏳ **Remaining bookkeeping:** archive FU-143, and decide whether the `12e7fcf` C4/C5 goal-child
containment can be RELAXED — it exists because "no open PR" could not separate merged-but-unlinked
from abandoned, and finalize's guaranteed issue link now removes that ambiguity. The `e704c36`
strong-link guard STAYS regardless.

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
  native blockedBy edges in scan logs (→ FU-111 retirement); Monday 05:00 retro (= FU-058 run 3).
- ⚠ Garage still has no offsite backup (FU-137) and now carries tofu state.

## Open, not mine

agent-runtime **#13** (watchdog misses silent loops), **#33** (resumed round reports "no resumable
branch"), **#35** (a failed `:latest` push skips `deploy-pin`), **#36** (a fix round that dies
mid-session reports `exit_status=clean`; `salvage_push` is disabled once a PR exists — the real
mechanism is `succeeded = bool(stats.get("pr_url"))` returning clean BEFORE any failure signature
is consulted, so only round 1 can strike a model; pinned by a STRICT xfail in PR#37).
⚠ **openrouter-operator's deploy-pin job has the identical #109 label gap and is NOT fixed.**
⚠ **`deepseek-v4-flash` struck TWICE today on `goose-32602-truncation`** (circles#32 r1 and r3) yet
r2..r5 all ran on it again — watch whether the router actually routes away from it.
⚠ **Its TESTS assert presence, not the property — 3 instances in ONE PR** (#39). One PR is not a
fleet pattern; if it recurs on another stack it is a model-selection fact, not prompt tuning.

## Durable warnings — re-read before touching these files

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
- **⚠ agent-runtime has NO `.agents/` BY DESIGN** (operator ruling 2026-08-06) — its fixes come from
  meta-coordination incidents, so drive it with the JAIL credentials; never look for an agent lane.
  (PR#37 adds a fixer lane; until it merges, the ruling stands.)
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
