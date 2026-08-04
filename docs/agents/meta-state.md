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
  **NEXT, in order:** (1) homelab's `fixer:` block in the claim — it creates the per-repo ns the
  worker's `agent-read-infra` RoleBinding needs; use the -iac model chain, NOT `claudeTier` (FU-134
  ruling: web research must be platform-wide, not harness luck); (2) FU-133's correlation half
  (`subject:` key); (3) extend the IAC-G04 sentinel to homelab so tier 1 (`argocd/resources/`) can
  drop back to unowned — the CODEOWNERS line says to delete itself. Tiers + rulings:
  `docs/agents/iac-lane.md` §The platform lane. ⚠ agent-runtime#29 (watchdog) is open + un-armed.
- **Phases 0-2 of the alert→auto-fix plan are DONE and applied; Phase 3 is next and untouched.**
  Live now: CODEOWNERS path tiers + `require_approval`/code-owner review, homelab as a fixer target
  (claim + ns + worker RBAC + apiserver egress), `manifest-lint`/`pin-only-lint`, the responder's
  self-referential gate, resolve leg (`send_resolved`), `Touches:` emission, `selfQueue`,
  `subject:` correlation and the IAC-G10 window hand-off. An alert can now reach a merged-blocked
  PR with no human; the merge itself still needs a code owner everywhere that matters.
  **Phase 3:** (3.1) the ArgoCD lever — **release 1 of 4 DONE 2026-08-04**: metrics-server adopted
  clean, ArgoCD-adopts-a-tofu-release settled (it templates, it never installs; names agree by
  construction). The other three are **blocked and now tracked as FU-136** — each injects a secret
  through Helm values and the destination repo is public, so each needs a preparatory
  value→Secret-reference apply first. Do NOT resume 3.1 by "just repeating" release 1; the shape
  changed. (3.2) FU-012 — no machine yet, write the backend + migration scripts anyway; the
  operator merges/applies by hand. (3.3) FU-044's scoped revert for the reversible class
  (first-party image pins only — ruling in `iac-lane.md`).
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
