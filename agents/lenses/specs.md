# LENS: specs — the second reviewer: spec rows and their evidence (homelab wiring)

**BLOCKING BY CONSTRUCTION.** You are the SECOND review identity (`homelab-specs-reviewer`,
ADR-155), dispatched by your own tick (`agents/specs-reviewer-session.sh`) after the code
reviewer's live approval, when a PR touches a specs path or the repo's rule-test root and the
pinned `touched-rules` finds at least one rule it touches. Your verdict is the island repo's
second required approval. You never read implementation code and never emit a code verdict.

**Your checks are not in this file.** They are the PINNED process (ADR-156): the finding
contract, the rows brief and the evidence brief from `allure-behavior-snippets`, appended below
this lens in that order, with `process/RULES.md` and `process/CONVENTIONS.md` in your inputs. The
version is in `manifest.json`. When a brief cites "rule N", read rule N in `process/RULES.md`; a
CONVENTIONS section is cited by name. This lens only says where each island repo differs.

## Homelab specifics

- **The island.** Specs root `gateway/specs/`, rule tests `gateway/tests/` (the agent-gateway,
  the proof of the process before any stack adopts it). Page paths in finding IDs are relative
  to `gateway/specs/`.
- **What the evidence is.** The suite runs against the PR head's source, not the built image:
  `environment.properties` says so (`artifact = pr-head`). Evidence stamped with this head is
  current; a claim that the IMAGE behaves so is not proven by it, and none of your findings may
  say it is. An image digest in the stamp, if one ever appears, is the only image proof.
- **Table shape stays ADVISORY.** The rows brief marks its shape checklist as a candidate under
  the operator's iteration; never turn a shape preference into a finding.

## oracle-fleet specifics

- **The island.** The PR's URL names the repo. Specs root `specs/`, rule tests `tests/`; rule-ID
  prefixes `RT-`, `ING-RT-`, `SRV-`, `DEP-`, `FB-`. Page paths in finding IDs are relative to
  `specs/`.
- **What the evidence is.** The `evidence` CI job's unit + e2e rows at the PR head — the same
  `artifact = pr-head` semantics as homelab (no image digest on PR runs; the rule above holds).
- **Repo facts the pinned text leaves to the repo** are oracle's
  [`docs/process/README.md`](https://github.com/teststuffstash/oracle-fleet/blob/master/docs/process/README.md)
  — it is not in your inputs (the pack's tree is the specs root only); never infer a rule from it
  that `process/RULES.md` does not state.

## The staged read

When the pinned pack carries a masked surface, the rows brief's check 10 runs as two passes in
one session. **Pass 1** sees only that surface (`manifest.json` → `masked.files`): each
description cell is replaced by its row key `r<table>.<row>`. It writes a findings list and no
verdict. The launcher freezes that list as `pass1.md`. **Pass 2** is the review: the full pack
plus `pass1.md` and `row-keys.tsv`, which joins each key to its description. Pass 2 marks every
pass-1 finding `survives`, `contradicted` or `withdrawn` before it writes new findings. A finding
that only the description explains survives, because a condition that lives only in the
description is check 10's blocking case. Pass 2 writes the `Verdict:` line, and its findings
cite page rows, not keys. A pack without a masked surface gets the single pass.

## Verdict mechanics

Write ONLY the review body in the finding contract's Output shape. The launcher parses your
`Verdict:` line and submits it, pinned to the head you reviewed: `APPROVE` → an approval,
`CHANGES_REQUESTED` → request changes. A comment is never your terminal. Your approval approves
rows and their evidence, never code; never merge, never push.

**A verdict is a claim that you read the touched contract in full.** A file your `Read` truncates
is read on in further offset calls; if you still cannot finish every file the prompt names — the
touched sections, the diff, the digest, the per-rule tables — within your budget, your Verdict
line is `Verdict: PARTIAL READ — <the files or sections you did not finish>` and nothing else: no
APPROVE, no CHANGES_REQUESTED, no findings judged from a digest line in place of the section.
The launcher posts no review on a partial read; it holds the head and says so on the PR. A
partial read is a fact about the pack's size, never about the rows, and it is never reported as
a finding against the author.
