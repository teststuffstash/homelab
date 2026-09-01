# ── bridge ── everything fix-debounce-argo.yaml's `decide` step sets BEFORE the pending-set block,
# and nothing else. Each name is the manifest's own: `$ORG` and `$DRY_RUN` come off the container
# env, and `/tmp/repos.txt` + `/tmp/stackmap.tsv` are written two lines above the opening sentinel
# by the AgentStack-claims read. A bridge that invents a variable pins a different clause.
#
# The claims read itself is deliberately NOT under replay here: it is the FU-144 routing half, it
# would drag a kubectl recording plus one `gh api` world file per claimed repo into a fixture whose
# subject is the label predicate, and the stub keys every repo's list call onto the same shortened
# world key anyway. One repo — homelab, the platform's own — is the world these two legs need.
ORG="teststuffstash"
DRY_RUN="0"
printf 'homelab\n' > /tmp/repos.txt
printf 'homelab\tplatform\t\n' > /tmp/stackmap.tsv   # platform is not graduated → empty loop_ns

# The /coordinate doorbell is the queue path's only non-`gh` I/O. Shadowing the binary with a shell
# function — the seam pattern this harness already uses for `mc_now`, `gb_ledger` and the
# responder's `curl` — puts "did this ring dispatch" into the SAME action stream as the label
# writes. Returns 0, so the clause takes its `&& echo rang …` branch: a bell that failed is a
# different fixture.
curl() { printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"; }

# ── the currency gate's seams (FU-133 leg c) ── the three names fix-debounce-argo.yaml defines
# between its two sentinels, in the same order and with the same meaning. Everything the gate
# DECIDES with — the fingerprint read, the endsAt arithmetic, the last-cleared comparison, the
# verdict — stays inside the block and under replay; only the alert store and the two clocks are
# shadowed, which is this harness's standing rule (README §When a clause depends on a sourced
# helper, and the `ag_limit` note on bounding a magnitude rather than a branch).
#
# `world/alertmanager/alerts.json` is the first world served by a SEAM rather than by a PATH-shim
# stub, and it is keyed by nothing: one file per fixture, because a fixture pins one moment of the
# alert store. The read is recorded as a CALL so "did the gate probe live state at all" is asserted
# in the same vocabulary as every label write — an unrecorded probe is how a gate that silently
# stopped probing would still look green.
fc_am_alerts() {
  printf 'CALL alertmanager GET /api/v2/alerts (currency probe)\n' >> "$REPLAY_ACTIONS"
  cat "$REPLAY_FIXTURE/world/alertmanager/alerts.json"
}
# Pinned by the fixture, never by the machine's clock: `endsAt > now` is the whole resolved/firing
# split, so a real clock would make every recording go stale the moment it passed its own endsAt.
# Declared per fixture (`env: - FC_NOW=<epoch>`) and LOUD when a fixture that reaches the gate
# forgot to — a defaulted clock is a fixture asserting against an accident.
fc_now() { printf '%s\n' "${FC_NOW:?this fixture reaches the currency gate and must pin the clock: env: - FC_NOW=<epoch seconds>}"; }

# The manifest sources this helper at the same point; the fixture sources the REAL file out of the
# checkout and shadows only its wall clock, so mc_event's find-or-create arithmetic (the POST-vs-
# PATCH decision) is what lands in the action stream — the summary-comment-* pattern verbatim.
. "$REPLAY_ROOT/agents/machine-comment.sh"
# classify_touches() in agents/footprint.sh — the ONE machine-readable home for the platform lane
# path tables (homelab#1151). Sourced here (outside the replay block) so the fixture shadows the
# path via $REPLAY_ROOT, same as machine-comment.sh.
. "$REPLAY_ROOT/agents/footprint.sh"
# classify_touches() reads CODEOWNERS at runtime. Point it at the real file in the checkout.
CLASSIFY_CODEOWNERS="$REPLAY_ROOT/CODEOWNERS"
mc_now() { printf '%s\n' "${MC_NOW:-2026-08-11T14:00:00Z}"; }
