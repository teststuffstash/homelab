#!/usr/bin/env bash
# model-id-test.sh — the FU-127 parser's cases, plus a DRIFT PIN on the one duplicate we cannot
# collapse. Run: devbox run model-id-test  (wired into CI next to footprint-test).
#
# Why a pin rather than a shared import: the egress proxy runs from a ConfigMap in a different
# deployment unit (argocd/resources/openrouter-proxy/) and cannot import agents/model_id.py. Its
# normalize_model must therefore RESTATE the rail-namespace half — so this test executes that
# function out of the proxy file and asserts it agrees with the parser on every case. If someone
# edits one and not the other, this fails instead of the fleet quietly disagreeing about what
# `openrouter/owl-alpha` means.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$HERE/model_id.py" "$ROOT/argocd/resources/openrouter-proxy/openrouter-proxy.py" <<'PY'
import ast
import importlib.util
import sys

parser_path, proxy_path = sys.argv[1], sys.argv[2]

spec = importlib.util.spec_from_file_location("model_id", parser_path)
model_id = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model_id)

# CASES: (id, rail, harness, model). The comment on each is the reason it exists as a case.
CASES = [
    # the subscription rail: prefix carries the HARNESS too (FU-066)
    ("claude/opus", "anthropic-subscription", "claude", "opus"),
    ("claude/haiku", "anthropic-subscription", "claude", "haiku"),
    # our rail prefix, stripped: goose/opencode want the id in OpenRouter's namespace
    ("openrouter/deepseek/deepseek-v4-flash-0731", "openrouter", "", "deepseek/deepseek-v4-flash-0731"),
    ("openrouter/qwen/qwen3-coder:free", "openrouter", "", "qwen/qwen3-coder:free"),
    # CLOAKED: OpenRouter's OWN namespace — the prefix is part of the id and must survive
    ("openrouter/owl-alpha", "openrouter", "", "openrouter/owl-alpha"),
    # the common case: bare vendor/model, OpenRouter implied
    ("xiaomi/mimo-v2.5", "openrouter", "", "xiaomi/mimo-v2.5"),
    ("tencent/hy3:free", "openrouter", "", "tencent/hy3:free"),
    # degenerate input parses instead of raising — dispatch must not die on a claim typo
    ("", "openrouter", "", ""),
    ("weird", "openrouter", "", "weird"),
]

fails = 0
for mid, rail, harness, model in CASES:
    got = model_id.parse(mid)
    want = {"rail": rail, "harness": harness, "model": model}
    if got != want:
        print(f"FAIL parse({mid!r}): {got} != {want}")
        fails += 1

# Extract the proxy's normalize_model WITHOUT importing the module (it has server-side globals and
# a threading/HTTP surface we must not spin up in a test).
tree = ast.parse(open(proxy_path).read())
fn = next((n for n in tree.body
           if isinstance(n, ast.FunctionDef) and n.name == "normalize_model"), None)
if fn is None:
    print("FAIL: normalize_model not found in the proxy — the drift pin cannot check anything")
    fails += 1
else:
    ns: dict = {}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), proxy_path, "exec"), ns)
    proxy_normalize = ns["normalize_model"]
    for mid, rail, _harness, model in CASES:
        # The pin covers the OPENROUTER rail only, and that is the contract: the proxy's function
        # exists to put an id into OpenRouter's namespace. Subscription ids never reach it — a
        # claude/* ride talks to the /anthropic leg with a model name Claude Code chooses — and an
        # empty id is not a request the proxy can receive.
        if not mid or rail != "openrouter":
            continue
        got = proxy_normalize(mid)
        if got != model:
            print(f"FAIL proxy normalize_model({mid!r}) = {got!r}, parser says {model!r} — "
                  "the two implementations have DRIFTED (FU-127)")
            fails += 1

