# ── bridge ── the per-alert loop variables the gate reads. Every name is set EARLIER in
# responder-argo.yaml's own loop: `$a` is the single firing alert as `jq -c` emitted it, `$NAME`
# and `$FP` come off it, and `$_ns` is the namespace derivation (empty here — a pushgateway metric
# has no namespace label, which is the whole point of this fixture).
#
# The alert is the live 2026-08-11 one, homelab#237: RetroReportOverdue, from the metric
# retro_report_last_success_timestamp, now carrying the rule author's `platform_machinery: "true"`.
NAME="RetroReportOverdue"
FP="5d87a09c332779c8"
_ns=""
a='{"status":"firing","fingerprint":"5d87a09c332779c8","labels":{"alertname":"RetroReportOverdue","severity":"warning","platform_machinery":"true"}}'
