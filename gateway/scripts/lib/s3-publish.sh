# shellcheck shell=bash
# REFERENCE IMPLEMENTATION for the minio-client → rclone migration (2026-10-28): nixpkgs marks
# minio-client insecure (abandoned upstream), which broke the oracle-fleet and circles legs of the
# weekly devbox-update. oracle-fleet's and circles' scripts/lib/s3-publish.sh port FROM this file —
# the mc→rclone verb map and every safety property below were proven here first (homelab PR lane,
# live round-trip against the gateway-specs bucket).
#
# Shared verified-write upload path for the specs publish + purge scripts — originally a copy of
# oracle-fleet scripts/lib/s3-publish.sh (the one home for the two lessons it encodes; keep in step):
#   * parallelism (oracle-fleet#129): the S3 client defaults serialized against Garage, where each
#     PUT pays a replicated fsync — an explicit, overridable worker count (rclone --transfers +
#     --checkers) uploads the set in one batch.
#   * verify-own-write (oracle-fleet#318): a bucket over quota 403'd EVERY PUT for a week while the
#     old `mc mirror --quiet` exited 0 and the publish step stayed green. The helpers run rclone with
#     --use-json-log, fail on a non-zero exit OR a non-zero error count in rclone's final stats
#     line, then post-verify a sentinel object at the destination (`rclone lsjson --stat`).
#
# mc → rclone map (paths: `alias/bucket/prefix` became `remote:bucket/prefix`):
#   mc alias set              → s3_publish_remote: RCLONE_CONFIG_<NAME>_* env (no config file, no
#                               secret on any command line)
#   mc mirror [--remove]      → rclone copy | rclone sync (excluded dest keys are kept by sync)
#   mc cp --recursive         → rclone copy
#   mc cp --attr K=V <f> <k>  → rclone copyto --ignore-times --header-upload "K: V"
#   mc stat --json            → rclone lsjson --stat --files-only + require "IsDir": false (see
#                               s3_publish_verify: on S3 a MISSING key stats as a dir, exit 0)
#   mc ls [--recursive|--json]→ rclone lsf -R --files-only | rclone lsjson --files-only
#   mc rm <key>               → rclone deletefile
#   mc rm --recursive --force → rclone delete
S3_PUBLISH_WORKERS="${S3_PUBLISH_WORKERS:-32}"
# rclone runs config-file-free: the remote lives in env only (s3_publish_remote).
export RCLONE_CONFIG=/dev/null

# s3_publish_remote <name> <endpoint> <access-key> <secret-key>
# Define the rclone S3 remote the helpers target as `<name>:bucket/key`, entirely in the
# environment (RCLONE_CONFIG_<NAME>_*) — the credentials never reach argv, so never `ps` or a log.
# Garage: path-style, region "garage"; no_check_bucket because the writer key owns objects, not
# the bucket (rclone would otherwise probe/create it on the first upload).
s3_publish_remote() {
  local n
  n=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  export "RCLONE_CONFIG_${n}_TYPE=s3" \
    "RCLONE_CONFIG_${n}_PROVIDER=Other" \
    "RCLONE_CONFIG_${n}_ENDPOINT=$2" \
    "RCLONE_CONFIG_${n}_ACCESS_KEY_ID=$3" \
    "RCLONE_CONFIG_${n}_SECRET_ACCESS_KEY=$4" \
    "RCLONE_CONFIG_${n}_REGION=garage" \
    "RCLONE_CONFIG_${n}_FORCE_PATH_STYLE=true" \
    "RCLONE_CONFIG_${n}_NO_CHECK_BUCKET=true"
}

# The flags every transfer shares: parallel (oracle-fleet#129) + a JSON log whose final stats line
# carries the run's error count (oracle-fleet#318).
_s3_publish_xfer_flags() {
  printf '%s\n' --transfers "$S3_PUBLISH_WORKERS" --checkers "$S3_PUBLISH_WORKERS" \
    --use-json-log --log-level INFO
}

