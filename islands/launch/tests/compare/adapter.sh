# shellcheck shell=bash
# Test-side adapter: stands where `agents/gateway-admit.sh` stands in the comparison's throwaway
# copy of the replay harness, and defines the three names the `gateway-admit` family's bridge calls.
# It only translates to and from the Python component (adapter.py): it builds no request and checks
# no answer. `curl` — the family's gateway seam, a shell function the bridge defines AFTER sourcing
# this file — is exported to the child so the component's transport can reach it.
_GW_ADAPTER_PY="${LAUNCH_COMPARE_DIR:?LAUNCH_COMPARE_DIR names islands/launch/tests/compare}/adapter.py"
_GW_SID=""; _GW_RELEASED=0
gw_preflight_caller() { return 0; }
_gw_py() {
  export -f curl; export GW_REPLY_HTTP GW_REPLY_BODY REPLAY_ACTIONS AGENT_GATEWAY_CALLER_TOKEN_FILE
  "${LAUNCH_PYTHON:-python3}" "$_GW_ADAPTER_PY" "$@"
}
gw_admit() {
  local _out _rc=0
  _out="$(mktemp)"
  _gw_py admit "$_out" -- "$@" || _rc=$?
  # shellcheck disable=SC1090  # the adapter's own mktemp output
  . "$_out"; rm -f "$_out"
  _GW_SID="$GW_SESSION_ID"; _GW_RELEASED=0
  return "$_rc"
}
gw_release() {
  [ -n "$_GW_SID" ] || return 0
  local _out; _out="$(mktemp)"
  _gw_py release "$_out" "$_GW_SID" "$_GW_RELEASED" || true
  # shellcheck disable=SC1090  # the adapter's own mktemp output
  . "$_out"; rm -f "$_out"
  _GW_RELEASED=1
  return 0
}
