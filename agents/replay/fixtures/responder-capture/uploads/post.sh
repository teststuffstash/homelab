# ── observation point ── not clause code: the two call sites, in the order responder-argo.yaml
# makes them. `_ts_session` runs immediately after the model returns (BEFORE the reopen/verdict
# belts, so a failure down there cannot cost the record); `_ts_finding` runs at the end of the
# iteration, where the verdict and the filed issue exist.
_ts_session
_ts_finding "fix" "teststuffstash/homelab#1751" "teststuffstash/homelab"
echo "REACHED: end"
