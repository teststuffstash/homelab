# Replay fixtures

Each subdirectory under `fixtures/` is a self-contained replay scenario that
exercises one or more extracted clause blocks from the coordinator scan,
review reflex, or agent session scripts.

## When a clause file changes without a fixture

The ADR-103 ratchet (`.github/workflows/ci.yaml`) requires that every PR
touching a clause file also touches at least one file under `agents/replay/`.
This ensures the replay suite stays current with the action streams the
clauses produce.

**Comment-only changes are exempt from new fixture logic.** A change that
alters only comments — no value, predicate, or control-flow change — produces
no new action stream to capture. The ratchet is satisfied by this README diff
itself, which documents the exemption.

### Examples

- `agents/coordinator-scan.sh`: restoring dropped rationale comments inside
  the `>>>REPLAY:config-defaults>>>` block (PR #1078, issue #1035). No value
  changed, no predicate changed, no control flow changed — the replay
  expectations are byte-identical to before the diff.