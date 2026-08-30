#!/bin/sh
# docs-graph-lint — the mechanical half of the doc graph (CLAUDE.md routing table,
# "Link, don't restate"). The reader-side rule (enter at the owning doc, chase links)
# only works if links resolve and the index is complete; this holds both.
#
# WHO RUNS IT (the homelab#953 disposition, 2026-08-30): the PR lane via the required `ci`
# check, and — the previously ungated lane — every DIRECT master push via the committed
# `githooks/pre-push` (core.hooksPath, re-wired by the jail entrypoint). Direct pushes bypass
# CI as OrgAdmin, and checks #3/#4 are repo-wide, so an ungated master push could red every
# open PR at once (three live instances, 2026-08-26 ×2 + 2026-08-30). The gate sits at the
# push client because the jail/host checkout is the only author of direct pushes; the
# repo-wide (not diff-scoped) shape of #3/#4 is DELIBERATE and unchanged — strict
# up-to-date-branch means a PR always lints the true post-merge world.
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
# FAILS since 2026-08-23 (FU-163 / S4 #767; shadow since 2026-08-11 — run 1: 3 warnings,
# 0 FPs, cleared): the glossary's ⚓ rows are the term list (one home — never duplicate terms
# here), linking the home OR the glossary satisfies it. Check-3-only exclusions beyond
# is_historical: TICK-LOG (append-only journal) and adr.md (decision record) use terms
# historically and must never be forced to grow links; meta-state is transient but LIVING
# (its rows are re-read every session) and stays checked.
#
# Check #4 — §-code heading anchors, two-way resolution (S5 #982, ADR-117; FAILS since
# 2026-08-30 — the shadow arc closed on the #984 comb's recorded clean run). The convention: a section
# other docs/code reference gets a stable CODE as heading prefix (`### M14. …`, `### A1. …`;
# the list-structured variant is a bolded lead, `- **L0b — …`), never reused and never renamed
# — and references write `§<CODE>` (grammar: letter + 1-2 digits + optional letter). The §
# sigil is the OPT-IN: only §-referenced codes are checked, so cold docs are never coerced
# into growing codes (the doc-heat rule) and un-sigiled report-local codes (retro F-codes,
# the fixer-context L-layers) stay out of scope until someone §-references one — at which
# point ANCHOR-AMBIGUOUS forces the rename the never-reuse rule demands. Historical docs +
# TICK-LOG + adr.md are exempt as referencers and invisible as definition sites.

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
# FAILING since 2026-08-23 (see the header note). ⚠ The findings must reach $status, so no
# pipe-subshell: the loop reads a captured row list (the flip would have been a no-op behind
# `grep | while` — the classic subshell-loses-status trap).
GLOSS=docs/glossary.md
if [ -f "$GLOSS" ]; then
  rows=$(grep '^| \*\*⚓' "$GLOSS")
  while IFS= read -r row; do
    [ -n "$row" ] || continue
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
      case "$f" in agents/coordinator/TICK-LOG.md|docs/adr.md) continue ;; esac
      grep -qiF "$term" "$f" || continue
      grep -qF "$hbase" "$f" && continue
      grep -qF "glossary.md" "$f" && continue
      echo "TERM-UNLINKED (check #3): $f uses \"$term\" without linking $home or the glossary"
      status=1
    done
  done <<EOF_ROWS
$rows
EOF_ROWS
fi

# --- 4) §-code anchors: every §CODE ref resolves to exactly one living definition ---
# Refs come from every tracked text file (code comments included); definitions from living
# .md only. No pipe-subshell (the check-#3 trap): the loop runs in the main shell so its
# $status writes stick.
CODE_RE='[A-Z][0-9][0-9]?[a-z]?'
anchor_refs=$(git grep -hoE "§${CODE_RE}" -- '*.md' '*.sh' '*.py' '*.yaml' '*.yml' \
    ":(exclude)agents/coordinator/TICK-LOG.md" ":(exclude)docs/adr.md" \
    ":(exclude)docs/agents/retros" ":(exclude)docs/incidents" \
    ":(exclude)docs/follow-ups-archive.md" 2>/dev/null | sed 's/^§//' | sort -u)
for code in $anchor_refs; do
  defs=$(git grep -nE "^#{1,6} +${code}[^A-Za-z0-9]|^- \*\*${code}[^A-Za-z0-9]" -- '*.md' \
      ":(exclude)agents/coordinator/TICK-LOG.md" ":(exclude)docs/adr.md" \
      ":(exclude)docs/agents/retros" ":(exclude)docs/incidents" \
      ":(exclude)docs/follow-ups-archive.md" 2>/dev/null | cut -d: -f1,2)
  n=$(printf '%s\n' "$defs" | grep -c . || true)
  if [ "$n" -eq 0 ]; then
    where=$(git grep -lF "§${code}" -- '*.md' '*.sh' '*.py' '*.yaml' '*.yml' 2>/dev/null | head -3 | tr '\n' ' ')
    echo "ANCHOR-UNRESOLVED (check #4): §${code} referenced (${where}) but no living heading/bullet defines it"
    status=1
  elif [ "$n" -gt 1 ]; then
    echo "ANCHOR-AMBIGUOUS (check #4): §${code} defined ${n}× — codes are never reused: $(printf '%s\n' "$defs" | tr '\n' ' ')"
    status=1
  fi
done

[ "$status" -eq 0 ] && echo "docs-graph: links resolve, agents doc table complete, ⚓ terms linked"
exit "$status"
