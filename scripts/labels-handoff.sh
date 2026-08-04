#!/usr/bin/env bash
# labels-handoff — hand homelab's agent/* labels from tofu to the AgentStack claim (FU-068 finale).
#
#   devbox run labels-handoff            # DRY RUN — lists exactly what it would forget
#   devbox run labels-handoff --apply    # do it
#
# ⚠ RUN OUTSIDE THE JAIL. Every tofu call goes through `devbox run github-tofu`, which assembles the
#   org-admin token + the homelab-merge App creds the jail deliberately does not have.
#
# WHY A STATE RM AND NOT AN APPLY. `tofu/github/labels.tf` was deleted in the same change that added
# this script, so an apply would see its 16 resources vanish from config and DESTROY the labels on
# GitHub. Measured 2026-08-04: none of the 16 are currently on any homelab issue or PR, so a destroy
# would not strip anything today — but `state rm` is still the right move, and the reason is not
# blast radius:
#   • it is what the other eight repos did (oracle/agent-*/sleep, 2026-07-16 → 07-25) — one
#     migration, one shape;
#   • the claim's IssueLabels is AUTHORITATIVE and ADOPTS an existing taxonomy; destroying first
#     means the labels are simply absent until the claim lands, which is blocked on a browser click;
#   • the coordinator drives the whole loop by relabelling, so the taxonomy must exist BEFORE
#     homelab ever carries agent work, not after.
# (An earlier version of this header claimed `automerge` was at risk. It is not tofu-managed at all
#  — it never appears in the addresses below — and the claim was wrong.)
#
# SCOPING. The address filter is `^github_issue_label\.` — NEVER a bare grep for "homelab", which
# also matches the repository and ruleset resources (the FU-068 warning; removing those from state
# would orphan the repo config and the next apply would try to recreate it).
#
# AFTER THIS: the labels sit unmanaged until homelab joins an AgentStack claim, whose composed
# IssueLabels is AUTHORITATIVE and adopts the taxonomy. That step is blocked on a browser click —
# the homelab-agents and homelab-reviewer Apps are NOT installed on the homelab repo (verified on
# the served /apps page). Adding homelab to the token lists before those installs makes ESO's token
# generation 422 and breaks the LIVE token for every repo. Order: install → verify /apps → claim.
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

ORG="${ORG:-teststuffstash}"
REPO="${LABELS_HANDOFF_REPO:-homelab}"
FILTER="^github_issue_label\.agent\[\"${REPO}::"

echo "── labels-handoff: ${ORG}/${REPO} — tofu forgets, GitHub keeps"
echo

# 1. What GitHub has NOW — the before-picture the verification below compares against.
before="$(gh api "repos/${ORG}/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null | sort || true)"
n_before=$(printf '%s\n' "$before" | grep -c . || true)
echo "GitHub labels on ${REPO} before: ${n_before}"

# 2. What tofu still manages — every call rides `devbox run github-tofu`, so the whole script is
#    one permission story (the wrapper assembles the org-admin token + merge-App creds).
# Capture the WHOLE state list first. Filtering straight into a grep would make "state unreadable"
# (wrong machine, no admin wallet, failed init) look identical to "already migrated" — a script that
# reports success while doing nothing is the exact failure class this platform keeps paying for
# (FU-125/FU-108/FU-131). Caught live: the first dry run of this script printed "nothing to do" from
# inside the jail, where the tofu/github state is not visible at all.
# The wrapper runs `tofu init` first, so stdout carries a banner before any address. Counting raw
# lines called that banner "12 resources" on the first try — count only things SHAPED like a tofu
# address (lowercase type, then a dot), never merely non-empty output.
state="$(devbox run github-tofu state list 2>/dev/null || true)"
state="$(printf '%s\n' "$state" | grep -E '^(module\.)?[a-z][a-z0-9_]*\.' || true)"
n_state=$(printf '%s\n' "$state" | grep -c . || true)
if [ "$n_state" -eq 0 ]; then
  cat >&2 <<EOF
FAIL: tofu/github state is EMPTY or unreadable here — refusing to report success.
  The tofu/github root runs OUTSIDE the jail: it needs the org-admin wallet
  (~/Documents/homelab-admin.kdbx) that scripts/github-tf.sh assembles. Run this on the host.
  Diagnose with: devbox run github-tofu state list
EOF
  exit 2
fi

mapfile -t addrs < <(printf '%s\n' "$state" | grep -E "$FILTER" || true)
if [ "${#addrs[@]}" -eq 0 ]; then
  echo "tofu state: ${n_state} resources visible, none of them ${REPO} labels — handoff already done."
  exit 0
fi
echo "tofu state: ${#addrs[@]} label resources to forget:"
printf '  %s\n' "${addrs[@]}"
echo

if [ "$APPLY" != 1 ]; then
  cat <<EOF
DRY RUN — nothing changed. To do it:

    devbox run labels-handoff -- --apply

Then confirm the plan is clean of label destroys:

    devbox run github-tofu plan | grep -E 'github_issue_label|will be destroyed' || echo 'no label changes'
EOF
  exit 0
fi

# 3. Forget them, one address at a time so a partial failure is obvious and resumable (this script
#    is idempotent: a second run simply finds fewer addresses).
for a in "${addrs[@]}"; do
  echo "→ state rm $a"
  devbox run github-tofu state rm "$a"
done

# 4. Verify GitHub kept them. A state rm that silently deleted labels would be the worst outcome
#    here, so this asserts rather than assumes — the same rule the rest of the platform runs on.
after="$(gh api "repos/${ORG}/${REPO}/labels" --paginate --jq '.[].name' 2>/dev/null | sort || true)"
n_after=$(printf '%s\n' "$after" | grep -c . || true)
echo
echo "GitHub labels on ${REPO} after: ${n_after}"
if [ "$n_after" -lt "$n_before" ]; then
  echo "FAIL: labels DISAPPEARED from GitHub ($n_before → $n_after) — a state rm must never delete." >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
  exit 1
fi

cat <<EOF

OK — tofu no longer manages ${REPO}'s labels and GitHub kept all ${n_after}.

NEXT (in order):
  1. devbox run github-tofu plan
     → must show NO github_issue_label changes. The pre-existing 'merge-conflict' description
       drift disappears with them.
  2. devbox run github-tofu apply     (for whatever else the plan legitimately carries)
  3. Still blocked on a click: install homelab-agents + homelab-reviewer on ${ORG}/${REPO}, verify
     on the served /apps page, THEN add homelab to the claim + stacks.json + both token lists.
EOF
