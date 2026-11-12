#!/usr/bin/env bash
# lock-cache-check.sh — every store path a devbox.lock pins must be DOWNLOADABLE, never compiled.
#
#   bash scripts/lock-cache-check.sh <devbox.lock>…             check   (the ci step before the warm)
#   bash scripts/lock-cache-check.sh --hold <old-lock> <lock>   rewrite (scripts/devbox-update.sh)
#   bash scripts/lock-cache-check.sh --self-test                offline (run by devbox-update-test)
#
# WHY: devbox installs a locked package by its store path; when no substituter has that path it
# falls back to BUILDING the package from its flake ref. `devbox update` can resolve a package to a
# nixpkgs revision whose build the binary cache does not carry, so the lock merges a compile into
# every CI run's warm step — which then dies on the runner's memory limit instead of failing with a
# reason (homelab#3233: argocd 3.5.6 at an uncached path, four runner OOM kills, a lock revert that
# named five innocent packages). The rule lives where the lock is MADE and where it is first READ:
#
#   --hold  the generator's side. A package whose NEW path no substituter has is put back to its
#           entry in <old-lock> (the whole entry — version, resolved ref, paths), so the rest of the
#           weekly update still lands and the package retries next week. One `held <key> <version>
#           <path>` line per package on stdout. A package with no usable old entry cannot be held:
#           `unheld …` on stdout, the lock keeps it, and the check below reds the PR with its name.
#   check   the consumer's side, BEFORE the first `devbox run`. A locked path that is neither in the
#           local /nix/store (the runner image's baked closure) nor on a substituter is exit 1 with
#           the package named. Needs only bash + jq + curl — the tools the bare runner image has.
#
# Judged: the DEFAULT outputs of LOCK_CACHE_SYSTEM (x86_64-linux — the system CI and the pods run).
# Absent means every substituter ANSWERED 404; a substituter that could not be read (any other
# status, after retries) with no 200 elsewhere is exit 2 — cannot judge, never a pass and never a
# hold. Seams: LOCK_CACHE_SUBSTITUTERS (space-separated; default = nix's own list, else
# cache.nixos.org), LOCK_CACHE_PROBE (a command printing the HTTP status of the URL in $1),
# LOCK_CACHE_STORE (the local store dir; empty = no local shortcut).
set -uo pipefail

SYSTEM="${LOCK_CACHE_SYSTEM:-x86_64-linux}"
STORE="${LOCK_CACHE_STORE-/nix/store}"

substituters() {
  if [ -n "${LOCK_CACHE_SUBSTITUTERS:-}" ]; then printf '%s\n' "$LOCK_CACHE_SUBSTITUTERS"; return; fi
  local s=""
  if command -v nix >/dev/null 2>&1; then
    s="$(NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" nix config show substituters 2>/dev/null)" || s=""
  fi
  printf '%s\n' "${s:-https://cache.nixos.org}"
}

probe() {  # probe <url> → the HTTP status ("000" = no answer)
  if [ -n "${LOCK_CACHE_PROBE:-}" ]; then "$LOCK_CACHE_PROBE" "$1"; return; fi
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors "$1" 2>/dev/null || true
}

# cached <store-path> <substituter>… → 0 some substituter has it · 1 all answered 404 · 2 cannot judge
cached() {
  local hash sub code unknown=0
  hash="$(basename "$1")"; hash="${hash%%-*}"; shift
  for sub in "$@"; do
    code="$(probe "${sub%/}/$hash.narinfo")"
    case "$code" in
      200) return 0 ;;
      404) ;;
      *)   unknown=1 ;;
    esac
  done
  [ "$unknown" = 0 ] && return 1
  return 2
}

# lock_paths <lock-file> → "<package-key>\t<version>\t<store-path>" per default output of $SYSTEM
lock_paths() {
  jq -r --arg s "$SYSTEM" '
    .packages // {} | to_entries[] | .key as $k | .value.version as $v
    | (.value.systems[$s].outputs // [])
    | (if any(.default == true) then map(select(.default == true)) else . end)[]
    | select((.path // "") != "") | [$k, ($v // "?"), .path] | @tsv' "$1"
}

# uncached <lock-file> <local-shortcut 0|1> → the lock_paths rows no substituter has; rc 2 = cannot judge
uncached() {
  local rows key ver path rc subs
  rows="$(lock_paths "$1")" || { echo "lock-cache-check: cannot read $1" >&2; return 2; }
  # shellcheck disable=SC2207  # substituter URLs carry no spaces or globs
  subs=($(substituters))
  [ "${#subs[@]}" -gt 0 ] || { echo "lock-cache-check: no substituter to ask" >&2; return 2; }
  while IFS=$'\t' read -r key ver path; do
    [ -n "$key" ] || continue
    if [ "$2" = 1 ] && [ -n "$STORE" ] && [ "${path#"$STORE"/}" != "$path" ] && [ -e "$path" ]; then continue; fi
    cached "$path" "${subs[@]}"; rc=$?
    case "$rc" in
      0) ;;
      1) printf '%s\t%s\t%s\n' "$key" "$ver" "$path" ;;
      *) echo "lock-cache-check: no substituter answered for $key ($path) — asked: ${subs[*]}" >&2; return 2 ;;
    esac
  done <<<"$rows"
  return 0
}

