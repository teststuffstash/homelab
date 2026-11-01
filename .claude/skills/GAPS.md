# GAPS — the skill gap ledger (ADR-105)

Sightings of skill shortcomings, FU-shaped. The contract lives in [`README.md`](README.md)
§Improvement contract: file on sighting · extend with a date on re-sighting (never a duplicate
line) · ≥2 dates on one entry = a class → promote it INTO the skill as a PR, closing the entry in
the same commit · an entry is ≤10 lines (`devbox run follow-ups-lint` → OVERSIZE-GAP): over the
bar it is a rule (promote) or work (file the `FU-NNN`, leave a pointer) · ≲5-min factual fixes
skip the ledger. History lives in this file's git log, not in the entries. This file is in a
PUBLIC repo — dialogue-level facts only, never tool output.

**2026-10-26 sweep:** every entry with a text fix was promoted in one PR; the "build
it" halves were built as their own PRs the same day (#2930, #2935 — operator: no FU for a decided,
bounded build); handoff-G4 waits on claude-jail#11.

## design

- [x] design-G1 — an answer proposing DOC EDITS never pulled in the writer-side rules. Sighted
      2026-08-11. **promoted→** closure step 2 gains "proposing doc changes ⇒ `docs/README.md`
      §Conventions + docs-cleanup Hard rules" (2026-10-26).
- [x] design-G2 — two design-shaped cues went unrecognised: "multiple passes gave different
      answers" (2026-08-11) and "what should I improve in <X>'s setup" — an audit ran as live-probe
      triage and contradicted the stack's own two-tier cache design (2026-10-16, operator).
      **promoted→** both cues in the trigger list; an audit reads the owning decision first.

## board-sweep

- [x] board-sweep-G1 — the sweep pipeline knew ONE context (the design-agents corpus) while the
      platform grew islands with their own owning docs. Sighted 2026-10-10 (operator). Closed by
      #2219 (island-first rule, the §C7 islands table, meta-state as CORRECTLY-WAITING's input).
- [x] board-sweep-G2 — a probe that ERRORS reads as an empty answer: a malformed PromQL printed
      "none" and the sweep reported history lost (2026-10-14, operator); a zsh no-word-split loop
      sent one malformed delete and the unchanged listing was explained away (~2026-10-21).
      **promoted→** the live-verify hard rule, the seat card §Claims and the subagent card: an
      empty/"none" read is absence only once the query's own success is shown (2026-10-26).
- [ ] board-sweep-G3 — a read-only sweep subagent downloaded the lane records (dig/responder
      findings) into the SHARED checkout as an untracked `lane/` dir (2026-10-31; the seat moved it
      out). The gather step names no destination — it should say "the scratchpad, never the tree".

## handoff

- [x] handoff-G1 — a stack's DIAGNOSIS of a platform fault was acted on as a diagnosis (09-08
      stall, 09-09 quorum loss). Operator ruling 2026-09-09: detect → let it fire on the real
      condition (replay) → fix from the alert. **promoted→** step 3 carries that order (2026-10-26).
- [x] handoff-G2 — the queue was worked by hand with the skill never invoked, though its trigger
      matched (2026-10-16, ~10-22, 10-23: "is there a handoff/proposal from oracle…").
      **promoted→** the description gains those cue phrases (2026-10-26).
