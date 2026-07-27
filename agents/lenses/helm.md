# LENS: helm — chart packaging & templating practice (FU-101)

**ADVISORY LENS.** Findings from this lens are ALWAYS `Follow-ups:` bullets prefixed
`LENS(helm):` — they NEVER change your verdict (per-stack claim knob graduates to blocking).
Apply only to the chart files this PR touches.

**Source (pinned):** [Helm — Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
(pin: Helm v4 docs @ 2026-07). A new Helm major = a re-baseline issue.

For the `chart/` files touched by this diff, check:

## Values & schema
- New values appear in `values.yaml` with a sane default AND in `values.schema.json` when the
  chart ships one — a required-but-undefaulted value is a typed infra delta the consuming `-iac`
  wrapper must fulfill in the SAME deploy (this repo's platform treats the schema diff as the
  infra-fixer dispatch signal, FU-106). Flag any new required value without a schema entry.
- Values names: camelCase, flat-over-clever nesting, booleans default-off for optional
  subsystems (`<feature>.enabled: false` — the ertMock/mcpServer precedent).
- The chart stays **target-agnostic**: no Crossplane claims, ExternalSecrets, or
  platform-specific CRDs rendered by default — consumption contract only (`existingSecret`,
  endpoint values, default-off ecosystem-standard flags). Platform fulfillment belongs to the
  `-iac` wrapper chart (platform-and-stacks.md §Composition axes, 4th bullet).

## Templates
- `helpers.tpl` names namespaced (`<chart>.fullname` pattern); labels via the standard
  `app.kubernetes.io/*` set rendered from one helper, not hand-copied per template.
- Render guards fail LOUDLY on invalid combinations (`required`, `fail`) rather than emitting
  broken manifests — and each guard has a decision-table render test row (the
  `tests/test_chart_*.py` convention; a guard without a red-case row is unverified).
- No `Values` reached without defaults deep in optional blocks (`with`/`default` discipline) —
  a nil-pointer render on an optional block is the classic drive-by break.
- Immutable fields (StatefulSet `volumeClaimTemplates`, Service `clusterIP`) not templated from
  values that can drift — an upgrade that mutates them wedges the release.

## Versioning & release
- `Chart.yaml` version bumps ride the deploy pipeline (chart version == appVersion == image tag
  here, ADR-084) — flag hand-edited versions that fight the pipeline.
- Chart dependencies pinned exact (no ranges); vendored charts carry their upstream version in
  the dir (the garage v2.3.0 precedent).
