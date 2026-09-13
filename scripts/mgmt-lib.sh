#!/usr/bin/env bash
# mgmt-lib — shared helpers for the management box's two loops (ADR-131, docs/management-box.md
# §MB3): scripts/mgmt-sentinel.sh (plan-on-PR) and scripts/mgmt-apply.sh (master → apply).
# SOURCED, never run. Tools: bash git curl jq openssl coreutils gnugrep gawk gnused + `devbox run`
# (tofu, yq) — resolved from $REPO, a checkout of this repo. No `gh`: the box mints its own App
# token (mgmt_gh_token) — gh is not in the closure and the App IS the identity (ADR-130).
#
# Env the callers set (from /var/lib/mgmt/sentinel.env — scripts/mgmt-provision-secrets.sh):
#   MGMT_GH_APP_ID MGMT_GH_APP_INSTALLATION_ID MGMT_GH_APP_KEY_FILE   the homelab-sentinel App
#   ORG (teststuffstash) MGMT_REPO (homelab)
#   MGMT_STATE_DIR   main's LOCAL state lives at $MGMT_STATE_DIR/main/terraform.tfstate (-state=)
#   TOFU_VAR_DIR     $TOFU_VAR_DIR/<root>.tfvars → -var-file= when present
#   TF_PLUGIN_CACHE_DIR  shared provider cache (created on demand)
#   MGMT_SHADOW=1    no GitHub writes (the callers log the would-be status/comment)
#
# Verdict-only leaves the box: mgmt_post_status / mgmt_upsert_comment carry addresses + counts,
# never attribute values. Plan text and `tofu show -json` stay local.

_mgmt_log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
declare -F log >/dev/null 2>&1 || log() { _mgmt_log "$@"; }   # a sourcing script's own log() wins (iac-sentinel.sh)

MGMT_API="https://api.github.com"
_MGMT_TOKEN=""

