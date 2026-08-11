#!/bin/sh
# docs-graph-lint — the mechanical half of the doc graph (CLAUDE.md routing table,
# "Link, don't restate"). The reader-side rule (enter at the owning doc, chase links)
# only works if links resolve and the index is complete; this holds both.
#
# FAILS on (living docs only):
# - DANGLING: a relative .md link whose target file does not exist
# - ORPHAN: a docs/agents/*.md that docs/agents/README.md (the doc table) never links
# WARNS on (never fails):
# - the same breakage inside HISTORICAL records (docs/agents/retros/, docs/incidents/,
#   docs/follow-ups-archive.md) — their references may be fixed (docs-cleanup), but
#   sediment never blocks CI.
# Links resolving OUTSIDE the repo (e.g. ../teststuff) are skipped — not ours to hold,
# and absent on CI runners.
#
# Check #3 — a doc leaning on a ⚓-anchored glossary term without linking the term's home —
# is LIVE in SHADOW (warn-only) since 2026-08-11: the glossary's ⚓ rows are the term list
# (one home — never duplicate terms here), linking the home OR the glossary satisfies it.
# Flip to fail after the docs-cleanup pipeline clears the initial warning set (FU-163).

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
status=0

is_historical() {
  case "$1" in
    docs/agents/retros/*|docs/incidents/*|docs/follow-ups-archive.md) return 0 ;;
    *) return 1 ;;
  esac
}

# --- 1) every relative .md link resolves -------------------------------------
for f in $(git ls-files '*.md'); do
  dir=$(dirname "$f")
  for tgt in $(grep -oE '\]\([^)#[:space:]]+\.md' "$f" 2>/dev/null | sed 's/^](//' | sort -u); do
    case "$tgt" in
      http://*|https://*|/*) continue ;;
    esac
    resolved=$(realpath -m "$dir/$tgt")
    case "$resolved" in
      "$ROOT"/*) ;;
      *) continue ;; # escapes the repo — skipped by design
    esac
    if [ ! -f "$resolved" ]; then
      if is_historical "$f"; then
        echo "WARN dangling (historical): $f -> $tgt"
      else
        echo "DANGLING: $f -> $tgt"
        status=1
      fi
    fi
  done
done

# --- 2) the agents doc table is complete -------------------------------------
readme=docs/agents/README.md
for f in docs/agents/*.md; do
  base=$(basename "$f")
  [ "$base" = "README.md" ] && continue
  if ! grep -qF "($base" "$readme"; then
    echo "ORPHAN: $f is not linked from $readme (the doc table is the reader's entry index)"
    status=1
  fi
done

# --- 3) glossary ⚓ terms: a living doc using an anchored term links its home or the glossary
# WARN-ONLY (shadow rollout, the sentinel/router pattern) — see the header note.
GLOSS=docs/glossary.md
if [ -f "$GLOSS" ]; then
  grep '^| \*\*⚓' "$GLOSS" | while IFS= read -r row; do
    term=$(printf '%s' "$row" | awk -F'|' '{print $2}' | sed 's/\*\*//g; s/⚓//g; s/^ *//; s/ *(.*//; s/ *$//')
    homerel=$(printf '%s' "$row" | awk -F'|' '{print $4}' | grep -oE '\]\([^)#]*\.md' | head -1 | sed 's/^](//')
    [ -n "$term" ] || continue
    [ -n "$homerel" ] || continue
    home=$(realpath -m "$ROOT/docs/$homerel"); home=${home#"$ROOT"/}
    hbase=$(basename "$home")
    for f in $(git ls-files '*.md'); do
      [ "$f" = "$GLOSS" ] && continue
      [ "$f" = "$home" ] && continue
      if is_historical "$f"; then continue; fi
      grep -qiF "$term" "$f" || continue
      grep -qF "$hbase" "$f" && continue
      grep -qF "glossary.md" "$f" && continue
      echo "WARN term-unlinked (check #3 shadow): $f uses \"$term\" without linking $home or the glossary"
    done
  done
fi

[ "$status" -eq 0 ] && echo "docs-graph: links resolve, agents doc table complete"
exit "$status"
