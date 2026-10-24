# GAPS — the skill gap ledger (ADR-105)

Sightings of skill shortcomings, FU-shaped. The contract lives in [`README.md`](README.md)
§Improvement contract: file on sighting · extend with a date on re-sighting (never a duplicate
line) · close in the same commit that edits the skill · ≲5-min factual fixes skip the ledger
and edit the skill directly · ≥2 dates on one entry = a class → propose promotion. This file
is in a PUBLIC repo — dialogue-level facts only, never tool output.

## design

- [ ] design-G1 — the read plan is reader-side only: an answer that proposes DOC EDITS never
      pulls in the writer-side rules (`docs/README.md` §Conventions, the docs-cleanup Hard
      rules). Fix: closure gains "proposing doc changes ⇒ read §Conventions + Hard rules".
      Sighted 2026-08-11.
- [ ] design-G2 — "multiple passes gave different answers to the same question" wasn't
      recognized as a design-shaped trigger; the first pass ran as grep-triage and missed
      tracker-held facts (FU-157's user-token nature; the live legacy token outside the
      matrix). Fix: add the inconsistent-answers cue to the skill's trigger list.
      Sighted 2026-08-11.
      **RESIGHT 2026-10-16 (operator catch, a new cue):** "what should I improve in <stack>'s
      setup" (a security/caching/performance audit) ran as live-probe triage; the first
      recommendation contradicted the stack's own two-tier cache design (operator: "What is
      oracle-fleet trying to do?"). An audit of a subsystem reads its owning decision first.
      Two dates → promote: the trigger list gains the inconsistent-answers AND the audit cue.

## board-sweep