check() {
  local lock miss rc=0 n
  for lock in "$@"; do
    [ -f "$lock" ] || { echo "lock-cache-check: no such lock: $lock" >&2; return 2; }
    miss="$(uncached "$lock" 1)" || return 2
    n="$(lock_paths "$lock" | grep -c . || true)"
    if [ -z "$miss" ]; then echo "lock-cache-check: $lock — $n locked path(s), none would be built from source"; continue; fi
    rc=1
    while IFS=$'\t' read -r key ver path; do
      echo "FAIL $lock: $key $ver is not in the binary cache ($path) — devbox would BUILD it from source"
    done <<<"$miss"
  done
  [ "$rc" = 0 ] || echo "lock-cache-check: the remedy is the lock, never the runner — keep that package's previous lock entry (scripts/devbox-update.sh holds it automatically) until the cache carries the new build"
  return "$rc"
}

hold() {  # hold <old-lock> <lock>
  local old="$1" lock="$2" miss key ver path tmp
  [ -f "$old" ] && [ -f "$lock" ] || { echo "lock-cache-check: --hold needs <old-lock> <lock>" >&2; return 2; }
  miss="$(uncached "$lock" 0)" || return 2
  [ -n "$miss" ] || return 0
  while IFS=$'\t' read -r key ver path; do
    # holdable: the old lock has the package at a DIFFERENT path (the same path would hold nothing)
    if jq -e --arg k "$key" --arg s "$SYSTEM" --arg p "$path" '
         .packages[$k] as $o | $o != null
         and ([$o.systems[$s].outputs[]?.path] | length > 0 and (index($p) | not))' "$old" >/dev/null 2>&1; then
      tmp="$(mktemp)"
      jq --arg k "$key" --slurpfile o "$old" '.packages[$k] = $o[0].packages[$k]' "$lock" >"$tmp" && cat "$tmp" >"$lock"
      rm -f "$tmp"
      echo "held $key $ver $path"
    else
      echo "unheld $key $ver $path"
    fi
  done <<<"$miss"
  return 0
}

self_test() {
  local t fails=0 n=0 got
  t="$(mktemp -d)"
  ok() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  want: $2"; echo "  got:  $3"; fails=$((fails+1)); fi; }
  lock() {  # lock <file> <key> <version> <hash> [<key> <version> <hash>…]
    local f="$1" j='{"lockfile_version":"1","packages":{}}'; shift
    while [ "$#" -ge 3 ]; do
      j="$(jq --arg k "$1" --arg v "$2" --arg p "/nix/store/$3-${1%@*}-$2" \
        '.packages[$k] = {resolved: ("github:NixOS/nixpkgs/rev-" + $v + "#" + ($k | sub("@.*"; ""))), version: $v,
                          systems: {"x86_64-linux": {outputs: [{name: "out", path: $p, default: true},
                                                              {name: "man", path: ($p + "-man")}]},
                                    "aarch64-darwin": {outputs: [{name: "out", path: ($p + "-darwin"), default: true}]}}}' <<<"$j")"
      shift 3
    done
    printf '%s\n' "$j" >"$f"
  }
  # the stub cache: hashes listed in $t/have answer 200, in $t/broken answer 503, the rest 404
  cat >"$t/probe" <<EOF