# ── the App token ──────────────────────────────────────────────────────────────────────────────
# RS256 JWT (scripts/gh-app-runner-token.sh's primitive) → installation token, cached per run.
# Empty on any failure — callers treat an empty token as SHADOW with a loud line.
_b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
mgmt_gh_token() {
  [ -n "$_MGMT_TOKEN" ] && { printf '%s' "$_MGMT_TOKEN"; return 0; }
  local id="${MGMT_GH_APP_ID:-}" inst="${MGMT_GH_APP_INSTALLATION_ID:-}" key="${MGMT_GH_APP_KEY_FILE:-}"
  if [ -z "$id" ] || [ -z "$inst" ] || [ ! -r "$key" ]; then
    return 1
  fi
  local now header payload unsigned signature jwt tok
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$id")
  unsigned="$(printf '%s' "$header" | _b64url).$(printf '%s' "$payload" | _b64url)"
  signature=$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$key" -binary | _b64url) || return 1
  jwt="${unsigned}.${signature}"
  tok=$(curl -fsS --max-time 20 -X POST \
    -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$MGMT_API/app/installations/$inst/access_tokens" 2>/dev/null | jq -r '.token // empty') || return 1
  [ -n "$tok" ] || return 1
  _MGMT_TOKEN="$tok"; printf '%s' "$tok"
}

# gh_api <method> <path-after-/repos/ORG/REPO or absolute /…> [json-body] → body on stdout.
# Non-2xx → return 1, body on stderr (PROBE-FAIL over silent empty state). Paginates nothing —
# use gh_api_paged for list endpoints.
gh_api() {
  local method="$1" path="$2" body="${3:-}" tok url out code
  tok="$(mgmt_gh_token)" || { echo "gh_api: no App token" >&2; return 1; }
  case "$path" in /*) url="$MGMT_API$path" ;; *) url="$MGMT_API/repos/${ORG}/${MGMT_REPO}/$path" ;; esac
  out="$(mktemp)"
  if [ -n "$body" ]; then
    code=$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" -H "Content-Type: application/json" \
      --data "$body" "$url")
  else
    code=$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$url")
  fi
  case "$code" in
    2*) cat "$out"; rm -f "$out"; return 0 ;;
    *)  echo "gh_api: $method $url → HTTP $code: $(head -c 300 "$out")" >&2; rm -f "$out"; return 1 ;;
  esac
}
# gh_api_paged <path> → concatenated JSON array over ?page=1..N (per_page=100)
gh_api_paged() {
  local path="$1" page=1 sep='?' acc='[]' chunk n
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    chunk="$(gh_api GET "${path}${sep}per_page=100&page=${page}")" || return 1
    n=$(jq 'length' <<<"$chunk") || return 1
    acc=$(jq -c --argjson a "$acc" '. as $b | $a + $b' <<<"$chunk")
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
  printf '%s' "$acc"
}

# mgmt_post_status <sha> <context> <state> <description> — the enforcement write. Shadow = log only.
mgmt_post_status() {
  local sha="$1" ctx="$2" state="$3" desc="$4"
  desc="$(printf '%s' "$desc" | head -c 130)"   # GitHub caps description at 140
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then
    log "[shadow] status $ctx=$state on ${sha:0:8}: $desc"; return 0
  fi
  if ! gh_api POST "statuses/$sha" "$(jq -nc --arg s "$state" --arg c "$ctx" --arg d "$desc" \
        '{state:$s, context:$c, description:$d}')" >/dev/null; then
    log "[${sha:0:8}] STATUS POST FAILED ($ctx=$state) — stays pending, next run retries"
    return 1
  fi
  log "[${sha:0:8}] status $ctx=$state: $desc"
}

# mgmt_upsert_comment <pr> <marker> <body-file> — one comment per PR, edited in place.
mgmt_upsert_comment() {
  local pr="$1" marker="$2" bodyf="$3" existing body
  if [ "${MGMT_SHADOW:-0}" = 1 ]; then
    log "[shadow] comment on #$pr ($(wc -l <"$bodyf") lines):"; sed 's/^/    /' "$bodyf"; return 0
  fi
  body="$(jq -Rs --arg m "$marker" '$m + "\n" + .' "$bodyf")"
  existing="$(gh_api_paged "issues/$pr/comments" | jq -r --arg m "$marker" '[.[] | select(.body | startswith($m))][0].id // empty')" || existing=""
  if [ -n "$existing" ]; then
    gh_api PATCH "issues/comments/$existing" "{\"body\":$body}" >/dev/null && log "[#$pr] comment updated"
  else
    gh_api POST "issues/$pr/comments" "{\"body\":$body}" >/dev/null && log "[#$pr] comment posted"
  fi
}

# ── policy ─────────────────────────────────────────────────────────────────────────────────────
# mgmt_policy_load <repo-dir> <ref> → path of a temp copy of policy/mgmt/plan-input.yaml at <ref>
# (origin/master on the box — NEVER the PR's copy). Empty + return 1 when absent.
mgmt_policy_load() {
  local repo="$1" ref="$2" f
  f="$(mktemp --suffix=.yaml)"
  if ! git -C "$repo" show "${ref}:policy/mgmt/plan-input.yaml" >"$f" 2>/dev/null || [ ! -s "$f" ]; then
    rm -f "$f"; echo "policy: policy/mgmt/plan-input.yaml missing at $ref" >&2; return 1
  fi
  printf '%s' "$f"
}
_yq() { ( cd "${REPO:-$PWD}" && devbox run --quiet -- yq "$@" ); }
# mgmt_policy_get <policy> <expr> — yq over the policy file, raw lines out
mgmt_policy_get() { _yq -r "$2" "$1"; }

# mgmt_roots_touched <policy> <files…via stdin, one per line> → root names, one per line (deduped)
# A path under roots[X].dir/ (longest dir wins) → X; a path under a foreign_roots dir → none;
# anything not under any root dir → none.
# FAILS CLOSED (rc 1, a line on stderr) when the policy cannot be read — a yq/devbox hiccup, a
# missing file, a roots map with no entries or a root without a dir. An EMPTY result here means
# "no box-held surface touched" = a success status, so a read failure must never degrade into it
# (review finding on homelab#1631: `mapfile < <(…)` discards the producer's rc and pipefail does
# not cover process substitution). Callers capture the output with `$(…) || …`, not mapfile.
mgmt_roots_touched() {
  local pol="$1" f root dir best bestdir foreign n d out
  local -a names dirs foreigns
  out="$(mgmt_policy_get "$pol" '.roots | keys | .[]')" || { echo "policy: roots unreadable ($pol)" >&2; return 1; }
  [ -n "$out" ] || { echo "policy: no roots in $pol" >&2; return 1; }
  mapfile -t names <<<"$out"
  for n in "${names[@]}"; do
    d="$(mgmt_policy_get "$pol" ".roots.\"$n\".dir")" && [ -n "$d" ] && [ "$d" != null ] \
      || { echo "policy: root $n has no dir" >&2; return 1; }
    dirs+=("$d")
  done
  out="$(mgmt_policy_get "$pol" '.foreign_roots[]?')" || { echo "policy: foreign_roots unreadable" >&2; return 1; }
  mapfile -t foreigns <<<"$out"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    foreign=0
    for dir in "${foreigns[@]}"; do [ -n "$dir" ] || continue; case "$f" in "$dir"/*) foreign=1 ;; esac; done
    [ $foreign = 1 ] && continue
    best=""; bestdir=""
    for i in "${!names[@]}"; do
      dir="${dirs[$i]}"
      case "$f" in "$dir"/*) [ ${#dir} -gt ${#bestdir} ] && { best="${names[$i]}"; bestdir="$dir"; } ;; esac
    done
    [ -n "$best" ] && printf '%s\n' "$best"
  done | sort -u
}
# mgmt_roots_touched_at <repo-dir> <ref> <files…via stdin> → mgmt_roots_touched over the policy AT
# <ref> (a temp copy, cleaned up); the classifier's rc survives the cleanup — never end a subshell
# in `rm -f` and read its status (the #1631 fail-open).
mgmt_roots_touched_at() {
  local pol rc
  pol="$(mgmt_policy_load "$1" "$2")" || return 1
  mgmt_roots_touched "$pol"; rc=$?
  rm -f "$pol"
  return $rc
}
mgmt_root_dir()   { mgmt_policy_get "$1" ".roots.\"$2\".dir"; }
# mgmt_root_excludes <policy> <root> <checkout-root-dir> → "-exclude=<addr>" args for every state
# resource of a type in roots[X].plan_exclude_types (github: the admin-only repo settings). Reads
# the STATE's address list (never the PR tree) — the exclusion set cannot be widened by a head.
# rc 1 when the policy or the state list cannot be read — the caller fails the plan rather than
# running it un-excluded (a silently empty exclusion set is the #1631 fail-open class).
mgmt_root_excludes() {
  local pol="$1" root="$2" dir="$3" t types_out addrs
  local -a types
  types_out="$(mgmt_policy_get "$pol" ".roots.\"$root\".plan_exclude_types[]?")" || return 1
  [ -n "$types_out" ] || return 0
  mapfile -t types <<<"$types_out"
  addrs="$( cd "$REPO" && devbox run --quiet -- tofu -chdir="$dir" state list 2>/dev/null )" || return 1
  printf '%s\n' "$addrs" \
    | while IFS= read -r addr; do for t in "${types[@]}"; do case "$addr" in "$t".*) printf -- '-exclude=%s\n' "$addr" ;; esac; done; done
}
mgmt_root_apply() { mgmt_policy_get "$1" ".roots.\"$2\".apply // false"; }
# mgmt_root_exclude_note <policy> <root> → the human line the verdict prints beside "not planned"
mgmt_root_exclude_note() { mgmt_policy_get "$1" ".roots.\"$2\".plan_exclude_note // \"\""; }

# mgmt_stage1 <policy> <repo-dir> <base-sha> <head-sha> → prints hits "rule<TAB>file<TAB>detail",
# one per line; exit 0 with no output = clean; rc 1 = the classifier could not read the policy (no
# verdict — the caller skips the head, never treats it as clean). Pure: reads the trees/diff as
# DATA, executes nothing.
# Only files inside a touched root's dir are judged (foreign roots + non-tofu paths are not this
# box's business). Checks: deny_paths (basename glob), symlinks in the head tree, deny_patterns
# over ADDED lines of the diff.
mgmt_stage1() {
  local pol="$1" repo="$2" base="$3" head="$4"
  local -a files roots dirs denyp denyre
  # EVERY read below is `$(…) || return 1` — never `mapfile < <(…)`, which discards the producer's
  # rc: a failed git diff / policy read would otherwise judge the head CLEAN (empty file list, no
  # dirs, no deny rules) — the #1631 fail-open class, second round.
  local files_out roots_out dirs_out denyp_out denyre_out r
  files_out="$(git -C "$repo" diff --name-only "$base" "$head" --)" || return 1
  [ -n "$files_out" ] || return 0
  mapfile -t files <<<"$files_out"
  roots_out="$(printf '%s\n' "${files[@]}" | mgmt_roots_touched "$pol")" || return 1   # classifier failed: no verdict
  [ -n "$roots_out" ] || return 0
  mapfile -t roots <<<"$roots_out"
  dirs_out="$(for r in "${roots[@]}"; do mgmt_root_dir "$pol" "$r" || exit 1; done)" || return 1
  mapfile -t dirs <<<"$dirs_out"
  denyp_out="$(mgmt_policy_get "$pol" '.deny_paths[]?')" || return 1
  denyre_out="$(mgmt_policy_get "$pol" '.deny_patterns[]?')" || return 1
  denyp=(); [ -n "$denyp_out" ] && mapfile -t denyp <<<"$denyp_out"
  denyre=(); [ -n "$denyre_out" ] && mapfile -t denyre <<<"$denyre_out"
  local f inside d pat mode base_f
  local -a judged=()
  for f in "${files[@]}"; do
    inside=0
    for d in "${dirs[@]}"; do case "$f" in "$d"/*) inside=1 ;; esac; done
    [ $inside = 1 ] || continue
    judged+=("$f")
    base_f="${f##*/}"
    for pat in "${denyp[@]}"; do
      # shellcheck disable=SC2254
      case "$base_f" in $pat) printf 'deny_paths\t%s\t%s\n' "$f" "$pat" ;; esac
    done
    mode="$(git -C "$repo" ls-tree "$head" -- "$f" 2>/dev/null | awk '{print $1}')"
    [ "$mode" = "120000" ] && printf 'symlink\t%s\t%s\n' "$f" "mode 120000 in the head tree"
  done
  [ ${#judged[@]} -gt 0 ] || return 0
  # ADDED lines of the diff over the judged files, tagged by file
  local cur=""
  while IFS= read -r line; do
    case "$line" in
      +++\ b/*) cur="${line#+++ b/}"; continue ;;
      +++\ *|---\ *) continue ;;
      +*) line="${line#+}"
          for pat in "${denyre[@]}"; do
            if printf '%s' "$line" | grep -Eq -- "$pat"; then
              printf 'deny_patterns\t%s\t%s\n' "$cur" "$pat"
            fi
          done ;;
    esac
  done < <(git -C "$repo" diff --no-color --unified=0 "$base" "$head" -- "${judged[@]}")
  return 0
}

# ── tofu ───────────────────────────────────────────────────────────────────────────────────────
# mgmt_plan_root <checkout> <policy> <root> <plan-out> [lock:true|false] → rc 0 no-changes / 2 changes /
# 1 error (stderr+stdout captured to <plan-out>.log). main = local state via -state=; a root
# with backend.tf = tofu-state-env.sh in a subshell (the mgmt-probe.sh pattern).
# ⚠ EXECUTION SURFACE (review finding on homelab#1619): <checkout> may be an UNTRUSTED PR
# worktree. Nothing of it is ever executed — `devbox run` resolves devbox.json (its init_hook
# runs!) from the cwd, so every tool invocation runs FROM $REPO (the loop's own clone, reset to
# origin/master each run) and tofu is pointed at the worktree by ABSOLUTE -chdir; the state-env
# script is $REPO's copy, never the worktree's. Stage 1 judges the tofu tree only, and this is
# what makes that sufficient.
mgmt_plan_root() {
  local co="$1" pol="$2" root="$3" out="$4" lock="${5:-false}" dir rel logf varfile stateargs
  rel="$(mgmt_root_dir "$pol" "$root")"; dir="$co/$rel"; logf="$out.log"
  [ -n "${REPO:-}" ] && [ -f "$REPO/devbox.json" ] || { echo "REPO unset or not a checkout — refusing to run tooling from the plan tree" >"$logf"; return 1; }
  varfile=""; [ -n "${TOFU_VAR_DIR:-}" ] && [ -f "$TOFU_VAR_DIR/$root.tfvars" ] && varfile="-var-file=$TOFU_VAR_DIR/$root.tfvars"
  stateargs=""
  if [ ! -f "$dir/backend.tf" ]; then
    [ -n "${MGMT_STATE_DIR:-}" ] || { echo "MGMT_STATE_DIR unset — cannot plan $root" >"$logf"; return 1; }
    [ -s "$MGMT_STATE_DIR/$root/terraform.tfstate" ] || { echo "no state at $MGMT_STATE_DIR/$root/terraform.tfstate — refusing to plan against an empty state (it would plan to CREATE the world)" >"$logf"; return 1; }
    stateargs="-state=$MGMT_STATE_DIR/$root/terraform.tfstate"
  fi
  mkdir -p "${TF_PLUGIN_CACHE_DIR:-/var/lib/mgmt/plugin-cache}"; export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-/var/lib/mgmt/plugin-cache}"
  (
    set +u
    cd "$REPO" || exit 1   # the TRUSTED tree: devbox.json + scripts/ from origin/master
    if [ -f "$dir/backend.tf" ]; then
      TOFU_STATE_ROOT_DIR="$dir" . "$REPO/scripts/tofu-state-env.sh" >/dev/null 2>&1 || { echo "tofu-state-env.sh failed for $root" >&2; exit 1; }
    fi
    # per-root env hook from the TRUSTED tree (scripts/mgmt-root-env/<root>.sh) — e.g. github's App keys
    [ -f "$REPO/scripts/mgmt-root-env/$root.sh" ] && . "$REPO/scripts/mgmt-root-env/$root.sh"
    devbox run --quiet -- tofu -chdir="$dir" init -input=false -lockfile=readonly -lock=false >/dev/null 2>&1 \
      || { echo "tofu init failed for $root" >&2; devbox run --quiet -- tofu -chdir="$dir" init -input=false -lockfile=readonly -lock=false 2>&1 | tail -5 >&2; exit 1; }
    excl_out="$(mgmt_root_excludes "$pol" "$root" "$dir")" || { echo "plan_exclude_types for $root could not be resolved (policy or state list unreadable) — not planning un-excluded" >&2; exit 1; }
    excludes=(); [ -n "$excl_out" ] && mapfile -t excludes <<<"$excl_out"
    # what this plan did NOT judge — the verdict must say so (a reviewer reads the comment, not the policy)
    printf '%s\n' "${excludes[@]#-exclude=}" | grep -v '^$' > "$out.excluded" || true
    # every address in state — the verdict's "not planned" set is this minus what the plan carried,
    # so an exclusion's DEPENDENTS (tofu excludes them too, silently) are named as well
    devbox run --quiet -- tofu -chdir="$dir" state list 2>/dev/null | sort > "$out.state" || true
    # shellcheck disable=SC2086
    devbox run --quiet -- tofu -chdir="$dir" plan -detailed-exitcode -input=false -lock="$lock" -out="$out" $stateargs $varfile "${excludes[@]}"
  ) >"$logf" 2>&1
  local rc=$?
  case $rc in 0|2) return $rc ;; *) return 1 ;; esac
}

# mgmt_plan_changes <checkout> <policy> <root> <plan-out> → lines "address<TAB>actions" for every
# resource change that is not a no-op (actions joined by '+', e.g. delete+create = replace).
# ⚠ Returns 1 (and prints why on stderr) when `tofu show -json` fails — the caller MUST treat that
# as a failed verdict, never as "no changes". The 2026-09-13 false negative: the github root's
# plan file embeds an ENCRYPTED state snapshot, `show` ran without TF_ENCRYPTION (only the plan
# subshell sourced the state env), failed with stderr suppressed, and an empty list was counted as
# +0 ~0 -0 on homelab#1617 while the plan had exit code 2. Same env as the plan, same subshell.
mgmt_plan_changes() {
  local co="$1" pol="$2" root="$3" out="$4" rel dir json
  rel="$(mgmt_root_dir "$pol" "$root")"; dir="$co/$rel"
  json="$(
    set +u
    cd "$REPO" || exit 1
    if [ -f "$dir/backend.tf" ]; then
      TOFU_STATE_ROOT_DIR="$dir" . "$REPO/scripts/tofu-state-env.sh" >/dev/null 2>&1 || { echo "tofu-state-env.sh failed for $root (show)" >&2; exit 1; }
    fi
    [ -f "$REPO/scripts/mgmt-root-env/$root.sh" ] && . "$REPO/scripts/mgmt-root-env/$root.sh"
    devbox run --quiet -- tofu -chdir="$dir" show -json "$out" 2>&1
  )" || { echo "plan summary FAILED for $root: $(printf '%s' "$json" | grep -v '^\s*$' | tail -2 | tr '\n' ' ' | head -c 300)" >&2; return 1; }
  printf '%s' "$json" | jq -e '.resource_changes' >/dev/null 2>&1 \
    || { echo "plan summary FAILED for $root: show -json produced no resource_changes" >&2; return 1; }
  # side channel for the verdict: every address the plan carried (no-ops included) — see mgmt_plan_root's $out.state
  printf '%s' "$json" | jq -r '.resource_changes[]?.address' | sort > "$out.planned"
  printf '%s' "$json" | jq -r '.resource_changes[]? | select(.change.actions != ["no-op"]) | [.address, (.change.actions | join("+"))] | @tsv'
}
# mgmt_plan_not_planned <plan-out> → the state addresses the plan did NOT carry (explicit excludes +
# their dependents), one per line; empty when nothing was excluded or the state list is unavailable
mgmt_plan_not_planned() {
  [ -s "$1.state" ] && [ -f "$1.planned" ] || return 0
  comm -23 "$1.state" "$1.planned"
}
# mgmt_plan_counts <changes-lines> → "add change destroy replace"
mgmt_plan_counts() {
  awk -F'\t' 'BEGIN{a=c=d=r=0} $2=="create"{a++} $2=="update"{c++} $2=="delete"{d++} $2~/\+/{r++} END{print a, c, d, r}'
}
# mgmt_apply_allowed <policy> <root> <changes-lines on stdin> → prints the addresses OUTSIDE the
# apply allowlist (empty = all allowed). apply:false roots → every address is outside.
mgmt_apply_allowed() {
  local pol="$1" root="$2" addr acts ok pat
  local -a globs
  mapfile -t globs < <(mgmt_policy_get "$pol" ".apply_addresses.\"$root\"[]?")
  while IFS=$'\t' read -r addr acts; do
    [ -n "$addr" ] || continue
    ok=0
    for pat in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case "$addr" in $pat) ok=1 ;; esac
    done
    [ $ok = 1 ] || printf '%s\n' "$addr"
  done
}

# mgmt_clone <dir> <url> — own clone for a loop (never the box's system checkout); fetch each run
# and RESET the working tree to origin/master: this tree is the trusted tooling (devbox.json,
# scripts/) every plan runs from, so it must be master's, not clone-time's.
mgmt_clone() {
  local dir="$1" url="$2"
  if [ ! -d "$dir/.git" ]; then
    mkdir -p "$(dirname "$dir")"
    git clone --quiet "$url" "$dir" || return 1
  fi
  git -C "$dir" fetch --quiet --prune origin || return 1
  git -C "$dir" reset --quiet --hard origin/master || return 1
}