# s3_publish_cp <src-dir> <dest>
# Recursive, parallel upload of a whole local directory, through the same checked path as a mirror
# (no remove, no sentinel).
s3_publish_cp() {
  s3_publish_mirror --sentinel '' "$1" "$2"
}

# rclone --use-json-log lines that mean "this object/step failed" (rclone v1.75.1, observed):
#   {"level":"error","msg":"Attempt 1/3 failed with 1 errors and: ... StatusCode: 403 ..."}
#   {"level":"critical","msg":"Failed to create file system for ..."}
S3_PUBLISH_ERROR_RE='"level"[[:space:]]*:[[:space:]]*"(error|critical)"'

# _s3_publish_check <label> <rc> <log-file>
# The #318 gate over one rclone run's JSON log: fail when rclone exited non-zero OR its FINAL stats
# line reports errors (stats are reset per --retries attempt, so the last line is the last
# attempt's truth). No stats line at all → any error-level line fails it. Prints the first errors.
_s3_publish_check() {
  local label="$1" rc="$2" out="$3" errors stats_errors
  errors=$(grep -cE "$S3_PUBLISH_ERROR_RE" "$out" || true)
  stats_errors=$(grep '"stats":{' "$out" | tail -1 | sed -n 's/.*"errors":\([0-9][0-9]*\).*/\1/p')
  echo "$label: rclone exit $rc, final-stats errors ${stats_errors:-n/a}, $errors error line(s)"
  if [ "$rc" -ne 0 ] || [ "${stats_errors:-0}" -gt 0 ] || { [ -z "$stats_errors" ] && [ "$errors" -gt 0 ]; }; then
    {
      echo "$label: FAILED — did not fully land (exit $rc, ${stats_errors:-?} error(s); issue #318). First errors:"
      grep -E "$S3_PUBLISH_ERROR_RE" "$out" | head -5
      # A non-zero exit with no JSON error line: show rclone's raw tail so the cause is in the log.
      [ "$errors" -gt 0 ] || tail -5 "$out"
    } >&2
    return 1
  fi
}

# s3_publish_mirror [--sentinel <rel-key>] [--remove] [rclone-filter-flags...] <src> <dest>
# Parallel mirror (the specs site). --remove makes <dest> an exact mirror (rclone sync — keys the
# filters exclude are left alone, never deleted); without it this is an add/overwrite copy. Other
# flags (--exclude '/report/**' ...) pass through verbatim. Fails (non-zero, errors printed) per
# _s3_publish_check, and when the sentinel — a key relative to <dest> that the mirror must have
# written, default index.html — is absent at <dest> after the mirror or differs in size from the
# same key under <src>. `--sentinel ''` skips the post-verify for a source with no stable key
# (printed, never silent). --checksum: a rebuilt site has fresh mtimes, so compare by MD5 (= the
# Garage ETag of a single-part object) instead of re-uploading or metadata-copying unchanged files.
s3_publish_mirror() {
  local sentinel=index.html verb=copy
  if [ "${1:-}" = "--sentinel" ]; then
    sentinel="$2"
    shift 2
  fi
  if [ "${1:-}" = "--remove" ]; then
    verb=sync
    shift
  fi
  local src="${*: -2:1}" dest="${*: -1}"
  # The JSON log goes to a FILE, never a shell variable: one line per object means megabytes for
  # the specs site, and in the CI runner's shell a variable that size bloated the environment of
  # every later exec ("head: Argument list too long", PR #458 run 33966417503 — the E2BIG class).
  local out rc=0 flags
  out=$(mktemp -t s3-publish-mirror.XXXXXX)
  mapfile -t flags < <(_s3_publish_xfer_flags)
  rclone "$verb" "${flags[@]}" --checksum "$@" >"$out" 2>&1 || rc=$?
  if ! _s3_publish_check "s3_publish_mirror: $verb $src -> $dest" "$rc" "$out"; then
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  s3_publish_verify "$src" "$dest" "$sentinel"
}

