#!/usr/bin/env bash
# mgmt-tf — run the MAIN tofu root through the management box (ADR-129/ADR-131, FU-012).
#
# Since 2026-09-13 main's state lives ON the box (/var/lib/mgmt/state/main/terraform.tfstate,
# local backend via -state=) beside the dangerous credentials — the box is the applier, the jail
# holds neither. A human plan/apply of main therefore runs THERE, from a COMMITTED ref (the box
# checks out what git says; the working tree of the jail is not a thing it can see). Push your
# branch, then:
#
#   devbox run mgmt-tf -- plan                          # origin/master; prints a PLAN ID
#   MGMT_REF=origin/fix/foo devbox run mgmt-tf -- plan  # a pushed branch
#   devbox run mgmt-tf -- apply <plan-id>               # applies THAT plan, nothing else
#   devbox run mgmt-tf -- state list                    # any tofu subcommand; -state/-var-file are
#                                                       # added for the ones that take them
#
# ⚠ **APPLY TAKES A PLAN ID, NEVER FLAGS** (FU-248, 2026-09-21). Every `plan` writes a saved plan
# on the box (/var/lib/mgmt/plan/<id>.bin, + .txt human copy, + .meta) and prints its id; `apply`
# accepts exactly that id and executes the recorded diff. An ad-hoc `apply -target=…` is refused.
# This is the 2026-09-16 incident's fix: a `-target` apply was typed WITHOUT planning that exact
# command, `-target` dragged in the whole VM resource, and three worker VMs were replaced
# (docs/incidents/2026-09-16-targeted-apply-replaced-three-vms.md). A scoped run is still
# expressible — plan it scoped, read it, apply the id — so nothing is lost but the guessing.
# Saved plans go stale by design: tofu refuses one whose state serial has moved, which is exactly
# the "the world changed since you read this" check a human cannot perform reliably.
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
MODE=passthrough
PLAN_ID=""
case "$1" in
  plan)
    # Always saved. The scoping flags travel INTO the plan file, so `apply <id>` needs none of
    # them and cannot acquire a scope the human never read.
    MODE=plan
    extra=(-state="$STATEF" -var-file=/var/lib/mgmt/main.tfvars)
    ARGS=("$1" "${extra[@]}" "${@:2}") ;;
  apply)
    MODE=apply
    [ $# -eq 2 ] || { cat >&2 <<'USAGE'
mgmt-tf: apply takes exactly one argument — a plan id from a previous `mgmt-tf -- plan`.

    devbox run mgmt-tf -- plan                 # prints: plan id <id>
    devbox run mgmt-tf -- apply <id>           # applies that plan, and only that plan

Want a scoped run? Plan it scoped and apply the id it prints:
    devbox run mgmt-tf -- plan -replace=talos_cluster_kubeconfig.this -target=talos_cluster_kubeconfig.this
An ad-hoc `apply -target=…` is what replaced three worker VMs on 2026-09-16 (FU-248).
USAGE
      exit 2; }
    case "$2" in -*) echo "mgmt-tf: apply takes a plan id, not a flag ($2) — plan it first, then apply the id (FU-248)" >&2; exit 2 ;; esac
    case "$2" in *[!A-Za-z0-9._-]*) echo "mgmt-tf: '$2' is not a plan id" >&2; exit 2 ;; esac
    PLAN_ID="$2"
    ARGS=(apply -state="$STATEF") ;;  # the plan path is appended on the box
  destroy)
    echo "mgmt-tf: no direct destroy — 'plan -destroy' writes a plan id, then 'apply <id>' (FU-248)" >&2; exit 2 ;;
  refresh|import|console|output|taint|untaint)
    extra=(-state="$STATEF" -var-file=/var/lib/mgmt/main.tfvars)
    ARGS=("$1" "${extra[@]}" "${@:2}") ;;
  state)
    [ $# -ge 2 ] || { echo "mgmt-tf: 'state' needs a subcommand (list, rm, mv, show, pull…)" >&2; exit 2; }
    ARGS=("$1" "$2" -state="$STATEF" "${@:3}") ;;
  *)
    ARGS=("$@") ;;
