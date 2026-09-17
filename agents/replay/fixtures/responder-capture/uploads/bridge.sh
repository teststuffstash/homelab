# ── bridge ── the pod environment and the loop variables the capture reads, each set EARLIER in
# responder-argo.yaml (the env block for the S3 four, the alert loop for FP/NAME/SUBJ/rail).
#
# `s5cmd` is not one of the harness's PATH shims — the two stubs are `gh` and `kubectl`. So this
# bridge installs one, against the documented runner contract ($REPLAY_ACTIONS is the append-only
# action file): the recorder is the same `CALL <tool> <argv>` shape, which is what lets the bucket
# writes be asserted at all.
mkdir -p "$PWD/bin"
cat > "$PWD/bin/s5cmd" <<'SNIP'
#!/bin/sh
printf 'CALL s5cmd %s\n' "$*" >> "$REPLAY_ACTIONS"
SNIP
chmod +x "$PWD/bin/s5cmd"
PATH="$PWD/bin:$PATH"

AGENT_TS_ACCESS_KEY_ID="k"
AGENT_TS_SECRET_ACCESS_KEY="s"
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

# ⚠ HOME is fixture-local. The capture walks `$HOME/.claude/projects` for the session's own JSONL,
# and the runner does not unset HOME — so without this the fixture uploaded the JAIL OPERATOR'S own
# transcript and its action stream carried a machine-specific path (replay README move 6: ambient
# env is part of the contract, and a bridge that inherits one is a leak vector).
HOME="$(mktemp -d)"
mkdir -p "$HOME/.claude/projects"
printf '{"type":"summary"}\n' > "$HOME/.claude/projects/session-abc.jsonl"

# The two files the loop has already written by the time the capture runs: the single-alert payload
# and the session's tee'd output.
printf '{"status":"firing","fingerprint":"%s","labels":{"alertname":"%s"}}' "$FP" "$NAME" > /tmp/alert-one.json
printf 'triage report: forgejo-pg-1 replica diverged after failover (pg_rewind, no common timeline)\n' > /tmp/triage.log
# The mark is dated into the past rather than `touch`ed now: `find -newer` is a STRICT comparison,
# and a mark created in the same second as the transcript is not older than it.
touch -d '2020-01-01' /tmp/ts-mark
