#!/usr/bin/env python3
"""Render a Claude Code session transcript (.jsonl on stdin) as a readable behaviour trace —
one line per turn: assistant text, tool calls (name + input), and tool results (truncated). This is
how you analyse the coordinator: kubectl logs is empty (the interactive session runs via exec, not
PID 1), so the transcript IS the log. Used by scripts/coordinator-logs.sh."""

from __future__ import annotations

import json
import sys


def _clip(s: object, n: int) -> str:
    return " ".join(str(s).split())[:n]


def dialogue() -> None:
    """--dialogue: user + assistant TEXT only — no tool calls, no tool results, no
    system-reminders. The skill-retro slice format (ADR-105): tool output may carry secrets
    and the analysis only needs the conversation (corrections live in the operator's words).
    Skill invocations keep a one-line marker so the analyzer can anchor them."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = o.get("type")
        msg = o.get("message") or {}
        content = msg.get("content")
        if kind == "assistant" and isinstance(content, list):
            for c in content:
                if c.get("type") == "text" and c.get("text", "").strip():
                    print(f"🤖 {_clip(c['text'], 2500)}")
                elif c.get("type") == "tool_use" and c.get("name") == "Skill":
                    print(f"[skill invoked: {_clip(json.dumps(c.get('input', {})), 200)}]")
        elif kind == "user":
            texts = [content] if isinstance(content, str) else [
                c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"
            ] if isinstance(content, list) else []
            for t in texts:
                t = t.strip()
                if t and not t.startswith("<system-reminder"):
                    print(f"👤 {_clip(t, 2500)}")


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = str(o.get("timestamp", ""))[11:19]
        kind = o.get("type")
        msg = o.get("message") or {}
        content = msg.get("content")
        if kind == "assistant" and isinstance(content, list):
            for c in content:
                if c.get("type") == "text" and c.get("text", "").strip():
                    print(f"{ts} 🤖 {_clip(c['text'], 600)}")
                elif c.get("type") == "tool_use":
                    print(f"{ts} 🔧 {c.get('name')}({_clip(json.dumps(c.get('input', {})), 240)})")
        elif kind == "user":
            if isinstance(content, str):
                print(f"{ts} 👤 {_clip(content, 400)}")
            elif isinstance(content, list):
                for c in content:
                    if c.get("type") == "tool_result":
                        r = c.get("content")
                        if isinstance(r, list):
                            r = " ".join(x.get("text", "") for x in r if isinstance(x, dict))
                        print(f"{ts} ⤷  {_clip(r, 300)}")


if __name__ == "__main__":
    dialogue() if "--dialogue" in sys.argv[1:] else main()
