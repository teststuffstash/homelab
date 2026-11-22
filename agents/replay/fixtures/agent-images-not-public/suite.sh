#!/usr/bin/env bash
# agent-images-not-public suite (fixture.yaml has the condition).
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
rc=0
ok()  { echo "✓ $*"; }
bad() { echo "✗ $*"; rc=1; }
HOME_REG='registry.teststuff.net/'
PUBLIC_RE='ghcr\.io/teststuffstash/agent-(base|coordinator)'

# ── 1. the two pins every launcher sources.
for var in AGENT_BASE_IMAGE AGENT_COORDINATOR_IMAGE; do
  val="$(grep -m1 "^${var}=" agents/images.env | cut -d= -f2-)"
  case "$val" in
    "${HOME_REG}"agent-*:*) ok "$var is pinned on ${HOME_REG%/} ($val)" ;;
    "") bad "$var has no pin in agents/images.env" ;;
    *)  bad "$var is pinned outside ${HOME_REG%/}: $val" ;;
  esac
done

# ── 2. the launchers' fallback defaults (what a missing images.env would run).
for f in agents/agent-session.sh agents/coordinator-session.sh agents/reviewer-session.sh; do
  def="$(grep -m1 -oE '^IMAGE="\$\{[A-Z_]+:-\$\{AGENT_[A-Z]+_IMAGE:-[^}]+\}\}"' "$f" | sed -E 's/.*:-([^}]+)\}\}"$/\1/')"
  case "$def" in
    "${HOME_REG}"agent-*) ok "$f falls back to $def" ;;
    "") bad "$f: no IMAGE fallback line of the known shape — the launcher changed, re-read it" ;;
    *)  bad "$f falls back outside ${HOME_REG%/}: $def" ;;
  esac
done

# ── 3. no reference to the public packages anywhere a pod or a pin reads.
hits="$(git grep -nE "$PUBLIC_RE" -- agents argocd ':!agents/replay/fixtures' ':!agents/coordinator/TICK-LOG.md' ':!*/fixtures/*' || true)"
if [ -z "$hits" ]; then ok "no ghcr agent-base/agent-coordinator reference under agents/ or argocd/"
else bad "the public ghcr packages are named again:"; printf '%s\n' "$hits" | cut -c1-200; fi
exit "$rc"
