#!/usr/bin/env bash
# opencode-phonehome-killswitch — the pod env card's opencode OPENCODE_DISABLE_AUTOUPDATE var.
#
# CONDITION UNDER REPLAY. opencode-1.18.18's SDK init (not just auto-update) makes runtime
# fetches to models.opencode.ai (model registry) + registry.npmjs.org (provider SDKs/@ai-sdk/*).
# OPENCODE_DISABLE_AUTOUPDATE disables the periodic auto-update check but not SDK init fetches —
# the CNP Policy DENY is the intended backstop. The var must be set UNCONDITIONALLY in the env
# card beside devbox/uv precedents (never gated on HARNESS=opencode), matching PR #503 §2: kill
# at tool, do not widen extraFQDNs (the CNP correctly denies the WAN call; the tool's own check
# is the thing to silence).
#
# WHAT IT PINS. Facts read OUT of agents/agent-session.sh at run time (never transcribed, #166):
#   1. the env card ships `OPENCODE_DISABLE_AUTOUPDATE` with value "1";
#   2. it is a sibling of the DEVBOX_DISABLE_TELEMETRY anchor — every line between them is one of
#      the env list's own shapes (list item / value / comment), so no `if`/`case` gate and no
#      list-terminating YAML key sits between the devbox block and the var;
#   3. the comment above it names the two denied destinations, so the pin carries its own alert.
#   4. (homelab#1247) the env card ALSO ships `MERMAID_LINT_NO_INSTALL` = "1" in the same
#      always-on block — the kill-switch scripts/mermaid-lint.sh honors, so an md-touching ride
#      never runs `npm ci` against the CNP-denied registry (~12k POLICY_DENIED/24h before it).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FU-167 move 5: fixtures/<family>/<fixture>/ is three levels below agents/replay — 5 up to the
# repo root (was 4 at the old depth-1 layout).
ROOT="$(cd "$HERE/../../../../.." && pwd)"
LAUNCHER="${LAUNCHER:-$ROOT/agents/agent-session.sh}"

