# 2026-09-02 — GitHub 401-throttles anonymous git from the WAN IP; the oracle loop is down ~4h through one unfixed clone site

**Impact:** every oracle coordinator item session failed at its PREP clone from ~09:15Z to
~13:05Z (issues 345/347/348/362 + the coordinate ticks that raced token gaps); oracle-fleet
PR#351's CI evidence step failed twice on the same class. No data loss; work queued, nothing
wrong was merged. Secondary casualty: fleet#345 sat in the C4/C5 silent-stall limbo (below).

## Timeline (UTC)

- **~09:10–09:50** — the ADR-121 morning: mirror-ghcr burned ~25GB of failed 6.4GB corpus
  pulls against ghcr (three `PROTOCOL_ERROR` laps, homelab#1282 recurrence; separate incident
  arc, fixed by ADR-121 same day).
- **~09:15** — first coordinate-perstack workflows fail. Root signal (established later):
  GitHub starts answering **anonymous `POST git-upload-pack` with 401** for the WAN IP —
  IP-wide (reproduced against `torvalds/linux`), while `GET info/refs` stays 200. git surfaces
  it as `could not read Username` + `expected flush after ref listing`, exit 128.
- **09:35** — fleet#345's worker r1 dies (`AGENT_STRIKE error_class=rate-limit`) — unrelated
  model rate-limit, but the label stays `agent/in-progress`.
- **~10:0x–10:45** — seat probes establish the throttle (jail curl/git discriminators;
  evidence comment on fleet PR#351). ⚠ the comment claims "loop pods unaffected" — wrong, see
  root cause 2.
- **10:x–13:0x** — oracle item pods fail at `Cloning into '/work/homelab'` repeatedly; each
  half-hourly tick's anonymous retry plausibly RE-TRIPS the throttle (it never decays).
- **12:5x** — operator points at #345; seat pulls the thread → the failing pods' logs name the
  clone; the wf clone sites are found already hardened (homelab#1136, the 2026-08-31 incident:
  47 failed workflows, same class) — `coordinator-session.sh`'s PREP clone is the ONE site
  #1136 missed.
- **13:0x** — fix pushed (`46c079cb`): the #1136 token-in-URL pattern in PREP (GH_TOKEN is
  exported by LOOP_FETCH immediately before — it was always present, just unused by bare git).
  fleet#345 re-queued with an audit comment.

## Root causes

1. **External:** GitHub's per-IP anonymous-git throttle (401 on upload-pack). Whether the
   morning's ghcr storm tripped it is unproven (those pulls were authenticated via the FU-196
   v0 PAT); once tripped, the loop's own anonymous retries every 30 min kept it tripped.
2. **Ours:** one anonymous clone site survived #1136 — the launcher PREP in
   `coordinator-session.sh` (the wf manifests were fixed; the script the wf dispatches was
   not). Single-site fixes to a repeated idiom rot; the idiom needed a sweep, not a patch.
3. **Amplifier:** the C4/C5 stall belt's conservative bare-mention exclusion — assembly PR#346
   bare-mentions #345, so the belt could neither re-queue it nor flip it to review. Documented
   limbo, first live sighting.

## What held

- The #1136-fixed wf clones (authenticated) kept SUCCEEDING whenever GH_TOKEN minted — which
  is also the healing path: master's fixed script reaches item pods through the wf's own
  authenticated clone.
- Worker/reviewer rides: authenticated by the agent-base credential helper throughout.
- Rule #6 discipline: no belt failed INTO a write.

## Residuals

- **The bare-mention limbo** (root cause 3): an `agent/in-progress` issue bare-mentioned by
  any open PR is invisible to both the stall wake and the review flip — needs a design ruling
  (wake with a distinguishing marker? age-bound the exclusion?). → filed as the next
  fu-sweep/board item; first sighting evidence is #345's timeline.
- ~~Anonymous-idiom sweep~~ **EXECUTED same day** (`0c6d00f7`): the per-stack CronWorkflows are
  **composition-rendered**, so #1136 never reached them — FOUR more anonymous sites in
  `argocd/resources/agentstack/composition.yaml` (coordinate/review/janitor with GH_TOKEN one
  line above; the prober with no token at all → soft broker fetch added). Found because ticks
  KEPT failing after the `46c079cb` launcher fix — root cause 2 restated: the idiom lived in
  three homes (wf files, launcher, composition) and each got fixed only when it burned.
  `agent-session.sh`'s context clones remain helper-covered in-pod.
- My PR#351 comment's wrong claim is corrected on-thread (asks-are-claims applies to the seat's
  own assertions — the design-agents-G1 class, self-caught late).

## Recurrence 2026-09-03 — and this time AUTHENTICATED clones are throttled too

