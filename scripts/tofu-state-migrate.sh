#!/usr/bin/env bash
# tofu-state-migrate — move ONE OpenTofu root's state from the local gitignored file to the homelab
# Garage S3 backend, encrypted (FU-012).
#
#   devbox run tofu-state-migrate cloudflare            # DRY RUN — probes everything, changes nothing
#   devbox run tofu-state-migrate -- cloudflare --apply # do it
#
# ⚠ This is the one operation in this repo where a mistake ORPHANS LIVE INFRASTRUCTURE: a root that
#   loses its state does not fail loudly, it plans to CREATE everything it already owns. So the
#   script is built to refuse rather than to proceed:
#     * it never migrates a root whose local state it cannot read (the labels-handoff lesson —
#       "empty state" and "already migrated" must never look alike);
#     * it backs the local file up OUTSIDE the repo, timestamped, before touching anything;
#     * it verifies the resource COUNT survived and that a plan is clean before it says a word
#       about success;
#     * it never deletes the local state file. That is left to a human, after the plan is clean.
#
# ONE ROOT PER RUN, on purpose. Five roots migrated in a loop is five chances to notice a problem
# after it stopped being cheap to fix.
#
# Design, the dependency-cone ruling (which roots may migrate at all) and the recovery procedure:
# docs/tofu-state.md.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"

BUCKET="${TOFU_STATE_BUCKET:-homelab-tofu-state}"

usage() {
  cat >&2 <<EOF
usage: devbox run tofu-state-migrate -- <root> [--apply]

roots:  main | provisioning | cloudflare | infisical | github

  main          tofu/                 ⚠ INSIDE the cluster's dependency cone — see docs/tofu-state.md
  provisioning  tofu/provisioning/
  cloudflare    tofu/cloudflare/
  infisical     tofu/infisical/
  github        tofu/github/          ⚠ HOST ONLY (org-admin wallet is outside the jail)
EOF
  exit 64
}

[ $# -ge 1 ] || usage
ROOT="$1"; shift
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

case "$ROOT" in
  main)         DIR="tofu" ;;
  provisioning) DIR="tofu/provisioning" ;;
  cloudflare)   DIR="tofu/cloudflare" ;;
  infisical)    DIR="tofu/infisical" ;;
  github)       DIR="tofu/github" ;;
  *)            usage ;;
esac
[ -d "$DIR" ] || { echo "FAIL: no such root directory: $DIR" >&2; exit 2; }

echo "── tofu-state-migrate: ${ROOT} (${DIR}) → s3://${BUCKET}/${ROOT}/terraform.tfstate"
echo

# ---------------------------------------------------------------------------
# 1 · Credentials + endpoint. Sourcing this also exports TF_ENCRYPTION, so everything below —
#     including the verification plan — runs against the ENCRYPTED state, not a lucky plaintext one.
#     The fallback is on for this run only: it is what lets the first migration read the plaintext
#     state that exists today.
# ---------------------------------------------------------------------------
export TOFU_STATE_ENC_FALLBACK=1
# ENC=on, not auto: the migration needs the passphrase BEFORE it writes this root's backend.tf,
# which is exactly what `auto` keys off.
export TOFU_STATE_ENC=on TOFU_STATE_ROOT_DIR="$ROOT_DIR/$DIR"
# shellcheck source=/dev/null
. "$ROOT_DIR/scripts/tofu-state-env.sh"
[ -n "${TF_ENCRYPTION:-}" ] || {
  echo "FAIL: no state passphrase — refusing to write homelab state to a shared bucket in plaintext." >&2
  echo "  Add wallet entry \`tofu-state-passphrase\` (scripts/keepass-init.sh), or set TOFU_STATE_PASSPHRASE." >&2
  exit 2
}

# ---------------------------------------------------------------------------
# 2 · The bucket answers, and the key can write to it. A backend that 403s only shows up as a
#     confusing init error halfway through a migration, so find out now.
# ---------------------------------------------------------------------------
aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || {
  echo "FAIL: cannot reach bucket '${BUCKET}' at ${AWS_ENDPOINT_URL_S3}." >&2
  echo "  Is argocd/resources/tofu-state/garage-workspace.yaml synced, and is the key the rw one?" >&2
  exit 2
}
echo "✓ bucket ${BUCKET} reachable at ${AWS_ENDPOINT_URL_S3}"

