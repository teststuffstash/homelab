# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Fresh-session pickup (2026-08-03)

- **The circles chainless-pilot bootstrap — steps 1-4 DONE 2026-08-03** (plan:
  `/workspace/life/documents/circles-of-happiness/others-view-plan.md` §"P-1/P0 session order").
  `stack-lint circles` GREEN; claim Ready (chainless, claudeTier); specs/fixture seed + goal
  issue circles#1 pushed; FU-126 fan-out DISPATCHED on 4 arms (claude/opus, kimi-k3,
  deepseek-0731 xs-cap, mimo-v2.5-pro — the last two rode ESCALATE-approved under the $2 top
  cap). **NEXT: operator cherry-picks the four un-armed, reviewer-approved
  `research/issue-1-*` PRs — circles#3 (opus) / #4 (kimi-k3) / #2 (deepseek-0731) / #5
  (mimo-v2.5-pro)** — lands the seed through the human gate → step 5 merge-path proof (one
  trivial PR E2E) → step 6 tandem lanes (operator leaning: ⚖ RENDER-TECH via N-way PoC spike
  issues; search-shaped gaps route task/research to the claude rail — awaiting ruling).
- **kimi-k3 arm cost autopsy (2026-08-04, from OpenRouter's activity export — feeds the arm
  comparison, not an action):** **$4.328 total**, Moonshot AI first-party, 56 calls, 2.95M prompt
  / 89.4k output (55% reasoning), **73.6% cache hit** billed correctly at $0.30/M (caching saved
  $5.87 — uncached this was $10.20). Two legs: r1 $2.2894 (25 calls, 18:24–18:46, budget-403 after
  banking `24c3f94` = 45% of the specs) + r2 $2.0386 (31 calls, **fresh context on the salvaged
  branch** — identical 5,769-token opening prompt, no transcript carry-over). **The cap cost ~$0:**
  re-orientation was $0.39, offset by ~$0.40 of cache reads saved by restarting at a 29k context
  instead of continuing at 104k — one uninterrupted run models to ≈$4.4. Cost driver is token
  volume × $3/$15, not the restart; the real lever is `reasoning_effort` (49.2k reasoning tokens =
  $0.74, incl. a 432s/16.2k-token think that wrote nothing). Ledger gap → FU-131.