**Timeline (UTC):** ~07:25 first exit-128s (review-perstack, review, switchboard, ledger-reflex,
update-pr-branch-cron, coordinate-perstack); by 08:00 every workflow that clones master fails
(argo, 3h window: 07h 7 failed / 38 ok → 08h 10 failed / 0 ok). Seat noticed via a PR re-review
that never came (#1329, head green at 07:40), then `argo list -A`.

**Evidence (seat probes, 07:5x–08:2x):**
- In-cluster pod, the loop's exact flow (`agentstack-loop` SA → broker `/loop-git-token` →
  `x-access-token:` clone): broker serves (TokenReview ok, 390-char token), clone fails —
  `fatal: remote error: GitHub is temporarily limiting some unauthenticated downloads to protect
  the stability of the platform. Please retry later or authenticate.`
- Jail, same WAN IP, fine-grained PAT (credential helper AND `x-access-token:` URL form): the
  SAME message. Anonymous `ls-remote` of `torvalds/linux`: same. → **IP-wide, and the message's
  "unauthenticated" is misleading: authenticated upload-pack is refused too.** (Yesterday's
  "what held" — authenticated clones kept succeeding — does NOT hold today.)
- `api.github.com` 200, `github.com` 200, `gh` API calls fine (core 5000/5000); **the API tarball
  path works, authenticated AND anonymous** (`GET repos/…/tarball/master` → 302 codeload → 200,
  3.4 MB). Only git's `upload-pack` is throttled.
- Not our token, not the broker, not GitHub status (All Systems Operational).

**Consequences:** the loop is fully down (no coordinate/review/reflex can clone); the bot
reviewer cannot re-review → the PR lane is closed for the duration; only the seat's direct lane
and the API work. #1329 (the #1315 gate) sits at a stale CHANGES_REQUESTED with CI green.

**Mitigation options (operator decision — none executed by the seat):**
1. Wait for decay. Yesterday it held ~4h while the loop kept retrying every 30 min.
2. Suspend the clone-heavy CronWorkflows (`argo cron suspend`) for a cooldown so the throttle
   can decay, then resume — reversible, direct-lane-shaped.
3. Replace the `git clone --depth 1 -b master` idiom with the API tarball (`gh api
   repos/…/tarball/master | tar xz`) — proven to bypass the throttle today, but the idiom
   lives in three homes (wf manifests, launcher PREP, composition — root cause 2 of this
   record) and FU-007's push-mirror is the designed direction; a fourth mechanism is a design
   ruling, not a quickfix.

**Open question:** what trips it. ~700 authenticated clones/day is the steady state that was
fine until 2026-09-02; the two trips are ~09:15 (09-02) and ~07:25 (09-03). The seat's four
`workflow_dispatch` CI runs + three PR runs in 06:45–07:20 precede today's trip, but seven
`actions/checkout`s are noise against the loop's volume — unproven either way.

**Decay + root cause of the recurrence (settled 08:1x–08:2x):** authenticated clones worked
again from ~08:10 (jail PAT, the coordinator-git token, the broker token from a loop pod — all
three); anonymous stayed refused with yesterday's `expected flush after ref listing`. #1329
re-reviewed and merged at 08:18. **Why an "authenticated" loop trips an anonymous throttle**
(`GIT_TRACE_CURL` on a token-in-URL clone of a public repo): git sends credentials only after a
401 challenge, and the refs GET of a public repo answers 200 anonymously — so every clone was
`GET info/refs` (anonymous, 200) → `POST git-upload-pack` (anonymous, **401**) → the same POST
again with Basic auth (200). Two anonymous requests per clone, ~700 clones/day ⇒ the loop itself
supplied ~30 anonymous upload-pack hits per hour to the per-IP counter, all day, and the "401
retry" is exactly the request GitHub started refusing outright during the 07:25–08:10 window.
**Fix (the header sweep, same day):** `git clone -c "http.extraHeader=Authorization: Basic
<base64 x-access-token:TOKEN>" https://github.com/…` — the `actions/checkout` pattern: the
credential rides the FIRST request (trace: no 401 round trip at all), and `clone -c` persists
it in the clone's config so later fetch/push stay authenticated with a plain remote URL. Applied
to every clone site the two earlier sweeps had touched (14 wf-manifest blocks, deploy-revert's
iac clone, retro's report push, the composition's three clones + the prober's two, the launcher
PREP, `scripts/devbox-update.sh`) and pinned by the `deploy-revert-token-clone` replay family.
Residual: worker rides authenticate through the agent-base credential helper, which is
challenge-based too — same anonymous-first shape, far lower volume; a per-URL
`http.<url>.extraHeader` in the ride's git config would close it if it ever shows up in the
counts. What is NOT known: GitHub's threshold, and whether zero anonymous requests keeps the
address clear — the first full day after the sweep answers that (FU-007's push-mirror is the
structural answer if it does not).
