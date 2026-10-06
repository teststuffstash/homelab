# unsettled-sibling: no run has SETTLED to `failure` yet. A sibling job is still running, so
# GitHub reports the run `in_progress` and `gh run list --status failure` returns nothing — while
# the failing job's log is already readable. The selector must fall back to the newest run on the
# branch (rows/unsettled-sibling/gh/run-list.json) rather than defer (homelab#1940).
[]
