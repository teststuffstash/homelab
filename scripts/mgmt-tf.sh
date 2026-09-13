#!/usr/bin/env bash
# mgmt-tf — run the MAIN tofu root through the management box (ADR-129/ADR-131, FU-012).
#
# Since 2026-09-13 main's state lives ON the box (/var/lib/mgmt/state/main/terraform.tfstate,
# local backend via -state=) beside the dangerous credentials — the box is the applier, the jail
# holds neither. A human plan/apply of main therefore runs THERE, from a COMMITTED ref (the box
# checks out what git says; the working tree of the jail is not a thing it can see). Push your
# branch, then:
#
#   devbox run mgmt-tf -- plan                          # origin/master
#   MGMT_REF=origin/fix/foo devbox run mgmt-tf -- plan  # a pushed branch
#   devbox run mgmt-tf -- apply                         # interactive approve, as before
#   devbox run mgmt-tf -- state list                    # any tofu subcommand; -state/-var-file are
#                                                       # added for the ones that take them
#
# Serialized with the box's own loops (flock /var/lib/mgmt/sentinel/.lock — the sentinel and the
# apply loop hold it while they plan/apply). The env file on the box supplies every TF_VAR_*.
set -euo pipefail
HOST="${MGMT_HOST:-192.168.2.53}"
REF="${MGMT_REF:-origin/master}"
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "mgmt-tf: cred dir not found (homelab-pve-ssh/ — the key the box trusts)" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <tofu subcommand> [args…]  (MGMT_REF=<ref> to pick the ref; default origin/master)" >&2; exit 2; }
# -state / -var-file only on the subcommands that accept them (init, providers, validate do not)
extra=()
case "$1" in
  plan|apply|destroy|refresh|import|console|output|taint|untaint) extra=(-state=/var/lib/mgmt/state/main/terraform.tfstate -var-file=/var/lib/mgmt/main.tfvars) ;;
  state) extra=(-state=/var/lib/mgmt/state/main/terraform.tfstate) ;;
esac
# the remote script: env file → checkout the ref in the box's apply clone → flock → tofu
# shellcheck disable=SC2016
exec ssh -t -o StrictHostKeyChecking=accept-new -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" \
  'set -euo pipefail; set -a; . /var/lib/mgmt/env; set +a
   REF="$1"; shift
   R=/var/lib/mgmt/apply/homelab
   [ -d "$R/.git" ] || git clone -q https://github.com/teststuffstash/homelab.git "$R"
   git -C "$R" fetch -q origin; git -C "$R" reset -q --hard "$REF"
   cd "$R"
   [ -d tofu/.terraform ] || devbox run --quiet -- tofu -chdir=tofu init -input=false -lockfile=readonly >&2
   echo "mgmt-tf: $(git rev-parse --short HEAD) on $(hostname) — tofu $*" >&2
   exec flock /var/lib/mgmt/sentinel/.lock devbox run --quiet -- tofu -chdir=tofu "$@"' \
  _ "$REF" "$1" "${extra[@]}" "${@:2}"
