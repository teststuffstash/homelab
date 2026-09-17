#!/usr/bin/env bash
# model-id-test.sh — the FU-127 parser's cases (the rail/harness parse AND the provider-routing
# suffix strip rule, homelab#1670/#1697), plus a DRIFT PIN on the one duplicate we cannot collapse.
# Run: devbox run model-id-test  (wired into CI next to footprint-test).
#
# Why a pin rather than a shared import: the egress proxy runs from a ConfigMap in a different
# deployment unit (argocd/resources/openrouter-proxy/) and cannot import agents/model_id.py. Its
# normalize_model must therefore RESTATE the rail-namespace half — so this test executes that
# function out of the proxy file and asserts it agrees with the parser on every case. If someone
# edits one and not the other, this fails instead of the fleet quietly disagreeing about what
# `openrouter/owl-alpha` means. The same pin covers the parser's own mirror copy, and a scan
# asserts no consumer re-derives the strip (the one-home acceptance of homelab#1697).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

python3 - "$HERE/model_id.py" "$ROOT/argocd/resources/openrouter-proxy/openrouter-proxy.py" \
         "$ROOT/agents/agent-session.sh" "$ROOT/argocd/resources/openrouter-proxy/model_id.py" \
         "$ROOT/agents/estimate_budget.py" "$ROOT/argocd/resources/openrouter-proxy/router.py" <<'PY'
import ast
import importlib.util
import pathlib
import shlex
import subprocess
import sys

(parser_path, proxy_path, session_path, mirror_path, estimate_path,
 router_path) = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]

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

# ── the provider-routing suffix strip rule (homelab#1670 pricing half, #1697 the one home) ──────
# STRIP_CASES: (id, base_id, lookup_ids, routing_suffix(id, base), strip_routing_suffix(id)).
# Two DIFFERENT questions, deliberately: `routing_suffix` is the DISCLOSURE helper (what did the
# price drop? — any genuine base counts, `:free` included), while `strip_routing_suffix` is the
# BOOKKEEPING key (drop only what this platform's router appends, so a `:free` chain id stays
# whole). Collapsing them would either silence the `:free` disclosure or key a cooldown under an
# id the /route eligibility loop never filters against.
STRIP_CASES = [
    # a routing suffix: the pricing path retries the base id, the bookkeeping key drops it
    ("deepseek/deepseek-v4.1-flash:exacto", "deepseek/deepseek-v4.1-flash",
     ["deepseek/deepseek-v4.1-flash:exacto", "deepseek/deepseek-v4.1-flash"], ":exacto",
     "deepseek/deepseek-v4.1-flash"),
    # a VARIANT in its own right: never degraded to its paid sibling, and a chain id the
    # eligibility loop filters against — so the bookkeeping strip leaves it WHOLE
    ("tencent/hy3:free", "tencent/hy3",
     ["tencent/hy3:free", "tencent/hy3"], ":free", "tencent/hy3:free"),
    # a DOUBLED suffix (#1693: the router re-appending to an already-suffixed chain entry) reduces
    # all the way to the paid id, nearest truncation first — one suffix per call, like the strip
    ("deepseek/deepseek-v4-flash:exacto:exacto", "deepseek/deepseek-v4-flash:exacto",
     ["deepseek/deepseek-v4-flash:exacto:exacto", "deepseek/deepseek-v4-flash:exacto",
      "deepseek/deepseek-v4-flash"], ":exacto", "deepseek/deepseek-v4-flash:exacto"),
    # the rail prefix is normalized away in the lookup list, and is NOT a routing suffix
    ("openrouter/acme/coder", None,
     ["openrouter/acme/coder", "acme/coder"], None, "openrouter/acme/coder"),
    # no suffix at all: base_id is None, the id is its own only lookup, nothing to strip
    ("xiaomi/mimo-v2.5", None, ["xiaomi/mimo-v2.5"], None, "xiaomi/mimo-v2.5"),
    # degenerate input never raises — dispatch must not die on a claim typo
    ("", None, [], None, ""),
]

for mid, want_base, want_lookups, want_suffix, want_strip in STRIP_CASES:
    got_base = model_id.base_id(mid)
    got_lookups = model_id.lookup_ids(mid)
    got_suffix = model_id.routing_suffix(mid, want_base) if want_base else None
    got_strip = model_id.strip_routing_suffix(mid)
    if got_base != want_base:
        print(f"FAIL base_id({mid!r}) = {got_base!r}, want {want_base!r}")
        fails += 1
    if got_lookups != want_lookups:
        print(f"FAIL lookup_ids({mid!r}) = {got_lookups!r}, want {want_lookups!r}")
        fails += 1
    if got_suffix != want_suffix:
        print(f"FAIL routing_suffix({mid!r}, {want_base!r}) = {got_suffix!r}, want {want_suffix!r}")
        fails += 1
    if got_strip != want_strip:
        print(f"FAIL strip_routing_suffix({mid!r}) = {got_strip!r}, want {want_strip!r} — the "
              "bookkeeping key must be the chain id the eligibility loop filters against")
        fails += 1