- [x] board-sweep-G1 — the sweep pipeline (board-sweep, fu-sweep) knows ONE context: the
      design-agents corpus. The platform outside the loop is growing islands of its own —
      dependency upgrades / Renovate, the [management box](../../docs/management-box.md), the OPNsense CARP pair, the cluster
      substrate (3 CPs, disks, Garage, the services) — each with its own owning docs, and the
      sweeps' items now split across them (operator 2026-10-10: the loop stays the heaviest, the
      rest is catching up). Also: (a) "run the design-agents read plan" predates the typed-only
      rule; (b) `meta-state.md` is named only as a staleness risk, never as the input for the
      seat's declared parks/rulings that CORRECTLY-WAITING needs. Fix: classify each item to its
      island first, then read THAT island's slice. PR#2219 carries the per-item slice rule
      (closes (a)); 2026-10-10 the island-first rule, the platform-island table (spike §C2)
      and (b) were added there too — the operator gathers the platform refactor in that PR;
      close this entry when it merges.
      Sighted 2026-10-10 (operator). **Merged 2026-10-11 (#2219, `42ad3aec`) — by a seat subagent's
      rebase whose plain `pr-wait` armed auto-merge (card clause added the same day); the operator's
      read of the spike (now §C7, `docs/spikes/context-and-autonomy.md`) is still owed, revert one
      `git revert 42ad3aec` away.** Closed with the merge.
- [ ] board-sweep-G2 — **a probe that errors reads as an empty answer.** A PromQL query with a
      syntax error (`offset` after the expression) printed "none", and the sweep reported
      "Prometheus history before the restart is gone" — the operator asked whether data was lost;
      it was not. The live-verify rule says verify, not "show the probe succeeded". Sighted
      2026-10-14 (operator). Resight ~2026-10-21 (second-jail, operator-ordered artifact deletes:
      a zsh no-word-split loop sent one malformed request and the unchanged listing was explained
      as "deleting in the background"). Cross-skill class, 2 dates → promotion candidate for the
      seat + subagent cards (maintenance-window-G2's 09-24 "fail loud" rule, generalised): an
      empty/"none" read is absence only once the query's own success is shown.

## handoff

- [ ] handoff-G1 — a stack handoff/issue comment that DIAGNOSES a platform fault was acted on as a
      diagnosis: the seat fixed from oracle's reading (09-08 stall → worker reset + belts written
      after the fact; 09-09 rollout quorum loss → readiness fix planned from oracle-fleet#228's
      comment) without first asking what PLATFORM signal would have caught it. Operator ruling
      2026-09-09: build order is **detect → let it fire on the real condition (replay) → fix from
      the alert**; the report is only "there is a problem" — downtime detection never depends on
      issue reports, and the belt reaching the reporter's conclusion independently is the fair
      test. Fix: the skill gains that order as its first step. Sighted 2026-09-09 (operator).
- [ ] handoff-G2 — **the queue is worked by hand, the skill not invoked, though its trigger
      matched.** 2026-10-16 (a circles handoff worked + Result written "as the protocol requires"),
      ~2026-10-22 (second jail: claim → doing → Result, unskilled), 2026-10-23 (operator: "Is there
      a handoff/proposal from oracle regarding gateway specs?" — the trigger nearly verbatim; inbox
      grepped by hand). Three dates → promote: the description adds "is there a handoff/proposal
      from <stack>", "<stack>'s inbox".
- [ ] handoff-G3 — an older inbox file was skipped as "already resolved" without the verify
      ("The handoff says it's already resolved, but I didn't check") and left in `inbox/`, neither
      answered nor moved. Step 1 (oldest first) has no already-resolved exit. Fix: same verify,
      then `## Result: already resolved — <evidence>` and the move to `done/`. Sighted 2026-10-16.
- [ ] handoff-G4 — **two shapes the protocol lacks, improvised consistently.** (a) OUTBOUND
      mono→stack notices (a SHIPPED notice for oracle, an answer for circles) written straight to
      `<stack>/done/` — `tools/handoff.md` describes only stack-filed tasks. (b) In a second jail,
      step 6 (make the task durable as an FU/issue) collides with second-jail rule 2; the sessions
      routed the record to the primary's final message. Sighted 2026-10-16, 2026-10-19,
      ~2026-10-22 → promote: `tools/handoff.md` gains the outbound shape; step 6 gains "in a second
      jail the durable record goes to the primary".

## meta-coordinate

- [x] meta-coordinate-G1 — platform-lane PR review read the diff but truncated the BODY; the
      worker's "Findings" section (no machine harvester on this lane) was merged past unread —
      one finding was live on the PR's own issue. Sighted 2026-08-11 (operator catch).
      **promoted→** the skill's review duty gains the you-are-the-harvester rule, same commit.
      **RESIGHT 2026-08-11 (operator catch, same day)** — the promoted rule under-covered: it
      named the PR body, and the seat then read bot REVIEW bodies at a 200-char head (PR#311's
      approve posted on the summary alone; no finding lost, by luck). Rule widened same commit:
      the read is the body AND every review's FULL body, no truncated slices.

## onboard-metal-node

- [x] onboard-G1 — **a whole CLASS: post-install registrations that `Ready` does not gate.** The
      skill listed them as ordinary numbered steps, so a miss looks identical to a success — the
      node is `Ready`, nothing alerts. Sighted 2026-07-28 (wk-metal-04 joined with **no BGP
      neighbour**; fixed by adding step 8 — a one-off, the class was not named).
      **RESIGHT 2026-09-07 (m70s)** — same shape, different step: `zone:` in `machines.yaml` is a
      SEPARATE tofu resource (`kubernetes_labels.node_zone`, `tofu/longhorn.tf`), not part of the
      machine config, so the documented recipe leaves the node **unlabelled** — on the very box
      bought to be ADR-114's third failure zone. Two dates ⇒ promoted, not patched again:
      **the steps are now one "Post-install registrations — the steps `Ready` does not gate"
      section with a standing instruction to add to it each round**, plus step 9's table of
      per-node doc rows and step 10's disk read. Closed in the same commit.
- [x] onboard-G2 — step 1's credential line was **stale by a month**: `tofu/provisioning` moved to
      the encrypted Garage S3 backend on 2026-08-04 (`docs/tofu-state.md`) and there is no `tf.sh`
      wrapper for that root, so `keepass-env.sh` alone dies with *"No valid credential sources
      found"*. Sighted 2026-09-07 (hit live). Fixed in the same commit — the step now sources
      `tofu-state-env.sh` with `TOFU_STATE_ROOT_DIR`. Lesson worth more than the fix: **a skill
      that touches a tofu root inherits that root's state config, which changes without the skill
      being edited.**
- [ ] onboard-G3 — step 2 still names `opnsense/dnsmasq-dhcp.py`; LAN DHCP is Kea on both CARP
      nodes now (`opnsense/kea-dhcp.py`) and the session used that. Factual fix, due at the next
      skill edit. Sighted 2026-10-20.
- [ ] onboard-G4 — **replacement hardware under an existing node name has no path.** The
      Big Data → wk-metal-04 rebuild improvised: keep the `machines.yaml` entry + zone, re-match
      disks by eui, fence a re-registered dead disk's slot BEFORE scheduling (it sat open to bulk
      replicas ~30 s), salvage single-replica volumes, `tofu init` the provisioning root. Fix: a
      "same name, new hardware" variant section. Sighted 2026-10-20.

## design-agents

- [x] design-agents-G1 — a STATUS read from `meta-state.md`/tracker was repeated in the answer
      ("agent-runtime#62 still queued") although the session's own live board probe contradicted
      it in-context (#62 closed 30 min after meta-state's consolidation stamp). Fix: the output
      contract gains "status claims lifted from transient docs are live-verified (or marked
      as-of-doc-date) before being reported" — the never-repeat-a-remembered-status rule applied
      to the corpus itself. Sighted 2026-08-11 (operator catch).
      **RESIGHT 2026-08-23 (operator catch)** — the class extends to CONFIG constants, not just
      statuses: the seat quoted workflow.md's "SUBSCRIPTION_MAX_RUNNING default 3" while the
      deployed value had been 5 for two weeks (the operator's own dashboard said /5 in the same
      conversation). A number in corpus prose describing live config is a status claim; the
      deployment/ConfigMap is the authority. **promoted→** the skill's output contract gains
      the live-state-claims-verified rule (statuses AND config constants), same commit.
