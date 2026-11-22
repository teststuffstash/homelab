# ── observation point ── not helper code: what a caller reads after gw_admit returns.
echo "rc=${rc}"
echo "GW_SESSION_ID='${GW_SESSION_ID}' GW_RAIL='${GW_RAIL}' GW_HARNESS='${GW_HARNESS}' GW_MODEL='${GW_MODEL}' GW_WIRE_MODEL='${GW_WIRE_MODEL}'"
echo "GW_ENV_KEYS='${GW_ENV_KEYS}' GW_PULL_URL='${GW_PULL_URL}' GW_PULL_PRELUDE set: $([ -n "${GW_PULL_PRELUDE}" ] && echo yes || echo no)"
echo "GW_DEFER_REASON='${GW_DEFER_REASON}' GW_RETRY_AFTER='${GW_RETRY_AFTER}'"
if [ -f "$ENVF" ]; then
  echo "env file: mode $(stat -c %a "$ENVF"), keys $(cut -d= -f1 "$ENVF" | paste -sd, -), gws_ lines $(grep -c 'gws_' "$ENVF")"
else
  echo "env file: absent"
fi
echo "gws_ in shell state: $( (set -o posix; set) | grep -v '^GW_REPLY_BODY=' | grep -c 'gws_' || true)"
gw_release; gw_release   # idempotent: at most ONE DELETE
