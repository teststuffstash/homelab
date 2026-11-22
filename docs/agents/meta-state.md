# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)

**`dig-explained: <Alert>[, <Alert>…] — <reason>`** is the ONLY line here the [deep dig](roles.md) (ADR-148,
`agents/deep-dig-select.sh`) reads as "this alert is explained"; a bare mention — the standing-alerts
list every wind-down writes — does NOT count (#2526, 2026-10-12: `RegistryMirrorDanglingLinks` hid from the
dig for days by being listed). Write the marker only when the cause is known; the reason rides into the dig's record.


(No marker standing. 2026-10-24: the `RouterRunModelUnverifiable` marker was REMOVED by the fu-sweep — the alert now
fires on 8 series incl. openrouter-rail models (kimi-k3, glm-5.3-flash, mimo) its reason did not cover, so the dig re-reads it.)

## Live state (pruned 2026-10-24 — every bullet re-verified against GitHub/the cluster/the box that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ PICKUP (2026-11-22 — island ladder spike, PR #3672 UNARMED, the operator reads it first; FU-320).**
  `docs/spikes/island-ladder/` on branch `fix/island-ladder`: a position page per
  island, the replay-to-specs map, and the README's three-group sort. Owed, all the operator's:
  - Rule the README §What would settle it (the rung list, where a roadmap lives, replay retirement, the experiment reader).
  - Cut `goal/3656-scan-checkpoint-b` (and the launch/retro Goal branches for #3480, #3482) — the intake identity is
    refused with HTTP 422; the class is still untracked. Before the cut, read #3656 pins 9 and 10 (intake's own picks).
  - `/seat-review 3627`, then admin-merge: until then no required check gates the scan, launch or retro suites.
  - Loop state at wind-down: #1941 (PR #3670, r3 after a changes-requested) and #2589 (PR #3669) riding; both
    un-latched by intake closing #3095 at 06:39 UTC.
- **⚑ PICKUP (2026-11-21 — nx-02 incident RECOVERED; [draft](../incidents/2026-11-20-nx-02-boot-disk.md); FU-299, FU-322).**
  The pair is whole: nx-02 MASTER, both router disks 32 GB, `check` 18/18. Owed:
  - Route the draft §Lessons with the operator: WAL-vs-service, mirrored boot (boot-only pair; ZFS+UEFI vs LVM raid1),
    backup target on two hosts, paging.
  - Bay-swap test if the SA400 drops again.
  - hp-01 Longhorn default disk at 79 % (`LonghornDiskBelowSchedulingFloor`, responder's).
  - Gateway #3622 LIVE (anthropic 5h/7d 0.95, `latch_scope: model`); the rail was unlatched from the second jail on 11-21 and
    reviews flow. The `catalog: docs parse failed (no Endpoints table)` warning is #3533 (blocked on one operator ruling:
    may the `docs` source read the rail's public `/go/v1/models` for limits only).
  - Fable weekly limit spent 11-21 (second jail: role `coordinator`, 45 sessions / ~1.2M output tokens in 7 d vs 3
    reviewer sessions). The only `--prefer strongest` caller is the intake sitting (`islands/intake/scripts/sitting.sh`,
    tier heavy → Fable), so this is FU-320's spend. It also killed the seat's Fable subagents. `latch_scope: model`
    (#3622) keeps opus serving next time; open: whether intake's prefer=strongest needs a Fable budget share (FU-320).
  - Open question: why reviewer sessions only ever land on anthropic (policy lists opencode + codex).
- **⚑ PICKUP (2026-11-19 — island rules learning loop; TICK-LOG 11-19 second entry; FU-320, FU-249, ADR-164).**
  FIRST LIVE RESULTS READ 11-20 (TICK-LOG 11-20): dig re-test, the sitting's forward/release/wait read and the digest's
  unattended merge (#3565) all worked. STILL OWED: read #3533's release on the 11-21/22 05:00Z sitting (it and #3538
  were not offered — parked <3 d); `TierEvidenceStale` re-cut is due (dig: seat; intake folded it).
  NEXT BUILDS: the replay runner + the edit-PR leg (cases in `islands/intake/tests/fixtures/wait-cases/`); cron
  sittings for the other islands (17 waits parked there, unclassified: scan 6, agent-loop 5, commons 3, retro 2,
  launch 1). FU-315: next apiserver refill on wk-metal-02 due ~2026-12-11; no detector for GC-at-the-limit.
- **⚑ PICKUP (2026-11-20 evening — intake IS its own island; outcome experiments in build; TICK-LOG 11-20 third entry; FU-320).**
  Goal #3574 BUILT BY SEAT SUBAGENTS AND ON MASTER (assembly #3598, 18:37Z; children #3575–#3581 closed; the operator said
  "finish this" for the codeowner merge). LIVE-PROVEN 11-20: `can-i` as `island-intake` (reads yes; pods/exec/configmaps/
  secrets no), one dry-run sitting `island-intake-cpsr9` (gateway island, 21 min, Succeeded: base image, install 14 s,
  gateway admitted the caller on Fable, two lens runs, uploads, metrics; peak 360 MiB → limit 3Gi → 1Gi, #3609
  merged). NOT YET SEEN: the first FULL WALK (05:00Z 11-21, nine islands in sequence under `parallelism: 1` — read that every
  island got a step, that one failing does not stop the rest, the `island_intake_listed_timestamp_seconds` push, the 23 h
  deadline); anything for a stack island (no stack declares `repos[].intake.facts`; oracle was told via
  `/workspace/.handoff/oracle/done/20261120-1915-platform-island-intake-contract-ready.md`). Verdict on #3574 is the
  operator's (human authority) — it stays open, post-launch.
  RESIDUE: intake's own items still ride the GATEWAY's sitting (no membership row or facts file for `islands/intake/`);
  `docs/intake/{launch,retro}.md` say no tests root is declared while both hold labelled tests (unchecked against the
  claim); the wait ledger double-counts 22 lines moved into `docs/intake/gateway.md` (ages out in 30 d);
  `.claude/skills/intake/SKILL.md` step 4 stale (operator-direct path); nothing bumps the agent-base tag in
  `agents/coordinator/kustomization.yaml` (agent-runtime deploy-pin needs one sed); the island devbox lock has no update lane
  and pins a newer nixpkgs than the image (harmless in the dry run); three facts-file reads are seat-only.
  GOAL #3586 ASSEMBLED + ON MASTER 11-21 (assembly #3637 admin-merged 18:30Z on the operator's word, `a330c03f`; children
  A–E #3608 #3610 #3611 #3624 #3632 + assembly fixes #3642 #3645). LIVE: `island-intake` runs `experiments → islands →
  sitting → experiments-failed`; label `experiment/open` provisioned (quickfix `50634967`: its 174-char description
  422'd every repo's IssueLabels — alert for that class is #3650); #3563 labelled, dry-run read = `pending`.
  NEXT: the Production-leg read — #3563 decided at its bound (2026-11-27T13:14Z with the 5-min settle): exactly ONE
  verdict comment, a second run writes nothing. Goal stays open post-launch; the verdict is the operator's.
  oracle inbox holds two unclaimed tasks (`20261116-2130-intake-size-test-nameable-split`,
  `20261120-1819-oracle-prod-diagnose-step-back-grants` — the second asks for grants: the operator's).
- **⚑ PICKUP (2026-11-21 night — #3652 ADR-166 + the Docker image clock, operator) — MERGED 2026-11-22 17:15Z `812b016f3`** (seat review + full CI by dispatch, run 45045460749). Supersedes ADR-158: stack pins lead by TIME (homelab minor/major 14 d, stacks 7 d); `scripts/image-clock.py` gives docker a release clock (first sighting on the `image-clock` side branch). After merge: the first scheduled run should log `image-clock: … rules`; oracle-fleet#1098
  (postgres 19-alpine) should be autoclosed until 11-27. The PR also files the prod-Postgres-frozen-at-18.3 item (its new FU id lands with it).
  Open operator calls: `lock-intake-lint` into the stack/platform repos' `ci` (Renovate 44.221 raises transitive uv.lock
  security PRs that skip the cooldown; worker `uv lock` additions are the other un-aged intake — 2 versions <7 d in ~4
  months; an optional reviewer line "a new direct dep names its importer" rides the same call). openrouter-operator:
  #113 closed 11-21; #110 (target virtualenv 21.14.9, itself vulnerable) stays OPEN until #111 merges — Renovate
  recreates a closed vulnerability PR while master is still vulnerable. #111 (armed, approved, red on deps-pin-guard =
  ADR-154's admin-merge route): "wait for the 7-day floor" does NOT converge — Renovate re-locked it 11-21 22:44Z to
  virtualenv 21.15.12 (uploaded 22:12Z, floor 11-28 ~22:12Z) and virtualenv ships every 1–3 days. Converging route is
  docs/renovate.md's own: `[tool.uv] exclude-newer` ≥7 d back + `uv lock` (fixed ≥21.14.13 exists aged, e.g. 21.15.6
  of 11-06), or admin-merge whichever head lock-intake-lint passes. Scan routing armed non-major #111 to unarmed-major:
  unchecked, a loop component → stop-and-ask.
- **⚑ PICKUP (2026-11-21 — Crossplane managed-resource belt, #3650 MERGED 19:54Z `31491512`).** Scrape live (3/3 providers
  `up=1`); `CrossplaneManagedResourceNotSynced` was PENDING at 19:56Z — confirm it FIRED `gvk="tf.upbound.io/v1beta1, Kind=Workspace"` ~30 min after the first scrape — the live positive control is
  Workspace `pr-oracle-fleet-minutark` (Synced=False, "failed to make http request"; the oracle stack's). Not firing = the
  PodMonitor or the expr is wrong. Coordinator scan fix #3636 LIVE (a gateway stack's goal lane no longer defers on the old
  proxy's latch; proven 16:10Z by #3586's checkpoint opening #3637).
- **⚑ PICKUP (2026-11-17 → 19 — router session; TICK-LOG 11-17; FU-297).** OPERATOR RULING OWED before any firmware
  window: how a node gets packages — the BACKUP (`opnsense-pve`) cannot reach the mirror ("Could not find the repository
  on the selected mirror"; only the CARP master has WAN — inferred, the routing table was not traced). Options in FU-297.
  Then the attended window: test VM → BACKUP (snapshot) → MASTER, 26.7.5 → 26.7.9_3, 73 packages, reboot; ask before the
  failover leg; try `carp-maintenance enter|leave` as `automation` on the test VM first (still root today).
  FIRING BY DESIGN until then: `MgmtRouterFirmwareBehind` (nx02) and `MgmtRouterFirmwareUnread` (pve — the same missing
  route; it needs a rule for "the BACKUP has no WAN" or the egress fix). `MgmtOpnsenseDrillScoreRegressed`: a drill run was
  started on the box 11-19 at wind-down and NOT read — expect ~17 (the dnsmasq rows gone, the rest wait on the firmware).
  #3539 (content-keyed test-VM verdict) MERGED 11-19 05:47Z — the first bot update of an open router PR should
  post "PASS carried from"; unproven live. Also unproven live from #3528: the hourly re-read of a drifted group and the
  7-day re-post. SEAT, operator-direct: `opnsense-users-self-test` into `.github/workflows/ci.yaml`. Same host-key class
  as #3527 still in `opnsense-test-vm.sh`, `opnsense-drill.sh`, `host-maintenance.sh`, `node-maintenance.sh`,
  `mgmt-tf.sh`, `mgmt-bmc.sh`, `mgmt-human-plan.sh` (default `known_hosts`, not the pinned file). JAIL: the running
  image has no `ssh` (the Dockerfile lists openssh-client — rebuild the container); `~/.ssh/known_hosts` starts empty.

- **⚑ PICKUP (2026-11-20 — scan island Goal #3490 on master, built overnight by seat subagents; TICK-LOG 11-19/20).**
  Operator instruction 11-19 evening: build unattended, "I can redo decisions in the morning". DONE: #3561 merged
  (`a715541b`; island gate 324 passed on master, run by hand — required `ci` still does not run it, #3391). OPERATOR
  READS: the ⚖ choices + the reviewer's open spec questions, both in #3561's body and on #3490. NEXT, none started:
  (a) #3550 is not one ride — the split into cuts A–F is on the issue; its `blocked-on: issue=3491` is now a closed
  target, so the next scan sitting re-decides it (no scan sitting is scheduled); (b) #3448's wait fact (#3490's assembly
  on master) is true — next sitting cuts it into a Goal; (c) #3553 trace is on the issue (FU-199), ruling unmade;
  (d) `docs/intake/scan.md` got a one-line currency fix only — the 13 unowned index rows and the ADR-164 wording are
  still owed (FU-320); (e) the intake identity still cannot cut a `goal/**` branch (422, IL-G02) — untracked class.

- **⚑ PICKUP (2026-11-16 — the gateway becomes self-sufficient before any new island leg; TICK-LOG 11-16; FU-320).**
  OPERATOR GATE: retro #3482 and launch #3480 are written and their goal branches UNCUT on purpose (scan #3490 was
  lifted for one night by the operator and is on master — the 11-20 bullet below). Order when it
  lifts: gateway first, then retro — with retro's own intake doing the work on the schedule. The bar: the island defines and
  ships its OWN metrics, monitors and improves them (the oracle-fleet#1082 shape: a claim per change — PromQL + pass
  threshold + baseline — judged on prod). RULED the same evening: (1) Kargo for the gateway POSTPONED — metric claims first,
  on the existing pin-PR deploy; (2) the shared intake rules are likely their own island soon; (3) oracle is NOT wired into
  platform intake yet — trial the shape with the specs review in homelab first; (4) where the extracted claim package lives:
  not now. NEXT (a fresh gateway session, island read only): write the gateway's next Goal from the two mining reports in
  `~/.claude/oracle-mining-2026-11-16/` (seat prep list vs the loop's Goal are both in there) — release identity on
  `/healthz`, a synthetic-traffic label, outcome alerts, its dashboard as code (it has none), the claims file + judge, loop
  self-metrics; and the open question from 11-16: the gateway path dropped the per-session OpenRouter budget key with no
  ruling recorded (prompt in TICK-LOG 11-16). SEAT, from the intake report: adopt the nameable-split size test (handoff
  `20261116-2130-…`, unclaimed); split the gateway's FACTS out of `islands/intake/rules/intake.md`; the specs-reviewer rule tally, THEN
  rule #3495 (the escape read's first filing against intake's own rules); a `wait: stalled` re-read kind in `intake-select.sh`.
  OVERNIGHT TRIAL (operator: "lets see in the morning how it went"): five operator-origin gateway inputs filed 11-16
  ~21:00Z — #3501 (release on /healthz), #3502 (real vs synthetic traffic), #3503 (dashboard as code), #3504 (outcome
  alerts), #3505 (claim per change + loop self-metrics, Goal-sized) — and a gateway sitting hand-submitted
  (`island-intake-bthpn`; the 05:00Z cron follows). MORNING READ: each one's ruling; what was queued, dispatched, built;
  whether #3308's footprint still held the `gateway/src` ones (the scan fix PR decides that); whether #3505 stalled on a
  goal-branch cut again.
  FIXES MERGED 11-16: #3507 (22:03Z — a no-strike goal child is decided from its goal base; a writer-less footprint holds
  no sibling) and #3508 (22:52Z — the scan's `dead-ride-record` pass writes the terminal record the dead launcher could
  not; the janitor keeps a Failed pod 1 h for it). FIRST LIVE PASS, read at 22:55Z: the 22:09Z scan resumed #3303 on its
  branch, re-dispatched #3308 and dispatched #3420 (→ PR #3511, in review); #3501 dispatched 22:41Z, running. MORNING
  CHECKS: (i) #3308-r2 died 3 min in (exit 255, both containers at once, while devbox was still copying nix store paths) —
  the coordinator parked it `blocked-on: human`; is there an `AGENT_STRIKE` on #3308 from the new pass (the first live
  proof of #3508)? what kills a kata ride during the nix copy (r1's cgroup hit its 5 GiB ceiling — the classifier reads
  `unknown`, kata never reports `OOMKilled`)? (ii) #3303-r2 sat Pending 44 min+: the `agentstack-storage` quota is 40Gi of
  `longhorn-scratch` = TWO 20Gi `docker-lib` volumes, and the dead #3308-r2 pod holds one until the janitor reaps it
  (now ≥1 h after death) — a dead ride costs half the stack's docker-ride capacity for an hour; (iii) #3309 still waits
  on #3308; (iv) #3503 (dashboard) got no ruling from the 21:00Z sitting — did the 05:00Z one rule it?
  JAIL FAULT, unfiled: `devbox run` rewrites `devbox.lock` (`nodejs_22` plugin_version 0.0.6 → 0.0.5, since #3471) and the
  pre-push hook's devbox wrappers then die 127 after the gate passes — direct master pushes fail; restore the lock after
  every devbox run. LIVE since 11-16: six platform components at 2 replicas + required anti-affinity + PDB (#3500);
  pushgateway limit 512Mi (#3496; FU-182 still owns the growth — 4.4k groups). Not done: Alertmanager ×2 waits on
  duplicate-safe receivers (responder, deploy-pin revert); `RetroReportOverdue` is #3166's stale series, not the pushgateway.

- **⚑ PICKUP (2026-11-15 evening — islands rebuilt from specs; TICK-LOG 11-15 evening; FU-320).** SEAT: (a)+(b) done 11-16 (#3418 merged; the next-leg sittings wrote Goals #3490 #3480 #3482 — see the 11-16 bullet); (c) first live sightings still owed: #3460's selector on a real fix round, #3458's sentinel run,
  #3456's diff base on a goal-branch master merge. OPERATOR: (d) verdicts on Goals #3384 #3390 (assemblies merged)
  and #3389; (e) the agent-runtime half — `agent-finalize` skips the `agent/review` flip on a `no-op` round;
  (f) specs-reviewer rules — operator direction: TALLY which rule rejects the most before any brief or rule change
  (the verdict line carries the ids; rough count today: R10 ≈ 8 blocks, E-NO_EVIDENCE 3, R2 2); a decidable rule goes
  to a lint/script, not the LLM pass; rule 10's `🚧 WIP → #<issue>` may be the thing that is wrong — a pointer to an
  ADR / plan step may be the correct mark; intake and Goal decomposition do NOT file placeholder issues to satisfy it
  (second sighting on #3450 after #3401; the seat filed #3461 that way — keep, re-scope or close it); a reviewer
  finding new blockers on old text in round five is a known pattern, the code reviewer did it before; (g) sleep-iac#80 needs a
  new head commit to leave the status cap. Superseded in the bullet below: its (c) is answered (new shape, Python)
  and #3337 is merged.

- **⚑ PICKUP (2026-11-15 day — island forward + pr-hold re-read on master; TICK-LOG 11-15 day; FU-320).** OPERATOR:
  (a) what may release a PR-level `blocked-on: human` besides a human comment — until ruled, `INTAKE_PR_HOLDS` stays
  off and a `pr-hold` row is report-only; (b) confirm or revert #3428's split amendment (an input the sitting may not
  close stays open; parts for other islands are verbatim copies). SEAT: (c) trial issues open and unruled — #3425,
  #3427 (dependency-upgrades), #3426 (agent-loop); #3424 open with its `intake: split` ruling; the 11-16 05:00Z sitting ran `island=gateway` only and ruled none —
  the first unattended `forward`/split read is still owed; (d) `intake-select.sh` copies the scan's `blocked-on:`
  grammar (a second reader) — fold into one definition; (e) `docs/intake/retro.md` still says the island is "not yet
  selectable"; (f) PR #3147's draft `intake-select` spec predates `pr-hold` and `forward`; (g) a plain `forward` and
  the hop cap have run only in the selector tests and one hand-written comment (#3427).

- **⚑ PICKUP (2026-11-15 — intake review stage live, islands scan/launch/retro started; TICK-LOG 11-14 → 15; FU-320).**
  OPERATOR: (a) verdicts on Goals #3384 #3390 #3389 when their assemblies land; (b) #3391 — the `.github/workflows/ci.yaml`
  steps so required `ci` runs each island's suite; (c) launch island: fresh launcher = bash carrying the same blocks over
  the same shell variables, or a new shape with its own test hooks? — the rest of that island stays unfiled until
  answered; (d) intake-workflow defects, unfixed: a dry-run's author/repair sessions hold the write token (only the
  prompt stops a write); unanswered findings miss the issue when a repair half-runs; a queue ruling without a hold line
  can be lost; (e) gateway inputs, unfiled: concurrent heavy Go sessions admitted against the 5-hour window;
  `gw_admit_lane` hard-codes the claude harness; (f) eight spec defects landed unnoticed on master/goal branches — the
  `real-landed` verdicts in the trial notes `~/.claude/intake-trial-2026-11-14/{v0,v1}/score/`; (g) still owed:
  #3309, #3308, #3337, PR #3147 (now partly carved into `islands/`), oracle handoff `20261113-1746-…` unclaimed (its
  three rules-home defects fixed by #3378; asks 1–2 + the issue-review wiring not started). SEAT: (h) an escape read
  per island worker PR as it merges — first sightings in `~/.claude/intake-trial-2026-11-14/night/escape-3401.md`; a
  brief change needs a second sighting; (i) unproven on a real author: the unit lens inside 1200 s, the repair's
  unanswered findings.

- **⚑ PICKUP (2026-11-14 — runner recreate on; TICK-LOG 11-14).** The next ci-runner template change is the first unattended
  recreate expected to need no seat close (#3372): read its journal for "window closed by the verb" + `management-apply=success`.
- **⚑ HANDOFF INBOX (2026-11-16; oracle ×2, circles empty).** Grafana plugin handoff CLOSED (the chart already defaulted
  `preinstall_auto_update` off; #3499 states it explicitly). NEW, unread: `20261116-2130-intake-size-test-nameable-split.md`.
  `20261113-1746-oracle-stack-intake-island-wiring.md`: A1.2–A1.4 done (#3378); OPERATOR rulings owed before any build — (1) wire
  `--island oracle` now, and with which research egress; (2) Experiment authoring in the shared `islands/intake/rules/intake.md` or oracle-only;
  (3) oracle adopts the platform review-repair stage (#3381) or gets its own `issue-review` sitting. Partial result not yet written back.
- **⚑ PICKUP (2026-11-13 — CI wait; TICK-LOG 11-13 evening).** On/after **2026-11-21**: re-run the burst-pickup table
  (`docs/spikes/ci-runtime-2026-11.md` §What waiting on CI costs) — PR job pickup should flatten toward ~3 s after #3348
  (`minRunners` 3, live); if not, raise again or read the listener. Delete this bullet after the readout.

- **⚑ PICKUP (2026-11-08 — oracle-fleet spec-process mount; operator ruling owed).** oracle-fleet#1026 made `scripts/lib/snippets.sh` set
  `SNIPPETS_RELEASE=<url>` and `SNIPPETS_WHEEL="file://…"`, so `sp_pin_version` (`agents/agent-session.sh`) parses nothing from it (checked against master 11-08; the gateway's still
  parses, #3228 kept the line). Oracle rides reaching `specs/` should be unmounted since 11-08 12:45Z; NOT confirmed in logs (the launcher's mount lines are not in the oracle Loki tenants).
  Ruling: fix in the launcher (also read `SNIPPETS_RELEASE=`; the seat's recommendation) or add a parseable pin line in oracle-fleet. Delete this bullet when done.

- **⚑ PICKUP (2026-11-08 — scan island specs vs replays, PR #3147 `spike/agent-loop-subcut`; operator reads it in another session).**
  Landed on the PR: `agents/islands/scan/pilot/updater/` (update-pr-branch.sh ported to Python against the replay family as oracle:
  43/43, bash family 43/43, 7/9 mutations caught, ~3× the bash in code lines, 12 bash findings incl. 3 arguable bugs — three reviewer
  identities, leg 2 null guards, leg 1 silent skip on a malformed probe) and `pilot/recorder/` (full-shape worlds: bash harness 43/43
  and the strict port 43/43 on the full copy, 0/43 strict on the trimmed original; a missing `author` meant "not Renovate", a missing
  `reviews` meant "unreviewed"). OPERATOR RULINGS OWED: (1) keep the sanitised oracle-fleet recording in the public tree? (2) replace
  the real updater family's world with the full-shape copy?  (4) fix bash findings 2/3/4 before any further port. Also in the session's scratchpad only (not on the PR):
  the world-mining catalog (391 item-bearing worlds, most persona fields unknown) — re-mine with `pilot`-style recorder data if wanted.
- **Gateway specs residue (the next gateway PR's; TICK-LOG 11-07).** `metrics.schema.json` `rail_choice_reason` lacks `order`;
  GW-SESSIONS-ADMIT citations in `agents/gateway-admit.sh` + `agents/agent-session.sh` comments.
- **Intake owed: #3139, #3141** (unruled since 11-01, no labels).
- **⚑ PICKUP (2026-11-01 — gateway rollout residue; TICK-LOG 11-01).** Strip `agent/error` from #1941 #2589 #3087 + correct #3095's
  attribution (#1941 = OOMKill, #2589 never pushed, #3087 pushed); file the agent-runtime half (finalize + launcher classify
  `Go usage limit exceeded`, today `unknown`); FU-270 pointer += #3105 #3108.
- **⚑ PICKUP (2026-10-29 — specs process delivery; TICK-LOG 10-29).** Retire the restated process text now that the card + mount
  carry it: homelab `.agents/fix.yaml` "Specs are the pinned process"; oracle-fleet `.agents/fix.yaml` step 0 (the oracle seat's).
  Read the first specs ride's `→ spec process:` log line.
- **Security contact + company mail (operator 2026-10-27/28, no FU — pointers below own status).** teststuff.net
  mail is LIVE on Proton (homelab#2974 + #2976 merged + applied); addresses + reasoning in the private teststuff
  repo `docs/company-email.md`. Disclosure policy text = `tofu/github/files/SECURITY.md` (its ONLY home) →
  homelab#3001 MERGED + APPLIED 2026-10-28: public `teststuffstash/.github` serves it as the org default (every
  repo's Security tab), PVR on all 13 public repos (verified via API). minutark.ee security page naming the lead + its own `security.txt`
  + contact → `info@teststuff.net`: oracle-fleet#943 (oracle loop). The minutark page URL = the CVP "security
  leader" link (e-äriregister entry meanwhile). LATER: the homelab single `security.txt` source + Expires/drift
  probe (minutark's copy becomes a consumer); Cloudflare Email Routing for every OTHER domain's
  `security@`/`privacy@`/`abuse@`/`postmaster@`; teststuff.net DMARC `p=quarantine` → `p=reject` once the
  `dmarc@` reports show only Proton sending.
- **⚑ PICKUP (2026-10-28 — minio-client → rclone; TICK-LOG 10-28).** oracle-fleet#939 done — owed: a PR dropping `minio-client` from
  oracle-fleet `devbox.json`/lock + the `ci.yaml` `mc` comment. circles#135 stalled on `agent/error` since 10-28 (3 strikes,
  homelab#3002, no r3): un-wedge, then the same drop in circles. G12b (#2995) re-prove after #3241/ADR-162 on the next red or
  stale ARMED automerge PR whose ride carries `bump-class=automerge` (operator to pick).
- **Component-check judgment reads (no other home; counts as of 10-25):** sa-automount 47, ro-rootfs 40, secret-role-verbs 37,
  probes 16, the agent-coordinator wildcard role, the infisical bootstrap Job.
- **⚑ KARGO (LIVE since 10-28).** Seat: `kargo-write-guard` is still `[Warn, Audit]` — the Deny PR once the VAP audit reads clean.
  #2798 (draft): close after the operator rules on `platform-kind-kargo.yaml` (FU-318 c). Residuals: FU-317, FU-318 (a)/(c).
- **⚑ ESCALATED → operator:** #2588 is `agent/error` again after the 10-31 re-queue. #2589 (`agent/in-progress` + `agent/error`)
  must land before [stint](chainless-redesign.md) #1418 closes.
- **wk-metal-04 (Big Data):** the CPU x16 slot stays EMPTY (corrupts data — #2926 #2928 #2931). Seat one-off: read `garage layout
  history` = one version (the last unread item from the 10-26 garage-0 rebuild; needs an exec).
- **⚑ wk-metal-04 on Big Data (#2758).** Watch the MX500's lifetime used (attr 202 = 34 %, flat since 10-20; no alert watches it).
  **OPERATOR:** does `sensor.plug_opnsense_power` (live, ~56 W) meter this box, or retire it (`docs/router-move.md`)?
- **#1101** (retro r2 batch): close by hand — #1651 closed 11-01, the 72 h passed.
- **⚑ OPEN GOALS / CONTAINERS (verdicts are the operator's):** #818 G-B HELD (4-clause verdict posted). #1302 G-G post-launch
  (#1311/#1334; RUM residual = FU-250). #1418 S8 stint closes after #2589. Newest: #3384 #3390 #3389 (top bullet).
- **⚑ OPERATOR-OWED (one list, re-verified 2026-11-16):**
  (1) the claude-jail HOST REBUILD — the Dockerfile reads the stamp (claude-jail#10); `VersionSetMembersDisagree` +
  `VersionSetBehindPin` (jails at 2.1.316 behind the pin, 11-16) still fire and clear on it.
  (2) Garage: prod is on **v2.5.0** since 2026-11-13 17:29Z (#3341 proposer, #3345 verbs, #3344 the bump —
  ONE-WAY, attended). Rulings: a one-way release = stop and escalate; v2 → v3 stays human. Owed by the seat: the
  verbs as PreSync/PostSync hooks with stop-and-page, no revert lease (#3358 fixed preflight/verify; its
  node-by-node snapshot has not run live yet). Owed by a person: the backup LXC (`ansible/garage-backup.yml`, still v2.3.0).
  (3) Reads owed: #2183's three calls (`MgmtApplyDeferredByWindow` at 6 h; reconciler node windows hold the apply loop;
  `--admit-apply` apart from `--admit-reconciler` — the DEFERRED path is proven live 10-05); the `fu-mint-gate` trial
  verdict (replace it if it doesn't change behaviour); the ADR-142 re-read **2026-10-28** (gate-change PRs, lens
  verdicts, DIFFERS lines, weakened gates; revert = `/scripts/` in CODEOWNERS + governance-lint GOVERNANCE); the r8
  reports (#2522, merged on the bot by ruling — read after).
  (4) Prod routers: see the 2026-11-17 router PICKUP above (26.7.9_3 offered, REBOOT needed).
  (5) pop-os `~/.talos/config` may still hold the pre-rotation identity (FU-264 rotated the CA 09-22).
  #1882's "3 flagged choices" were never recorded.
  (6) pve's CMOS clear reset "Restore on AC Power Loss" — UNREADABLE headless: a monitor/GPU visit or a deliberate
  plug-pull test; until then pve may stay dark after a power cut. The pve x16 NVMe test-fit also rides a pve visit.
  (7) Human-next-mover PR: sleep-iac#80 (`merge-conflict`; needs a new head commit to leave the status cap).
  (8) Operator/seat sittings, open: #1237 (E1), #1224 (parts-coverage), #1280 (kind-timing evidence),
  #1370 (FU-171 resight).
  (9) Cloudflare `Cache Purge` onto tofu-apply vs relying on oracle-fleet#414's Cache-Control: undecided.
  (10) Whether the 10 `cronjob-needs-priority` Audit-warned CronJobs get a PriorityClass each (10-09).
  (11) HA plugs laptop3/laptop4/pve offline since 10-03 (`HomeAssistantPowerSensorStale` ×6, Tuya — not platform).
- **⚑ UNOBSERVED FIRSTS (read when they happen; no action until then):**
  `fixer.imageVolumes` (#1808, ADR-135): the first ride with `/corpus` mounted. The first oracle
  closeout under `.agents/closeout.md` (#1806, ADR-134). The first real `CronJobNotSucceeding` fire on a weekly job:
  is the 21-day threshold tolerable? The origin mark's SERVE-TIME check (#1942), owed by oracle: a null `origin`
  column means the header does not survive the tunnel hop. Also check whether our platform-stack deny on
  `deepseek/deepseek-v4-flash-0731` was meant to cover the permaslug-spelled cell, against which it is INERT.
  The first provider MAJOR merged on the lens's APPROVED alone (rule e1748261). READABLE NOW, unread: the r8 F1 ratchet step
  (CI on #3270 / #3416 / #3418); the FU-143 goal-child closeout on the children of Goals #3389 #3390 #3384.
- **⚑ UNBUILT, NO HOME YET (single sightings — detector-first on a second):** `fstrim-guard-<node>`
  is nodeName-pinned ON PURPOSE (the manifest: "must still run when cordoned") — so while a node is
  OFF in a window its guard sits Pending and `CronJobNotSucceeding` fires (2026-09-27, wk-04): a window
  consequence for GAPS maintenance-window-G5's EXPECTED class, not a skip-on-cordon change. `KubeJobFailed`
  fired 45 series during the 09-16 window, and adding it to `DECLARED_ALERTS` was rejected as too broad.
  Separately, the registry exposes no scraped metric, so push throughput has no belt. The OPNsense firmware
  daily-check belt (official path, no Renovate). The reviewer exit-contract keys a merge head differently from the
  reviewer's standing-aside (false NO TERMINAL).
- **⚑ HYGIENE (11-16):** stale agent branches (homelab 11 `agent/*`, agent-runtime 1, circles 4): delete or resume. Zombie runs
  32217689970 + 34748702282 (still `queued`): operator UI or ignore. Phantom closes: oracle-fleet #25 #24 #22 #7 (`agent/review`),
  sleep-tracking#7 (`agent/blocked`) — relabel. sleep-iac's inert `:dependencyDashboard`; agent-runtime `deps-pin-guard.sh`
  pre-#83 (unverified). #1988 closes when its base-image half has its own home.
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
- Shell/tool gotchas (jail shell is bash, `--body-file`, `gh --jq`, `gh pr view` merged, python3
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
- **Doorbell residual (#2975 proven live 11-16 — `specs-review-edge-*` Succeeded):** `docs/agents/specs-reviewer.md` §Reach — an island
  adopting the lens must also carry the App-permission diff (`statuses: read`, #2973). One line, next docs pass.
