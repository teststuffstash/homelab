# shellcheck shell=bash
# shellcheck disable=SC2034  # the GW_* globals are this helper's OUTPUTS — read by the sourcing launcher
# gateway-admit.sh — admission through the agent-gateway's POST /sessions. ONE implementation,
# sourced by every launcher whose LLM session the gateway admits (FU-270; operator ruling
# 2026-11-01: one shared helper, adopted launcher by launcher). Today's caller: agent-session.sh's
# gateway-sessions block. Same division as kube.sh / argv-guard.sh: this file defines functions and
# resolves two addresses; it never exits and never installs a trap — every refusal is a typed
# return code, and the CALLER decides what it means (exit, requeue, log-and-skip).
#
# The contract it speaks is the island's, not restated here: gateway/specs/endpoints/sessions.md
# (GW-SESSIONS-ADMIT / -ENV / -PULL / -AUTH / -RELEASE) and sessions.schema.json post.input.
#
# ── Interface ──────────────────────────────────────────────────────────────────────────────────
#   Environment it reads (the caller identity, GW-SESSIONS-AUTH):
#     AGENT_GATEWAY_URL               the control plane (default: the cluster Service)
#     AGENT_GATEWAY_CALLER_TOKEN_FILE in a pod: the projected caller token
#                                     (default /var/run/secrets/agent-gateway/token)
#     AGENT_GATEWAY_CALLER_SA=<ns>/<sa>  JAIL CANARY ONLY: mint that ServiceAccount's token with the
#                                     admin kubeconfig (KUBECTL / KUBE, kube.sh's pair)
#
#   gw_preflight_request <round> [<attempt>]   rc 0 | 2 (refused: a non-integer round, attempt < 1)
#   gw_preflight_caller                        rc 0 | 2 (refused: malformed SA / no token); sets
#                                              GW_CALLER_DESC. Mints once (a jail canary).
#   gw_admit --stack S --role R --task T [--round N] [--attempt N] [--tier T] [--harness H]
#            [--rail R] [--canary <model>@<provider>]
#            ( --bind <ns>/<sa>/<pod> | --env-file <path> ) [--harnesses claude,opencode,…]
#       rc 0  dispatch. Sets GW_SESSION_ID GW_RAIL GW_HARNESS GW_MODEL GW_WIRE_MODEL
#             GW_CONTEXT_TOKENS GW_EXPIRES_AT GW_ENV_KEYS, and
#               --bind     (the pod pulls its own env — the launcher never holds the token):
#                          GW_PULL_URL + GW_PULL_PRELUDE (the in-pod pull, to run first in the pod
#                          command; it reads AGENT_GATEWAY_PULL_URL / AGENT_GATEWAY_ENV_KEYS);
#               --env-file (unbound — the caller's own process runs the harness, the specs-reviewer
#                          shape): the dispatch `env` written to <path> (0600) as KEY=VALUE lines,
#                          for `mapfile` + `env -i "${args[@]}"` — never `source` it.
#             The caller owns the release from here: `trap gw_release EXIT` (or chain it).
#       rc 1  defer — the gateway said so. GW_DEFER_REASON / GW_RETRY_AFTER set; no session.
#       rc 3  fail closed — unreachable, non-200, unknown decision, or an unusable dispatch
#             (released here before returning). GW_DEFER_REASON names it. Never falls back.
#       rc 2  refused before any request (a bad round/attempt).
#   gw_release        DELETE /sessions/{id}; idempotent, non-fatal (the TTL is the backstop).
#   gw_auth_header    the caller header for `curl -H @<(gw_auth_header)` — the token never rides argv.
#
# The model is the GATEWAY's: no argument names one. --harness only narrows the walk to a dialect.
# A bound answer that carries a credential (a token or an env map) is refused: the launcher never
# holds a session token (operator ruling 2026-10-17, GW-SESSIONS-PULL). No helper variable ever
# holds a session token either; the unbound env lands only in the caller's file.

GW_URL="${AGENT_GATEWAY_URL:-http://agent-gateway.agent-egress.svc.cluster.local:8080}"
GW_CALLER_TOKEN_FILE="${AGENT_GATEWAY_CALLER_TOKEN_FILE:-/var/run/secrets/agent-gateway/token}"
GW_SESSION_ID=""; GW_ENV_KEYS=""; GW_PULL_URL=""; GW_RAIL=""; GW_CONTEXT_TOKENS=""; GW_EXPIRES_AT=""
GW_HARNESS=""; GW_MODEL=""; GW_WIRE_MODEL=""; GW_PULL_PRELUDE=""; GW_CALLER_DESC=""
GW_DEFER_REASON=""; GW_RETRY_AFTER=""

