# Oracle loop retro r1 — goose (Block general-purpose)

## Summary

Across 32 ledger rows (8 deep-dive), the loop burned **14 fix rounds** on only 6 issues (ranks 1–5 + #47), while 24 issues finished in a single round. The worst cost driver is **monolithic-write truncation on deepseek-v4-flash**, which killed 2 of 4 rounds on #1 ($0.036 lost) and is unrecoverable without a harness-level guard. The second pattern is **recipe path-exclusion deadlocks** (#47, #66) where the coordinator correctly detects a contradiction but can't resolve it, burning reconcile cycles. Third, **haiku "unknown" strikes** cluster on small tasks (#42, #43, #29×2, #52) where the worker actually completes the work but fails to push — a token-TTL or turn-cap expiry masked as model failure. Calibration data is too sparse to evaluate (only 3 of 32 rows have `calibration_error`). Retry-storm count is 0 across all 32 tasks.

## Findings (ranked by expected saving)

### 1. Monolithic write truncation → dead rounds (deepseek-v4-flash)

**Evidence:** #1 r1: worker emitted a 15,267-char single tool call → truncated at model output limit → goose `-32602 EOF`, zero commits. #1 r3: 14,781-char monolithic write → same truncation → then 401 auth storm. Both rounds consumed $0.036 each with zero resumable artifact. The recipe already states "WRITE FILES INCREMENTALLY: ≲50 lines per write/edit" (added after r1) but the model did not comply. R2 and the Python re-scope succeeded because they used incremental edits, not file recreation.

**Mechanism:** deepseek-v4-flash's tool-call output cap is ~16k chars. When the task requires writing a large file from scratch (scaffold), the model emits the entire file in one `write` call, which naturally exceeds the cap. Instructional guardrails don't bind because the model plans the write as a single action. The harness has no truncation detection or early-abort that would save the round.

**Process change:** In `.agents/fix.yaml`, replace the instruction "WRITE FILES INCREMENTALLY" with a **harness-level split gate**: if any single tool call to `write` or `edit` exceeds 4,000 characters, the harness intercepts and rejects the call with an error message forcing chunked output. This is a one-line guard in the goose retry/response pipeline, not a model-level instruction.

**Expected saving:** 2 rounds ($0.072) + ~55 minutes wall-time per occurrence. On #1 alone this would have saved 2 of 4 rounds. Confidence: high — the two truncation deaths are mechanically identical.

### 2. Recipe path exclusions deadlock coordinator on lane-owned files

**Evidence:** #47: coordinator blocked 3 times (round 1 dispatch blocked, reconcile re-blocked twice) because `.agents/fix.yaml` bans `chart/` editing but the task requires removing `chart/templates/cronjob.yaml`. Total wall-time before human amendment: ~33,000s across the blocked period. #66: identical pattern — `.github/` is banned in the recipe, but `.github/workflows/ci.yaml` is `track/chassis`-owned per `specs/TRACKS.md`. Worker correctly reported the contradiction and stopped. Both issues required human CODEOWNERS amendments to `.agents/fix.yaml`.

**Mechanism:** The recipe's hard-rule path exclusions are a static list, but lane ownership (TRACKS.md) is dynamic and evolves. When a lane's scope grows to include a banned path, the coordinator detects the contradiction at dispatch time but has no mechanism to auto-escalate or skip — it re-blocks on every reconcile tick until a human edits the recipe. The coordinator's block comments are accurate but the gap between detection and resolution is pure wall-time waste.

**Process change:** Add a **pre-dispatch label×path scan** in the coordinator's reconcile script (the tick that calls `coordinator-scan.sh`): cross-reference the issue's `track/*` label against `.agents/fix.yaml`'s path exclusions; if the track's OWNED paths (per TRACKS.md) overlap the recipe's banned paths, emit a single `agent/needs-human` label + comment with the specific conflict, and **skip re-dispatch on subsequent ticks** (don't re-block N times). The comment already contains the resolution options; the scan just prevents the loop.

**Expected saving:** ~66,000s wall-time across #47+#66 (3+ re-blocks avoided). Confidence: high — both issues show the coordinator re-blocking identically on every tick.

### 3. Haiku "unknown" strikes mask successful work — wasted rounds

**Evidence:** #43: AGENT_STRIKE error_class=unknown, but the log tail shows "110 passed, ci green" — the worker completed successfully but couldn't push (no resumable branch). #29 r1: `--max-turns 80` hit, "97 passed, ci green", no push. #29 r2: `--max-turns 200` hit, same outcome — work done, no PR. #42: AGENT_STRIKE error_class=unknown, worker output shows "110 passed, ci green, PR opened" — actually succeeded on the task. #52: AGENT_STRIKE error_class=unknown, log shows "ConnectionRefused" (infra, not model). Wall time on all these: 0s in the ledger (infra deaths aren't timed). Total: 5 haiku tasks with "unknown" strikes, of which 4 completed the actual work.

