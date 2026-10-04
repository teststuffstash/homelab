# One Alertmanager POST: a RESOLVED alert for another provider first (must be skipped), then the
# firing one the chain acts on.
PAYLOAD='{"alerts":[{"status":"resolved","labels":{"alertname":"MgmtApplyErroredOnNewProvider","root":"main","provider":"helm","locked":"3.0.2","exercised":"2.17.0"}},{"status":"firing","labels":{"alertname":"MgmtApplyErroredOnNewProvider","root":"main","provider":"kubernetes","locked":"3.2.1","exercised":"2.38.0"}}]}'