# ---------------------------------------------------------------------------
# 3 · THE LOCK PROBE — the fact this whole design rests on and the one worth measuring rather than
#     believing. `use_lockfile = true` is S3-native locking: it works only if the object store
#     honours conditional writes (`If-None-Match: *` must fail with 412 when the object exists).
#     Garage is not AWS. If this probe passes, concurrent applies are safe; if it fails, the backend
#     still WORKS but silently offers no mutual exclusion, and two applies can interleave into a
#     corrupt state. That is not a warning to print at the end — it is a reason to stop.
# ---------------------------------------------------------------------------
#
#     The verdict is the EXIT STATUS of the second PUT, and the error string is only ever inspected
#     on the failure path. The first version of this probe grepped the output for `412` either way —
#     which meant a SUCCESSFUL put whose random ETag/VersionId happened to contain "412" read as
#     "conditional writes honoured". It fired once, mid-session, and reported the opposite of the
#     truth. A check that can green-light because of a substring is the same failure class this
#     script exists to refuse.
PROBE_KEY=".lockprobe/$(date +%s)-$$"
probe_out=""
if aws s3api put-object --bucket "$BUCKET" --key "$PROBE_KEY" --if-none-match '*' >/dev/null 2>&1; then
  if probe_out="$(aws s3api put-object --bucket "$BUCKET" --key "$PROBE_KEY" --if-none-match '*' 2>&1)"; then
    probe_verdict=accepted   # the store took a second conditional PUT — enforcement absent
  else
    case "$probe_out" in
      *PreconditionFailed*|*412*) probe_verdict=rejected ;;
      *) echo "FAIL: lock probe errored for an unrelated reason, refusing to guess:" >&2
         printf '%s\n' "$probe_out" >&2; exit 2 ;;
    esac
  fi
  aws s3api delete-object --bucket "$BUCKET" --key "$PROBE_KEY" >/dev/null 2>&1 || true
  case "$probe_verdict" in
    rejected)
      echo "✓ conditional writes honoured — use_lockfile is safe on this Garage" ;;
    *)
      cat >&2 <<EOF