# ── --shell interface and HARNESS_SET interaction pin (homelab#827) ───
# #791's deliverable 3 said "the launcher's harness derivation stops forcing goose for OR
# models." That is mis-stated: for OpenRouter, harness is a CHOICE, not a property of the
# id — goose, opencode, and claude all serve OpenRouter today. model_id.py correctly returns
# harness="" for every OR model, leaving the choice to the caller's --harness flag.
#
# This pin verifies:
#   1. The --shell output for an OR model sets MODEL_HARNESS=''
#   2. Sourcing that output in a shell with HARNESS_SET (from --harness) correctly KEEPS
#      the explicit harness — the caller's choice survives the empty derivation.
#   3. Sourcing that output without HARNESS_SET also leaves the caller's default harness,
#      because the empty MODEL_HARNESS is skipped by [ -z "$MODEL_HARNESS" ].
for mid, label in [("openrouter/anthropic/claude-sonnet-4-20250514", "vendor/model"),
                    ("openrouter/deepseek/deepseek-v4-flash", "vendor/model"),
                    ("xiaomi/mimo-v2.5", "bare vendor/model")]:
    import subprocess
    result = subprocess.run(
        [sys.executable, parser_path, "--shell", mid],
        capture_output=True, text=True)
    if result.returncode != 0:
        print(f"FAIL --shell {mid!r} exited {result.returncode}: {result.stderr}")
        fails += 1
        continue
    # Parse the shell output manually — Python exec can't run shell assignments.
    # Output is space-separated KEY=VALUE with shlex-quoted values.
    parsed = {}
    for token in result.stdout.strip().split():
        if "=" in token:
            k, v = token.split("=", 1)
            # shlex.quote produces '' for empty strings
            parsed[k] = v.strip("'") if v.startswith("'") else v
    if parsed.get("MODEL_HARNESS") != "":
        print(f"FAIL --shell {mid!r}: MODEL_HARNESS={parsed.get('MODEL_HARNESS')!r}, want ''")
        fails += 1
    if parsed.get("MODEL_RAIL") != "openrouter":
        print(f"FAIL --shell {mid!r}: MODEL_RAIL={parsed.get('MODEL_RAIL')!r}, want 'openrouter'")
        fails += 1
    # HARNESS_SET interaction: explicit --harness claude must survive the empty derivation.
    # We use subprocess with bash to test the exact agent-session.sh:511 guard line.
    MODEL_HARNESS = parsed.get("MODEL_HARNESS", "")
    # Test 1: HARNESS_SET=1 (caller passed --harness) — harness stays unchanged
    p1 = subprocess.run(
        ["bash", "-c",
         'MH="$1"; H="$2"; HS="$3"; '
         '[ -z "$MH" ] || [ -n "${HS:-}" ] || H="$MH"; echo "$H"',
         "_", MODEL_HARNESS, "opencode", "1"],
        capture_output=True, text=True)
    if p1.stdout.strip() != "opencode":
        print(f"FAIL HARNESS_SET interaction {mid!r}: harness={p1.stdout.strip()!r}, want 'opencode'")
        fails += 1
    # Test 2: no HARNESS_SET, MODEL_HARNESS empty — harness stays unchanged
    p2 = subprocess.run(
        ["bash", "-c",
         'MH="$1"; H="$2"; '
         '[ -z "$MH" ] || [ -n "${HARNESS_SET:-}" ] || H="$MH"; echo "$H"',
         "_", MODEL_HARNESS, "opencode"],
        capture_output=True, text=True)
    if p2.stdout.strip() != "opencode":
        print(f"FAIL no-HARNESS_SET interaction {mid!r}: harness={p2.stdout.strip()!r}, want 'opencode'")
        fails += 1
    # Subscription model for comparison: claude/haiku must produce MODEL_HARNESS=claude
    # which triggers the override path on agent-session.sh:511 ([ -z "$MODEL_HARNESS" ] is FALSE).
    sub_result = subprocess.run(
        [sys.executable, parser_path, "--shell", "claude/haiku"],
        capture_output=True, text=True)
    sub_parsed = {}
    for token in sub_result.stdout.strip().split():
        if "=" in token:
            k, v = token.split("=", 1)
            sub_parsed[k] = v.strip("'") if v.startswith("'") else v
    if sub_parsed.get("MODEL_HARNESS") != "claude":
        print(f"FAIL --shell claude/haiku: MODEL_HARNESS={sub_parsed.get('MODEL_HARNESS')!r}, want 'claude'")
        fails += 1
    else:
        sub_MH = sub_parsed["MODEL_HARNESS"]
        # Verify the override path: subscription MODEL_HARNESS=claude overrides default opencode
        p3 = subprocess.run(
            ["bash", "-c",
             'MH="$1"; H="$2"; '
             '[ -z "$MH" ] || [ -n "${HARNESS_SET:-}" ] || H="$MH"; echo "$H"',
             "_", sub_MH, "opencode"],
            capture_output=True, text=True)
        if p3.stdout.strip() != "claude":
            print(f"FAIL subscription harness derivation: HARNESS={p3.stdout.strip()!r}, want 'claude'")
            fails += 1
        # With explicit HARNESS_SET, the derivation is skipped
        p4 = subprocess.run(
            ["bash", "-c",
             'MH="$1"; H="$2"; HARNESS_SET="$3"; '
             '[ -z "$MH" ] || [ -n "${HARNESS_SET:-}" ] || H="$MH"; echo "$H"',
             "_", sub_MH, "opencode", "1"],
            capture_output=True, text=True)
        if p4.stdout.strip() != "opencode":
            print(f"FAIL subscription HARNESS_SET interaction: explicit harness overridden to {p4.stdout.strip()!r}")
            fails += 1

print(f"model-id: {len(CASES)} cases × parser + proxy drift pin + {3} OR shell/HARNESS_SET pins — "
      f"{'FAILED' if fails else 'all agree'}")
sys.exit(1 if fails else 0)
PY
