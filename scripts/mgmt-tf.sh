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
#
# A FULL `apply` of origin/master (no -target/-exclude/-replace/-destroy) that succeeds also
# STAMPS the apply loop's baseline (/var/lib/mgmt/apply/applied-rev = that sha, refused-rev
# cleared): the loop refuses any master diff since its last stamp that hits stage 1 or leaves the
# apply allowlist, and "waiting for a human apply" only ends when the human apply advances the
# baseline — otherwise every later master carried the same hit forever (found on the #1718 class,
# 2026-09-16; FU-237 (e)). A targeted apply does not stamp: finish with a full one.
set -euo pipefail
HOST="${MGMT_HOST:-192.168.2.53}"
REF="${MGMT_REF:-origin/master}"
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "mgmt-tf: cred dir not found (homelab-pve-ssh/ — the key the box trusts)" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <tofu subcommand> [args…]  (MGMT_REF=<ref> to pick the ref; default origin/master)" >&2; exit 2; }
# -state / -var-file only on the subcommands that accept them (init, providers, validate do not).
# ⚠ `tofu state` takes its flags AFTER the sub-subcommand: `state rm -state=X <addr>` is valid,
# `state -state=X rm <addr>` is a usage error. The flat `$1 + extra + rest` form below therefore
# builds `state` wrong, which is why `mgmt-tf -- state list` — advertised in this very header —
# had never once worked (found 2026-09-21 needing `state rm` during the wk-metal-02 recovery).
# Hence ARGS is assembled per-case instead of one shared `extra`.
STATEF=/var/lib/mgmt/state/main/terraform.tfstate
extra=()
case "$1" in
  plan|apply|destroy|refresh|import|console|output|taint|untaint)
    extra=(-state="$STATEF" -var-file=/var/lib/mgmt/main.tfvars)
    ARGS=("$1" "${extra[@]}" "${@:2}") ;;
  state)
    [ $# -ge 2 ] || { echo "mgmt-tf: 'state' needs a subcommand (list, rm, mv, show, pull…)" >&2; exit 2; }
    ARGS=("$1" "$2" -state="$STATEF" "${@:3}") ;;
  *)
    ARGS=("$@") ;;
esac
STAMP=0
if [ "$1" = apply ] && [ "$REF" = origin/master ]; then
  STAMP=1
  for a in "${@:2}"; do case "$a" in -target*|-exclude*|-replace*|-destroy|-refresh-only) STAMP=0 ;; esac; done
fi
# the remote script: env file → checkout the ref in the box's apply clone → flock → tofu.
# ssh joins its arguments into ONE command line for the remote shell, so the positionals must
# travel inside an explicit `bash -c <script> _ <args…>` (found 2026-09-14: the bare form left
# `$1` unbound on the first real plan). `printf %q` keeps every arg intact across the hop.
# shellcheck disable=SC2016
remote='set -euo pipefail; set -a; . /var/lib/mgmt/env; set +a
   REF="$1"; STAMP="$2"; shift 2
   R=/var/lib/mgmt/apply/homelab
   [ -d "$R/.git" ] || git clone -q https://github.com/teststuffstash/homelab.git "$R"
   git -C "$R" fetch -q origin; git -C "$R" reset -q --hard "$REF"
   cd "$R"
   [ -d tofu/.terraform ] || devbox run --quiet -- tofu -chdir=tofu init -input=false -lockfile=readonly >&2
   echo "mgmt-tf: $(git rev-parse --short HEAD) on $(hostname) — tofu $*" >&2
   # ONE lock span for tofu AND the stamp: mgmt-apply reads/writes applied-rev under this same
   # lock (a long-lived fd), so the stamp must not land after the command-form flock released
   # (review finding on PR#1721)
   exec 9>/var/lib/mgmt/sentinel/.lock; flock -w 600 9 || { echo "mgmt-tf: lock busy for 10 min" >&2; exit 1; }
   rc=0; devbox run --quiet -- tofu -chdir=tofu "$@" || rc=$?
   if [ "$STAMP" = 1 ] && [ $rc = 0 ] && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/master)" ]; then
     mkdir -p /var/lib/mgmt/apply; git rev-parse HEAD >/var/lib/mgmt/apply/applied-rev; rm -f /var/lib/mgmt/apply/refused-rev
     echo "mgmt-tf: apply loop baseline stamped at $(git rev-parse --short HEAD) (refused-rev cleared)" >&2
   fi
   exit $rc'
exec ssh -t -o StrictHostKeyChecking=accept-new -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" \
  "bash -c $(printf '%q' "$remote") _ $(printf '%q ' "$REF" "$STAMP" "${ARGS[@]}")"