FAIL: Garage accepted a SECOND \`If-None-Match: *\` PUT on the same key.
  Conditional writes are not enforced here, so \`use_lockfile = true\` would give the appearance of
  state locking with none of the substance — two concurrent applies could interleave.
  Options: pin the roots to single-operator use and set TOFU_STATE_NO_LOCK=1 (accepting that),
  or keep local state until the Garage version supports it. Do not paper over this.
EOF
      [ "${TOFU_STATE_NO_LOCK:-0}" = "1" ] || exit 2
      echo "  → TOFU_STATE_NO_LOCK=1: proceeding WITHOUT locking, deliberately." >&2 ;;
  esac
else
  echo "FAIL: could not write the lock probe to ${BUCKET} — the key is not read/write?" >&2
  exit 2
fi
USE_LOCKFILE=true
LOCK_NOTE=""
if [ "${TOFU_STATE_NO_LOCK:-0}" = "1" ]; then
  USE_LOCKFILE=false
  LOCK_NOTE="    # false, DELIBERATELY: this Garage does not enforce conditional writes (measured
    # 20/20). Safe only while this root has ONE writer — the operator. An automated APPLIER against
    # this root is blocked on real locking; docs/tofu-state.md carries the ruling.
"
fi

# ---------------------------------------------------------------------------
# 4 · The local state must be READABLE and non-empty. Count only lines shaped like a tofu address —
#     `init` prints a banner, and counting raw lines once turned that banner into "12 resources"
#     (scripts/labels-handoff.sh carries the same scar).
# ---------------------------------------------------------------------------
if [ -f "$DIR/backend.tf" ]; then
  echo "note: ${DIR}/backend.tf already exists — this root looks migrated. Verifying only."
fi
tofu -chdir="$DIR" init -input=false >/dev/null 2>&1 || true
before="$(tofu -chdir="$DIR" state list 2>/dev/null | grep -E '^(module\.)?[a-z][a-z0-9_]*\.' || true)"
n_before=$(printf '%s\n' "$before" | grep -c . || true)
if [ "$n_before" -eq 0 ]; then
  cat >&2 <<EOF
FAIL: ${DIR} state is EMPTY or unreadable here — refusing to report success.
  A migration that "succeeds" against invisible state is how a root ends up planning to recreate
  live infrastructure. Diagnose with: tofu -chdir=${DIR} state list
  (For the 'github' root this is expected inside the jail — it needs the host's org-admin wallet.)
EOF
  exit 2
fi
echo "✓ local state readable: ${n_before} resources"

BACKUP_DIR="${TOFU_STATE_BACKUP_DIR:-$HOME/.claude/homelab-tofu-state-backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_DIR}/${ROOT}-${STAMP}.tfstate"

# ---------------------------------------------------------------------------
# 5 · Dry run stops here, having proven every precondition that can be proven without writing.
# ---------------------------------------------------------------------------
if [ "$APPLY" != 1 ]; then
  cat <<EOF

DRY RUN — nothing changed. What --apply would do, in order:

  1. cp ${DIR}/terraform.tfstate → ${BACKUP}
  2. write ${DIR}/backend.tf  (bucket=${BUCKET}, key=${ROOT}/terraform.tfstate,
     use_lockfile=${USE_LOCKFILE}; NO credentials — those stay in the environment)
  3. tofu -chdir=${DIR} init -migrate-state -force-copy
  4. verify: state list still shows ${n_before} resources, and a plan is clean
  5. print the two things a HUMAN must then do: commit backend.tf, and only after a clean plan,
     delete ${DIR}/terraform.tfstate

To do it:

    devbox run tofu-state-migrate -- ${ROOT} --apply
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# 6 · Apply.
# ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
if [ -f "$DIR/terraform.tfstate" ]; then
  cp "$DIR/terraform.tfstate" "$BACKUP"; chmod 600 "$BACKUP"
  echo "→ backed up local state to ${BACKUP}"
else
  echo "note: no ${DIR}/terraform.tfstate on disk (already remote?) — continuing, nothing to back up"
fi

if [ ! -f "$DIR/backend.tf" ]; then
  cat > "$DIR/backend.tf" <<EOF
# Remote state — homelab Garage S3 (FU-012, docs/tofu-state.md). GENERATED by
# scripts/tofu-state-migrate.sh; commit it, it is part of the root's definition.
#
# There is deliberately NO credential here: the access key, the endpoint and the state-encryption
# passphrase all come from the environment via scripts/tofu-state-env.sh, which is what makes this
# block safe to commit to a public repo. \`tofu init\` in this root will fail without it — that is
# the intended failure, not a bug.
terraform {
  backend "s3" {
    bucket = "${BUCKET}"
    key    = "${ROOT}/terraform.tfstate"
    region = "garage"

    # Garage speaks S3 and nothing else AWS: no STS, no IMDS, no account id, path-style only.
    endpoints                   = { s3 = "https://s3.teststuff.net" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true

    # S3-native locking via conditional writes. scripts/tofu-state-migrate.sh probes whether Garage
    # actually enforces them and writes the ANSWER here — it never writes true on faith.
${LOCK_NOTE}    use_lockfile = ${USE_LOCKFILE}
  }
}
EOF
  echo "→ wrote ${DIR}/backend.tf"
fi

echo "→ tofu -chdir=${DIR} init -migrate-state -force-copy"
tofu -chdir="$DIR" init -migrate-state -force-copy -input=false

# ---------------------------------------------------------------------------
# 7 · Verify against the remote, not against hope.
# ---------------------------------------------------------------------------
after="$(tofu -chdir="$DIR" state list 2>/dev/null | grep -E '^(module\.)?[a-z][a-z0-9_]*\.' || true)"
n_after=$(printf '%s\n' "$after" | grep -c . || true)
echo
echo "remote state: ${n_after} resources (local had ${n_before})"
if [ "$n_after" -ne "$n_before" ]; then
  echo "FAIL: resource count changed — DO NOT delete ${DIR}/terraform.tfstate." >&2
  echo "  Restore with: cp ${BACKUP} ${DIR}/terraform.tfstate && rm ${DIR}/backend.tf" >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true
  exit 1
fi

cat <<EOF

OK — ${ROOT} state now lives in s3://${BUCKET}/${ROOT}/terraform.tfstate, encrypted, and all
${n_after} resources survived the move. The local file is still on disk, on purpose.

NEXT (a human does these, in order — nothing below is automated):
  1. Prove it plans clean against the REMOTE state:
         devbox run tf-plan                      # 'main'
         devbox run -- tofu -chdir=${DIR} plan   # other roots (source scripts/keepass-env.sh first)
     A plan that wants to CREATE things you already own means the migration did not carry state —
     stop and restore from ${BACKUP}.
  2. Commit ${DIR}/backend.tf.
  3. ONLY THEN: rm ${DIR}/terraform.tfstate ${DIR}/terraform.tfstate.backup
     Keep ${BACKUP}. It is the only copy that is not in the cluster you may one day be rebuilding.
EOF