# s3_publish_put [--header <Name: value>]... <src-file> <dest-key>
# ONE object with custom headers (the gzipped single-file report: Content-Encoding, which a mirror
# cannot set per key) through the SAME verified-write path as s3_publish_mirror (issue #318):
# rclone copyto --ignore-times (always writes, like the old `mc cp`), fail per _s3_publish_check,
# then s3_publish_verify — the key must be present at <dest> with the source's size.
s3_publish_put() {
  local hdr=()
  while [ "${1:-}" = "--header" ]; do
    hdr+=(--header-upload "$2")
    shift 2
  done
  local src="$1" dest="$2"
  local out rc=0 flags
  out=$(mktemp -t s3-publish-put.XXXXXX)
  mapfile -t flags < <(_s3_publish_xfer_flags)
  rclone copyto "${flags[@]}" --ignore-times "${hdr[@]}" "$src" "$dest" >"$out" 2>&1 || rc=$?
  if ! _s3_publish_check "s3_publish_put: $src -> $dest" "$rc" "$out"; then
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  s3_publish_verify "$(dirname "$src")" "$(dirname "$dest")" "$(basename "$dest")"
}

# s3_publish_verify <src> <dest> <rel-key>
# Post-write check: stat the sentinel at <dest> (absent → fail) and compare its "Size" with the
# same key under <src> when both stat (mismatch → fail); if either side does not yield one the
# size check is skipped and said so — presence is the hard requirement. TRAP (observed live,
# rclone v1.75.1 on Garage): `rclone lsjson --stat` of a MISSING S3 key exits 0 with a synthetic
# {"IsDir": true, "Size": -1} (no real directories in a bucket); --files-only turns that into
# `null`, still exit 0. So presence = exit 0 AND an `"IsDir": false` object — never the exit alone.
s3_publish_verify() {
  local src="${1%/}" dest="${2%/}" key="$3"
  if [ -z "$key" ]; then
    echo "s3_publish_verify: NOTE — no sentinel key for $dest, post-verify skipped"
    return 0
  fi
  local have want have_size want_size
  local rc=0
  have=$(rclone lsjson --stat --files-only "$dest/$key" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$have" | grep -qE '"IsDir"[[:space:]]*:[[:space:]]*false'; then
    {
      echo "s3_publish_verify: VERIFY FAILED — $dest/$key is absent after the write; the server did not keep our writes (issue #318):"
      printf '%s\n' "$have" | sed -n 1,3p
    } >&2
    return 1
  fi
  have_size=$(_s3_publish_size "$have")
  want=$(rclone lsjson --stat --files-only "$src/$key" 2>/dev/null || true)
  want_size=$(_s3_publish_size "$want")
  if [ -n "$have_size" ] && [ -n "$want_size" ] && [ "$have_size" != "$want_size" ]; then
    echo "s3_publish_verify: VERIFY FAILED — $dest/$key is $have_size bytes but $src/$key is $want_size bytes: the write left stale bytes at the destination (issue #318)" >&2
    return 1
  fi
  if [ -n "$have_size" ] && [ -n "$want_size" ]; then
    echo "s3_publish_verify: verified $dest/$key present, $have_size bytes = source"
  else
    echo "s3_publish_verify: verified $dest/$key present (size not comparable: dest '${have_size:-?}' vs source '${want_size:-?}')"
  fi
}

# s3_publish_ls <rclone-ls-cmd...> — run a listing probe, its exit status captured APART from its
# output (oracle-fleet#529/#550: a failing probe must never read as "nothing there"). rclone
# reports a bucket prefix holding no objects as exit 3 "directory not found" — that one exit means
# empty (the old `mc ls` exit 0 + no rows); every other non-zero exit fails. Output on stdout.
s3_publish_ls() {
  local listing err rc=0
  err=$(mktemp -t s3-publish-ls.XXXXXX)
  listing="$(rclone "$@" 2>"$err")" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    echo "s3_publish_ls: probe failed (rclone $*, exit $rc): $(cat "$err")" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  [ "$rc" -eq 3 ] || printf '%s\n' "$listing"
}

# _s3_publish_size <rclone-lsjson-stat-output> → the first "Size": N value, or nothing.
_s3_publish_size() {
  printf '%s\n' "$1" | sed -n 's/.*"Size"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | sed -n 1p
}
