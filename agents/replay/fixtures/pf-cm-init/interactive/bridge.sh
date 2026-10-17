# ── bridge ── the launcher runs under `set -u`; clear any ambient values so only the init
# block can define them.
set -u
unset PF_CM_CREATED PF_CM_MOUNT PF_CM_VOLUME
