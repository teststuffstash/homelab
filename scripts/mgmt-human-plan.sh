#!/usr/bin/env bash
# mgmt-human-plan — the management sentinel's escape hatch (ADR-131, FU-237 (e),
# docs/management-box.md §MB3 "When the box refuses").
#
# Stage 1 of the sentinel refuses to plan a PR head that touches provider/backend/CLI surface
# (`deny_paths` / `deny_patterns` in policy/mgmt/plan-input.yaml), and the timer never plans such
# a head — that invariant stays. But `management-sentinel` is a REQUIRED context, so a refusal
# alone wedges the PR: no merge, no bot review (review-reflex needs green). This is the human's
# side of the policy's own sentence, "or gets a human plan in the jail": ssh to the box and run
# ITS sentinel in `--human-plan` mode for ONE PR — stage 1 reported (not enforced), the plan
# shown here for you to READ, and the verdict (status + comment, marked as a human plan with the
# overridden rules named) posted under the homelab-sentinel App only after you confirm.
#
#   devbox run mgmt-human-plan -- <pr>          # plan, read, confirm y/N, post
#   devbox run mgmt-human-plan -- <pr> --yes    # no prompt (a seat session; it has read the diff)
#
# You are the reviewer of the overridden rules: read the diff FIRST. The verdict goes on the
# exact head sha; a push afterwards is a new head the box refuses again (re-run after re-reading).
# Same ssh identity as mgmt-tf (root@box via homelab-pve-ssh). The box's copy of the sentinel is
# its system checkout at master, so the mode exists there only once merged and pulled.
set -euo pipefail
HOST="${MGMT_HOST:-192.168.2.53}"
[ $# -ge 1 ] || { echo "usage: $0 <pr> [--yes]" >&2; exit 2; }
case "$1" in ''|*[!0-9]*) echo "usage: $0 <pr> [--yes]  — <pr> is the homelab PR number" >&2; exit 2 ;; esac
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "mgmt-human-plan: cred dir not found (homelab-pve-ssh/ — the key the box trusts)" >&2; exit 1; }
# shellcheck disable=SC2016
remote='set -euo pipefail; set -a; . /var/lib/mgmt/env; set +a
   S=/var/lib/homelab/scripts/mgmt-sentinel.sh
   grep -q -- "--human-plan" "$S" || { echo "mgmt-human-plan: the box checkout ($(git -C /var/lib/homelab rev-parse --short HEAD)) predates the human-plan mode — wait for mgmt-pull (hourly) or run: systemctl start mgmt-pull" >&2; exit 1; }
   echo "mgmt-human-plan: sentinel at $(git -C /var/lib/homelab rev-parse --short HEAD) on $(hostname) — human plan of #$1" >&2
   exec "$S" --human-plan "$@"'
exec ssh -t -o StrictHostKeyChecking=accept-new -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" \
  "bash -c $(printf '%q' "$remote") _ $(printf '%q ' "$@")"