# gw_caller_token — a FRESH caller token on stdout (GW-SESSIONS-AUTH), fetched per call and never
# kept in a variable: the release may run hours after admission, past a 10-minute mint and past a
# kubelet rotation of the projected file. Non-zero = no token.
gw_caller_token() {
  local _t=""
  if [ -n "${AGENT_GATEWAY_CALLER_SA:-}" ]; then
    # JAIL CANARY: the admin kubeconfig impersonates the named dispatcher SA — HONEST IMPERSONATION
    # for canaries only, never an in-cluster path (a loop pod cannot mint for other SAs, by RBAC).
    # shellcheck disable=SC2086  # $KUBE is deliberately unquoted: empty must expand to no argument (kube.sh)
    _t="$("${KUBECTL:-kubectl}" ${KUBE:-} -n "${AGENT_GATEWAY_CALLER_SA%%/*}" create token "${AGENT_GATEWAY_CALLER_SA#*/}" \
          --audience agent-gateway --duration 10m 2>/dev/null)" || return 1
  elif [ -r "$GW_CALLER_TOKEN_FILE" ]; then
    _t="$(cat "$GW_CALLER_TOKEN_FILE" 2>/dev/null)" || return 1
  fi
  [ -n "$_t" ] || return 1
  printf '%s' "$_t"
}

gw_auth_header() { local _t; _t="$(gw_caller_token)" || return 1; printf 'Authorization: Bearer %s\n' "$_t"; }

gw_release() {
  [ -n "${GW_SESSION_ID:-}" ] || return 0
  local _sid="$GW_SESSION_ID"; GW_SESSION_ID=""
  if curl -fsS --max-time 10 -H @<(gw_auth_header) -X DELETE "${GW_URL}/sessions/${_sid}" >/dev/null 2>&1; then
    echo "→ gateway(sessions): released ${_sid}"
  else
    echo "WARN gateway(sessions): release of ${_sid} FAILED — it holds its rail slot until the session TTL" >&2
  fi
  return 0
}

gw_preflight_request() {
  case "${1:-}" in ''|*[!0-9]*)
    echo "PREFLIGHT REFUSED: --round '${1:-}' is not a non-negative integer (sessions.schema.json post.input.round). No session, no pod." >&2
    return 2;;
  esac
  # The retry contract (GW-SESSIONS-ADMIT): the caller's automatic re-admission counter at the SAME
  # round; 1 (the default) is omitted from the request.
  case "${2:-1}" in ''|0|*[!0-9]*)
    echo "PREFLIGHT REFUSED: AGENT_GATEWAY_ATTEMPT='${2:-}' is not a positive integer (sessions.schema.json post.input.attempt). No session, no pod." >&2
    return 2;;
  esac
  return 0
}

