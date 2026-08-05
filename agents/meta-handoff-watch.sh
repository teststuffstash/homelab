#!/bin/bash
# meta-handoff-watch — emit when a STACK jail files a cross-jail handoff task.
# Protocol + procedure: /workspace/tools/handoff.md + .claude/skills/handoff/SKILL.md.
# Change-only: prints the new inbox files (and anything left stranded in doing/) so the mono
# session can claim them. Probe failures are LOUD — a missing mount reads as "no work" otherwise.
ROOT="${HANDOFF_ROOT:-/workspace/.handoff}"
[ -d "$ROOT" ] || { echo "PROBE-FAIL: $ROOT missing — handoff channel not mounted"; exit 1; }
last_in=""; last_doing=""; stale_since=0
while true; do
  # ls over every stack's subtree; the mono jail sees them all, a stack jail only its own.
  inbox=$(ls -1 "$ROOT"/*/inbox/*.md 2>/dev/null | sort | tr '\n' ' ')
  doing=$(ls -1 "$ROOT"/*/doing/*.md 2>/dev/null | sort | tr '\n' ' ')
  if [ ! -d "$ROOT" ]; then echo "PROBE-FAIL: $ROOT vanished mid-watch"; exit 1; fi
  if [ "$inbox" != "$last_in" ]; then
    if [ -n "$inbox" ]; then
      echo "HANDOFF INBOX: $inbox — claim the oldest with /handoff (mv to doing/ first)"
      for f in $inbox; do echo "  --- ${f##*/}"; head -6 "$f" | sed 's/^/  | /'; done
    else
      echo "HANDOFF INBOX: drained (was: ${last_in:-<none>})"
    fi
    last_in="$inbox"
  fi
  # A file sitting in doing/ across >45min of watch is a claim nobody finished (session died).
  if [ -n "$doing" ]; then
    [ "$doing" != "$last_doing" ] && { echo "HANDOFF doing/: $doing (claimed)"; stale_since=$(date +%s); }
    if [ $(( $(date +%s) - stale_since )) -gt 2700 ]; then
      echo "HANDOFF STALL: $doing has been claimed >45min — finish it or move it back to inbox/"
      stale_since=$(date +%s)
    fi
  elif [ -n "$last_doing" ]; then
    echo "HANDOFF doing/: cleared"
  fi
  last_doing="$doing"
  sleep 60
done
