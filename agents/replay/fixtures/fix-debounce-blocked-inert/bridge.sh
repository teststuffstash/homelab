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
