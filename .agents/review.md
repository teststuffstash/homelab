# homelab review rubric (appended to the reviewer's system prompt)

This repo is the PLATFORM'S OWN -iac, and it is **public**. ArgoCD watches `argocd/`,
`agents/coordinator` and `agents/fixer`, so for those paths **a merge syncs to the live cluster
within minutes**. It is also where the agent loop's own machinery lives, which is why scope here is
judged PER PATH (`docs/agents/iac-lane.md` §The platform lane) rather than per repo.

## BLOCKING

- **A literal secret or credential value, anywhere.** References only (ExternalSecret,
  `existingSecret`, `ref:<ns>/<name>`). The repo is public; this is not a style question.
- **A diff outside the author's declared `Touches:` footprint** that lands in a governance path —
  `agents/**`, `.agents/**`, `scripts/**`, `policy/**`, `.github/**`, `tofu/github/**`, `tofu/cloudflare/**`.
  Those are the launcher, the scan, the reflex and the rulesets over them. A worker editing its own
  governor is ungated whatever the ruleset says. Block regardless of how good the change looks.
  ⚠ The ADR-097 compelled-counterpart classes are NEVER escapes and NEVER governance-blocking —
  `agents/replay/**`, top-level `agents/*-test.sh`/`agents/*-replay.sh` (not `agents/*/*`), and
  `docs/agents/*-fsm.{yaml,md}` (`agents/footprint.sh` `fp_replay_exempt` is the one predicate;
  do not re-derive an escape from the raw `Touches:` line, and do not trust a PR-body
  `Touches-escapes:` entry for these classes over the predicate — PR#893 manufactured a blocked
  round exactly that way). The FOURTH class is content-keyed, not path-keyed (addendum 3,
  homelab#944): a file whose ENTIRE diff is `# >>>REPLAY:<name>>>>` / `# <<<REPLAY:<name><<<`
  marker comments is a compelled edit (the harness extractor cannot pin a block without them)
  and is already excluded from TOUCHES-ESCAPES by `sentinel_only_paths` — do not re-derive an
  escape for it (PR#941 blocked a round exactly this way). A file with even ONE non-marker
  changed line keeps full escape/governance semantics, and the marker lines themselves are
  still ordinary review content (a sentinel-shaped line inside a heredoc/string is code).
- **A hand-edited chart or image pin** outside the deploy pipeline (ADR-084), unless the PR says
  why. `targetRevision:` and `agents/images.env` move via bump PRs.
- **A manifest that does not validate**, or a PR claiming green without saying WHICH lints ran —
  there is no single `devbox run ci` here, so "CI green" is not a meaningful claim on its own.
- **A `prune: true` Application edit that deletes a service** without its data story (PVCs,
  buckets, what happens to the objects).
- **An alert rule whose `description` asserts a CAUSE.** Descriptions state the SYMPTOM and what to
  check. A guessed cause in an alert is how a wrong diagnosis gets institutionalised — this
  platform has paid for that twice (#94, #103).
- **An edit or removal of an EXISTING replay assertion or recorded world** —
  `agents/replay/**` (worlds, `expected/actions.txt`) and the `agents/*-test.sh` behaviour pins.
  CI executes these from the PR branch, so weakening one changes what the required `ci` check
  PROVES before any human looks (#354 — the `agents/**` "authoring is not effect" rationale is
  false for exactly this subset). **Editing worlds is extraordinary**: additive rows are
  ordinary work; an edit/removal is acceptable ONLY when the same PR deliberately changes the
  pinned behaviour (the ADR-103 ratchet flow) and the body says so explicitly — an unexplained
  weakened assertion is blocking no matter how plausible the diff reads.
- **A VACUOUS pin** (retro r1 F3): a NEW replay world, `expected/actions.txt` row, or
  `agents/*-test.sh` pin that does not fail against the pre-fix source is blocking — the ratchet
  gates weakening, this gates vacuity ("additive rows are ordinary work" is not a licence for
  pins that prove nothing). The PR body shows the red run against the pre-fix source.

## In-diff findings BLOCK — fix them in THIS PR (codeowner economics, operator 2026-08-12)

A correctness or robustness finding the PR's own branch can absorb — a state leak, a fail-open
guard, a parser divergence, a missing edge-case the diff itself introduces — is
**CHANGES_REQUESTED**, never a follow-up. The author (seat or fixer round) pushes the fix, you
re-review; convergence is bounded by the round machinery. Why this repo differs from the stack
rubrics: master here IS the platform (merge = deploy), a follow-up costs a whole extra PR cycle,
and on the operator lane the `Follow-ups:` channel has NO machine harvester — deferral here is a
lossy channel to the most expensive resource there is (the codeowner's read time). "PR better
than master" almost never favours deferring an in-diff defect when master is load-bearing.

## NOT blocking — follow-ups, sparingly

Genuinely NEW scoped work only: a finding whose fix would materially grow the diff or leave the
PR's declared footprint — real work, filed as work (during a Goal it lands in the goal's findings
pile, never a 1:1 issue). Pure style (naming, comment polish) may stay a comment with no bullet
at all. What no longer qualifies as a follow-up: anything the branch could have fixed.

## Judge these carefully rather than by rule

- **`manifest-lint` SKIPS CRs it has no schema for** (Applications, AgentStacks,
  CiliumNetworkPolicies). PrometheusRules left this class 2026-08-11: `devbox run
  prometheus-rules-lint` (promtool, in `ci`) parses every expr — demand that check green
  instead. A PR whose whole diff is one of those kinds passed a
  validator that checked *nothing*. That is acceptable if the author SAYS so and describes what
  they did instead; it is not acceptable dressed up as "CI green".
- **Documentation is load-bearing here.** `docs/` carries the FU tracker, the ADRs and the incident
  record — the things the next session reads as ground truth. A doc change that contradicts what
  shipped is a real defect, not a nit. `docs/follow-ups.md` is single-writer (operator/meta): a
  worker appending to it is blocking.
- **Path tier decides who merges, and the PR should say so.** Tier 1 (`argocd/resources/**`) merges
  on CI; `argocd/platform/**`, `tofu/`, `ansible/`, `opnsense/`, `machines/`, **and `docs/`**
  (CODEOWNERS `/docs/` since 2026-08-04 — the platform's memory) need a human. If the
  diff needs a human and the body does not say it, that is a follow-up — someone will otherwise
  wait in silence for an auto-merge that cannot come.

Greenfield bias does NOT apply here: this repo is prod-serving and public. But "better than master"
still wins over "perfect" for a change that is contained, validated, and inside its tier.
