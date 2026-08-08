# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)


## Live state (2026-08-08 ~15:00Z heartbeat — everything below is CURRENT; history is TICK-LOG's)

- **Cloudflare/PublicRoute: ARMED, zero consumers.** Operator's acts: echo test claim → ha
  retrofit. FU-039 open legs: DIY GraphQL poller; declare cloudflared :2000 in tofu.
- **agent-runtime lane LIVE and self-running**: #12 done (full machine cycle, PR#40), #41
  (self-filed follow-up) + #33/#35/#36 queued, #13→PR#42 in review. Reviewer coverage follows
  the fixer block (unowned paths auto-merge; governor paths codeowner-gated).
- **circles**: PR#65 (#59) + PR#66 (#60) riding/armed — goal-#29 grind moving post-phantom-clear.
  Assembly PR#54 waits on the children. Frozen: PR#21/#25.
- **oracle**: PR#217 (#188) BLOCKED in review pipeline; queued #193/#194/#195/#207/#211/#215
  (pinned, gates corpus rebuild); #225 ingest = next frontier; goals #175/#176 unstarted.
  Artifact: claude.ai/code/artifact/6828adf5-165d-4092-aa92-a3c2e8800903 (goal-174 map).
- **homelab queue**: #103 (containment holds), #133/#137/#138 pending debounce (responder-filed
  today), #41-class watch: the >24h clause owns unlabeled platform issues now (v3: alert-records
  excluded).
- **Operator physical**: wk-metal-02 cable reseat (100Mbps, was 1G). **tuya**: frozen-accepted,
  silence c73baef2 → ~08-22 auto re-triage.
- **⚠ FLEET DISPATCH STARVED until ~00:00Z reset (OpenRouter keys-modify DAILY limit,
  openrouter-operator#26)**: no worker keys mint anywhere since ~18:58Z; queued issues defer.
  Post-midnight heartbeat MUST: (1) verify the 13 wedged deletions drained + a mint succeeds,
  (2) clear oracle-fleet#228's agent/error (it recorded THIS infra failure, not its content)
  and restore agent/queued, (3) supervise the backed-up dispatch wave (oracle
  #194/#195/#207/#211/#215/#228, homelab #103/#149/#155/#156/#157, agent-runtime #41/#52,
  openrouter-operator#26 itself). ⚠ #215 declares `Touches: *` — a wildcard footprint that
  serializes against EVERYTHING; expect it to hold or be held.
- **Soaks**: iac-sentinel shadow (FU-106); router shadow (FU-095); Monday retro (FU-058);
  FU-149 spot-check; first concurrent double-e2e on the 2-slot runner (glance at contention).

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
  — unreviewed platform PRs + `agent/blocked` issues only. ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — every sweep runs `bash agents/meta-alert-crosscheck.sh` + the board/chain
  check against this file.
- Handoff watch: `bash agents/meta-handoff-watch.sh` (persistent).
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
