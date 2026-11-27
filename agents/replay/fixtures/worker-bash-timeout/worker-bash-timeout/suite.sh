#!/usr/bin/env bash
# worker-bash-timeout — the pod env's Claude Code shell-command cap sits above the pre-PR gate.
#
# WHAT IT PINS. Facts read OUT of agents/agent-session.sh at run time (never transcribed, #166):
#   1. the env list ships BASH_DEFAULT_TIMEOUT_MS and BASH_MAX_TIMEOUT_MS;
#   2. each value is >= 30 min (a gate is 20–30 min; Claude Code's own max is 10 min) and below
#      the pod's default activeDeadlineSeconds (the deadline still bounds a hung command);
#   3. both sit in the always-rendered env list before the devbox block — only env-list shapes
#      (list item / value / comment) between them, so no HARNESS gate hides them.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
LAUNCHER="${LAUNCHER:-$ROOT/agents/agent-session.sh}"
[ -f "$LAUNCHER" ] || { echo "worker-bash-timeout: launcher not found: $LAUNCHER" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "${2:-}"; }

printf '\033[1mworker-bash-timeout\033[0m — the shell-command cap sits above the pre-PR gate\n'

deadline_s="$(grep -oE 'activeDeadlineSeconds: \$\{AGENT_POD_DEADLINE_S:-[0-9]+\}' "$LAUNCHER" | head -1 | grep -oE '[0-9]+\}$' | tr -d '}')"
[ -n "$deadline_s" ] || { bad "pod default deadline readable" "no activeDeadlineSeconds default found"; deadline_s=0; }
anchor_ln="$(grep -nF -- '- name: DEVBOX_NO_UPDATE_CHECK' "$LAUNCHER" | awk -F: 'NR==1{print $1}')"

for var in BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS; do
  ln="$(grep -nF -- "- name: $var" "$LAUNCHER" | awk -F: 'NR==1{print $1}')"
  if [ -z "$ln" ]; then bad "env ships $var" "no '- name: $var' in agents/agent-session.sh"; continue; fi
  ok "env ships $var"
  val="$(sed -n "$((ln+1))p" "$LAUNCHER" | sed -E 's/^[ ]*value: *"?([0-9]*)"?$/\1/')"
  if [ -n "$val" ] && [ "$val" -ge 1800000 ] && [ "$deadline_s" -gt 0 ] && [ "$val" -lt $((deadline_s*1000)) ]; then
    ok "$var=$val is >= 30 min and below the ${deadline_s}s pod deadline"
  else
    bad "$var is >= 30 min and below the pod deadline" "value='$val' deadline=${deadline_s}s"
  fi
  if [ -z "$anchor_ln" ] || [ "$ln" -ge "$anchor_ln" ]; then
    bad "$var sits in the env list before the devbox block" "anchor L${anchor_ln:-?}, var L$ln"
  elif awk -v a="$ln" -v b="$anchor_ln" 'NR>=a && NR<=b { l=$0; sub(/^[ \t]+/,"",l); if (l==""||l~/^#/||l~/^- name:/||l~/^value:/) next; bad=1 } END{exit bad}' "$LAUNCHER"; then
    ok "$var sits in the always-rendered env list before the devbox block"
  else
    bad "$var sits in the always-rendered env list before the devbox block" "a non-env-list line lies between L$ln and L$anchor_ln"
  fi
done

printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nThe worker pod env no longer lifts the shell-command cap above the gate. If deliberate,\n'
  printf 'update the fixture in the same PR (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mThe shell-command cap holds above the gate.\033[0m\n'
