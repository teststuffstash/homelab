# The condition: a SINGLE-pair claim (the oracle-fleet shape: `specs: {root: specs, tests: tests}`,
# no `extraSpecs`) reached by a spec page — the path every stack had before extraSpecs, through the
# pin default `scripts/lib/snippets.sh` (constructed world). Pins that a claim without the new field
# behaves exactly as before: one pin read, mounted, no README read.
PROJECT="oracle-fleet"
_ib_ref="${ORG}/${PROJECT}#${ISSUE_N}"
SPECS_CLAIM_JSON='{"root":"specs","tests":"tests"}'
EXTRA_SPECS_CLAIM_JSON=''
_ib_body='---
Touches: specs/endpoints/x.md
---'