- [x] handoff-G3 — an inbox file judged "already resolved" was left in `inbox/` unverified
      (2026-10-16). **promoted→** step 2's already-resolved exit: same verify, `## Result: already
      resolved — <evidence>`, move to `done/` (2026-10-26).
- [ ] handoff-G4 — two shapes the protocol lacked, improvised the same way three times (2026-10-16,
      10-19, ~10-22): OUTBOUND mono→stack notices written to `<stack>/done/`, and a second jail's
      durable record (step 6 collides with second-jail rule 2). Operator 2026-10-26: expand the
      protocol for now; the direction is stack↔platform comms that need no live seat
      (`platform-request` label); "a useful antipattern to keep an eye on". The skill half landed
      (step 6, mission line); the protocol half is claude-jail#11 (`tools/handoff.md`) — close
      this entry when it merges.

## meta-coordinate

- [x] meta-coordinate-G1 — a PR review read the diff but truncated the BODY; a worker's finding
      was merged past unread (2026-08-11, operator; resight same day on bot review bodies).
      **promoted→** the review duty reads the body AND every review's full body, no truncation.

## onboard-metal-node

- [x] onboard-G1 — post-install registrations that `Ready` does not gate (BGP neighbour 07-28,
      zone label 09-07). **promoted→** the "Post-install registrations" section with a standing
      add-to-it instruction.
- [x] onboard-G2 — step 1's credential line was a month stale after the provisioning root moved
      to the Garage S3 backend (2026-09-07). Fixed same commit; lesson: a skill touching a tofu
      root inherits that root's state config.
- [x] onboard-G3 — step 2 still named `dnsmasq-dhcp.py` as the applier; LAN DHCP is Kea on both
      CARP nodes (2026-10-20). **promoted→** step 2: the reservation is edited in `HOSTS`, applied
      with `kea-dhcp.py` to both nodes via `opnsense-router-node.sh converge` (2026-10-26).
- [x] onboard-G4 — replacement hardware under an EXISTING node name had no path (Big Data →
      wk-metal-04, 2026-10-20: entry kept, disks re-matched by eui, a re-registered dead disk's
      slot open to replicas ~30 s before fencing, single-replica salvage). **promoted→** the
      "Variant: replacement hardware under an existing node name" section (2026-10-26).

## design-agents

> **Routing (operator 2026-10-26): design-agents is semi-deprecated — context is read per island
> (spike `context-and-autonomy.md` §C7; oracle-fleet#935's read map is the track-unit shape).** A
> promotion from this section goes to the seat card (cross-cutting rules) or to the islands table
> (read scoping), never into the skill's own text. Every entry below closed into
> `agents/jail-seat-card.md` §Claims / §Design questions on 2026-10-26.

- [x] design-agents-G1 — statuses and config constants lifted from transient docs were repeated
      although live state contradicted them (2026-08-11, 08-23). **promoted→** live-state claims
      verified (statuses AND config constants) — now the seat card §Claims.
- [x] design-agents-G2 — a lifecycle LABEL was reported as activity (2026-09). **promoted→**
      §Claims: a label is a claim; join it with the live pod/PR before reporting.
- [x] design-agents-G3 — a machine's DEMANDED OPERATOR ACTION relayed without reading the declared
      record one grep away (2026-08-30; resights 09-02, 10-15, 10-17, 10-19 — the last three with
      the corpus unloaded, so a skill-contract rule never reached them). **promoted→** asks-are-
      claims in the seat card §Claims. The fleet half stays the `agents/ground-rules.md` bullet
      (PR#1044) + ADR-122's intake contract; a belt on brief-clause compliance is unbuilt, no FU —
      file one on the next machine-lane resight.
- [x] design-agents-G4 — per-instance hand fixes and "one more reader" proposals where the operator
      wanted the authoring SURFACE fixed by subtraction (2026-09-01 ×2, 09-03, 10-15: "a lot of
      conditions that will go stale"). **promoted→** §Claims: count the readers the surface already
      has; a fix that adds one argues why subtraction is impossible; new cases ride the existing
      predicate; the hand edit is the un-wedge, never the fix.
- [x] design-agents-G5 — a Goal's readiness relayed as DUE from shipped machinery while its
      acceptance verbs named unobserved events (2026-09-02). **promoted→** §Claims: acceptance verbs
      verify against an observed event, never a ship record.
- [x] design-agents-G6 — incident history written into per-session briefs (2026-09-11; resight
      2026-10-14, self-caught). **promoted→** §Claims: a rule in a per-session prompt cites its ADR
      and carries no dates/issue refs. Mechanical twin (a lint on brief files) unbuilt; file it if
      the class resights.
- [x] design-agents-G7 — the island exemption lived only in auto-memory; the seat asked the corpus
      question on gateway work (2026-10-17, operator). **promoted→** §Design questions: island work
      reads the island only, never the corpus question.
- [x] design-agents-G8 — a change to a loop component designed with no slice read and no
      stop-and-ask (2026-10-20, operator: the dig already groups). **promoted→** §Design questions:
      a proposed change to a loop component IS the stop-and-ask trigger.

## tofu-apply

- [x] tofu-apply-G1 — `tf-apply -auto-approve` exited 127 AFTER `Apply complete!` (2026-08). The
      reproduce half is dead (`tf-apply` refuses since 09-13; `mgmt-tf.sh` propagates the remote
      rc). **promoted→** Gotchas: a non-zero exit after a completed apply means verify the end
      state, never re-run or roll back (2026-10-26).
- [x] tofu-apply-G2 — a `machines.yaml` `longhorn_disks` apply REBOOTS the node (2026-09). Both
      apply resources run `apply_mode = "no_reboot"` since 09-22, so the apply refuses instead.
      **promoted→** the skill routes a disks change through `node-maintenance settle|down` → reboot
      → `up` (2026-10-26).
- [x] tofu-apply-G3 — a github-provider apply that 403s PERSISTS the planned state (2026-09; the
      proxmox resight: a VM apply's post-check). **promoted→** three rules: `github-tofu` applies
      outside the jail with the org-admin wallet; a failed apply is not a no-op (`state rm` +
      `import`, re-plan); a `proxmox_virtual_environment_vm` apply is checked with `qm config`
      against the plan before `node-maintenance up` (2026-10-26).

## maintenance-window

- [x] maintenance-window-G1 — a fix that addressed only the instances in view, reported as the
      class (2026-09). **promoted→** Hard-won: a class fix closes only with the enumeration — every
      site listed, the count stated, a self-test case per site (2026-10-26).
- [x] maintenance-window-G2 — the alert watch was a snippet the seat re-typed; seven copies between
      2026-09-21 and 10-23, each with its own defect. **built→** `maint watch` (one process per window,
      seeded from `baseline.json`, seen-set dedupe, `WATCH BLIND`, lease renewal) and `node-maintenance
      up` starting a VM — #2935 (2026-10-26); live proof = the next real window.
- [x] maintenance-window-G3 — one state slot per user clobbered concurrent windows (2026-09-22).
      **fixed→** state keyed by window id, `--id`, `list` verb, self-test §7.
- [x] maintenance-window-G4 — the stock meta-alerts (`Watchdog`, `InfoInhibitor`) and a
      deliberately fired detector blocked `close` (2026-09-23, 09-24, 10-05, 10-15, 10-20).
      **promoted→** `check`/`close` drop the two meta-alerts (`META_ALERTS`, self-test §6); a fired
      detector is `claim`ed; `open --expect` for one the responder must also see rides the same PR.
- [x] maintenance-window-G5 — `close` refused on the window's OWN consequences and on alerts the seat
      had already `claim`ed (six dates 2026-09-27 → 10-23). **built→** claimed alerts honoured (#2929),
      EXPECTED bins for node-pinned consequence classes + `open --expect` (#2935, 2026-10-26); the
      rollout-settles-before-baseline rule is skill text.
- [x] maintenance-window-G6 — a proof that may cut the seat's own network path ran with no
      self-revert (2026-10-08, nine hours blind). The dead-man half shipped 2026-10-09 (#2399).
      **promoted→** the skill asks "does your own session ride what you are about to move?" → arm
      the dead-man first, probe from outside the cut (2026-10-26).
- [x] maintenance-window-G7 — urgent restarts and a key-rotation rollout ran with no window
      (2026-10-17; weak resight 10-22, an ArgoCD sync rolling the single-replica gateway).
      **promoted→** triggers + hard rule: urgent is not exempt — incident restarts, key rotations,
      single-replica sync-restarting merges (2026-10-26).
- [ ] maintenance-window-G8 — the watch's `NEW <name>` line never reached the seat mid-window:
      `maint watch` ran as a background shell task, which interrupts only on EXIT, so a NEW
      `UpgradeLeaseInFlight` (07:04Z) was read after `close` and got its outcome late (benign,
      info/triage none). Sighted 2026-10-28 (merge window #2916/#2915/#2911). Fix shape: the skill
      says to arm the watch as a line-streaming monitor (each line = a notification), not a
      background task read only at exit.

## opnsense-as-code

- [x] opnsense-as-code-G1 — the test-VM gate was invisible from the skill and ran only the four
      plays, so a PR touching another role got a green report that never ran its code (2026-10-13,
      #2537 failed on the production BACKUP). **promoted→** the skill's "Validate a router-role PR on
      the test VM" section (script, env line, reading the plays-under-test header); **built→** #2930:
      the play set derives from the PR's touched paths, step `all` joins by default (2026-10-26).
## docs-cleanup

- [x] docs-cleanup-G1 — a generated marker-delimited block was hand-edited; the pre-push hook caught
      it (2026-10-14). **promoted→** first hard rule: fix `machines.yaml`, re-run
      `machines/generate.py`, never the block (2026-10-26).
- [ ] docs-cleanup-G2 — the §Scale note keeps edits in the main session; on 2026-10-31 (operator:
      "let subagents go over all docs") nine per-island fact-check subagents each EDITED their own
      partition in a clone + PR (9 PRs, all approved without a requested change; tracker/ADR
      corrections came back to the seat). Found what the comb never did: committed conflict
      markers on master (#2946 → gate #3082), a register failing its own `--check`. One sighting —
      a second run like it promotes "fan out edits by island, tracker stays with the seat".

## second-jail

- [x] second-jail-G1 — rule 1 named only `/workspace/homelab`; a session reset and fast-forwarded
      the operator's `/workspace` checkout unasked (~2026-10-17). **promoted→** rule 1 covers every
      operator checkout under `/workspace`; rewriting one needs the operator's say (2026-10-26).
- [x] second-jail-G2 — rule 2 over-applied to the hardware repo ("you can edit the hardware repo",
      2026-10-13). **promoted→** rule 2's list is homelab's records; other repos follow their own
      protocol (2026-10-26).
- [x] second-jail-G3 — invoked mid-session after an unpushed primary-seat commit; nothing handed it
      over (2026-10-13). **promoted→** "Invoked mid-session?" block: list prior writes/commits,
      finish under the old role or hand to the primary, then the rules start (2026-10-26).
