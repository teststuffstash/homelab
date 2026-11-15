# ── bridge ── seams only, no gate logic. The shim's only collaborator is the REAL gh, which the pod
# hands it as VP_REAL_GH; here that is this function. It records every call as a CALL line (a
# `body=@<tmpfile>` argument is recorded as `body=@<file>` plus a BODY line carrying the file's
# content — the body reaching the POST is part of the contract), serves the world's pr-view.json
# for the FIRST `pr view` and pr-view-after.json (when the world has one) for every later one, and
# answers the reviews POST with a review id.
VP_STATE="$(mktemp -d)"
PR_NUMBER=3444
REPO_SLUG=teststuffstash/homelab
VP_REAL_GH=gh
VP_REVIEWED_HEAD_FILE="$VP_STATE/reviewed-head"
VP_DROP_RECORD="$VP_STATE/verdict-dropped"
printf '536ed6a0f0e1d2c3b4a5968778695a4b3c2d1e0f\n' > "$VP_REVIEWED_HEAD_FILE"
export PR_NUMBER REPO_SLUG VP_REAL_GH VP_REVIEWED_HEAD_FILE VP_DROP_RECORD

gh() {
  local _a _bodyf=""
  {
    printf 'CALL gh'
    for _a in "$@"; do
      case "$_a" in body=@*) _bodyf="${_a#body=@}"; printf ' body=@<file>' ;; *) printf ' %s' "$_a" ;; esac
    done
    printf '\n'
    [ -n "$_bodyf" ] && printf 'BODY %s\n' "$(cat "$_bodyf")"
  } >> "$REPLAY_ACTIONS"
  case "$1 ${2:-}" in
    "pr view")
      if [ "$*" = "pr view 3444 --repo teststuffstash/homelab --json state" ]; then printf '{"state":"OPEN"}\n'; return 0; fi
      if [ -f "$VP_STATE/viewed" ] && [ -f "$REPLAY_WORLD/gh/pr-view-after.json" ]; then cat "$REPLAY_WORLD/gh/pr-view-after.json"
      else cat "$REPLAY_WORLD/gh/pr-view.json"; fi
      : > "$VP_STATE/viewed" ;;
    "api -X")
      case "${3:-}" in POST) printf '9001\n' ;; PUT) printf '{}\n' ;; esac ;;
    "pr review") printf 'reviewed (passthrough)\n' ;;
  esac
  return 0
}
