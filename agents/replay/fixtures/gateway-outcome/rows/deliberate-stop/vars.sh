# row deliberate-stop — homelab#3309 r1: the worker posted AGENT_INFEASIBLE + its deliberate-stop
# report and built nothing; agent-finalize set strike_by_pod only to suppress the launcher's fallback
# strike. The live gateway answered the old `unknown` report with a counted model strike and the
# launcher re-admitted on another model — this row's GW_REPLY_STRIKE is that answer.
STRIKE_BY_POD="true"; STATS='{"exit_status":"blocked-deliberate","error_class":"worker-stop-report","root_cause":"x"}'; GW_REPLY_STRIKE='{"class":"unknown","scope":"model"}'
