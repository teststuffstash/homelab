# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Live world state (2026-08-02 ~20:35Z, overnight build-out session — operator asleep)

- **World ENABLED**, all cron/doorbell/review machinery green. Sleep chain = mimo-first (claim
  + stacks.json both, after the chain-source drift fix — brief now reads the CLUSTER claim).
- **In flight, machinery-owned (verify on wake-ups):** sleep #109 (fix for #103, arrived
  `armed_by_pod=true` — FU-123 acceptance MET, archived) + #110 (recipe rule) both armed →
  merges + #103's C6 flip to verify. snore-recorder#15 fix round = the FIRST snore worker ride
  (reviewer correctly caught my stale CLAUDE.md/README pointers). oracle-iac#97 = the FIRST
  oracle-iac ride (probe armed). oracle-fleet#166 (build+research port) + #167 (G07
  pin-follow) armed. sleep-iac#57 merged (snore fixer live, render verified).
  **#105 dispatches next WIP-free tick = the FIRST mimo ride** (watch its estimator + pin).
- **OPERATOR STEP PENDING:** `devbox run github-tofu apply` (deploy_repos += snore-recorder;
  committed; org-admin wallet is host-side). Until then snore's deploy-pin job fails
  loud-but-harmless. Also pending: mimo `model_tiers` entry at the next proxy-roll window;
  soak watch on `router_request_deadline_exceeded_total` (stay 0 on healthy rides).
- ✅ homelab#22 CLOSED (proxy deadline/gauge/generation_ms/activeDeadlineSeconds live).
  ✅ oracle-iac fixer lane LIVE (#262 + ns render). ✅ FU-114 L3 (task class in dispatch
  units). ✅ IAC-G07 (pin-follow rides the bump commit, pin-hold opt-out). ✅ FU-126 platform
  legs (research-fanout.sh + branch-slug rules). ✅ FU-051 built (wallet apply = the residue).

## Standing / parked (compressed — detail in TICK-LOG or the FU)

- ⚠ **IAC-G01 exposure widens** with the two new fixer lanes (oracle-iac + snore) — G04
  sentinel is the next -iac priority (iac-lane.md build order + reprioritization note).
- **review.yaml on sleep-tracking = vestigial-suspect** (pre-subscription goose reviewer;
  deliberately NOT ported to oracle) — drift-role judgment case, decide keep/delete.
- Open session FUs: **FU-124** (last-open-PR BEHIND → unreliable cron is the sole updater
  backstop; watch clause: armed PR BEHIND >15min).

- **FU-117** (context architecture) — DELIBERATE let-it-pile-up (operator's grow-then-refactor).
  Note sightings; don't refactor yet.
- **Dep-gate fragility**: a markdown-bullet `- Depends-on:` slips the `^[ \t]*depends-on:` scan
  regex. Write Depends-on lines UNBULLETED until FU-111 (native `blockedBy`) lands.
- Worker git tokens CAN push `.github/workflows/*` (homelab-agents App has `workflows:write`, proven
  PR#80). Workflow-only issues ARE worker-doable. Branch-protection RULE edits stay repo-admin/tofu.
- **FU-058 retro-session** deployed SUSPENDED (hand-fire). **Oracle/UC-1** operator-paced (its lane).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch (`bash agents/meta-watch-loop.sh`, persistent) + 2h backstop heartbeat (each sweep runs
  `agents/meta-alert-crosscheck.sh`). Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
