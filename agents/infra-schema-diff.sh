#!/bin/sh
# infra-schema-diff — the FU-106 infra-fixer role's DETERMINISTIC detector: the typed infra
# delta between two chart versions' values.schema.json. The contract/fulfillment split
# (platform-and-stacks.md §Composition axes, 4th bullet) makes the schema diff the ONE signal
# an -iac wrapper must react to: a NEW REQUIRED value (case (c) in FU-106's rollout matrix) has
# no default the chart can supply — the bump PR must be ENRICHED with fulfillment or it wedges
# at deploy. New optional values (case (b)) are informational; removals feed the
# expand/contract debt timer (case (d)).
#
#   agents/infra-schema-diff.sh <old-values.schema.json> <new-values.schema.json>
#
# Output: one JSON object on stdout —
#   { "new_required": [...], "removed_required": [...],
#     "new_properties": [...], "removed_properties": [...], "enrichment_needed": bool }
# Property paths are dotted (a.b.c), recursing JSON-Schema object nesting. POSIX sh + jq only
# (dash-safe — devbox run runs scripts under dash), so the coordinator scan can source or exec
# it as-is; consumers: the future scan infra clause dispatches ONE infra unit per -iac target
# when enrichment_needed is true. No callers yet (FU-106 remaining leg).
set -eu

OLD="${1:?usage: infra-schema-diff <old-values.schema.json> <new-values.schema.json>}"
NEW="${2:?usage: infra-schema-diff <old-values.schema.json> <new-values.schema.json>}"
[ -f "$OLD" ] || { echo "ERROR: $OLD not found" >&2; exit 2; }
[ -f "$NEW" ] || { echo "ERROR: $NEW not found" >&2; exit 2; }

# One jq program computes both sides: flatten (path, required?) pairs out of nested
# object-schemas, then set-diff old vs new.
jq -n --slurpfile old "$OLD" --slurpfile new "$NEW" '
  # walk an object-schema, emitting {path, required} for every property leaf/node
  def flatten_props($prefix):
    (.properties // {}) | to_entries[] as $e
    | ($prefix + [$e.key]) as $p
    | {path: ($p | join(".")), node: $e.value}
    , ($e.value | select(type == "object") | flatten_props($p));
  def props($s): [$s | flatten_props([]) | .path];
  # required paths: each schema level lists its OWN required keys
  def flatten_req($prefix):
    ((.required // [])[] as $r | ($prefix + [$r]) | join("."))
    , ((.properties // {}) | to_entries[] as $e
       | $e.value | select(type == "object") | flatten_req($prefix + [$e.key]));
  def reqs($s): [$s | flatten_req([])];
  (props($old[0])) as $po | (props($new[0])) as $pn
  | (reqs($old[0]))  as $ro | (reqs($new[0]))  as $rn
  | {
      new_required:       ($rn - $ro),
      removed_required:   ($ro - $rn),
      new_properties:     ($pn - $po),
      removed_properties: ($po - $pn),
      enrichment_needed:  (($rn - $ro) | length > 0)
    }'
