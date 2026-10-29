# ── bridge (shared by the family) ── the launcher variables REPLAY:specs-process-volume reads, and
# the two REGISTRY seams. Every name here is one the real dispatch sets (`HERE`, `ORG`, `PROJECT`,
# `ISSUE_N`, `BASE_REF`, `_ib_ref`, the IV_* outputs) — a bridge that renames things pins a
# different clause. `ib_get` runs the REAL parser out of the checkout (block:preflight-body-parser);
# `fp_conflict` is the scan's own predicate (agents/footprint.sh); the pin read goes through the
# PATH-shim `gh`, which serves this fixture's recorded pin file. Only the registry leaves: the
# tag→digest step and the digest probe are recorded stubs (S3: the read is a CALL line), so an
# unrecorded `gh` read — a pin fetch the clause must NOT make — still DIES loudly.
HERE="$REPLAY_ROOT/agents"
. "$REPLAY_ROOT/agents/footprint.sh"
ORG="teststuffstash"
PROJECT="homelab"
ISSUE_N="3030"
BASE_REF="master"
_ib_ref="${ORG}/${PROJECT}#${ISSUE_N}"
IV_MOUNT=""; IV_VOLUME=""; IV_CARD=""; IV_SEEN_NAMES=" "; IV_SEEN_PATHS=""
# The registry, recorded: the tag the snippets release published as an image resolves to its
# index digest; a tag with no published image (v0.6.4 — the pin before the artifact existed) does not.
iv_digest_of() {
  printf 'CALL iv_digest_of %s %s %s\n' "$1" "$2" "$3" >> "$REPLAY_ACTIONS"
  case "$3" in v0.6.5) printf 'sha256:dce3b1676e3dfa5cadfbe8ecd0ae418b1be069e486a26ba0c4f78da72fa91cf9';; *) return 1;; esac
}
iv_probe() { printf 'CALL iv_probe %s %s %s\n' "$1" "$2" "$3" >> "$REPLAY_ACTIONS"; return 0; }
