# ── observation point ── the manifest's splice, expanded exactly as agent-session.sh's
# volumeMounts/volumes lines do (no :- defaults) — an unset var dies here under set -u.
printf 'MOUNT:%s\n' "${PF_CM_MOUNT}"
printf 'VOLUME:%s\n' "${PF_CM_VOLUME}"
printf 'CREATED:%s\n' "${PF_CM_CREATED:-}"
