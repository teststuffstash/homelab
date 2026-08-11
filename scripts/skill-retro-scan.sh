#!/bin/sh
# skill-retro-scan — the deterministic half of the skill-retro skill (ADR-105).
# Finds jail session transcripts that invoked a skill and are newer than the watermark,
# and renders each as a DIALOGUE-ONLY slice (user + assistant text — no tool dumps; tool
# output may carry secrets) for the LLM pass. Read-only: the SKILL advances the watermark
# after the GAPS ledger is written (date -Iseconds > ~/.claude/skill-retro/watermark).
set -eu
PROJ="$HOME/.claude/projects/-workspace-homelab"
OUT="$HOME/.claude/skill-retro"
WM="$OUT/watermark"
SLICES="$OUT/slices"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$SLICES"

# Slash-invoked skills leave <command-name> tags; tool-invoked ones leave Skill tool_use blocks.
MARKER='<command-name>/(design|design-agents|docs-cleanup|fu-sweep|meta-coordinate|handoff|onboard-metal-node|opnsense-as-code|tofu-apply|skill-retro)</command-name>|"name": *"Skill"'

n=0
for f in "$PROJ"/*.jsonl; do
  [ -f "$f" ] || continue
  if [ -f "$WM" ] && [ "$WM" -nt "$f" ]; then continue; fi
  # a transcript written to in the last 10 min is a live session — not finished, skip
  if [ -n "$(find "$f" -newermt '-10 minutes' 2>/dev/null)" ]; then
    echo "skip (active): $(basename "$f")"
    continue
  fi
  grep -qE "$MARKER" "$f" || continue
  id="$(basename "$f" .jsonl)"
  python3 "$REPO/scripts/render-transcript.py" --dialogue < "$f" > "$SLICES/$id.txt"
  skills="$(grep -oE '<command-name>/[a-z-]+' "$f" | sort -u | sed 's,.*/,,' | tr '\n' ' ')"
  echo "slice: $SLICES/$id.txt ($(wc -l < "$SLICES/$id.txt") lines; skills: ${skills:-tool-invoked})"
  n=$((n + 1))
done
echo "rendered $n slice(s); watermark: $([ -f "$WM" ] && cat "$WM" || echo none)"
