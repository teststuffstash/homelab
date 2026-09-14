# REJECT (no token): the allowlist passes but `coordinator-git`'s GH_TOKEN is absent — fail-closed,
# never a silent no-op. The bridge's `unset GH_TOKEN` is what makes this genuinely absent.
RING_REPO="oracle-fleet"
RING_PREFIX="2026-09-14"
