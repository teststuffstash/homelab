# add-agent-error: the oracle-fleet#637 shape — the SAME `verdict` world, with `agent/error` on #66.
#
# The axis this row adds is the CRASH LATCH. A ride that declares infeasible and THEN dies on the
# way out is the common shape (the wall that made the task infeasible often kills the session too),
# and it is exactly the case the marker exists for: oracle-fleet#637 posted a well-formed marker at
# 13:34:50Z, died in an http-401-storm 31 s later, and the launcher stamped `agent/error`.
#
# On the base tree the infeasible read drew its candidates through `C4C5_SEL`, whose first filter
# drops `agent/error` — so #66 was invisible to the terminal, stayed `agent/in-progress` +
# `agent/error` forever, and the named resource never reached a human. This row reds there.
map(if .number == 66 then .labels += [{"name": "agent/error"}] else . end)
