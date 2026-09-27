# workflow-pin-revert-merge-lane

Pins the two 2026-09-27 fixes to the FU-1990 chain (`agents/coordinator/deploy-revert-argo.yaml`,
the `workflow-pin-revert` WorkflowTemplate): the reverted-pins extraction (the `+` lines of the
original PR, de-duplicated) and the merge lane of the revert PR (labelled `automerge` +
`dependencies` BEFORE arming, so the renovate-approve reflex posts the one approving review the
platform repos require). Contract prose in `fixture.yaml`.

**`agents/reviewer-session.sh` in the same PR — why no fixture.** The change is one sentence of
the reviewer's PROMPT (the migration-investigation verdict line: an ARMED major is the
CI-exercised blast class and the reviewer's approve is its merge gate; an un-armed major stays
human-gated). Prompt prose is LLM-facing text, not a clause with an action stream — the harness
pins what the shell does, not what the model is told. The lane split itself IS pinned: the
reflex's selector (armed, not `automerge`-labelled) is unchanged, and `c9-rearm` pins that the
reflex never arms a `major` on its own — Renovate arms the Actions majors at creation
(`.github/renovate-global.json`, ADR-141).