- [ ] design-agents-G3 — a machine-filed issue's DEMANDED OPERATOR ACTION was relayed verbatim
      ("grant Issues:Read on the reviewer App — console class, needs you") without checking the
      declared record one grep away (docs/github-apps.yaml carried issues:write since FU-069(b);
      the quiet GithubAppPermissionDrift alert alone refuted the ask — the real gap was the token
      MINT). The G1 class one ring out: an escalation ASK is a live-state claim too. Sighted
      2026-08-30 (operator catch: "still multiple rounds escalate to me doing a manual click
      instead of a simple grep/curl"). **promoted→** the skill's output contract gains
      asks-are-claims, same commit; the fleet half is the ground-rules bullet (PR#1044).
      **RESIGHT 2026-09-02 (operator catch — first in the MACHINE lane, wiring ruled correct):**
      the fleet half's clause was delivered but did not take on a cluster ride: an item-scoped
      coordinator (oracle, judging its issue's deploy leg) filed homelab#1319 under the ADR-119
      intake contract — whose rule 4 carries asks-are-claims verbatim, in the pod's own master
      clone — and still asked the operator to check the homelab-deploy install list, refuted by
      one /apps read (install intact; transient blip, next run green). A prose clause at rule
      4's tail of a ~1050-line brief is the suspect, and the "(ground-rules)" pointer names a
      file only worker rides receive. Belt candidates: a retro seed (§B2) on brief-clause
      compliance, or a deterministic declared-record check at the filing door (the #1207 shape).
      **REOPENED 2026-10-24 (skill-retro scoring — the promotion failed outside its skill):**
      2026-10-15 (P0/#1935 relayed as "your lane (tofu/github)"; a live ruleset read showed the
      bypass in place since 08-07), 2026-10-17 (gateway island: "I need one decision from you" to
      grant Secret creation — operator: "What requirement, give me a link"; none, the blocker was
      the seat's own unrequired hardening), 2026-10-19 (a pickup relayed a seat-work model pick as
      an "operator ruling" — "again deciding on opencode models?"). Two of three ran with the corpus
      unloaded, so the output-contract rule never loaded. Fix: asks-are-claims moves to the seat
      card (it governs every escalation the seat writes, corpus or not).
- [ ] design-agents-G4 — the seat proposed a PER-INSTANCE hand fix ("I can wire #326's two
      blockedBy edges and the task/build labels") where the operator wanted the CONSUMER
      SURFACE fixed: the consumer card gains the rules the instance tripped, and a deterministic
      `goal-lint` runnable from every jail catches them before queueing. "Wrong fix" — a
      malformed input from a documented authoring surface is evidence about the surface, not a
      chore. Sighted 2026-09-01 (operator catch); the same session had ALREADY applied the
      lesson once (#1069's recipe paste → the launcher prefetch mechanism) and still reverted to
      the instance fix on the next case. **RESIGHT 2026-09-01 (operator catch, third in 24h):**
      the seat executed PR#1192's ~10-line completion and presented it as the durable fix, while
      the operator wanted the SURFACE — the arbitrate "re-dispatch stronger" verdict has no
      carrier to the router ("they did not meet") → FU-201. The hand edit was sanctioned as the
      un-wedge; presenting it as the fix was the gap.
      **RESIGHT 2026-09-03 (operator catch, twice in one sitting):** on #1315/#1338 the seat
      proposed a `goal/deferred` label + a goal-lint clause — one more READER on an authoring
      surface the operator had just measured as unauthorable ("even a label linter would not
      have helped: #1338 was authored correctly"). The surface fix was SUBTRACTION (ADR-122:
      filing inert, walk retired, one parser, container-written disposition), not another
      rule. Candidate promotion: the skill's output contract gains "before proposing a lint/
      label/rule, count the readers the author already has to model; a fix that adds one needs
      the case for why subtraction is impossible."
      **RESIGHT 2026-10-15 (operator catch):** the #2588 fix first came as an enumerated
      guard list — "a lot of conditions that will go stale" — redone as ONE self-retiring
      predicate inside the updater's existing pick (memory: fix-inherits-existing-filters).
      Fourth date → promote the candidate line above.
- [ ] design-agents-G5 — a Goal's verdict-readiness was relayed as DUE from SHIPPED machinery
      while its Production-leg's verbs (demoting/advising/probing) name OBSERVED events: on #818
      the operator's exercised-in-a-stack bar refuted 3 of 4 deliverables (teeth never fired —
      burnt-bool 30d max 0; blocking knob — no stack sets `lenses:`; dial — nothing rendered).
      Fix candidate: the live-state rule extends to ACCEPTANCE VERBS — a verdict recommendation
      verifies each Production-leg verb against an observed event, never a ship record.
      Sighted 2026-09-02 (operator catch: "most of it has not been exercised in a stack yet").
- [ ] design-agents-G6 — the seat wrote INCIDENT HISTORY inline into a per-session brief
      ("retro r3 F1's #915 sat 9.3h parked `agent/blocked` on exactly this input" in the
      coordinator brief's new human-CR bullet; the same in the reviewer prompt + the rubric).
      Every coordinator/reviewer session pays those tokens; the rationale belongs in the ADR /
      the FSM `incidents:` field, the brief carries the rule + the ADR id. Sighted 2026-09-11
      (operator catch: "Is the history really relevant in a coordinator brief … every coordinator
      session uses tokens"). Candidate promotion: the output contract gains "a rule written into
      a per-session prompt (brief, reviewer prompt, rubric, env card) cites its ADR and carries
      no dates/issue refs of its own"; mechanical twin = a lint on those files.
      Resight 2026-10-14 (fu-sweep lane, self-caught + reverted before push). Two dates → promote.
- [ ] design-agents-G7 — **the island exemption lives only in auto-memory.** On gateway-island
      work the seat asked the full-corpus question before a launcher `/sessions` change — operator:
      "only launcher and gateway as context … whole point of islands is to get rid of the read
      everything requirement". Neither the seat card's stop-and-ask nor this skill names islands.
      Fix: the stop-and-ask paragraph gains "island work (its owning dir + the touched launcher)
      reads the island only; never ask the corpus question for it". Sighted 2026-10-17 (operator).
- [ ] design-agents-G8 — the inverse of G7: new grouping machinery for the [deep dig](../../docs/agents/roles.md) was designed
      with no slice read and no stop-and-ask — operator: "dig responder is supposed to take more
      than one alert at a time already" (`deep-dig-select.sh` groups). The trigger read as "a
      design question"; a PROPOSED CHANGE TO A LOOP COMPONENT is the same trigger. Fix: the
      stop-and-ask cue names it. Sighted 2026-10-20 (operator).
- [ ] design-agents-G2 — a lifecycle LABEL was reported as activity ("#833 is riding —
      in-progress") from a live `gh` read alone: the label is a CLAIM, and the state is the
      JOIN (label × live pod × PR state) — the issue's PR had merged 8h earlier with no pod
      running (the FU-143 held class). The promoted live-state rule covered doc-sourced claims;
      this extends it: a lifecycle label is never reported as activity without the pod/PR join
      (the seat-side twin of IL-T16's phantom-label lesson). Sighted 2026-08-24 (operator
      catch). Tooling half → the #628 observability-plane discussion.

## tofu-apply

- [ ] tofu-apply-G1 — `devbox run tf-apply -- -auto-approve` returned **exit status 127 AFTER
      tofu printed "Apply complete!"** (2 changed, in-place VM resizes); the apply had fully
      landed (verified on pve + the node's allocatable). A session reading the exit code alone
      would call a successful apply failed and re-run or roll back. Sighted 2026-09-08 (seat).
      Cause not chased (no local-exec in the root; `tf.sh` ends in `exec tofu`). Next: reproduce
      with `tf-plan`'s exit, then either fix the wrapper or add "the Apply line is truth, verify
      the end state" to the skill.
- [ ] tofu-apply-G3 — **a github-provider apply that 403s PERSISTS THE PLANNED STATE, and
      `-refresh-only` does not reconcile it.** Applying `github_repository_ruleset.required_checks`
      with a token that can read but not write (the jail PAT has no repository *Administration*)
      failed with `PUT …/rulesets/18664851: 403 Resource not accessible by personal access token`
      — and tofu then recorded `e2e` in state anyway. The next plan read **No changes** while
      GitHub still had only `ci`, so the drift was invisible AND self-sealing: a later apply with
      the correct admin token would have been a no-op and the ruleset would have stayed wrong.
      `apply -refresh-only` did NOT fix it (the provider's Read does not repopulate the nested
      `required_check` blocks). Repair that worked: `state rm` + `import '<repo>:<ruleset_id>'`,
      then re-plan to confirm the diff returns. Sighted 2026-09-16 (seat, oracle-fleet#369 /
      homelab#1727). Next: the skill should say a failed apply is NOT a no-op — verify state
      against live before retrying — and that `github-tofu` needs the org-admin wallet, not any
      token that happens to plan cleanly.
      **RESIGHT 2026-09-27 (seat, FU-289, bpg/proxmox this time) — the OTHER half of the class: a
      SUCCESSFUL apply that did not land.** The first apply of wk-04's placement change 500'd
      (`only root can set 'hugepages'`); the quickfix apply then printed `Modifications complete
      … 1 changed`, but pvedaemon's own record of the request was `update VM 8114: -name wk-04`
      — no `numa0`/`numa1` — and `qm config` had none. A third plan+apply sent them. The apply
      line is not the end state for a VM config: `qm config <vmid>` (or `journalctl -u
      pvedaemon | grep 'update VM'`) is, and the 2026-09-24 hostpci apply had the same shape
      (config accepted, the start failed on a mapping property). Next, sharpened: the skill's
      post-apply check for a `proxmox_virtual_environment_vm` change is a `qm config` diff
      against the plan's `+`/`~` lines, read on the hypervisor, before `node-maintenance up`.
- [ ] tofu-apply-G2 — **a `machines.yaml` `longhorn_disks` apply REBOOTS the node**, and the skill
      does not say so. Talos provisions user disks at boot, so the provider's default (auto) mode
      staged the config and rebooted `m70s` — a node then carrying garage-1, loki-0 and six
      single-replica Deployments — with no cordon, no drain and every pod killed ungracefully. The
      2026-09-10 Loki WAL corruption came from exactly that shape on hp-01; here it was luck
      (loki-0 had already moved). Sighted 2026-09-12 (seat, the PM961 fit). Next: the skill's
      gotcha list should route disk/volume-shaped machine-config changes through
      `scripts/node-maintenance.sh settle` (or `down`) first — the reboot itself is fine, doing it
      undrained is not.

## maintenance-window

- [ ] maintenance-window-G1 — **a fix that addresses only the instances in view, then reports the
      CLASS as closed.** Three separate review rounds in one session caught the same shape: the
      `client-configs.sh` write-order race (#1803) landed after the local/box split had been
      "handled"; #1804's first fix hardened three of five read paths and its commit message said
      "all three reads now distinguish 'queried and found nothing' from 'the query failed'" — the
      tool has FIVE checks, and the two left untouched had the identical fail-open bug, one of them
      the cilium backend check the whole tool exists for. The reviewer found each by enumerating
      the call sites; the seat found none of them. Sighted 2026-09-20 (seat, homelab#1803/#1804).
      RESIGHT, same day, same PR: rounds 4 and 5 found two MORE fail-open sites after the round-3
      fix had again claimed the set ("all five now") — `snapshot()`'s zero-node `exit`, which the
      call site turned into a silent death, and cilium `have=0 unknown=N` reading as `ok`. The
      count claim was wrong three times running; a claimed count is worth nothing without the
      enumeration and a test per site behind it.
      Next: when a fix names a failure CLASS, the skill should require enumerating every call site
      of that class and stating the count — "5 reads, 5 guarded" — before the class may be called
      closed; and a mechanical test per site, since the self-test added here initially pinned 3 of
      5 while its own docstring claimed the set.
- [ ] maintenance-window-G2 — **the skill's alert watch is a snippet the seat re-types, and it went
      silent for 30 min.** The `Monitor` loop written for the 2026-09-21 pve window used
      `for a in $cur` — zsh does not word-split, so the whole alert list compared as ONE name and
      nothing was ever emitted while `maint check` showed four new alerts. The ping-based "is pve
      up" watch failed the same way twice (`ping`/`nc` absent from the jail's bare PATH; a `$PV`
      command-in-a-variable never ran). Also improvised: there is no `down` verb for a CONTROL
      PLANE (node-maintenance refuses, cp-upgrade only upgrades) — cp-01 went down by hand (etcd
      status + leader/VIP read, snapshot, drain, `talosctl shutdown`, cilium-check). Sighted
      2026-09-21 (seat, pve GPU swap). RESIGHT 2026-09-22 (seat, registry GC window): the re-typed
      watch carried a SECOND defect, one the first sighting's bug would have masked — no dedupe, so
      a persistent new alert re-notified every poll (`GarageDisruptionBlocked`, already pending 90
      min before the window opened, fired on its 2 h `for:`, then repeated each 45 s tick). Two
      independent defects in two consecutive hand-written copies is the argument for shipping the
      verb, not for a bigger snippet in the skill. Next: ship the watch as a verb (`maint watch`,
      emits one line per new alert name ONCE — baseline-diff plus a seen-set — exits never) so it is
      run, not re-typed; and a `cp-down`/`cp-up` pair beside cp-upgrade with the same gates.
      **cp-down/cp-up HALF BUILT 2026-09-30 (operator: "node maintenance should take control plane
      as argument")** — homelab#2137: `node-maintenance.sh down|up <cp>` hands off to
      `controlplane-upgrade.sh <cp> <verb>` (+ etcd leadership forfeit). First live run (cp-01, the
      pve NIC window) found `down`'s Longhorn read aborting on a CP (no nodes.longhorn.io) — fixed
      in the PR; the review found the forfeit read's pipefail fail-open. The watch verb is still
      unbuilt (fourth hand-written copy — bash + seen-set — worked).
      **RESIGHT 2026-09-30 (same session, a PR watch — fifth hand-written loop):** it piped
      `gh pr view --json reviews` through zsh `echo`, which expanded the escapes inside review
      bodies; every `jq` read failed, the loop could never see a terminal, and it ran its full
      30 min blind while both PRs had merged in minute 1. Replaced by a script file reading each
      field with `gh --jq` (no JSON through echo), dry-run before arming. Same argument: the
      watch belongs in a verb, not re-typed.
      **RESIGHT 2026-09-23 (seat, wk-metal-04 drive swap) — THIRD hand-written copy, THREE more
      defects, and the first was a new class: the PROBE, not the loop.** The watch exec'd
      `wget` inside the prometheus container; that container has no `wget`, so the command produced
      nothing, every poll compared an EMPTY alert set, and the Monitor sat silent for its full 30 min
      while reporting "expired with no events". Silence from a working watch and silence from a dead
      one are the same notification — which is the whole failure this skill exists to prevent, now
      committed by the skill's own recipe (§Arm the watch prints `curl $PROM/api/v1/alerts` and never
      says what `$PROM` is or how to prove it answered). The zsh `for a in $cur` bug from the first
      sighting was ALSO re-committed in the replacement loop minutes later. Two fixes, both cheap:
      the verb must (a) resolve a probe that is reachable from the jail — Alertmanager's LB VIP
      `192.168.40.14:9093/api/v2/alerts` works with plain `curl`, no exec, no in-container tooling —
      and (b) FAIL LOUD on an unreadable probe (`WATCH BLIND` after N consecutive empty reads),
      mirroring `maint check`'s own "UNREADABLE blocks like a regression" rule, which the watch half
      never inherited. Three sightings, three distinct defects, zero successful hand-written copies:
      And a third, purely operational: the replacement Monitor was armed WITHOUT stopping the
      broken one, so two watches ran and the dead one kept delivering its blob as if it were a
      finding — a hand-managed watch has no notion of "replaces". Four defects across three copies,
      zero successful ones: **stop re-typing it, ship `maint watch`** (one verb, one process, a
      dedupe set, a loud-on-unreadable probe, and an id so re-arming replaces rather than duplicates).
      **RESIGHT 2026-09-24 — the class is broader than the alert watch.** The same seat committed
      the identical defect in a *benchmark*: an fio pod whose four jobs each redirected stderr to
      /dev/null and whose jq parser was wrapped in `|| echo "(no data)"`. The jq was wrong
      (`.jobs[0].sync.lat_ns` is null for non-fsync jobs, and indexing null throws before `//` can
      default), so all four results printed "(no data)" and the output could not distinguish "fio
      failed" from "the parser failed" — eight minutes and a 200 GiB run to learn nothing. The
      re-run carried per-job exit codes and an `ls -la` of the JSON, and it was the parser.
      **So the fix is not only "ship `maint watch`": any probe this seat writes must fail loud and
      must be able to say WHICH HALF broke.** That belongs in the skill as a rule, not just in one
      verb. Counter-example from the same session, and the pattern to ship: the alert watch DID
      work, because it was written to a FILE (no zsh word-split), kept its dedupe + blind counter in
      fixed paths so they survived re-invocation, and was self-tested against a known-firing alert
      before being armed — and when it later reported nothing across a control-plane shutdown, that
      silence was VERIFIED against Prometheus rather than trusted.
      **RESIGHT 2026-09-24 (seat, wk-04 SN530 passthrough) — FOURTH hand-written copy, FOURTH new
      defect class, and this one is the SEED.** The loop itself was right this time (a file, a
      dedupe set, a loud-on-unreadable counter). What was wrong was where its baseline came from:
      the seat re-typed the alert names out of `maint open`'s printed output, which prints the
      **responder SKIP list** — a fixed 14-name set — and NOT the 6 alerts actually firing. The
      watch therefore reported all six pre-existing alerts as NEW on its first poll, seven
      notifications in the first minute of the window, and `maint check` had to be run to find out
      which one (`InfoInhibitor`) was real. Crying wolf is the same failure as silence: both make
      the next notification unreadable. **The fix is one line and removes the re-typing entirely**
      — the true baseline is already on disk at `$STATE_DIR/<id>/baseline.json` under `.alerts[]`,
      which `open` wrote. Seed from that file, never from the terminal. Four copies, four distinct
      classes (zsh word-split → no dedupe → dead probe → wrong seed), zero clean ones; every one
      of them would have been prevented by the verb that has now been "next" for three sightings.
      **Also improvised this window, and the sibling of the missing `cp-down`: `node-maintenance up`
      cannot start a VM.** Its `up` path is WoL-then-wait — for a VM it logs *"no MAC … (a VM? start
      it on pve)"* and then blocks on `node_ready` forever, so after `down` stopped wk-04 the verb
      hung with the node off and nothing to wake it. The seat started it by hand
      (`ssh root@nx-02 qm start 8114`) and `up` then completed its uncordon + storage wait normally.
      So `down` works for a VM and `up` does not — the asymmetry is invisible until a window is
      already open with a node down. Next: give `up` a hypervisor start path (the node's
      `hypervisor` + `vm_id` are both in `var.nodes`) so the verb pair is symmetric for VMs as it
      is for metal.
      RESIGHT 2026-09-24 (seat, registry cutover): a FOURTH copy, this time written as a bash script
      file with a failed-read counter (it held, and stayed silent across a clean window). Still no verb.
      2026-10-09: the CP half is DONE and composed — `controlplane-upgrade.sh down|up` is what
      `node-maintenance down <cp>` hands to, and the new hypervisor verb (`scripts/host-maintenance.sh
      preflight|down|up <nx-02|pve>`, #2401) runs it inside a whole-host down/up. This entry now covers
      only the `maint watch` half (the alert watch as a verb, not a re-typed snippet — this session
      re-typed it once more, as a file under bash, and it worked; the point stands).
      **RESIGHTS 2026-10-20, 2026-10-22, 2026-10-23** (seat windows: re-armed twice for a flapping
      InfoInhibitor and at Monitor expiry; a zsh no-word-split copy whose first event reported all
      12 baseline alerts NEW). New nuance from 10-22: the Monitor's 30-min cap equals the lease, so
      a hand watch that also renews makes the window's life depend on a re-arm nobody prompts.
      Still no verb.
- [ ] maintenance-window-G4 — **a window opened to PROVE a detector fires cannot close.** The
      acceptance for any detector-first item (the standing build order: detector, let it fire on
      the real condition, then the fix) is to make the new alert fire on purpose — but `check`
      diffs firing alerts against the baseline with no notion of an EXPECTED one, so the window's
      own product reads as a regression and `close` refuses. `open --alerts` does not help: it is
      the responder's skip list, never consulted by `check`. The only exit is `--force`, which the
      skill documents for a stale slot from a dead session — so the seat either forces (and the
      word stops meaning what it says) or leaves a window open for the alert's whole window.
      Sighted 2026-09-23 (seat, FU-247's kernel-oops acceptance: `KernelOopsCaptured` fired as
      designed on wk-03, silenced 7h in Alertmanager, self-clears ~6h). Next: an expected-alert
      declaration that `check` honours (`open --expect <alert>`, reported as "expected, firing"
      rather than NEW), and the skill's detector-acceptance path should name it.
      **RESIGHT 2026-09-24 (seat, the hp-01/nx-01/nx-02 drive session) — a SECOND shape, and it is
      the common one.** Two windows in one session could not close, neither because of a detector:
      (a) `InfoInhibitor` — stock kube-prometheus-stack plumbing, `severity: none`, driven by a
      *pending* `CPUThrottlingHigh` the window did not cause (its expr matches
      `ALERTS{severity="info"}` without requiring `alertstate="firing"`); (b) `CiliumUnreachableNodes`
      + `NodeRebooted` + `PodSigkilled` after a planned reboot — all lagging alerts on conditions
      verified resolved (`maint cilium-check` clean, 13/13 agents, have=13 missing=0), and
      `PodSigkilled` is documented by node-maintenance itself as firing up to 30 min after the kill.
      So the missing mechanism is not only "expected detector output" — it is **alerts a window
      causes, or does not cause, that outlast it**. `--force` was used both times with the items
      named: sanctioned, but the word means less each time. Note the node-scoped windows
      `node-maintenance` opens already declare exactly the right list (`KubeNodeNotReady`,
      `PodSigkilled`, `CiliumUnreachableNodes`, `NodeRebooted`, …) — `check` should honour that
      declared list rather than diffing raw firing sets past it.
      **Resight 2026-10-05 (the #2254 window):** the blocker was not even the window's own detector —
      the stock `InfoInhibitor` (fires whenever an `info` alert has no warning sibling in its namespace)
      flapped every ~30 min all day, landed between `open` and `check`, and `close` refused on it as
      a NEW name. `check` should drop the two stock meta-alerts (`Watchdog`, `InfoInhibitor`) exactly
      as the Alertmanager route does; forced closed with this note. Second date → promote.
      **RESIGHTS 2026-10-15 (router window, `--force` on InfoInhibitor), 2026-10-20 (filtered out
      of the hand watch).** Promotion proposed: `check` drops `Watchdog`/`InfoInhibitor`.
- [x] maintenance-window-G3 (filed 2026-09-22 under a colliding `-G1` id) — `maintenance-window.sh`
      kept ONE state slot per user, so a seat and its subagent with windows open at once clobbered
      each other's baseline + window id (the first `close` would have closed the SUBAGENT's
      window). Sighted 2026-09-22. **fixed→** state keyed by window id (`$STATE_DIR/<id>/`),
      `check`/`close --id`, no-`--id` refuses + lists when several are open, `list` verb; skill
      says to note the id; self-test §7 — same commit.
- [ ] maintenance-window-G5 — **`close` refuses on the window's OWN expected consequences, and the
      seat waits out a 30-minute lookback for nothing.** The wk-04 placement restart (FU-289,
      2026-09-27) shut the node down through `node-maintenance down`; the four DaemonSet pods that
      die at a node shutdown fired `PodSigkilled` (`increase(...restarts[30m])`) and the node fired
      `NodeRebooted` (10 min after boot). `check` listed both as NEW, `close` refused, and the seat
      sat in a poll loop for the 30 minutes until the lookback drained — operator: "this is wasting
      time. Is the alert the problem or the silence or the waiting?" The silence is irrelevant
      (`check` reads Prometheus firing state, not Alertmanager's muting); the alert is right
      elsewhere; the WAIT was the defect. Closed with `--force`, stated. Sighted 2026-09-27 (seat).
      Re-sighted 2026-09-27 evening (seat, the unattended nx-02 hypervisor reboot): the same two
      alerts plus `NodeRebooted` for the HYPERVISOR's node_exporter and `CronJobNotSucceeding` for
      the down node's own `fstrim-guard-<node>` (nodeName-pinned, so it sits Pending while the
      node is off) — a per-node CronJob is a fourth member of the "known consequence" class.
      Next: `check` should classify an alert whose labels pin it to the window's `--node` (node,
      the pods of that node's DaemonSets) AND whose class is the declared act's known consequence
      (NodeRebooted, PodSigkilled, KubeNodeNotReady …) as EXPECTED, printed but not blocking
      `close`; the baseline-diff stays strict for everything else.
      **RESIGHT 2026-09-30 (seat, pve NIC window — 3rd date):** `NodeRebooted` (pve + cp-01) and
      `PodSigkilled` again blocked `close` after a clean return (nodes 13/13, targets 186/186, cilium
      13/13); `--force`, named. Plus a MECHANISM for the lagging `CiliumUnreachableNodes` the
      09-24 resight only called "lagging": `cilium-health status --verbose` on the reporting agents
      showed results frozen at the rebooting node's mid-boot probe (`Last probed` 15 min old,
      `connection refused` on :4240) — a stale prober, not a network fault; cp-01's own agent saw
      all 13. It cleared by itself (past episodes 5–50 min). The alert reads the gauge, so it
      cannot tell stale from real — read `Last probed` before acting.
      **RESIGHTS 2026-10-20 (PodSigkilled after a reinstall), ~2026-10-21 (the only NEW alerts were
      two restart alerts the seat had already CLAIMED — a claim does not satisfy `close`),
      2026-10-23 (the ride's own expected `AgentWorkerEgressDropped`; and a new sub-shape: the
      baseline taken right after a rollout counted its old pod, so `check` read one target short).**
      Six dates → promote: expected-consequence classification + claimed alerts honoured; take the
      baseline after a just-finished rollout settles.
- [ ] maintenance-window-G7 — **urgent restarts ran with no window.** `rollout restart` of the
      gateway after a policy merge, then gateway + openrouter-proxy during a key rotation, checked
      only "no session in flight" — the skill's triggers name restarts. Sighted 2026-10-17.
      Weak resight 2026-10-22: a merge whose ArgoCD sync rolled the single-replica gateway (old
      image refused new policy keys, ~13 min down) ran undeclared. Fix: the skill's examples name
      incident restarts, key-rotation rollouts and single-replica sync-restarting merges
      ("urgent is not exempt").
- [ ] maintenance-window-G6 — **a proof that may cut the seat's own network path runs with no
      self-revert, and the skill never asks.** The window-2 failover proof (2026-10-08) was a
      background script because the jail's internet rides `.1`; its back-out step failed silently and
      the session sat blind (`EAI_AGAIN`) for nine hours with nx-02 in CARP maintenance
      (`docs/incidents/2026-10-08-carp-maintenance-not-left.md`). The skill's alert watch and
      `check` both ride the same path and were equally blind. Sighted 2026-10-09 (seat). Next: the
      skill asks, for any act on the router/WAN path, "does your own session ride what you are about
      to move?" and, if yes, requires an armed dead-man revert BEFORE the act (FU-308) and a probe
      from OUTSIDE the cut (the mgmt box over its own path, or the operator's phone).
      2026-10-09: the dead-man half is BUILT + drilled (#2399, FU-308 archived) and the WAN-leg window ran
      with the mgmt-box probe; the skill text still asks nothing — this entry now covers only that question.

## opnsense-as-code

- [ ] opnsense-as-code-G1 — **the test-VM gate is invisible from the skill, and it does not cover every play.**
      Sighted 2026-10-13 (seat, FU-312 / #2535–#2537). (a) The skill never names `scripts/opnsense-test-vm.sh`
      as the validation step for a router-role PR, nor its two required inputs — two runs died on
      `OPN_TEST_HOST`/`OPN_TEST_VMID` unset before the seat found the one runbook line (§OPNsense test VM, line
      ~131) that exports them. (b) Steps 2/3/5 run acme, bgp, unbound, haproxy only: a PR changing the
      `opnsense-system` role (#2537, identity over ssh) got a fully green report that never executed the changed
      code; the real failure (`write_config()` → `shell_safe()` undefined, `util.inc` not included) surfaced on
      the production BACKUP. Next: the skill routes every `ansible/opnsense-*`/`roles/opnsense-*` PR through the
      script with the env line quoted; the script's play set follows the PR's touched roles (or `--steps all` is
      the default for a role outside the four).
- [ ] opnsense-as-code-G2 — **ACME on the CARP BACKUP returns 400** (no WAN leg while BACKUP; its
      certs are seed copies) and the skill never mentions the pair. Fix: issue/sign on the MASTER,
      carry certs to the BACKUP (FU-297's cert-carry); expect 400 from a BACKUP issuance. Sighted
      2026-10-15.

## docs-cleanup

- [ ] docs-cleanup-G1 — a generated block (marker-delimited, `machines/generate.py`) was
      hand-edited; the pre-push hook caught it and the fix moved to `machines.yaml`. The hard rules
      should say it first. Sighted 2026-10-14.

## second-jail

- [ ] second-jail-G1 — rule 1 ("work only in a clone") names only `/workspace/homelab`; on an
      operator-ordered task in `/workspace` (the claude-jail checkout) the session committed the
      operator's uncommitted changes via a clone, then reset six files and fast-forwarded the
      live tree unasked. Fix: rule 1 covers every operator checkout under `/workspace`; rewriting
      one needs the operator's say. Sighted ~2026-10-17.
- [ ] second-jail-G2 — rule 2 was over-applied to the separate hardware repo (refused to update
      its purchases record as a "shared record") — operator: "you can edit the hardware repo".
      Fix: rule 2's list is homelab's records; other repos follow their own protocol. Sighted
      2026-10-13 (operator).
- [ ] second-jail-G3 — invoked MID-session (`/second-jail do the PR`) after the session had
      already made an unpushed direct master commit in the shared tree as primary; the skill
      assumes session start, so nothing handed that commit over. Fix: on a mid-session switch,
      list prior writes in `/workspace/homelab` and finish or hand them over first. Sighted
      2026-10-13.