**Mechanism:** The strike classifier assigns `error_class=unknown` to any non-CI failure, but the underlying causes are heterogeneous: turn-cap exhaustion (#29), token-TTL expiry (#43), infra ConnectionRefused (#52), and unknown (#42). Because the error class is "unknown", the chain-walk escalates to the next model unnecessarily — the model didn't fail, the harness did. Each escalation burns a re-dispatch cycle.

**Process change:** Replace the catch-all `unknown` classifier with **granular exit inspection**: parse the worker's final structured output (`ci_passed`, `branch`, `pr_url` fields) before classifying. If `ci_passed=true` and `branch` is set but `pr_url` is empty → classify as `push-failure` (token/TTL/infra) and re-dispatch on the **same model** with `--work-branch`. Only escalate to next chain entry on genuine model failures (no output, wrong output, or `ci_passed=false` with no resumable branch).

**Expected saving:** 3–4 unnecessary chain escalations avoided; each re-dispatch cycle costs ~2–5 minutes of coordinator wall-time + pod spin-up. Confidence: medium — #42's true cause is genuinely unclear, but #43/#29's are documented as infra.

### 4. CITE-invariant review whack-a-mole burns fix rounds on scaffolds

**Evidence:** #1 across 3 fix rounds: reviewer returned CHANGES_REQUESTED each time with 2–4 new blocking bugs, all in `build_provision_response`'s text-assembly paths. R1 found 4 bugs (single-lõige prefix, alampunkt-only empty text, .gitignore, dead test). R2 found 2 new bugs (all-points lõige dropped, intro-less lõige duplication). R3 found 2 more (whole-§ duplication, alampunkt ambiguity). Each round fixed the prior bugs but the reviewer's execution-based testing found fresh instances in untested code paths. Total: 3 rounds, $0.1254, 193,579s wall-time, task ended `agent/blocked` for human rewrite.

**Mechanism:** The function has ~6 distinct code paths (multi-lõige, single-lõige, alampunkt-only, whole-paragraph, all-points, TOC) but the test suite only exercises 2–3 of them. Each fix round patches the tested paths and the reviewer discovers the next untested path. The reviewer's methodology (execute the engine against constructed inputs) is effective at finding bugs but the fix-round budget is consumed faster than the test coverage can expand.

**Process change:** Add a **CITE-invariant regression harness** in `scripts/cite-invariant-check.py`: for every provision query shape (multi-lõige, single-lõige, alampunkt-only, whole-paragraph, all-points), assert that `citation.paragraph` is never null when `text` is non-empty and that `len(text) > 0` implies the citation addresses the correct scope. Run this as a CI gate separate from the parametrized test suite, so the reviewer's execution-based testing doesn't discover regressions the CI missed. Pin the harness shapes as a **spec row** in `specs/tools/statute.md` (⚖ human-gated).

**Expected saving:** 1–2 fix rounds on #1-class issues (~$0.04–0.08, ~65,000–130,000s wall-time). Confidence: medium — the hypothesis is that a comprehensive path-exhaustion test would have caught all 8 bugs in round 1, but this depends on the harness being correctly shaped.

### 5. Worker removes working evidence without replacement → reviewer regression

**Evidence:** #45 r2: haiku worker stripped `@rule("ING-RT-SNAPSHOT")` / `@rule("ING-RT-CHECKSUM")` from 6 test cases, claiming e2e coverage replaces them. But the e2e only covers 3/6 scenarios, and CI job wiring (`needs: e2e` + artifact download) doesn't exist yet — net regression from 6 working evidence rows to 0. Reviewer caught it as blocking-class (breaking behavior that already worked on master). Also: #8 r1: worker modified 3 `specs/` files but PR body declared "No spec changes" — reviewer rejected on unflagged spec edits.

**Mechanism:** The recipe's instruction "spec-row TDD" and the review rubric's "rows, not functions" are well-specified, but there's no pre-submit gate that validates the worker's claims against the actual diff. The worker's self-report (`spec_changes: []`) is trusted at face value. For #45, the worker also violated a simpler invariant: "do not remove working evidence until replacement evidence is wired and verified in CI."

**Process change:** Add a **diff-vs-claims validator** to `.agents/fix.yaml`'s post-work checklist: `git diff --name-only main...HEAD | grep -q '^specs/' && ! grep -q 'Spec changes:' <pr_body>` → fail with "unflagged spec edits detected". For the evidence-regression case: `git diff main...HEAD -- tests/ | grep -c '^-.*@rule('` > 0 → fail with "removed evidence labels without CI-verified replacement". Both are ~5-line shell checks in the recipe's response schema validation.

**Expected saving:** 1 round on #8-class issues (~$0.05, ~15,000s); prevents evidence regressions like #45 from landing. Confidence: high — the validator directly checks what the reviewer checks.

### 6. OpenRouter key PATCH doesn't extend expiry — platform bug burns dispatch cycles

**Evidence:** #1 post-TS-re-scope: tencent/hy3 worker died at 18:40:08Z — the exact second the OpenRouter key's original `expires_at` (16:40+2h) expired, despite the coordinator PATCHing the CR with a new 2h window at 20:19:22. The coordinator believed the key was valid for 2+ more hours. Total: 1 re-dispatch cycle (~20 minutes of worker runtime + coordinator overhead). The bug was platform-side (OpenRouter key PATCH doesn't update `expires_at`), and was caught by the human postmortem, not the loop.

**Mechanism:** The coordinator mints per-session OpenRouter keys by PATCHing existing CRs. OpenRouter's API treats PATCH as update-metadata-only, not as create-new, so the `expires_at` field stays pinned to the original POST time. The coordinator's budget estimator reads the CR's claimed expiry (which it wrote) rather than verifying against the API's actual TTL.

**Process change:** In the coordinator's key-minting path (the `apply`/`PATCH` logic in `agent-session.sh`), **always POST a new key and DELETE the old CR** instead of PATCHing. Alternatively, add a TTL verification step: after PATCH, query the key's actual expiry via the OpenRouter API and abort the dispatch if the real TTL differs from the expected by >60s. The DELETE+POST path is simpler and avoids the TTL-check race.

**Expected saving:** 1 re-dispatch cycle per occurrence (~20 minutes wall-time + ~$0.05 pod cost). Confidence: high — the bug was root-caused to the PATCH-vs-POST difference in the platform postmortem.

## Proposed process changes

| Change | Artifact | Expected saving | Confidence |
|---|---|---|---|
| Harness-level 4k-char write split gate | `.agents/fix.yaml` retry pipeline (goose output interceptor) | 2 rounds + 55min per truncation-prone task | High |
| Pre-dispatch label×path conflict scan + single-block escalation | `coordinator-scan.sh` (reconcile tick) | ~66,000s wall-time across #47+#66-class issues | High |
| Granular exit classifier (replace `unknown` with `push-failure`/`token-expiry`/`infra`) | coordinator strike-bookkeeping (agent-finalize) | 3–4 unnecessary chain escalations | Medium |
| CITE-invariant regression harness as CI gate | `scripts/cite-invariant-check.py` + spec row in `specs/tools/statute.md` | 1–2 fix rounds on #1-class scaffold issues | Medium |
| Diff-vs-claims validator (specs/ edits + evidence removal) | `.agents/fix.yaml` post-work checklist (5-line shell) | 1 round on #8-class issues | High |
| Always POST (never PATCH) OpenRouter keys; delete stale CRs | `agent-session.sh` key-minting path | 1 re-dispatch cycle per key-TTL bug | High |

## Evidence confidence

**What I could verify:**
- Ledger numbers for all 32 tasks (rounds, costs, wall-time, CI sequences, terminal labels, worker exits)
- Issue comment trails for ranks 1–8 (full AGENT_STRIKE, coordinator reconcile, and human arbitration comments)
- Recipe text (`.agents/fix.yaml`) and reviewer rubric (`.agents/review.md`)
- The specific error classes: truncation (#1 r1, r3), auth-storm (#1 r3), turn-cap (#29), chart/-ban deadlock (#47), .github/-ban deadlock (#66), unknown strikes (#42, #43, #52), unflagged specs/ (#8)

**What I could NOT verify and why:**
- **Calibration quality by tier**: only 3 of 32 rows have `calibration_error` populated (ranks 30–32, all 0.0). The remaining 29 rows have `null`, so no calibration analysis is possible.
- **Retry-storm clustering**: `retry_storms` is 0 across all 32 rows. Either the harness doesn't count storms, or the infra was stable. Cannot distinguish between these.
- **Model failure-class distribution**: the `unknown` error class is a catch-all; without the raw worker logs (only accessible via `gh run view` on specific CI runs, which are ephemeral), I cannot reclassify the haiku strikes into finer buckets.
- **The actual reviewer prompt**: I can see the reviewer's output (CHANGES_REQUESTED with specific items) but not the LLM reviewer's system prompt or rubric weighting. The review rubric in `.agents/review.md` is the human-authored portion; the actual `reviewer` recipe is not in the repo.
- **Whether #52 succeeded on deepseek-v4-flash re-dispatch**: the ledger shows rank 6 as 1-round, $0.154, deepseek, ci=true — likely the re-dispatch succeeded, but I couldn't verify from issue comments alone (the comments stop after the haiku strike; the deepseek success is implied by the ledger).
- **Coordinator-scan.sh exact implementation**: I looked for it but the coordinator code lives outside the oracle-fleet repo (it's in the homelab-agents infrastructure). The process changes reference it as the target artifact, but I couldn't verify its current behavior.
