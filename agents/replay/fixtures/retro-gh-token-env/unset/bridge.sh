# ── bridge ── run.sh's env-leak hermeticity rule (README "Ambient-env hermeticity") only unsets
# PROJECT globally; RETRO_GH_SECRET is a new var and `env K=V ...` (run.sh's invocation) never
# CLEARS an unlisted var, so this fixture's "absent" leg would silently pass on a machine whose
# shell happens to export it. Unset explicitly rather than trust ambient absence.
unset RETRO_GH_SECRET
