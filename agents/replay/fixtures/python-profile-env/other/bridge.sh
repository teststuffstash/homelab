# ── bridge ── run.sh's ambient-env hermeticity rule only unsets PROJECT globally, and `env K=V …`
# never CLEARS an unlisted var — so the "not python" leg must unset EGRESS_PROFILE explicitly
# rather than trust the launcher machine's shell (the retro-gh-token-env/unset precedent).
unset EGRESS_PROFILE
unset AGENT_PYPI_CACHE_URL
