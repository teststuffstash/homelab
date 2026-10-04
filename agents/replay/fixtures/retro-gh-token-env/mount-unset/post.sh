# ── observation point ── not launcher code. The three fragments the manifest heredoc splices in:
# the mount, the volume (Secret NAME only — never a value) and the broker env, which the retro
# ride must NOT carry (homelab#2171: the in-pod gh wrapper resolves broker → file → env, so a
# rendered broker URL silently replaces the fleet-wide retro token with the worker token).
printf 'CRED_BROKER_ENV: %s\n' "${CRED_BROKER_ENV:-(empty)}"
printf 'RETRO_GH_MOUNT:%s\n' "${RETRO_GH_MOUNT:-(empty)}"
printf 'RETRO_GH_VOLUME:%s\n' "${RETRO_GH_VOLUME:-(empty)}"
