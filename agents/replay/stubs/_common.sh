# agents/replay/stubs/_common.sh — shared guts of the PATH-shim stubs.
#
# Sourced by `gh` and `kubectl` in this directory via $REPLAY_STUB_DIR (never `dirname $0`: the
# stubs are COPIED onto $BIN and invoked through $PATH, so $0 is whatever the caller's shell
# resolved and is not a reliable anchor).
#
# Contract with the runner (agents/replay/run.sh):
#   $REPLAY_WORLD    fixture's world/ directory — the RECORDED responses
#   $REPLAY_ACTIONS  append-only action file — every invocation lands here as one `CALL` line
#   $REPLAY_STUB_DIR this directory
#
# Two behaviours, and the split is the whole design:
#   READ  → serve a recorded world file, or DIE. A read with no recording is the failure mode that
#           makes a replay lie (an empty payload usually parses, and the clause then asserts on
#           nothing), so it is loud and fatal — never an empty body with exit 0.
#   WRITE → record and return success. Mutations are the OUTPUT under test; serving them would be
#           replaying the world's reply to an action instead of asserting the action.
set -u

_rp_die() {   # _rp_die <message...> — exit 9, the "the fixture is wrong" code the runner reports
  printf 'replay-stub[%s]: %s\n' "${_RP_TOOL:-?}" "$*" >&2
  exit 9
}

# One argv → one line. Embedded newlines (a `--body` with prose in it, the common case) collapse to
# a literal \n so a CALL is always exactly one line and `diff` stays line-oriented.
_rp_record() {
  _rp_out="$_RP_TOOL"
  for _rp_a in "$@"; do
    _rp_esc="$(printf '%s' "$_rp_a" | sed ':a;N;$!ba;s/\n/\\n/g')"
    _rp_out="$_rp_out $_rp_esc"
  done
  printf 'CALL %s\n' "$_rp_out" >> "$REPLAY_ACTIONS"
}

# The bare words of an invocation — the command path plus its positionals, with options and their
# values dropped. `gh pr view 234 --repo o/r --json a,b` → `pr view 234`. This is what a world file
# is keyed on: the SHAPE of the call, not the flags a clause happens to pass today (a clause that
# adds a --json field must not have to re-record its world).
_RP_VALUE_FLAGS=" -n --namespace -o --output --repo -R --json -q --jq -l --selector -f --filename
 -L --limit -H --header -X --method -F --field --template --kubeconfig --context --body --body-file
 --field-selector -c --container --label --search --state --author --base --head --add-label
 --remove-label --title --raw-field --input --hostname --cache --subresource --type -p --patch "
_rp_words() {
  _rp_w=""; _rp_skip=0
  for _rp_a in "$@"; do
    if [ "$_rp_skip" = 1 ]; then _rp_skip=0; continue; fi
    case "$_rp_a" in
      --*=*) continue ;;
      -*)    case "$_RP_VALUE_FLAGS" in *" $_rp_a "*) _rp_skip=1 ;; esac; continue ;;
    esac
    _rp_w="${_rp_w}${_rp_w:+ }${_rp_a}"
  done
  printf '%s' "$_rp_w"
}

_rp_slug() {   # "pr view 234" → "pr-view-234"
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's#[^a-z0-9]\{1,\}#-#g; s#^-##; s#-$##'
}

# Serve the most specific recording that exists, shortening the key one word at a time:
# world/gh/pr-view-234.json → world/gh/pr-view.json → world/gh/pr.json. So a fixture records once
# per call SHAPE and only pins a positional when it needs two different answers for it.
_rp_serve() {
  _rp_k="$1"; _rp_orig="$1"; _rp_tried=""
  while [ -n "$_rp_k" ]; do
    for _rp_ext in .json .txt ''; do
      _rp_f="$REPLAY_WORLD/$_RP_TOOL/$(_rp_slug "$_rp_k")$_rp_ext"
      _rp_tried="$_rp_tried  $_rp_f
"
      [ -f "$_rp_f" ] && { cat "$_rp_f"; return 0; }
    done
    case "$_rp_k" in *' '*) _rp_k="${_rp_k% *}" ;; *) _rp_k="" ;; esac
  done
  printf 'replay-stub[%s]: no recorded world file for this READ.\n' "$_RP_TOOL" >&2
  printf '  call:  %s %s\n' "$_RP_TOOL" "$_rp_orig" >&2
  printf '  tried:\n%s' "$_rp_tried" >&2
  printf '  Record it: %s ... | tee %s/%s/<key>.json  (see docs/agents/workflow.md §Replay harness)\n' \
    "$_RP_TOOL" "$REPLAY_WORLD" "$_RP_TOOL" >&2
  exit 9
}

# Is any of the leading bare words a mutating verb? Checking the first three covers both shapes in
# play — `kubectl apply`, verb first, and `gh pr comment`, verb second.
_rp_is_mutation() {   # _rp_is_mutation "<verb list>" "<bare words>"
  _rp_verbs=" $1 "; _rp_n=0
  for _rp_a in $2; do
    _rp_n=$((_rp_n + 1)); [ "$_rp_n" -gt 3 ] && break
    case "$_rp_verbs" in *" $_rp_a "*) return 0 ;; esac
  done
  return 1
}
