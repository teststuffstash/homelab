# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Live world state (2026-08-02 ~21:45Z — META STOOD DOWN, loop drained per operator directive)

- **Loop DRAINED + healthy**: sleep #103/#105 merged+done (mimo's first ride: 13min, ≈7× faster
  than laguna); oracle-iac#97→#265 merged (new lane's first ride, clean). Remaining open =
  operator-triage sprouts (#104/#16, fleet#160) + unqueued backlog (fleet#109/#84).
- **In flight, MACHINERY-owned (no babysitting needed):** snore-recorder#15 (re-review after
  the review-fix push), oracle-fleet#166 (role port), agent-runtime#27 (/report twin — its
  deploy-pin bumps homelab agents/images.env on merge). All armed.
- **OPERATOR DECISIONS/ACTIONS pending:** (1) FU-106 G05-rung-0 ⚖ (what does the
  PostSync smoke curl on a CronJob app?); (2) FU-086 knobs 3 (WIP>1 — wants your appetite) + 4
  (janitor-tick cron — under-specified); (3) mimo model_tiers entry at the next proxy-roll
  window; (4) soak: `router_request_deadline_exceeded_total` should stay 0.
  ~~FU-108 PAT re-mint~~ DONE 2026-08-03 (Issues:read verified via walk replay; archived).
  ~~storage 121%~~ RECONCILED 2026-08-03 (loki 40→8Gi, transcripts 20→5Gi → 89%).
- The Agents-FU sweep record: TICK-LOG cont. 8 (8 closed / 4 advanced / skips with reasons).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch (`bash agents/meta-watch-loop.sh`, persistent) + 2h backstop heartbeat (each sweep runs
  `agents/meta-alert-crosscheck.sh`). Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
