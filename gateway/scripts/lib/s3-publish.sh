# shellcheck shell=bash
# Shared verified-write upload path for the specs publish + purge scripts — a copy of
# oracle-fleet scripts/lib/s3-publish.sh (the one home for the two lessons it encodes; keep in step):
#   * parallelism (oracle-fleet#129): `mc mirror` defaults serialized against Garage, where each PUT
#     pays a replicated fsync — an explicit, overridable --max-workers uploads the set in one batch.
#   * verify-own-write (oracle-fleet#318): a bucket over quota 403'd EVERY PUT for a week while
#     `mc mirror --quiet` exited 0 and the publish step stayed green. The mirror helper runs mc in
#     --json mode and counts error events, then post-verifies a sentinel object at the destination.
S3_PUBLISH_WORKERS="${S3_PUBLISH_WORKERS:-32}"

# s3_publish_alias <alias> <endpoint> <access-key> <secret-key>
# Register the mc alias the upload helpers target (thin wrapper — kept here so both scripts share
# the one definition and the alias name never drifts between them).
s3_publish_alias() {
  mc alias set "$1" "$2" "$3" "$4" >/dev/null
}

# s3_publish_cp <src-dir> <dest>
# Recursive, parallel upload of a whole local directory (the allure report/svg/e2e trees).
s3_publish_cp() {
  mc cp --quiet --recursive --max-workers "$S3_PUBLISH_WORKERS" "$1" "$2"
}

# mc --json event lines that mean "this object/step failed" (mc RELEASE.2025-08-13, observed):
#   {"status":"error","error":{"message":"Unable to stat `...`.","cause":{...},"type":"fatal"}}
# Matched defensively: `"status":"error"` anywhere on the line OR a top-level `"error":` key —
# either is enough to say the mirror did not fully land. Success lines carry `"status":"success"`.
S3_PUBLISH_ERROR_RE='"status"[[:space:]]*:[[:space:]]*"error"|^\{[[:space:]]*"error"[[:space:]]*:'

# s3_publish_mirror [--sentinel <rel-key>] [mc-mirror-flags...] <src> <dest>
# Parallel mirror (the specs site; allure-publish's latest/ promote+prune). Extra flags
# (--overwrite, --remove, --exclude ...) pass through verbatim. Fails (non-zero, errors printed)
# when mc exits non-zero OR reports any error event, and when the sentinel — a key relative to
# <dest> that the mirror must have written, default index.html — is absent at <dest> after the
# mirror or differs in size from the same key under <src>. `--sentinel ''` skips the post-verify
# for a source with no stable key (printed, never silent).
s3_publish_mirror() {
  local sentinel=index.html
  if [ "${1:-}" = "--sentinel" ]; then
    sentinel="$2"
    shift 2
  fi
  local src="${*: -2:1}" dest="${*: -1}"
  # mc's --json output goes to a FILE, never a shell variable: one JSON line per object means
  # megabytes for the specs site, and in the CI runner's shell a variable that size bloated the
  # environment of every later exec ("head: Argument list too long", PR #458 run 33966417503 —
  # the E2BIG class; reproduced locally under `set -a`). Files have no such ceiling.
  local out rc=0
  out=$(mktemp -t s3-publish-mirror.XXXXXX)
  mc mirror --json --max-workers "$S3_PUBLISH_WORKERS" "$@" >"$out" 2>&1 || rc=$?
  local events errors
  events=$(grep -c '^{' "$out" || true)
  errors=$(grep -cE "$S3_PUBLISH_ERROR_RE" "$out" || true)
  echo "s3_publish_mirror: $src -> $dest: mc exit $rc, $events event(s), $errors error(s)"
  if [ "$rc" -ne 0 ] || [ "$errors" -gt 0 ]; then
    {
      echo "s3_publish_mirror: FAILED — mc mirror $src -> $dest did not fully land (exit $rc, $errors error event(s); issue #318). First errors:"
      grep -E "$S3_PUBLISH_ERROR_RE" "$out" | head -5
      # A non-zero exit with no JSON error line: show mc's raw tail so the cause is in the log.
      [ "$errors" -gt 0 ] || tail -5 "$out"
    } >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  s3_publish_verify "$src" "$dest" "$sentinel"
}

