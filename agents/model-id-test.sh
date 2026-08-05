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

print(f"model-id: {len(CASES)} cases × parser + proxy drift pin — "
      f"{'FAILED' if fails else 'all agree'}")
sys.exit(1 if fails else 0)
PY
