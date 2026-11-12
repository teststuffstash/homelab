# shellcheck shell=sh
# The allure-behavior-snippets release this island renders evidence with — ONE pin, sourced by
# scripts/gateway-evidence.sh, scripts/specs-build.sh and scripts/ci.sh (oracle-fleet
# scripts/lib/snippets.sh shape; ADR-156 = one portable process, pinned per repo). Consumed as a
# RELEASE WHEEL, never a git clone (anonymous git-upload-pack gets rate-limited from the NAT'd WAN
# IP — oracle-fleet#362). `allure-evidence` reads RAW allure results → evidence.json, <RULE>.md
# fragments, digest.md; `--spec` joins a page's tables to the evidence rows. v0.5.2 = the join reads
# `||`-divided decision tables and plain sub-sections; v0.6.x = rule 11 (the requirement describes
# the system, never its tests), the header IS the parameter list, ROW_UNKEYED + HEADER_UNTHREADED in
# the digest; v0.6.2 = prose rules soft, unproven facts MARKED (rule 11); v0.6.3 = expected columns
# end in `?` (argname `expected_<name>`), the `||` divider read but retired; v0.6.4 =
# `evidence-pack --mask-descriptions`, the specs reviewer's staged read (rows-brief check 10);
# v0.6.7 = a surviving blocking finding stays in the verdict until it carries a permitted
# disposition (snippets#43); v0.6.8 = pass1-prior.tsv + touched-rules scoped by glossary term
# (snippets#46/#48); v0.6.9 = the hygiene-repeat belt escalates only the cases a PR added or changed
# (`**Cases:**` + [added|changed|unchanged] marks in the digest) — the exemption applies where the
# consuming repo DECLARES a hygiene ratchet (snippets#49/#50): this island's is
# scripts/spec-hygiene-ratchet.py, declared in specs/README.md §Rules.
# Bump TOGETHER with SNIPPETS_VERSION in
# agents/specs-reviewer-session.sh (the reviewer's context pack) — one process, two consumers.
SNIPPETS_WHEEL=https://github.com/teststuffstash/allure-behavior-snippets/releases/download/v0.6.9/allure_behavior_snippets-0.6.9-py3-none-any.whl
# The wheel's sha256 — bump TOGETHER with the SNIPPETS_WHEEL line above and SNIPPETS_SHA256 in
# agents/specs-reviewer-session.sh (the reviewer's own copy of the same pin).
SNIPPETS_SHA256=4ca24515835b0969a6b225eef6e48a2d6337ec984367e74b0b4a1dc9def6ef16

# The wheel is fetched ONCE per machine into SNIPPETS_CACHE_DIR and verified against SNIPPETS_SHA256
# before every use (a hash is local; no network). A miss tries the release URL, then the GitHub API
# asset of the same release, each with bounded retries. Only a verified file is ever promoted into
# the cache; an HTML error page or a truncated body is discarded and never used as the wheel.
SNIPPETS_CACHE_DIR=${SNIPPETS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/allure-behavior-snippets}
SNIPPETS_FETCH_TRIES=${SNIPPETS_FETCH_TRIES:-3}
SNIPPETS_FETCH_BACKOFF=${SNIPPETS_FETCH_BACKOFF:-2}
# Set by _snippets_fetch: the file:// URL of the verified local wheel that the functions below hand
# to uv. SNIPPETS_WHEEL itself stays the remote pin (sp_pin_version parses it).
SNIPPETS_WHEEL_LOCAL=

# _snippets_sha256 <file> — the file's sha256 hex digest (sha256sum on Linux, shasum on macOS).
_snippets_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# _snippets_get <url> <dest> <accept> — one download attempt; non-zero on any transport or HTTP error.
_snippets_get() {
  curl -fsSL --connect-timeout 20 --max-time 120 -H "Accept: $3" -o "$2" "$1"
}

# _snippets_retry <command…> — run the command up to SNIPPETS_FETCH_TRIES times, backing off between.
_snippets_retry() {
  _snip_try=1
  while :; do
    "$@" && return 0
    if [ "$_snip_try" -ge "$SNIPPETS_FETCH_TRIES" ]; then
      return 1
    fi
    sleep $((_snip_try * SNIPPETS_FETCH_BACKOFF))
    _snip_try=$((_snip_try + 1))
  done
}

