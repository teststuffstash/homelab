# ── observation point ── not launcher code: the manifest fragments (env, volumeMounts, volumes) +
# the pod labels + whether any fragment holds a token. Any API write would be a CALL line.
printf '%s\n' "$LLM_ENV" | sed 's/^/LLM_ENV|/'
printf '%s\n' "$GW_TOKEN_MOUNT" | sed 's/^/MOUNT|/'
printf '%s\n' "$GW_TOKEN_VOLUME" | sed 's/^/VOLUME|/'
echo "SUB_LABEL='${SUB_LABEL}'"
echo "gws_ in the manifest fragments: $(printf '%s%s%s' "$LLM_ENV" "$GW_TOKEN_MOUNT" "$GW_TOKEN_VOLUME" | grep -c 'gws_' || true)"