- **Platform lane is LIVE — homelab is gated, not yet a fixer target.** Shipped 2026-08-04 and
  applied: CODEOWNERS path tiers + `require_approval`/`require_code_owner_review` (ruleset created),
  homelab in the platform claim as CONTEXT-ONLY (reviewer coverage, claim-owned labels, no dispatch),
  `labels.tf` retired, `agent-read-app`/`agent-read-infra` ClusterRoles (responder can finally read
  `events` — the #94 wrong-diagnosis cause), CI gained `manifest-lint` + `pin-only-lint`, and the
  responder gained a self-referential gate + the FU-133 resolve leg (`send_resolved` now true).
  **FU-068 is DONE + ARCHIVED 2026-08-05** — the fixer block landed (guardrail `none`, egress
  enforced, `claudeTier: false` per the FU-134 ruling) and the App-install CLICK is verified live
  (`agent-git-homelab` + `loop-{git,reviewer-git}-platform` SecretSynced; an uninstalled App 422s
  the generator). **NEXT, in order:** (1) FU-133's correlation half (`subject:` key); (2) extend the
  IAC-G04 sentinel to homelab so tier 1 (`argocd/resources/`) can drop back to unowned — the
  CODEOWNERS line says to delete itself, now tracked as a FU-106 next-action. Tiers + rulings:
  `docs/agents/iac-lane.md` §The platform lane. ⚠ agent-runtime#29 (watchdog) is open + un-armed.
- **Phases 0-2 of the alert→auto-fix plan are DONE and applied; Phase 3 is next and untouched.**
  Live now: CODEOWNERS path tiers + `require_approval`/code-owner review, homelab as a fixer target
  (claim + ns + worker RBAC + apiserver egress), `manifest-lint`/`pin-only-lint`, the responder's
  self-referential gate, resolve leg (`send_resolved`), `Touches:` emission, `selfQueue`,
  `subject:` correlation and the IAC-G10 window hand-off. An alert can now reach a merged-blocked
  PR with no human; the merge itself still needs a code owner everywhere that matters.
  **Phase 3 — all three legs landed 2026-08-04.**
  (3.1) **The ArgoCD lever is COMPLETE** (FU-136 archived): metrics-server, kube-prometheus-stack,
  forgejo and garage are all ArgoCD Applications. tofu class 4 is down to cilium/longhorn/argo-cd
  (≈ADR-005 substrate), and **alert rules are an ordinary GitOps PR** — that was the point.
  (3.2) FU-012 — **3 of 5 roots migrated** (cloudflare/provisioning/infisical, encrypted, each
  verified with the local file deleted against a pre-move baseline). **Garage v2.3.0 does not
  enforce conditional writes (measured 20/20)** → `use_lockfile = false`: fine at one writer, a
  hard block on any automated applier. ⚠ `main` stays local until it has an out-of-cone state copy;
  `github` is host-only. Ruling + cone table: `docs/tofu-state.md`.
  (3.3) FU-044's scoped revert — homelab passes the source guard behind a pin-only predicate
  (IAC-G09), unit-exercised on 5 diffs, **never fired for real**.
  **What Phase 3 did NOT buy, contra the original estimate:** the lever reaches #51
  (`tofu/monitoring.tf`) but NOT #94 (`tofu/longhorn.tf`, ADR-005 substrate) or the OOM family
  (`tofu/metal.tf`, node definitions) — those need the out-of-cluster applier, which is blocked on
  real state locking. Re-count the tier arithmetic before relying on it.
  **Three things now wait on a first real event**: the `subject:` key, `Touches:`, and the homelab
  revert path. All three are cheaper to watch than to build on.
  ⚠ **Garage has no offsite backup (FU-137)** — a local count-verified copy in `backups/garage/` is
  the only restore path, and it is now load-bearing for tofu state too.
- **Pre-launch bug sweep DONE 2026-08-05** (before the next stack gets workers + iac + a goal).
  Archived: FU-068, FU-120, FU-128, FU-132, FU-138, FU-139. Part-shipped and re-scoped: FU-127
  (parser landed, structured claim field left), FU-130 (three PRs open: circles#15,
  sleep-tracking#115, agent-runtime#30), FU-131 (backoff+metric landed, T+1 activity sweep left),
  FU-134 (`POST /search` live, watch a real goose ride use it).
  **Two findings that outlived their fixes:** (1) making guardrails real (FU-138) exposed
  `only-free` claims on PAID chains — oracle-fleet fixed via oracle-iac#271, **openrouter-operator
  still declares only-free with a paid stack chain, which 403s every ride pre-spend: an operator
  policy call, and `stack-lint` KEY-02 fails on it until decided**; (2) the four per-stack loop
  transcripts PVCs are covered only by the session exit trap, NOT by a nightly crash-net —
  `transcripts-sync` is agent-coordinator-only. Verified harmless this time (267/267 files were in
  Garage) but a per-stack sync does not exist. **NEXT:** merge the three FU-130 PRs, decide
  openrouter-operator's guardrail, then launch.
- **Soak watches, not actions** (each gates a later operator flip): iac-sentinel shadow
  violations (→ G01 enforcement flip, FU-106), router shadow decisions + capability-floor skips
  (→ P4 flip, FU-095), native blockedBy edges in scan logs (→ FU-111 body-line retirement),
  Monday 05:00 retro fire (= FU-058 run 3) + the first 05:47 janitor ticks.

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch (`bash agents/meta-watch-loop.sh`, persistent) + 2h backstop heartbeat (each sweep runs
  `agents/meta-alert-crosscheck.sh`). Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