esac
# The baseline stamp moved to the box: only an apply whose PLAN was unscoped, taken from
# origin/master, still at origin/master when it lands, may advance it. It used to be decided here
# from the apply's own flags — which a plan-file apply no longer carries, so the scope now travels
# in the plan's .meta instead.
STAMP=0
[ "$MODE" = apply ] && [ "$REF" = origin/master ] && STAMP=1
# the remote script: env file → checkout the ref in the box's apply clone → flock → tofu.
# ssh joins its arguments into ONE command line for the remote shell, so the positionals must
# travel inside an explicit `bash -c <script> _ <args…>` (found 2026-09-14: the bare form left
# `$1` unbound on the first real plan). `printf %q` keeps every arg intact across the hop.
# shellcheck disable=SC2016
remote='set -euo pipefail; set -a; . /var/lib/mgmt/env; set +a
   REF="$1"; STAMP="$2"; MODE="$3"; PLAN_ID="$4"; YES="$5"; shift 5
   R=/var/lib/mgmt/apply/homelab
   P=/var/lib/mgmt/plan
   [ -d "$R/.git" ] || git clone -q https://github.com/teststuffstash/homelab.git "$R"
   git -C "$R" fetch -q origin; git -C "$R" reset -q --hard "$REF"
   cd "$R"
   mkdir -p "$P"; chmod 700 "$P"
   [ -d tofu/.terraform ] || devbox run --quiet -- tofu -chdir=tofu init -input=false -lockfile=readonly >&2
   SHA=$(git rev-parse --short HEAD)
   # A plan id is unique per (when, ref-sha) and names its own artifacts. Nothing but this script
   # writes into $P, and a saved plan holds state values — root-only, 600.
   if [ "$MODE" = plan ]; then
     PLAN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$SHA"
     set -- "$@" -out="$P/$PLAN_ID.bin"
     SCOPED=0
     for a in "$@"; do case "$a" in -target*|-exclude*|-replace*|-destroy|-refresh-only) SCOPED=1 ;; esac; done
   elif [ "$MODE" = apply ]; then
     [ -f "$P/$PLAN_ID.bin" ] || { echo "mgmt-tf: no such plan id: $PLAN_ID (ls $P)" >&2; exit 2; }
     . "$P/$PLAN_ID.meta"
     set -- "$@" "$P/$PLAN_ID.bin"
     # A saved-plan apply does NOT prompt (the approval is the plan file), so the prompt is here
     # instead — showing what the plan actually was, since the whole point is that the apply can
     # no longer be typed differently from what was read. MGMT_YES=1 for a non-interactive caller
     # (passed as a positional, not an env var — ssh carries no environment across the hop).
     echo "mgmt-tf: plan $PLAN_ID — ref $PLAN_REF @ ${PLAN_SHA:0:8}, scoped=$SCOPED, planned $PLANNED_AT" >&2
     grep -E "^(Plan:|No changes|OpenTofu will perform)" "$P/$PLAN_ID.txt" 2>/dev/null | head -3 >&2 || true
     if [ "$YES" != 1 ]; then
       printf "mgmt-tf: apply this plan? [y/N] " >&2; read -r ans || ans=""
       case "$ans" in y|Y|yes|YES) ;; *) echo "mgmt-tf: aborted" >&2; exit 1 ;; esac
     fi
   fi
   echo "mgmt-tf: $SHA on $(hostname) — tofu $*" >&2
   # ONE lock span for tofu AND the stamp: mgmt-apply reads/writes applied-rev under this same
   # lock (a long-lived fd), so the stamp must not land after the command-form flock released
   # (review finding on PR#1721)
   exec 9>/var/lib/mgmt/sentinel/.lock; flock -w 600 9 || { echo "mgmt-tf: lock busy for 10 min" >&2; exit 1; }
   rc=0; devbox run --quiet -- tofu -chdir=tofu "$@" || rc=$?
   if [ "$MODE" = plan ] && [ $rc -le 2 ] && [ -f "$P/$PLAN_ID.bin" ]; then
     chmod 600 "$P/$PLAN_ID.bin"
     devbox run --quiet -- tofu -chdir=tofu show -no-color "$P/$PLAN_ID.bin" > "$P/$PLAN_ID.txt" 2>/dev/null || true
     chmod 600 "$P/$PLAN_ID.txt" 2>/dev/null || true
     { echo "PLAN_REF=$REF"; echo "PLAN_SHA=$(git rev-parse HEAD)"; echo "SCOPED=$SCOPED";
       echo "PLANNED_AT=$(date -u +%FT%TZ)"; } > "$P/$PLAN_ID.meta"
     # keep the 30 newest plans; a saved plan is a credential-adjacent artifact, not an archive
     ls -1t "$P"/*.bin 2>/dev/null | tail -n +31 | while read -r old; do rm -f "$old" "${old%.bin}.txt" "${old%.bin}.meta"; done
     echo "mgmt-tf: plan id $PLAN_ID   (scoped=$SCOPED)   apply it with: devbox run mgmt-tf -- apply $PLAN_ID" >&2
   fi
   # The stamp needs THREE things true, and the first two now come from the plan, not the apply:
   # the plan was unscoped, it was taken from origin/master, and THAT COMMIT is still the tip.
   # ⚠ The last one compares the PLAN sha, not HEAD: HEAD was just reset to $REF a few lines up,
   # so `HEAD = origin/master` is trivially true and would stamp a commit whose diff was never
   # applied — master moving from A to B between plan and apply (a config-only B, so tofu own
   # state-serial staleness check never trips) would mark B reconciled and the apply loop would
   # never revisit it: the FU-237/#1718 ratchet bug this stamp exists to prevent (review, #1827).
   if [ "$MODE" = apply ] && [ "$STAMP" = 1 ] && [ $rc = 0 ] && [ "${SCOPED:-1}" = 0 ] \
      && [ "${PLAN_REF:-}" = origin/master ] && [ -n "${PLAN_SHA:-}" ] \
      && [ "$PLAN_SHA" = "$(git rev-parse origin/master)" ]; then
     mkdir -p /var/lib/mgmt/apply; echo "$PLAN_SHA" >/var/lib/mgmt/apply/applied-rev; rm -f /var/lib/mgmt/apply/refused-rev
     echo "mgmt-tf: apply loop baseline stamped at ${PLAN_SHA:0:8} (refused-rev cleared)" >&2
   elif [ "$MODE" = apply ] && [ "$STAMP" = 1 ] && [ $rc = 0 ] && [ "${SCOPED:-1}" = 0 ] \
      && [ "${PLAN_REF:-}" = origin/master ]; then
     echo "mgmt-tf: NOT stamping — this plan is ${PLAN_SHA:0:8}, master is now $(git rev-parse --short origin/master). Re-plan and apply that to advance the baseline." >&2
   fi
   exit $rc'
exec ssh -t -o StrictHostKeyChecking=accept-new -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" \
  "bash -c $(printf '%q' "$remote") _ $(printf '%q ' "$REF" "$STAMP" "$MODE" "$PLAN_ID" "${MGMT_YES:-0}" "${ARGS[@]}")"
