# deploy-revert-judge — the gateway seam. The caller token is a temp file holding a plain fixture
# string (the pod's projected file in production). `curl` is shadowed: every call is recorded as
# `CALL curl <method> <url> [task=<key>] [auth: <header>] [<body>]` — the -o path (a mktemp) and the
# -w format are deliberately NOT recorded, so the stream is stable across machines. A list GET
# (`-G … task=<key>`) serves $REPLAY_WORLD/gateway/<slug-of-key>.json, or DIES unrecorded (an
# unrecorded read is the lie the harness exists to catch); an outcome POST serves
# $REPLAY_WORLD/gateway/outcome.json. Nothing here reaches the network. `gh` is the harness's stub.
_tokf="$(mktemp)"; printf 'fake-judge-token-projected' > "$_tokf"
GATEWAY_TOKEN_FILE="$_tokf"
curl() {
  local _o="" _d="" _m="GET" _u="" _q="" _prev="" _auth=""
  for _a in "$@"; do
    case "$_prev" in
      -o) _o="$_a";; --data-binary|-d) _d="$_a";; -X) _m="$_a";;
      --data-urlencode) _q="$_a";;
      -H) case "$_a" in @*) _auth="$(sed -n 's/^Authorization: //p' "${_a#@}")";; esac;;
    esac
    case "$_a" in http*) _u="$_a";; esac
    _prev="$_a"
  done
  printf 'CALL curl %s %s%s [auth: %s]%s\n' "$_m" "$_u" "${_q:+ $_q}" "${_auth:-none}" "${_d:+ $_d}" >> "$REPLAY_ACTIONS"
  local _f
  case "$_m" in
    GET)  _f="$REPLAY_WORLD/gateway/$(printf '%s' "${_q#task=}" | tr 'A-Z' 'a-z' | sed 's#[^a-z0-9]\{1,\}#-#g; s#^-##; s#-$##').json" ;;
    POST) _f="$REPLAY_WORLD/gateway/outcome.json" ;;
    *)    _f="" ;;
  esac
  [ -n "$_f" ] && [ -f "$_f" ] || { printf 'replay-bridge[curl]: no recorded gateway reply for %s %s %s (tried %s)\n' "$_m" "$_u" "$_q" "$_f" >&2; exit 9; }
  [ -z "$_o" ] || cat "$_f" > "$_o"
  printf '200'
}
