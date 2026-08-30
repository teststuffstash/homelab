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
# fixture may reach the live registry) and re-render its emitted CR's inline-flow `metadata: { … }`
# into BLOCK style. emit_cr does not produce this shape today — that is the point. The parser must
# read a CR whose rendering the emitter is free to move to, which is the contract #989 buys.
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

    print(key + ":")

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

    for part in parts:
        # Split on first ": "
        colon = part.find(": ")
        if colon == -1:
            continue
        k = part[:colon].strip()
        v = part[colon + 2:].strip()

        if v.startswith("{") and v.endswith("}"):
            # Nested inline object -> block style
            print("  " + k + ":")
            nested = v[1:-1].strip()
            for npart in nested.split(","):
                npart = npart.strip()
                if not npart:
                    continue
                ncolon = npart.find(": ")
                if ncolon == -1:
                    continue
                nk = npart[:ncolon].strip()
                nv = npart[ncolon + 2:].strip()
                print("    " + nk + ": " + nv)
        else:
            print("  " + k + ": " + v)
'
  fi
}