# s3_publish_put [--attr <mc-attr>] <src-file> <dest-key>
# ONE object with custom metadata (the gzipped single-file report: Content-Encoding needs --attr,
# which a mirror cannot set) through the SAME verified-write path as s3_publish_mirror (issue
# #318): mc cp in --json mode, fail on a non-zero exit or any error event, then s3_publish_verify
# — the key must be present at <dest> with the source's size. No --quiet: a rejected PUT must
# never read as green (PR #771 review).
s3_publish_put() {
  local attr=()
  if [ "${1:-}" = "--attr" ]; then
    attr=(--attr "$2")
    shift 2
  fi
  local src="$1" dest="$2"
  local out rc=0
  out=$(mktemp -t s3-publish-put.XXXXXX)
  mc cp --json "${attr[@]}" "$src" "$dest" >"$out" 2>&1 || rc=$?
  local errors
  errors=$(grep -cE "$S3_PUBLISH_ERROR_RE" "$out" || true)
  echo "s3_publish_put: $src -> $dest: mc exit $rc, $errors error(s)"
  if [ "$rc" -ne 0 ] || [ "$errors" -gt 0 ]; then
    {
      echo "s3_publish_put: FAILED — mc cp $src -> $dest did not land (exit $rc, $errors error event(s); issue #318). First errors:"
      grep -E "$S3_PUBLISH_ERROR_RE" "$out" | head -5
      [ "$errors" -gt 0 ] || tail -5 "$out"
    } >&2
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  s3_publish_verify "$(dirname "$src")" "$(dirname "$dest")" "$(basename "$dest")"
}

# s3_publish_verify <src> <dest> <rel-key>
# Post-write check for s3_publish_mirror: `mc stat` the sentinel at <dest> (absent → fail) and
# compare its size with the same key under <src> when both stat (mismatch → fail). Sizes are
# read from mc's `"size":N` field; if either side does not yield one the size check is skipped
# and said so — presence is the hard requirement.
s3_publish_verify() {
  local src="${1%/}" dest="${2%/}" key="$3"
  if [ -z "$key" ]; then
    echo "s3_publish_mirror: NOTE — no sentinel key for $dest, post-verify skipped (empty source?)"
    return 0
  fi
  local have want have_size want_size
  if ! have=$(mc stat --json "$dest/$key" 2>&1); then
    {
      echo "s3_publish_mirror: VERIFY FAILED — $dest/$key is absent after the mirror; the server did not keep our writes (issue #318):"
      printf '%s\n' "$have" | sed -n 1,3p
    } >&2
    return 1
  fi
  have_size=$(_s3_publish_size "$have")
  want=$(mc stat --json "$src/$key" 2>/dev/null || true)
  want_size=$(_s3_publish_size "$want")
  if [ -n "$have_size" ] && [ -n "$want_size" ] && [ "$have_size" != "$want_size" ]; then
    echo "s3_publish_mirror: VERIFY FAILED — $dest/$key is $have_size bytes but $src/$key is $want_size bytes: the mirror left stale bytes at the destination (issue #318)" >&2
    return 1
  fi
  if [ -n "$have_size" ] && [ -n "$want_size" ]; then
    echo "s3_publish_mirror: verified $dest/$key present, $have_size bytes = source"
  else
    echo "s3_publish_mirror: verified $dest/$key present (size not comparable: dest '${have_size:-?}' vs source '${want_size:-?}')"
  fi
}

# _s3_publish_size <mc-stat-json-line> → the first "size":N value, or nothing.
_s3_publish_size() {
  printf '%s\n' "$1" | sed -n 's/.*"size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n 1p
}
