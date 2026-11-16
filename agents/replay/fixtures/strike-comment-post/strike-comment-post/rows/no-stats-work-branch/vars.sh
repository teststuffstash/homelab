# finalize never ran, the launcher outlived the ride: it reads the pod's creation (RIDE_SINCE is
# unset on the launcher path), finds no record for this pod, and names the --work-branch it was
# dispatched on as the resumable branch (no branch listing needed).
WORK_BRANCH="fix/issue-42-tighten"
STRIKE_LINE="AGENT_STRIKE: model=openrouter/x error_class=unknown round=2 session=agent-test-project-issue-42-r2"
