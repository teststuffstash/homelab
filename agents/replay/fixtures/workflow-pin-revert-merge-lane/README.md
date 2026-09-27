# workflow-pin-revert-merge-lane

Pins the two 2026-09-27 fixes to the FU-1990 chain (`agents/coordinator/deploy-revert-argo.yaml`,
the `workflow-pin-revert` WorkflowTemplate): the reverted-pins extraction (the `+` lines of the
original PR, de-duplicated) and the merge lane of the revert PR (labelled `automerge` +
`dependencies` BEFORE arming, so the renovate-approve reflex posts the one approving review the
platform repos require). Contract prose in `fixture.yaml`.

**`agents/reviewer-session.sh` in the same PR — why no fixture.** The changes are PROMPT text
(the migration-investigation block: an ARMED major is the CI-exercised blast class and the
reviewer's approve is its merge gate; a Renovate-authored PR has no fixer behind it, so a
missed-on-master call site is never a finding; the PR is read as a member of its Renovate batch;
platform facts come from the homelab clone) plus three lines of pod PREP outside every replay
seam: the best-effort shallow homelab master clone (a failed clone prints a WARN and the review
carries the TOOL_GAP), the `migration` lens selection on the `major` / `deps-review` label (the
lens file `agents/lenses/migration.md` is prose fetched at review time, like the other lenses),
and the posture pin `migration: blocking` merged into `LENS_MAP` BEFORE the
`lens-posture-handling` seam — the seam's own loop is byte-identical, so the `lens-posture`
family still pins it; the pin is a constant, not a decision. Prompt prose is LLM-facing text, not a clause with an action stream — the harness
pins what the shell does, not what the model is told. The lane split itself IS pinned: the
reflex's selector (armed, not `automerge`-labelled) is unchanged, and `c9-rearm` pins that the
reflex never arms a `major` on its own — Renovate arms the Actions majors at creation
(`.github/renovate-global.json`, ADR-141).