gw_preflight_caller() {
  if [ -n "${AGENT_GATEWAY_CALLER_SA:-}" ] && ! [[ "$AGENT_GATEWAY_CALLER_SA" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    echo "PREFLIGHT REFUSED: AGENT_GATEWAY_CALLER_SA='${AGENT_GATEWAY_CALLER_SA}' is not <namespace>/<serviceaccount> (GW-SESSIONS-AUTH). No session, no pod." >&2
    return 2
  fi
  if ! gw_caller_token >/dev/null; then
    if [ -n "${AGENT_GATEWAY_CALLER_SA:-}" ]; then
      echo "PREFLIGHT REFUSED: could not mint a caller token for ${AGENT_GATEWAY_CALLER_SA} (kubectl create token --audience agent-gateway) — GW-SESSIONS-AUTH. No session, no pod." >&2
    else
      echo "PREFLIGHT REFUSED: no gateway caller token — ${GW_CALLER_TOKEN_FILE} is not mounted, and AGENT_GATEWAY_CALLER_SA (jail canary: <ns>/<sa> of the dispatcher, e.g. platform-agents/agentstack-loop) is unset. /sessions authenticates its caller (GW-SESSIONS-AUTH). No session, no pod." >&2
    fi
    return 2
  fi
  GW_CALLER_DESC="${AGENT_GATEWAY_CALLER_SA:+${AGENT_GATEWAY_CALLER_SA} (minted, jail canary)}"
  GW_CALLER_DESC="${GW_CALLER_DESC:-the projected token of this pod (AGENT_GATEWAY_CALLER_TOKEN_FILE)}"
  return 0
}

# The pod command's FIRST step for a bound session (ahead of the harness and outside its tee):
# read the projected token, POST the pull URL, export exactly the `env_keys`, drop the locals. Any
# failure exits 97 BEFORE the harness starts. Static text: it expands only in the pod.
# shellcheck disable=SC2016  # single quotes on purpose — this text expands in the pod, never here
_GW_PULL_PRELUDE_TEXT='_gw_t="$(cat /var/run/secrets/agent-gateway/token)" && _gw_env="$(curl -fsS --max-time 30 --retry 3 --retry-delay 2 --retry-connrefused -X POST -H "Authorization: Bearer ${_gw_t}" "$AGENT_GATEWAY_PULL_URL")" || { echo "→ gateway(sessions): env pull FAILED at ${AGENT_GATEWAY_PULL_URL} — the harness does not start (FU-270)" >&2; exit 97; }; unset _gw_t; for _gw_k in ${AGENT_GATEWAY_ENV_KEYS//,/ }; do _gw_v="$(printf "%s" "$_gw_env" | jq -er --arg k "$_gw_k" ".env[\$k] | strings")" || { echo "→ gateway(sessions): the env pull answer lacks ${_gw_k} — the harness does not start (FU-270)" >&2; exit 97; }; export "${_gw_k}=${_gw_v}"; done; unset _gw_env _gw_v _gw_k; echo "→ gateway(sessions): env pulled (${AGENT_GATEWAY_ENV_KEYS})"; '

gw_admit() {
  local stack="" role="" task="" round="0" attempt="1" tier="" harness="" rail="" canary="" bind="" envfile=""
  local harnesses="claude,opencode,goose,codex"
  while [ $# -gt 0 ]; do
    case "$1" in
      --stack) stack="${2-}";; --role) role="${2-}";; --task) task="${2-}";; --round) round="${2-}";;
      --attempt) attempt="${2-}";; --tier) tier="${2-}";; --harness) harness="${2-}";; --rail) rail="${2-}";;
      --canary) canary="${2-}";; --bind) bind="${2-}";; --env-file) envfile="${2-}";; --harnesses) harnesses="${2-}";;
      *) echo "gw_admit: unknown argument '$1'" >&2; return 2;;
    esac
    [ $# -ge 2 ] || { echo "gw_admit: '$1' needs a value" >&2; return 2; }
    shift 2
  done
  GW_SESSION_ID=""; GW_ENV_KEYS=""; GW_PULL_URL=""; GW_RAIL=""; GW_CONTEXT_TOKENS=""; GW_EXPIRES_AT=""
  GW_HARNESS=""; GW_MODEL=""; GW_WIRE_MODEL=""; GW_PULL_PRELUDE=""; GW_DEFER_REASON=""; GW_RETRY_AFTER=""
  if [ -z "$stack" ] || [ -z "$role" ] || [ -z "$task" ]; then
    echo "gw_admit: --stack, --role and --task are required (sessions.schema.json post.input)" >&2; return 2
  fi
  if { [ -n "$bind" ] && [ -n "$envfile" ]; } || { [ -z "$bind" ] && [ -z "$envfile" ]; }; then
    echo "gw_admit: exactly one of --bind <ns>/<sa>/<pod> (the pod pulls its env) or --env-file <path> (unbound) is required" >&2; return 2
  fi
  local b_ns="" b_sa="" b_pod=""
  if [ -n "$bind" ]; then
    b_ns="${bind%%/*}"; b_pod="${bind##*/}"; b_sa="${bind#*/}"; b_sa="${b_sa%/*}"
    [ -n "$b_ns" ] && [ -n "$b_sa" ] && [ -n "$b_pod" ] && [ "$bind" = "$b_ns/$b_sa/$b_pod" ] \
      || { echo "gw_admit: --bind '$bind' is not <namespace>/<serviceaccount>/<pod>" >&2; return 2; }
  fi
  gw_preflight_request "$round" "$attempt" || return 2

  # sessions.schema.json post.input — optional fields only when given.
  local req resp http decision
  req="$(jq -nc --arg stack "$stack" --arg role "$role" --arg task "$task" --argjson round "$round" \
      --argjson attempt "$attempt" --arg tier "$tier" --arg harness "$harness" --arg rail "$rail" \
      --arg canary "$canary" --arg ns "$b_ns" --arg sa "$b_sa" --arg pod "$b_pod" \
      '{stack: $stack, role: $role, task: $task, round: $round}
       + (if $attempt > 1 then {attempt: $attempt} else {} end)
       + (if $tier != "" then {tier: $tier} else {} end)
       + (if $harness != "" then {harness: $harness} else {} end)
       + (if $rail != "" then {rail: $rail} else {} end)
       + (if $canary != "" then {canary: {model: ($canary | split("@")[0]), provider: ($canary | split("@")[1])}} else {} end)
       + (if $ns != "" then {bind: {namespace: $ns, serviceaccount: $sa, pod: $pod}} else {} end)')"
  resp="$(mktemp)"
  http="$(curl -sS --max-time 20 -o "$resp" -w '%{http_code}' -H 'Content-Type: application/json' \
      -H @<(gw_auth_header) -X POST "${GW_URL}/sessions" -d "$req" 2>/dev/null)" || http="000"
  decision=""
  [ "$http" != "200" ] || decision="$(jq -r '.decision // ""' "$resp" 2>/dev/null)" || decision=""
  case "$decision" in
    defer)
      GW_DEFER_REASON="$(jq -r '.reason // "?"' "$resp")"; GW_RETRY_AFTER="$(jq -r '.retry_after_s // "?"' "$resp")"
      echo "→ gateway(sessions): defer — [${GW_DEFER_REASON}] retry_after=${GW_RETRY_AFTER}s — not dispatching (task=${task}, round=${round})." >&2
      rm -f "$resp"; return 1;;
    dispatch) ;;
    *)
      # Only a NON-200 body is echoed: it is the gateway's error envelope, redacted by GW-REDACT. A
      # 200 that is neither verdict could carry a token, so its body is never printed.
      local why="http ${http}"; [ "$http" != "000" ] || why="unreachable"
      [ "$http" = "200" ] && why="http 200, unknown decision '${decision}'" \
        || why="${why}$(head -c 200 "$resp" 2>/dev/null | tr '\n' ' ' | sed 's/^./: &/')"
      GW_DEFER_REASON="gateway-${why}"; GW_RETRY_AFTER="?"
      echo "→ gateway(sessions): defer — [${GW_DEFER_REASON}] retry_after=?s — FAIL CLOSED at ${GW_URL}/sessions, not dispatching (AGENT_GATEWAY=sessions never falls back to the old proxy)." >&2
      rm -f "$resp"; return 3;;
  esac

  # From here a session exists: any refusal below releases it before returning.
  GW_SESSION_ID="$(jq -r '.session.id // ""' "$resp")"
  local bad=""
  [[ "$GW_SESSION_ID" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || bad="session id"
  if [ -n "$bind" ]; then
    # A bound answer carries NO credential (GW-SESSIONS-PULL). A token or an env map here means the
    # gateway ignored the bind (a pre-pull build): refuse, so the launcher never holds a token.
    jq -e '(.session.token == null) and (.env == null)' "$resp" >/dev/null 2>&1 \
      || bad="${bad:+$bad, }a credential in a bound answer"
    # Every env key becomes an in-pod `export` name — a hostile key is a refusal.
    jq -e '(.env_keys | type == "array") and (.env_keys | length > 0) and ([.env_keys[] | select((type != "string") or (test("^[A-Za-z_][A-Za-z0-9_]*$") | not))] | length == 0)' \
      "$resp" >/dev/null 2>&1 || bad="${bad:+$bad, }env_keys"
    GW_ENV_KEYS="$(jq -r '(.env_keys // []) | map(tostring) | join(",")' "$resp" 2>/dev/null)" || GW_ENV_KEYS=""
    GW_PULL_URL="$(jq -r '.pull_url // ""' "$resp")"
    [[ "$GW_PULL_URL" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._-]+)*/sessions/${GW_SESSION_ID}/env$ ]] \
      || bad="${bad:+$bad, }pull_url"
  else
    # Unbound: the answer IS the credential (GW-SESSIONS-ENV). Keys become env names; a value with
    # a newline cannot be a KEY=VALUE line — both are refusals, and nothing is written.
    jq -e '(.env | type == "object") and (.env | length > 0) and ([.env | to_entries[] | select((.key | test("^[A-Za-z_][A-Za-z0-9_]*$") | not) or (.value | type != "string") or (.value | test("\n")))] | length == 0)' \
      "$resp" >/dev/null 2>&1 || bad="${bad:+$bad, }env"
    GW_ENV_KEYS="$(jq -r '(.env // {}) | keys_unsorted | join(",")' "$resp" 2>/dev/null)" || GW_ENV_KEYS=""
  fi
  GW_RAIL="$(jq -r '.rail // ""' "$resp")"
  GW_EXPIRES_AT="$(jq -r '.session.expires_at // "?"' "$resp")"
  GW_CONTEXT_TOKENS="$(jq -r '.context_tokens // "" | tostring' "$resp")"
  GW_HARNESS="$(jq -r '.harness // ""' "$resp")"
  GW_MODEL="$(jq -r '.model // ""' "$resp")"
  [ -n "$GW_MODEL" ] || bad="${bad:+$bad, }model"
  # The harness invocation's model: the policy id with its rail prefix removed (GW-MODEL-RESOLVE's
  # strip). The env carries the same values; for a bound session the launcher cannot read them.
  case "$GW_RAIL" in
    anthropic) GW_WIRE_MODEL="${GW_MODEL#claude/}";;
    opencode)  GW_WIRE_MODEL="${GW_MODEL#opencode-go/}";;
    codex)     GW_WIRE_MODEL="${GW_MODEL#codex/}";;
    *)         GW_WIRE_MODEL="$GW_MODEL";;
  esac
  # The harness must be one the caller runs, and its model key must be in the env (GW-SESSIONS-ENV).
  local need=""
  case "$GW_HARNESS" in
    claude) need=ANTHROPIC_MODEL;; opencode) need=OPENCODE_CONFIG_CONTENT;;
    goose)  need=GOOSE_MODEL;;     codex)    need=CODEX_MODEL;;
  esac
  if [ -z "$need" ] || [[ ",${harnesses}," != *",${GW_HARNESS},"* ]]; then
    bad="${bad:+$bad, }harness '${GW_HARNESS}' (this launcher runs ${harnesses//,/|})"
  elif [[ ",${GW_ENV_KEYS}," != *",${need},"* ]]; then
    bad="${bad:+$bad, }env_keys lacks ${need}"
  fi
  if [ -n "$bad" ]; then
    rm -f "$resp"
    GW_DEFER_REASON="dispatch-unusable: ${bad}"; GW_RETRY_AFTER="?"
    echo "→ gateway(sessions): defer — [${GW_DEFER_REASON}] retry_after=?s — FAIL CLOSED, releasing and not dispatching." >&2
    gw_release
    return 3
  fi
  if [ -n "$bind" ]; then
    rm -f "$resp"
    echo "→ gateway(sessions): dispatch ${GW_MODEL} [rail=${GW_RAIL},harness=${GW_HARNESS},session=${GW_SESSION_ID},context_tokens=${GW_CONTEXT_TOKENS:-null}] (task=${task}, round=${round}) — bound to ${b_ns}/${b_sa} pod ${b_pod}; the pod pulls env ${GW_ENV_KEYS}; caller ${GW_CALLER_DESC:-?}"
    GW_PULL_PRELUDE="$_GW_PULL_PRELUDE_TEXT"
  else
    ( umask 077; jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$resp" > "$envfile" ) 2>/dev/null \
      || { rm -f "$resp" "$envfile"; GW_DEFER_REASON="dispatch-unusable: env file ${envfile} not writable"; GW_RETRY_AFTER="?"
           echo "→ gateway(sessions): defer — [${GW_DEFER_REASON}] retry_after=?s — FAIL CLOSED, releasing and not dispatching." >&2
           gw_release; return 3; }
    rm -f "$resp"
    echo "→ gateway(sessions): dispatch ${GW_MODEL} [rail=${GW_RAIL},harness=${GW_HARNESS},session=${GW_SESSION_ID},context_tokens=${GW_CONTEXT_TOKENS:-null}] (task=${task}, round=${round}) — unbound; env ${GW_ENV_KEYS} written to ${envfile}; caller ${GW_CALLER_DESC:-?}"
  fi
  return 0
}
