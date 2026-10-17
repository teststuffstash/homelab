# ── observation point ── not launcher code: the manifest fragment + the pod labels + whether the
# fragment (what lands in the pod spec) holds the token. The Secret's STDIN is the CALL stream.
printf '%s\n' "$LLM_ENV" | sed 's/^/LLM_ENV|/'
echo "SUB_LABEL='${SUB_LABEL}' GW_SECRET='${GW_SECRET}' GW_SECRET_CREATED='${GW_SECRET_CREATED}'"
echo "token in LLM_ENV: $(printf '%s' "$LLM_ENV" | grep -c 'gws_' || true)"