# ── ONE HOME (homelab#1697 acceptance 1): no consumer re-derives the strip ──────────────────────
# The rule lives in model_id.py; a `removesuffix(":exacto")` or a hand-rolled `rpartition(":")` in
# a consumer is exactly the drift this issue exists to end. The patterns are spelled here as data,
# which is why the scan is scoped to the three consumers rather than the whole tree.
CONSUMERS = [estimate_path, router_path, proxy_path]
FORBIDDEN = ['removesuffix(":exacto")', 'rpartition(":")']
for path in CONSUMERS:
    src = pathlib.Path(path).read_text()
    for pat in FORBIDDEN:
        if pat in src:
            print(f"FAIL {path}: {pat!r} — the strip rule has ONE home (model_id.py); import it")
            fails += 1
    if "model_id" not in src:
        print(f"FAIL {path}: does not reference the parser — the strip rule must be imported, "
              "never re-derived")
        fails += 1

# ── DRIFT PIN, extended (homelab#1697): the parser's own mirror copy must AGREE ─────────────────
# `argocd/resources/openrouter-proxy/model_id.py` is the byte-identical mirror shipped in the
# proxy's ConfigMap (kustomization.yaml, FU-127) — a different deployment unit that cannot import
# agents/model_id.py. Every case above runs against BOTH copies, so editing one and not the other
# fails HERE instead of the fleet quietly disagreeing about what a suffix means.
if pathlib.Path(parser_path).read_bytes() != pathlib.Path(mirror_path).read_bytes():
    print(f"FAIL {mirror_path} is not byte-identical to {parser_path} — the mirror has DRIFTED")
    fails += 1
spec_mirror = importlib.util.spec_from_file_location("model_id_mirror", mirror_path)
mirror = importlib.util.module_from_spec(spec_mirror)
spec_mirror.loader.exec_module(mirror)
for mid, *_ in CASES:
    if mirror.parse(mid) != model_id.parse(mid):
        print(f"FAIL mirror parse({mid!r}) = {mirror.parse(mid)!r}, parser says "
              f"{model_id.parse(mid)!r} — the two copies have DRIFTED")
        fails += 1
for mid, want_base, want_lookups, want_suffix, want_strip in STRIP_CASES:
    got = (mirror.base_id(mid), mirror.lookup_ids(mid),
           mirror.routing_suffix(mid, want_base) if want_base else None,
           mirror.strip_routing_suffix(mid))
    want = (want_base, want_lookups, want_suffix, want_strip)
    if got != want:
        print(f"FAIL mirror strip rule on {mid!r}: {got!r} != {want!r} — the two copies have DRIFTED")
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

# ── HARNESS guard pin (homelab#827) ──────────────────────────────────────────
# #791's deliverable 3 said "the launcher's harness derivation stops forcing goose for OR
# models." That is mis-stated: for OpenRouter, harness is a CHOICE, not a property of the
# id — goose, opencode, and claude all serve OpenRouter today. model_id.py correctly returns
# harness="" for every OR model, leaving the choice to the caller's --harness flag.
#
# This pin extracts the EXACT guard line from agents/agent-session.sh and evals it, so a
# re-typing drift in that shell file turns this test red. The guard is:
#
#   [ -z "$MODEL_HARNESS" ] || [ -n "${HARNESS_SET:-}" ] || HARNESS="$MODEL_HARNESS"
#
# Cases verified:
#   1. OR model (MODEL_HARNESS="") — guard short-circuits at [ -z "$MODEL_HARNESS" ],
#      leaving the caller's default harness intact.
#   2. Subscription model (MODEL_HARNESS="claude") without HARNESS_SET — guard overrides
#      HARNESS to "claude".
#   3. Subscription model (MODEL_HARNESS="claude") with HARNESS_SET=1 — guard short-circuits
#      at [ -n "${HARNESS_SET:-}" ], leaving the caller's explicit --harness intact.
session_sh = pathlib.Path(session_path).read_text()
guard_lines = [l for l in session_sh.splitlines() if 'HARNESS="$MODEL_HARNESS"' in l]
if len(guard_lines) == 0:
    print("FAIL: guard line HARNESS=\"$MODEL_HARNESS\" not found in agent-session.sh — "
          "the test cannot pin anything")
    fails += 1
elif len(guard_lines) > 1:
    raise SystemExit(
        f"FATAL: {len(guard_lines)} lines match HARNESS=\"$MODEL_HARNESS\" in "
        f"agent-session.sh, expected exactly 1")
