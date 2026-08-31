# Fixture notes

## homelab#1113 — dispatch-time `bash -n` assembly guard

No fixture applies. The guard added in `agents/reviewer-session.sh` runs **host-side** before a
pod is spawned — it checks the assembled heredocs (`$PREP`, `$TOUCHESPART`, `$UPLOADER`,
`$RUNPART`) with `bash -n` and exits with a FATAL diagnostic before reaching any code that the
replay harness exercises (the pod-side blocks extracted via sentinel markers). The guard's
entire effect is "exit 1 before pod creation", which is outside the replay harness's scope
(the harness stubs `gh`/`kubectl` and replays pod-side blocks; it does not stub `bash -n` or
simulate heredoc assembly).

A fixture that tested the guard would need to:
1. Set up the four heredoc variables with controlled content
2. Run the `bash -n` check
3. Assert the FATAL message on syntax error or silent pass on clean syntax

This is a pure-bash operation with no external calls, so the action-stream assertion model
(the harness's only assertion mode) has nothing to record. A future `mode: exec` or
`mode: exit-code` extension could cover this class.