# _snippets_download_verified <url> <accept> — one attempt: download to a private partial file and
# promote it into the cache ONLY when its sha256 is the pin. Anything else is deleted.
_snippets_download_verified() {
  _snip_part="$SNIPPETS_CACHE_DIR/.partial.$$"
  if _snippets_get "$1" "$_snip_part" "$2" && [ "$(_snippets_sha256 "$_snip_part")" = "$SNIPPETS_SHA256" ]; then
    mv -f "$_snip_part" "$_snip_wheel_path"
    return 0
  fi
  rm -f "$_snip_part"
  return 1
}

# _snippets_api_asset_url — the API asset URL of the wheel within the pinned release (api.github.com,
# a different host from the download path, so it can answer when that one does not). Prints the URL.
_snippets_api_asset_url() {
  _snip_json="$SNIPPETS_CACHE_DIR/.release.$$.json"
  if ! _snippets_get "$_snip_api_release" "$_snip_json" application/vnd.github+json; then
    rm -f "$_snip_json"
    return 1
  fi
  _snip_rc=0
  python3 -I -c '
import json, sys
try:
    assets = json.load(open(sys.argv[1])).get("assets", [])
except Exception:
    sys.exit(1)  # not JSON (an error page): no asset, quietly
for asset in assets:
    if asset.get("name") == sys.argv[2]:
        print(asset["url"])
        break
else:
    sys.exit(1)
' "$_snip_json" "$_snip_name" || _snip_rc=$?
  rm -f "$_snip_json"
  return $_snip_rc
}

# _snippets_fetch — make sure the pinned wheel is in the cache and verified, then set
# SNIPPETS_WHEEL_LOCAL. A failure names the URLs it tried and leaves nothing cached.
_snippets_fetch() {
  _snip_name=${SNIPPETS_WHEEL##*/}
  case "$SNIPPETS_CACHE_DIR" in
    /*) _snip_dir=$SNIPPETS_CACHE_DIR ;;
    *) _snip_dir=$PWD/$SNIPPETS_CACHE_DIR ;;
  esac
  _snip_wheel_path=$_snip_dir/$_snip_name
  if [ -f "$_snip_wheel_path" ] && [ "$(_snippets_sha256 "$_snip_wheel_path")" = "$SNIPPETS_SHA256" ]; then
    SNIPPETS_WHEEL_LOCAL=file://$_snip_wheel_path
    return 0
  fi
  if ! mkdir -p "$_snip_dir"; then
    echo "snippets: cannot create the wheel cache $_snip_dir" >&2
    return 1
  fi
  _snip_repo=${SNIPPETS_WHEEL#https://github.com/}
  _snip_repo=${_snip_repo%%/releases/download/*}
  _snip_tag=${SNIPPETS_WHEEL#*/releases/download/}
  _snip_tag=${_snip_tag%%/*}
  _snip_api_release="https://api.github.com/repos/$_snip_repo/releases/tags/$_snip_tag"
  _snip_asset=

  if _snippets_retry _snippets_download_verified "$SNIPPETS_WHEEL" application/octet-stream; then
    :
  elif _snip_asset=$(_snippets_retry _snippets_api_asset_url) && [ -n "$_snip_asset" ] \
    && _snippets_retry _snippets_download_verified "$_snip_asset" application/octet-stream; then
    :
  else
    echo "snippets: cannot fetch the pinned wheel ($_snip_name, sha256 $SNIPPETS_SHA256) after $SNIPPETS_FETCH_TRIES tries each — release URL: $SNIPPETS_WHEEL; API URL: $_snip_api_release; nothing cached" >&2
    return 1
  fi
  SNIPPETS_WHEEL_LOCAL=file://$_snip_wheel_path
}

# allure_evidence <args…> — run the pinned tool's `allure-evidence` console script.
allure_evidence() {
  _snippets_fetch || return 1
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL_LOCAL}" allure-evidence "$@"
}

# allure_snippets_python <script.py> [args…] — run an island script that imports the pinned tool
# (`from allure_behavior_snippets import evidence`) inside the wheel's environment, so the island
# reuses the tool's own join and hygiene computation instead of re-implementing them
# (scripts/spec-join-ratchet.py, scripts/spec-hygiene-ratchet.py — the two ratchets in scripts/ci.sh).
allure_snippets_python() {
  _snippets_fetch || return 1
  uv run --no-project --with "allure-behavior-snippets @ ${SNIPPETS_WHEEL_LOCAL}" python "$@"
}