else:
    guard = guard_lines[0].strip()

    # ── OR model: empty MODEL_HARNESS short-circuits ─────────────────────
    for mid in ["openrouter/anthropic/claude-sonnet-4-20250514",
                "openrouter/deepseek/deepseek-v4-flash",
                "xiaomi/mimo-v2.5"]:
        result = subprocess.run(
            [sys.executable, parser_path, "--shell", mid],
            capture_output=True, text=True)
        if result.returncode != 0:
            print(f"FAIL --shell {mid!r} exited {result.returncode}: {result.stderr}")
            fails += 1
            continue
        # shlex.split correctly handles the shlex.quote'd output from --shell
        parsed = dict(token.split("=", 1) for token in shlex.split(result.stdout))

        if parsed.get("MODEL_HARNESS") != "":
            print(f"FAIL --shell {mid!r}: MODEL_HARNESS={parsed.get('MODEL_HARNESS')!r}, want ''")
            fails += 1
        if parsed.get("MODEL_RAIL") != "openrouter":
            print(f"FAIL --shell {mid!r}: MODEL_RAIL={parsed.get('MODEL_RAIL')!r}, want 'openrouter'")
            fails += 1

        MODEL_HARNESS = parsed.get("MODEL_HARNESS", "")
        # Guard with MODEL_HARNESS="" short-circuits at [ -z "$MODEL_HARNESS" ],
        # so HARNESS stays at "opencode" (the caller's default).
        p_short = subprocess.run(
            ["bash", "-c",
             'MH="$1" H="$2" HS="$3" '
             'MODEL_HARNESS="$MH" HARNESS="$H" HARNESS_SET="$HS"; '
             + guard + '; echo "$HARNESS"',
             "_", MODEL_HARNESS, "opencode", ""],
            capture_output=True, text=True)
        if p_short.stdout.strip() != "opencode":
            print(f"FAIL OR empty-derivation short-circuit {mid!r}: "
                  f"HARNESS={p_short.stdout.strip()!r}, want 'opencode'")
            fails += 1

    # ── Subscription model: non-empty MODEL_HARNESS exercises override ───
    sub_result = subprocess.run(
        [sys.executable, parser_path, "--shell", "claude/haiku"],
        capture_output=True, text=True)
    sub_parsed = dict(token.split("=", 1) for token in shlex.split(sub_result.stdout))

    if sub_parsed.get("MODEL_HARNESS") != "claude":
        print(f"FAIL --shell claude/haiku: "
              f"MODEL_HARNESS={sub_parsed.get('MODEL_HARNESS')!r}, want 'claude'")
        fails += 1
    else:
        sub_MH = sub_parsed["MODEL_HARNESS"]
        # Without HARNESS_SET: MODEL_HARNESS="claude" is non-empty so [ -z ] is false;
        # HARNESS_SET is empty so [ -n "${HARNESS_SET:-}" ] is false; guard fires:
        # HARNESS becomes "claude" (the subscription's derived harness).
        p_override = subprocess.run(
            ["bash", "-c",
             'MH="$1" H="$2" HS="$3" '
             'MODEL_HARNESS="$MH" HARNESS="$H" HARNESS_SET="$HS"; '
             + guard + '; echo "$HARNESS"',
             "_", sub_MH, "opencode", ""],
            capture_output=True, text=True)
        if p_override.stdout.strip() != "claude":
            print(f"FAIL subscription harness derivation: "
                  f"HARNESS={p_override.stdout.strip()!r}, want 'claude'")
            fails += 1
        # With HARNESS_SET=1: MODEL_HARNESS="claude" is non-empty so [ -z ] is false;
        # but HARNESS_SET is "1" so [ -n "${HARNESS_SET:-}" ] is true; guard short-circuits:
        # HARNESS stays at "opencode" (the caller's explicit --harness).
        p_set = subprocess.run(
            ["bash", "-c",
             'MH="$1" H="$2" HS="$3" '
             'MODEL_HARNESS="$MH" HARNESS="$H" HARNESS_SET="$HS"; '
             + guard + '; echo "$HARNESS"',
             "_", sub_MH, "opencode", "1"],
            capture_output=True, text=True)
        if p_set.stdout.strip() != "opencode":
            print(f"FAIL subscription HARNESS_SET override-skip: "
                  f"HARNESS={p_set.stdout.strip()!r}, want 'opencode'")
            fails += 1

print(f"model-id: {len(CASES)} parse cases + {len(STRIP_CASES)} strip cases × parser + mirror "
      f"drift pin + proxy normalize_model pin + one-home scan + "
      f"OR empty-derivation + subscription guard pins — "
      f"{'FAILED' if fails else 'all agree'}")
sys.exit(1 if fails else 0)
PY