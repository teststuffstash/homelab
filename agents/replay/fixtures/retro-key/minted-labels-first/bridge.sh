# ── bridge ── the retro-session variables the block reads, each named exactly as retro-session.sh
# sets it upstream, plus the two `kube.sh` resolves (the stub `kubectl` stands in for the binary).
HERE="$REPLAY_ROOT/agents"
HARNESS="goose"
MODEL="deepseek/deepseek-v4-pro"
PROJECT="oracle-fleet"
RUN_ID="r4"
REVIEW=""
BRIEF="$REPLAY_FIXTURE/brief.md"
KUBECTL="kubectl"
KUBE=""

# ── seam ── two call sites, two behaviours. `$1 = -` is the inline parser THIS fixture exists to
# exercise: it passes through untouched. Anything else is estimate_budget.py: pin the price (no
# fixture may reach the live registry) AND reorder the emitted CR's inline-flow metadata keys so
# `labels` precedes `name`. emit_cr does not produce this order today — that is the point. The
# parser must read a CR whose key order the emitter is free to change, which is the contract #1075
# buys.
python3() {
  if [ "$1" = "-" ]; then
    command python3 "$@"
  else
    command python3 "$@" --price-per-mtok 0.30 | command python3 -c '
import re, sys

for line in sys.stdin:
    # Match inline flow: key: { k1: v1, k2: v2, ... }
    m = re.match(r"^(\w+):\s*\{(.*)\}\s*$", line.rstrip("\n"))
    if not m:
        sys.stdout.write(line)
        continue

    key = m.group(1)
    inner = m.group(2).strip()

    # Split inner content on top-level commas (not inside nested braces)
    parts = []
    depth = 0
    buf = ""
    for ch in inner:
        if ch == "{":
            depth += 1
            buf += ch
        elif ch == "}":
            depth -= 1
            buf += ch
        elif ch == "," and depth == 0:
            parts.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip():
        parts.append(buf.strip())

    # Separate labels from other keys
    labels_part = None
    others = []
    for part in parts:
        if part.startswith("labels:"):
            labels_part = part
        else:
            others.append(part)

    # Reorder: labels first, then the rest
    if labels_part:
        reordered = [labels_part] + others
    else:
        reordered = others

    items = ", ".join(reordered)
    print(f"{key}: {{{items}}}\n")
'
  fi
}