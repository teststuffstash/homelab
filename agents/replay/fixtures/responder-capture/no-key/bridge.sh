# ── bridge ── identical to the uploads twin except for the ONE difference under test: no key.
# `s5cmd` is still installed, so the degrade is attributed to the KEY and not to a missing binary —
# which is also the production shape (the image always carries s5cmd; the Secret is optional).
mkdir -p "$PWD/bin"
cat > "$PWD/bin/s5cmd" <<'SNIP'
#!/bin/sh
printf 'CALL s5cmd %s\n' "$*" >> "$REPLAY_ACTIONS"
SNIP
chmod +x "$PWD/bin/s5cmd"
PATH="$PWD/bin:$PATH"

AGENT_TS_ACCESS_KEY_ID=""
AGENT_TS_SECRET_ACCESS_KEY=""
AGENT_TS_BUCKET="agent-transcripts"
AGENT_TS_ENDPOINT="http://garage.garage.svc.cluster.local:3900"

NAME="CNPGInstanceNotReady"
FP="5f9b1c0a77d31e42"
SUBJ="workload:forgejo/forgejo-pg-1"
ROUTE_STACK="platform"
ROUTE_REPO="teststuffstash/homelab"
SELF_REF=""
WIN=""
rail="claude/sonnet"
TS_MODEL="sonnet"
HOSTNAME="respond-abcde"
# ⚠ HOME is fixture-local (see the uploads twin), and here it deliberately has NO
# `.claude/projects` — the real shape when claude dies before its first turn. That is the state
# whose `find` exits non-zero, and the `|| true` guarding it is what keeps pipefail + set -e from
# taking down the whole alert loop. The degrade returns before the find, so what this row pins is
# that the key check comes FIRST and nothing downstream of it runs.
HOME="$(mktemp -d)"
mkdir -p "$HOME"
# ⚠ The clause's scratch dir is fixture-local too (homelab#2600): it writes its temp files under
# $SCRATCH — /tmp in the pod, where nothing sets it — and two replay runs sharing a jail's /tmp
# raced on alert-one.json / triage.log / ts-finding.json. Under $HOME, so the one <fixhome> scrub
# covers it.
SCRATCH="$HOME/scratch"; mkdir -p "$SCRATCH"
printf '{"status":"firing"}' > "$SCRATCH/alert-one.json"
printf 'triage report\n' > "$SCRATCH/triage.log"
touch -d '2020-01-01' "$SCRATCH/ts-mark"
