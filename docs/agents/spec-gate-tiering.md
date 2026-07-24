# Tiered spec gate — PROPOSAL (FU-094, not accepted)

**Status: proposal, 2026-07-24.** Operator: *"will consider it once I have more data and cleaned
up the specs even more."* Do not implement any part without the operator re-opening FU-094.

## The data that motivates it (meta-9, 2026-07-21→24)

~16 delegated-codeowner spec gates in 72h; **zero rejections**; one factual catch (a wrong date);
several corrections embedded in approvals. Interpretation: the gate's value has migrated
**upstream** — the ⚖ judgment calls (exclude-and-count, positional fallback, constraint
relaxation) were pre-decided at issue-authoring time, so PR-time review verifies fidelity to an
already-decided contract. Roughly half the gated diffs were purely mechanical: status-marker
flips (🚧→✓ with an issue ref), events-list syncs, provenance notes, evidence-block includes.

## The proposal (two independent legs)

### Leg 1 — classify the diff, tier the gate

A deterministic classifier (spec-gate family, CI-side) labels each spec diff:

- **mechanical** — every hunk matches a whitelist of shapes: marker flip whose referenced issue
  is CLOSED and whose evidence link resolves; events-list line addition matching an event the
  code emits (existing enum lint); provenance/date note; `<details>` evidence include; alias-only
  ID refactor (old anchor preserved). *The classifier verifies the claims, not just the shapes —
  a ✓ flip on an open issue is NOT mechanical.*
- **judgment** — anything else: decision-table row add/change/delete, ⚖-flagged prose, glossary
  changes, schema changes, new/removed requirement IDs, threshold/constant changes.

Gate: judgment diffs keep the full human/delegated-codeowner read; mechanical diffs auto-approve
on classifier-green (the reviewer bot still reviews; the rubric gains "verify the mechanical
classification is honest"). Gaming risk (semantics smuggled into mechanical-looking hunks) is
bounded by the claim-verification above plus the bot review.

### Leg 2 — derive the mechanical half out of existence (preferred long-term)

Half the mechanical diffs are status markers that "verified-ness is derived, never declared"
says shouldn't be declared at all: a 🚧/✓ state is a *function of* (issue state, evidence
presence). Rendering status from issue+evidence state at spec-site build time — instead of
hand-flipping markers in source — removes those diffs entirely, shrinking gate traffic without
touching the gate's strength. This is the same move the evidence system already made
(digest-stamped SVGs are derived; nobody hand-declares "tested ✓").

## Relation to prior art

`../../../teststuff/docs/specs-for-agentic-delivery.md` already carries `tier:` frontmatter for
risk-tiering *pages* (testbed vs IdP). This proposal tiers *diffs*, orthogonally — a
human-review-tier page would ignore the mechanical lane entirely.

## Re-open criteria (what "more data" means)

- The specs/docs tree split has landed (cleaner surface to classify).
- ~30 more gate events with the mechanical/judgment ratio measured (the classifier can run in
  report-only mode to gather exactly this without changing the gate).
- At least one incident-free month of the current gate as the baseline.