[ -f "$LAUNCHER" ] || { echo "opencode-phonehome-killswitch: launcher not found: $LAUNCHER" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n       %s\n' "$1" "${2:-}"; }

printf '\033[1mopencode-phonehome-killswitch\033[0m — the pod env card ships the opencode kill-switch\n'
printf 'launcher: %s\n' "${LAUNCHER#$ROOT/}"

# ── 1. presence ────────────────────────────────────────────────────────────────────────────────
var_ln="$(grep -nF -- '- name: OPENCODE_DISABLE_AUTOUPDATE' "$LAUNCHER" | awk -F: 'NR==1{print $1}')"
if [ -n "$var_ln" ]; then
  ok "env card ships OPENCODE_DISABLE_AUTOUPDATE"
else
  bad "env card ships OPENCODE_DISABLE_AUTOUPDATE" "grep found no '- name: OPENCODE_DISABLE_AUTOUPDATE' in agents/agent-session.sh"
fi
[ -n "$var_ln" ] || { printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"; exit 1; }

# ── 2. value ────────────────────────────────────────────────────────────────────────────────────
val="$(sed -n "$((var_ln+1))p" "$LAUNCHER" | sed -E 's/^[ ]*value: *"?([^"]*)"?$/\1/')"
[ "$val" = "1" ] && ok 'value is "1"' || bad 'value is "1"' "line $((var_ln+1)) reads: value=$val"

# ── 3. unconditional sibling of the devbox block ─────────────────────────────────────────────────
anchor_ln="$(grep -nF -- '- name: DEVBOX_DISABLE_TELEMETRY' "$LAUNCHER" | awk -F: 'NR==1{print $1}')"
if [ -z "$anchor_ln" ]; then
  bad "sits in the always-rendered env list next to the devbox block" "no '- name: DEVBOX_DISABLE_TELEMETRY' anchor found"
elif [ "$anchor_ln" -ge "$var_ln" ]; then
  bad "sits in the always-rendered env list next to the devbox block" "devbox anchor (L$anchor_ln) is NOT before the var (L$var_ln)"
else
  # between the devbox anchor and the var only the env list's own shapes are legal: a list item
  # (`- name:`), its value (`value:`), or a comment. A HARNESS gate (`if [` / `case`) or a YAML
  # key that terminates the list would be a non-matching line — the var left the always-on block.
  if awk -v a="$anchor_ln" -v v="$var_ln" '
      NR >= a && NR <= v {
        line = $0; sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^#/) next
        if (line ~ /^- name:/ || line ~ /^value:/) next
        bad = 1
      }
      END { exit bad }' "$LAUNCHER"; then
    ok "sits in the always-rendered env list next to the devbox block"
  else
    bad "sits in the always-rendered env list next to the devbox block" "a non-env-list line lies between L$anchor_ln and L$var_ln — the var left the always-on block"
  fi
fi

# ── 4. the comment names the pair it exists for (the pin carries its alert) ──────────────────────
comment="$(sed -n "$((var_ln-5)),$((var_ln-1))p" "$LAUNCHER")"
for dest in models.opencode.ai registry.npmjs.org; do
  if printf '%s\n' "$comment" | grep -qF -- "$dest"; then
    ok "comment above the var names $dest"
  else
    bad "comment above the var names $dest" "no '$dest' in the comment block (L$((var_ln-5))–L$((var_ln-1)))"
  fi
done

# ── 5. the mermaid-lint kill-switch (homelab#1247) — same block, same discipline ────────────────
ml_ln="$(grep -nF -- '- name: MERMAID_LINT_NO_INSTALL' "$LAUNCHER" | awk -F: 'NR==1{print $1}')"
if [ -n "$ml_ln" ]; then
  ok "env card ships MERMAID_LINT_NO_INSTALL"
  ml_val="$(sed -n "$((ml_ln+1))p" "$LAUNCHER" | sed -E 's/^[ ]*value: *"?([^"]*)"?$/\1/')"
  [ "$ml_val" = "1" ] && ok 'MERMAID_LINT_NO_INSTALL value is "1"' || bad 'MERMAID_LINT_NO_INSTALL value is "1"' "line $((ml_ln+1)) reads: value=$ml_val"
  # same always-on-block walk as check 3, anchored at the opencode var this suite already pinned:
  # only env-list shapes (list item / value / comment) may sit between them.
  if [ -n "$var_ln" ] && [ "$var_ln" -lt "$ml_ln" ] && awk -v a="$var_ln" -v v="$ml_ln" '
      NR >= a && NR <= v {
        line = $0; sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^#/) next
        if (line ~ /^- name:/ || line ~ /^value:/) next
        bad = 1
      }
      END { exit bad }' "$LAUNCHER"; then
    ok "MERMAID_LINT_NO_INSTALL sits in the same always-on env block"
  else
    bad "MERMAID_LINT_NO_INSTALL sits in the same always-on env block" "a non-env-list line lies between the opencode var (L$var_ln) and it (L$ml_ln), or the ordering flipped"
  fi
  # the CONSUMER honors it: scripts/mermaid-lint.sh tests the var before its npm ci
  if grep -qF 'MERMAID_LINT_NO_INSTALL' "$ROOT/scripts/mermaid-lint.sh" 2>/dev/null; then
    ok "scripts/mermaid-lint.sh honors the var"
  else
    bad "scripts/mermaid-lint.sh honors the var" "no MERMAID_LINT_NO_INSTALL reference in scripts/mermaid-lint.sh — the env line is a no-op"
  fi
else
  bad "env card ships MERMAID_LINT_NO_INSTALL" "grep found no '- name: MERMAID_LINT_NO_INSTALL' in agents/agent-session.sh (homelab#1247)"
fi

# ── result ──────────────────────────────────────────────────────────────────────────────────────
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nThe pod env card drifted from the opencode kill-switch contract. If that was deliberate, update\n'
  printf 'the fixture in the same PR (ADR-103).\n'
  exit 1
fi
printf '\n\033[32mThe opencode phone-home kill-switch holds.\033[0m\n'