#!/usr/bin/env bash
h="\$(basename "\$1" .narinfo)"
grep -qx "\$h" "$t/broken" 2>/dev/null && { echo 503; exit 0; }
grep -qx "\$h" "$t/have" 2>/dev/null && { echo 200; exit 0; }
echo 404
EOF
  chmod +x "$t/probe"
  export LOCK_CACHE_PROBE="$t/probe" LOCK_CACHE_SUBSTITUTERS="http://mirror.invalid https://cache.invalid"
  STORE=""
  printf '%s\n' aaaa bbbb oldc >"$t/have"; : >"$t/broken"
  lock "$t/old.lock" jq@latest 1.0 aaaa argocd@latest 3.5.6 oldc
  lock "$t/new.lock" jq@latest 1.1 bbbb argocd@latest 3.5.6 newc

  got="$(check "$t/old.lock" 2>&1)"; ok "check: every path cached → exit 0" 0 "$?"
  got="$(check "$t/new.lock" 2>&1)"; ok "check: an uncached path → exit 1" 1 "$?"
  ok "check: names the package, not its cached sibling" 1 "$(grep -c '^FAIL .*argocd@latest 3.5.6' <<<"$got")"
  ok "check: the cached package is not named" 0 "$(grep -c 'jq@latest' <<<"$got")"
  # a non-default output and another system's path are never asked (only `out` of x86_64-linux is in `have`)
  ok "check: only default outputs of the judged system are probed" "" "$(uncached "$t/old.lock" 0)"

  echo newc >"$t/broken"
  check "$t/new.lock" >/dev/null 2>&1; ok "check: a substituter that cannot be read → exit 2, never a pass" 2 "$?"
  cp "$t/new.lock" "$t/h.lock"; got="$(hold "$t/old.lock" "$t/h.lock" 2>/dev/null)"
  ok "hold: an unreadable substituter → exit 2, the lock untouched" "2 same" "$? $(cmp -s "$t/new.lock" "$t/h.lock" && echo same || echo changed)"
  : >"$t/broken"

  # the local-store shortcut: a path already on disk is never built, so the check passes it — the
  # generator's hold never takes the shortcut (its own `devbox update` may have just built the path)
  mkdir -p "$t/store"; STORE="$t/store"
  jq --arg s "$t/store" '.packages["argocd@latest"].systems["x86_64-linux"].outputs[0].path = ($s + "/newc-argocd-3.5.6")' "$t/new.lock" >"$t/local.lock"
  : >"$t/store/newc-argocd-3.5.6"
  check "$t/local.lock" >/dev/null 2>&1; ok "check: a path in the local store is not a build → exit 0" 0 "$?"
  cp "$t/local.lock" "$t/h.lock"; got="$(hold "$t/old.lock" "$t/h.lock")"
  ok "hold: ignores the local store (held all the same)" "held argocd@latest 3.5.6 $t/store/newc-argocd-3.5.6" "$got"
  STORE=""

  cp "$t/new.lock" "$t/h.lock"; got="$(hold "$t/old.lock" "$t/h.lock")"
  ok "hold: reports the held package" "held argocd@latest 3.5.6 /nix/store/newc-argocd-3.5.6" "$got"
  ok "hold: the held package is back at its whole old entry" "$(jq -c '.packages["argocd@latest"]' "$t/old.lock")" "$(jq -c '.packages["argocd@latest"]' "$t/h.lock")"
  ok "hold: the cached package keeps its new entry" "$(jq -c '.packages["jq@latest"]' "$t/new.lock")" "$(jq -c '.packages["jq@latest"]' "$t/h.lock")"
  check "$t/h.lock" >/dev/null 2>&1; ok "hold: the held lock passes the check" 0 "$?"

  cp "$t/old.lock" "$t/h.lock"; got="$(hold "$t/old.lock" "$t/h.lock")"
  ok "hold: nothing uncached → no output, lock untouched" " same" "$got $(cmp -s "$t/old.lock" "$t/h.lock" && echo same || echo changed)"

  # no usable old entry: a package new to the lock, and one whose old entry is the same uncached path
  lock "$t/old2.lock" jq@latest 1.0 aaaa
  cp "$t/new.lock" "$t/h.lock"; got="$(hold "$t/old2.lock" "$t/h.lock")"
  ok "hold: a package new to the lock cannot be held" "unheld argocd@latest 3.5.6 /nix/store/newc-argocd-3.5.6 same" "$got $(cmp -s "$t/new.lock" "$t/h.lock" && echo same || echo changed)"
  cp "$t/new.lock" "$t/h.lock"; got="$(hold "$t/new.lock" "$t/h.lock")"
  ok "hold: an old entry at the same path cannot be held" "unheld argocd@latest 3.5.6 /nix/store/newc-argocd-3.5.6" "$got"

  rm -rf "$t"
  echo "lock-cache-check self-test: $((n - fails))/$n passed"
  [ "$fails" = 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  --hold)      shift; [ "$#" = 2 ] || { echo "usage: lock-cache-check.sh --hold <old-lock> <lock>" >&2; exit 2; }; hold "$1" "$2" ;;
  ""|-h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  *)           check "$@" ;;
esac
