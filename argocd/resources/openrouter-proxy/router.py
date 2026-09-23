#!/usr/bin/env python3
"""router — the ADR-096 control-plane module of the egress proxy (FU-095 router leg).

openrouter-proxy.py imports this beside its data plane. This module owns the DURABLE state the
proxy never had: strikes and run attribution (POST /report), passively observed provider events
(every OpenRouter chat/completions response the data plane forwards), the rotation/canary feed
(POST /rotation — no rankings API exists upstream, probed 2026-07-27: `order=top-weekly` is
ignored by /api/v1/models and the frontend paths serve the app shell, so the rotation is a
git-curated list in model-classes.json plus scout canary verdicts), 429-latch persistence
(a proxy restart no longer forgets the subscription latch), and the class-policy config
(model-classes.json — tier thresholds for FU-109, class rails/allowances for /route in P3).

Storage is sqlite3 (stdlib) on the Longhorn PVC at ROUTER_DB. FAIL-OPEN INVARIANT (the
subscription-latch.sh rule, kept): if the PVC is absent/unwritable the store degrades to
:memory: and reports router_db_persistent 0 — an empty or ephemeral DB never blocks dispatch,
it only forgets. All writes are best-effort from the proxy's request threads: one process-wide
lock + WAL; traffic is tens of requests/min, contention is not a concern.

Stdlib only; same ConfigMap as openrouter-proxy.py (the script dir is on sys.path, so the
import needs no packaging). `--self-test` runs the in-memory round-trip; CI runs it via
`devbox run router-self-test`.
"""

import calendar
import copy
import json
import math
import os
import random
import re
import sqlite3
import sys
import threading
import time

# FU-127: the canonical model-id parser, deployed alongside the proxy in the same ConfigMap.
# One definition — the same one `devbox run model-id-test` pins against agents/model_id.py by
# AST; never a third copy.
import model_id

# ── THE RAIL VOCABULARY — THE ONE HOME (Goal #1769 acceptance 1) ───────────────────────────────
# A candidate's rail is whatever `model_id.parse()` says it is. The parser has owned the rule
# since FU-127; the walk re-derived it anyway as a two-way split
# (`"subscription" if m.startswith("claude/") else "openrouter"`, three sites), so an
# `opencode-go/*` candidate classified as OpenRouter and was gated by the OpenRouter KEY's state
# (`or_gate`) instead of the Go rail's own capacity (`/opencode-limit`). The rule is read from
# the parser now, at the one place that decides — `route()`'s walk — and the walk's own
# vocabulary IS the parser's, so `classes.<cls>.rails` and a decision row cannot spell a rail the
# parser would never produce.
#
# `classes.<cls>.rails` is written in this CANONICAL vocabulary. `opencode-zen` is the one member
# no parse rule produces yet: the `opencode/` prefix is the Zen leg (homelab#445), parked by
# OPENCODE_RAIL_DISABLED and unmetered — Goal #1769 acceptance 2's `rails:` block declares it
# `enabled: false`. A class may name it; no candidate can parse onto it, so the walk finds an
# empty pool and moves on (a rail with no candidates is not a rail with a wrong answer).
RAIL_OPENCODE_ZEN = "opencode-zen"
RAILS = (model_id.RAIL_SUBSCRIPTION, model_id.RAIL_OPENCODE_GO, model_id.RAIL_OPENROUTER,
         RAIL_OPENCODE_ZEN)
# ONE-RELEASE alias for the pre-Goal-#1769 spelling. Applied once at load and logged once
# (below), so a class file still carrying `subscription` means the canonical rail instead of
# meaning NOTHING (which is what an unaliased unknown name would be — an empty pool, silently).
# Deleted next release, with the alias row.
RAIL_ALIASES = {"subscription": model_id.RAIL_SUBSCRIPTION}

# ── CALLER CAPABILITY — THE RAIL WALK'S OTHER INPUT (Goal #1769 acceptance 4, router half) ─────
# The 2026-08-26 incident (docs/incidents/2026-08-26-reviewer-404-loop.md) named the gap:
# "the gate asks 'can the ACCOUNT buy', never 'can the CALLER ride'". The reviewer sends no
# OpenRouter `key_ref` BY DESIGN, and `review`'s second rail entry — one YAML token — turned
# "defer + fallback" into a served, dead OpenRouter pick with zero review verdicts for ~6h.
# FU-188 pinned the reviewer to shadow; this predicate is what makes WIDENING the rail lists safe
# again, so the pin's shell line (theme 2's deletion) stops being load-bearing.
#
# What each rail REQUIRES of the caller, declared per rail. Goal #1769 acceptance 2 EXTERNALIZED
# this into model-classes.json's `rails:` block (`surfaces`), which `rail_surfaces()` reads; the
# table below is the code BELT for a jail run without the file (same contract as every other
# table here). The requirement is the rail's `surfaces` list, plus openrouter's `key_ref` (its own
# credential — the one requirement that is not a surface, so it stays a code predicate).
#
#   openrouter                a `key_ref` — the caller's OWN credential. Its absence now means
#                             "I cannot ride this rail", never "unknown, try anyway". Its
#                             `surfaces` cover every caller surface (any CLI can ride it WITH a key).
#   anthropic-subscription,
#   opencode-go, opencode-zen the matching CLI surface. Derived from the rail's HARNESS, which
#                             `model_id.parse()` already owns: a Go ride is executed by the claude
#                             binary (agent-session.sh rides `opencode-go/*` through the jail
#                             shim / claude CLI — parser harness "claude"), and the parked Zen leg
#                             is the one the opencode CLI rides. So the Go rail is rideable by a
#                             `claude-cli` caller — which is why the reviewer's surface can serve
#                             a Go model when the Anthropic window is latched.
RAIL_DEFAULTS = {
    model_id.RAIL_SUBSCRIPTION: {
        "gate": "sub", "surfaces": ["claude-cli"], "cost": "flat-window",
        "windows": ["5h", "7d"], "tier_thresholds": {"dispatch": 0.9, "heavy": 0.8},
        "concurrency": None, "enabled": True},
    model_id.RAIL_OPENCODE_GO: {
        "gate": "go", "surfaces": ["claude-cli"], "cost": "flat-pool",
        "windows": ["5h", "7d", "30d"], "tier_thresholds": {"dispatch": 0.9, "heavy": 0.8},
        "concurrency": 3, "enabled": True},
    model_id.RAIL_OPENROUTER: {
        "gate": "or", "surfaces": ["claude-cli", "opencode-cli", "openai-api"],
        "cost": "per-token", "windows": [], "tier_thresholds": {}, "concurrency": None,
        "enabled": True},
    RAIL_OPENCODE_ZEN: {
        "gate": "none", "surfaces": ["opencode-cli"], "cost": "per-token", "windows": [],
        "tier_thresholds": {}, "concurrency": None, "enabled": False},
}
# The env kill switch's leg names (FU-213): OPENCODE_RAIL_DISABLED parks the opencode legs by
# their LEG name, the rail vocabulary names them by rail. ONE map, so the walk and the proxy's
# forward-path belt (`_rail_disabled`) cannot disagree about which rail an env value parks.
RAIL_ENV_LEG = {model_id.RAIL_OPENCODE_GO: "go", RAIL_OPENCODE_ZEN: "zen"}

# ── STRIKE VOCABULARY — THE ONE HOME (Goal #1640 acceptance 1) ────────────────────────────────
# These error classes are INFRA failures (model-routing-history.md §M1): they blacklist the (task, model)
# pair without consuming a round. This set IS the vocabulary — `/report` stores a strike under a
# member of it, the finalizer (agent-runtime `agent-finalize`) reports a member of it, and the
# scan's fleet-strike reader keys on a member of it. Neither keeps a second copy: the router
# serves this list on GET /router-status (`strike_classes`/`serving_classes`, status_summary) so
# both cite it instead of re-listing it. Extend the vocabulary HERE, nowhere else.
#
# `turn-cap` (homelab#1665): a goose ride that died at the turn cap. `tool-loop`: a cap death
# with zero tool-result progress — the same tool call repeated to the cap — which is a SERVING
# shape (below), not a model verdict. Both replace the `unknown` a cap death used to be rewritten
# to, which is why `router_strikes_total{error_class="tool-loop"}` was empty on 2026-09-13 while
# five rides looped. `unknown` stays: it is still the unclassified-death class the FU-200 reader
# latches on (the goal's interim condition).
STRIKE_CLASSES = {"harness-death", "auth-storm", "timeout", "provider-5xx", "no-pr",
                  "unknown", "turn-cap", "tool-loop"}

# FU-201 c: serving-shaped strike classes — provider-side failures that exclude the (model,
# provider) PAIR rather than the model entirely. A model-level blacklist needs ≥2-provider
# evidence (the #783 rule). These classes are the ADR-115 evidence set: provider 4xx/5xx
# responses and tool-call malformation that the serving provider caused. NOT a second
# vocabulary: this is a SUBSET VIEW of STRIKE_CLASSES (self-test pins `SERVING_CLASSES <=
# STRIKE_CLASSES`), so the two can never drift into disagreeing about what a strike is.
SERVING_CLASSES = {"provider-5xx", "timeout", "auth-storm", "tool-loop"}

# ── #1259: tier ordering for label_map tier_floor enforcement ──
# Ordered from cheapest to most expensive. Used to compare a model's `models.<key>.tier` grade
# against the tier_floor from a resolved label_map entry. A model whose tier is below the floor is
# excluded from the candidate walk.
_TIER_ORDER = {"free": 0, "cheap": 1, "large": 2, "premium": 3}

# ── STRIKE ENFORCEMENT IS UNCONDITIONAL (Goal #1640 acceptance 3) ─────────────────────────────
# The 2026-08-23 ruling (model-routing-history.md §M1a) RETIRED the strike-enforcement env knob as a
# blacklist knob: the 16-day store read showed six strikes, five one harness class, and
# enforcement would have changed ~1 decision for cents. The knob was left as dead code for the
# G-A sweep, and the 2026-09-13 checkpoint on #1231 read it `False` in production on every
# routerMode — the branch never ran. It is DELETED here: `route()` now enforces the task's struck
# cells unconditionally (the (model, provider) PAIR for serving-shaped classes, the MODEL once
# struck at two providers) and prices each candidate by the provider it lands on AFTER the
# exclusion. The residual provider 4xx/5xx class still rides `model_cooldowns` (the transport
# belt).
# Retention (days): the FU-057 ledger (pushgateway + transcripts) is the long-horizon store;
# this DB answers "recent enough to route on".
RETAIN_EVENTS_D = 30   # provider_events, decisions
RETAIN_REPORTS_D = 90  # run_reports, strikes

_SCHEMA = """
CREATE TABLE IF NOT EXISTS strikes(
  ts REAL, task TEXT, stack TEXT, model TEXT, error_class TEXT, round INTEGER, session TEXT,
  provider TEXT, error_subclass TEXT);
CREATE INDEX IF NOT EXISTS ix_strikes ON strikes(stack, task, model);
CREATE TABLE IF NOT EXISTS provider_events(
  ts REAL, model TEXT, provider TEXT, status INTEGER, class TEXT, session TEXT);
CREATE TABLE IF NOT EXISTS rotation(
  class TEXT, model TEXT, source TEXT, rank INTEGER, canary_verdict TEXT, updated_ts REAL,
  PRIMARY KEY(model, source));
CREATE TABLE IF NOT EXISTS budget_anchors(
  rail TEXT, window_start_ts REAL, anchor_usage_usd REAL, budget_usd REAL, updated_ts REAL,
  PRIMARY KEY(rail, window_start_ts));
CREATE TABLE IF NOT EXISTS run_reports(
  ts REAL, session TEXT PRIMARY KEY, task TEXT, stack TEXT, role TEXT, round INTEGER,
  model TEXT, served_model TEXT, served_provider TEXT, cache_hit REAL, cost_usd REAL,
  error_class TEXT, outcome TEXT, rail TEXT);
CREATE TABLE IF NOT EXISTS generations(
  id TEXT PRIMARY KEY, ts REAL, requested_model TEXT, served_model TEXT, provider TEXT,
  tokens_prompt INTEGER, tokens_completion INTEGER, tokens_cached INTEGER,
  cost_usd REAL, latency_ms INTEGER, finish TEXT, generation_ms INTEGER);
CREATE TABLE IF NOT EXISTS decisions(
  ts REAL, session TEXT, stack TEXT, role TEXT, class TEXT, decision TEXT, rail TEXT,
  model TEXT, reason TEXT, detail TEXT, surface TEXT, key_ref TEXT);
CREATE TABLE IF NOT EXISTS latch_state(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS circuit_events(
  ts REAL, session TEXT, model TEXT, class TEXT, n_4xx INTEGER);
CREATE TABLE IF NOT EXISTS openrouter_keys(
  ref TEXT PRIMARY KEY, first_seen REAL, last_seen REAL);
CREATE TABLE IF NOT EXISTS model_cooldowns(
  model TEXT, role TEXT DEFAULT 'worker', until REAL, streak INTEGER, reason TEXT, set_ts REAL,
  PRIMARY KEY(model, role));
CREATE TABLE IF NOT EXISTS capability(
  model TEXT, source TEXT, intelligence REAL, coding REAL, agentic REAL, updated_ts REAL,
  PRIMARY KEY(model, source));
CREATE TABLE IF NOT EXISTS task_market(
  tag TEXT, model TEXT, rank INTEGER, usage_share REAL, token_share REAL, updated_ts REAL,
  PRIMARY KEY(tag, model));
CREATE TABLE IF NOT EXISTS go_usage(
  ts REAL, stack TEXT, model TEXT, usd REAL, usd_draw REAL,
  tokens_in INTEGER, tokens_out INTEGER,
  cache_read INTEGER DEFAULT 0, cache_creation INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS ix_go_usage_ts ON go_usage(ts);
CREATE TABLE IF NOT EXISTS cell_start_tier(
  class TEXT, urgency TEXT, start_tier INTEGER, clean INTEGER, degraded INTEGER,
  updated_ts REAL, PRIMARY KEY(class, urgency));
CREATE TABLE IF NOT EXISTS shadow_decisions(
  ts REAL, session TEXT, stack TEXT, class TEXT, urgency TEXT, urgency_source TEXT,
  served_rail TEXT, served_model TEXT, shadow_rail TEXT, shadow_model TEXT,
  ladder_tier TEXT, start_tier TEXT, learned_tier TEXT, reprobe INTEGER,
  sub_gate TEXT, agrees INTEGER);
CREATE INDEX IF NOT EXISTS ix_shadow_session ON shadow_decisions(session);
CREATE INDEX IF NOT EXISTS ix_pe_model_ts ON provider_events(model, ts);
"""

# ── M11 (homelab#159): the cross-rail cost ladder, in SHADOW ────────────────────────────────────
# The rungs are ordered by TRUE MARGINAL cost, which is not the same axis as the effective $/M the
# in-rail ordering uses: a :free model costs nothing, the claude subscription is already bought (so
# a slot with headroom is also ~$0 at the margin — bounded by the FU-088 gates, which are the
# safety net's, not the ladder's, to spend), and paid OpenRouter is the reliable spender of last
# resort. See docs/spikes/model-routing-history.md §M11.
LADDER = ("free", "subscription", "paid")
URGENCIES = ("tight", "elastic")

_lock = threading.Lock()
_conn: sqlite3.Connection | None = None
_persistent = False
_last_sweep = 0.0
_classes: dict = {}


def _log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S', time.gmtime())} router: {msg}", flush=True)


def init(db_path: str | None, classes_path: str | None = None) -> bool:
    """Open (or degrade) the store, load class config. Returns persistent?"""
    global _conn, _persistent, _classes
    with _lock:
        for attempt, path in ((db_path, True), (":memory:", False)):
            if not attempt:
                continue
            try:
                conn = sqlite3.connect(attempt, check_same_thread=False)
                conn.executescript(_SCHEMA)
                # homelab#22: generation_ms landed after the PVC store existed — migrate in
                # place. It sits LAST in the CREATE TABLE above so column order matches the
                # ALTER'd layout and positional INSERTs stay valid on both.
                try:
                    conn.execute("ALTER TABLE generations ADD COLUMN generation_ms INTEGER")
                except sqlite3.OperationalError:
                    pass  # duplicate column — schema already current
                # homelab#164: same story for run_reports.rail — the launcher has been sending
                # `rail` in every /report body since homelab#158 and record_report dropped it for
                # want of a column, so a degraded ride's cost was answerable only from ephemeral
                # pod labels. Same LAST-column discipline as above.
                try:
                    conn.execute("ALTER TABLE run_reports ADD COLUMN rail TEXT")
                except sqlite3.OperationalError:
                    pass  # duplicate column — schema already current
                # 2026-08-17: go_usage grew the WINDOW-DRAW price + token columns. Same
                # LAST-column discipline: CREATE TABLE above carries them, an existing PVC
                # store takes them by ALTER, and the positional INSERT in go_usage_add stays
                # valid on both. Old rows land with NULL usd_draw → their draw falls back to
                # the stored billed usd (acknowledged under-count, self-corrects as windows
                # roll — uploads/opencode-go.txt reconciliation).
                for _gocol in ("usd_draw REAL", "tokens_in INTEGER", "tokens_out INTEGER"):
                    try:
                        conn.execute(f"ALTER TABLE go_usage ADD COLUMN {_gocol}")
                    except sqlite3.OperationalError:
                        pass  # duplicate column — schema already current
                # homelab#540: go_usage grew the CACHE SPLIT columns (cache_read, cache_creation)
                # — the fleet's flash workload is cacheRead-DOMINATED and the ingest row was
                # losing the split, so the ledger priced every cache-read token at full input
                # price (2026-08-18 reconciliation: kimi-k3 priced $0.1978 vs console $0.1701).
                # Same LAST-column discipline; old rows default to 0 → recomputation only
                # improves NEW rows (historical rows lack the split).
                for _gocol in ("cache_read INTEGER DEFAULT 0", "cache_creation INTEGER DEFAULT 0"):
                    try:
                        conn.execute(f"ALTER TABLE go_usage ADD COLUMN {_gocol}")
                    except sqlite3.OperationalError:
                        pass  # duplicate column — schema already current
                # FU-201 c: strikes grew provider column — the served provider slug, sourced
                # proxy-side from provider_events in record_report(). Same LAST-column discipline.
                try:
                    conn.execute("ALTER TABLE strikes ADD COLUMN provider TEXT")
                except sqlite3.OperationalError:
                    pass  # duplicate column — schema already current
                # FU-201 c: provider_events grew session column — the proxy-side session key ref,
                # so record_report() can look up the served provider for a session-keyed request
                # (generations is not harvested for session keys — _generation_lookup skips
                # Bearer ref: auth). Same LAST-column discipline.
                try:
                    conn.execute("ALTER TABLE provider_events ADD COLUMN session TEXT")
                except sqlite3.OperationalError:
                    pass  # duplicate column — schema already current
                # Goal #1640 acceptance 1 (reader half, 2026-09-17): strikes grew
                # error_subclass — the FINE producer sub-type (`http-401-storm`,
                # `goose-32602-truncation`), kept as evidence now that `error_class` holds a
                # vocabulary MEMBER. Same LAST-column discipline — and the CREATE TABLE above
                # carries it since 2026-09-18: it shipped with the ALTER alone, which left a
                # fresh store's column order dependent on this migration running rather than on
                # the schema declaring it (found by a $0 shadow re-review of PR#1763, homelab#946
                # — the recorded review had read the discipline as already satisfied).
                try:
                    conn.execute("ALTER TABLE strikes ADD COLUMN error_subclass TEXT")
                except sqlite3.OperationalError:
                    pass  # duplicate column — schema already current
                # Goal #1769 acceptance 4 (router half, 2026-09-22): decisions grew the CALLER
                # facts the walk filtered on — `surface` (what the caller can execute) and
                # `key_ref` (its OpenRouter credential ref). A `caller:*` skip reason is only
                # actionable if the row says which surface/credential the decision was made on,
                # so the facts ride the decision row itself, queryable on /router-status. Same
                # LAST-column discipline: the CREATE TABLE above carries them and the positional
                # INSERT in route() stays valid on both layouts.
                for _dcol in ("surface TEXT", "key_ref TEXT"):
                    try:
                        conn.execute(f"ALTER TABLE decisions ADD COLUMN {_dcol}")
                    except sqlite3.OperationalError:
                        pass  # duplicate column — schema already current
                
                # homelab#1042: model_cooldowns grew role-scoped PRIMARY KEY(model, role). SQLite
                # cannot change a PK by ALTER, so this rebuilds — which means it MUST NOT re-run
                # after a successful migration (the INSERT ... SELECT would force role='worker'
                # back onto scoped rows, and collide with the PK when both roles exist). The
                # sibling migrations above are idempotent by construction; a rebuild is not, so
                # it is guarded on the actual old shape.
                try:
                    _cool_cols = [r[1] for r in conn.execute("PRAGMA table_info(model_cooldowns)")]
                    if _cool_cols and "role" not in _cool_cols:
                        conn.execute("DROP TABLE IF EXISTS model_cooldowns_new")  # stray from a failed run
                        conn.execute("CREATE TABLE model_cooldowns_new("
                                     "model TEXT, role TEXT DEFAULT 'worker', until REAL, streak INTEGER, "
                                     "reason TEXT, set_ts REAL, PRIMARY KEY(model, role))")
                        conn.execute(
                            "INSERT INTO model_cooldowns_new(model, role, until, streak, reason, set_ts) "
                            "SELECT model, 'worker', until, streak, reason, set_ts FROM model_cooldowns")
                        conn.execute("DROP TABLE model_cooldowns")
                        conn.execute("ALTER TABLE model_cooldowns_new RENAME TO model_cooldowns")
                except sqlite3.OperationalError:
                    pass  # schema already current
                if attempt != ":memory:":
                    conn.execute("PRAGMA journal_mode=WAL")
                conn.commit()
                _conn, _persistent = conn, path and attempt != ":memory:"
                break
            except sqlite3.Error as e:
                _log(f"open {attempt} failed: {e} — falling back")
        if _conn is None:  # even :memory: failed — run storeless (every write becomes a no-op)
            _persistent = False
    if classes_path:
        try:
            with open(classes_path) as f:
                _classes = json.load(f)
        except (OSError, ValueError) as e:
            _log(f"model-classes load failed ({classes_path}): {e} — defaults only")
            _classes = {}
        # The ONE-RELEASE rail alias (Goal #1769 acceptance 1): a file still spelling the old
        # rail name loads, logged once per class that needed it. Runs HERE, at the load, so
        # nothing downstream ever reads the old vocabulary.
        _alias_rails()
        # Goal #1769 acceptance 3: the Anthropic-only top-level `tier_thresholds` is retired into
        # the subscription rail's declared table. A stale file's copy is folded in ONCE here, so
        # nothing downstream reads the old location.
        _migrate_tier_thresholds()
        # Goal #1769 acceptance 3: the id→grade `model_tiers` table is retired into the canonical
        # `models` table. A stale file's copy is folded in ONCE here (one-release alias), so
        # nothing downstream reads the old location.
        _migrate_model_tiers()
        # Goal #1769 acceptance 2/5: no class may name a rail the `rails:` block does not declare
        # — a load-time assert, so a typo is a startup failure, never a silently empty pool.
        _assert_declared_rails()
    _log(f"store={'persistent' if _persistent else 'ephemeral'} "
         f"classes={'loaded' if _classes else 'defaults'}")
    return _persistent


def classes() -> dict:
    return _classes


def _alias_rails() -> int:
    """Rewrite every `classes.<cls>.rails` entry onto the canonical vocabulary, in place.
    Returns how many classes needed it (0 = the file is already canonical), so a stale file is
    VISIBLE in the router's own log rather than silently meaning nothing. This is the whole
    one-release alias — deleted next release, with RAIL_ALIASES."""
    n = 0
    for cls, cinfo in (_classes.get("classes") or {}).items():
        if not isinstance(cinfo, dict) or not isinstance(cinfo.get("rails"), list):
            continue
        given = [str(r) for r in cinfo["rails"]]
        fixed = [RAIL_ALIASES.get(r, r) for r in given]
        if fixed != given:
            cinfo["rails"] = fixed
            _log(f"model-classes: class {cls} rails {given} → {fixed} "
                 "(one-release rail alias; update the file to the canonical names)")
            n += 1
    return n


def _migrate_tier_thresholds() -> int:
    """Goal #1769 acceptance 3: fold a stale file's Anthropic-only top-level `tier_thresholds`
    into `rails.anthropic-subscription.tier_thresholds` ONCE at load, then drop the old key so
    nothing downstream reads it. Returns how many rails it filled (0 = the file is already
    migrated). The declared per-rail table is the home; this is the one-release alias."""
    old = _classes.get("tier_thresholds")
    if not isinstance(old, dict):
        return 0
    folded = {k: v for k, v in old.items() if not str(k).startswith("_")}
    rails = _classes.get("rails")
    seeded = False
    if not isinstance(rails, dict):
        # A file with the old top-level table and no `rails:` block at all (a partial revert of
        # just model-classes.json). Popping the old key here would silently revert to
        # RAIL_DEFAULTS. Seed the WHOLE canonical block — which is what rail_facts() already
        # gives a rails-less file — because seeding one entry would make _assert_declared_rails()
        # fail every class naming another rail.
        rails = {r: dict(f) for r, f in RAIL_DEFAULTS.items()}
        _classes["rails"] = rails
        seeded = True
    sub = rails.get(model_id.RAIL_SUBSCRIPTION)
    n = 0
    if isinstance(sub, dict) and (seeded or not sub.get("tier_thresholds")):
        sub["tier_thresholds"] = folded
        n = 1
        _log("model-classes: top-level tier_thresholds → rails.anthropic-subscription."
             "tier_thresholds (one-release migration"
             + ("; no `rails:` block — seeded from RAIL_DEFAULTS" if seeded else "")
             + "; update the file)")
    elif folded:
        _log(f"model-classes: top-level tier_thresholds {sorted(folded)} dropped — "
             f"rails.{model_id.RAIL_SUBSCRIPTION} already declares its own")
    _classes.pop("tier_thresholds", None)
    return n


def _migrate_model_tiers() -> int:
    """Goal #1769 acceptance 3: fold a stale file's id→grade `model_tiers` table into the
    canonical `models` table ONCE at load, then drop the old key so nothing downstream reads it.
    Returns how many ids it seeded (0 = the file is already migrated). The one-release alias: the
    seeded entries carry `ids` (the id under its parsed rail), `tier` (the old grade) and null for
    the three facts the old table never held — so a stale file still routes, and the two
    router-self-test asserts still hold over it (the ids are keyed by model_family() and railed by
    model_id.parse() by construction). Deleted next release, with the alias row."""
    old = _classes.get("model_tiers")
    if not isinstance(old, dict):
        return 0
    models = _classes.get("models")
    if not isinstance(models, dict):
        models = {}
        _classes["models"] = models
    n = 0
    for mid, tier in old.items():
        if str(mid).startswith("_"):
            continue
        key = model_family(str(mid))
        rail = model_id.parse(str(mid))["rail"]
        entry = models.setdefault(key, {"ids": {}, "tier": tier, "context_tokens": None,
                                        "tool_verified": None, "pool_usd": None})
        entry.setdefault("ids", {}).setdefault(rail, str(mid))
        if entry.get("tier") != tier:
            _log(f"model-classes: model_tiers {mid!r} grades {tier!r} but models.{key} is "
                 f"{entry.get('tier')!r} — the canonical key collapses the variant; the grade is "
                 f"resolved per-id by _model_tier() (`:free` floors to 'free')")
        n += 1
    _classes.pop("model_tiers", None)
    _log(f"model-classes: model_tiers → models (one-release migration; {n} ids; update the file)")
    return n


def _assert_declared_rails() -> None:
    """Goal #1769 acceptance 2/5: every `classes.<cls>.rails` entry must be a rail the `rails:`
    block DECLARES. A class naming an undeclared rail is an empty pool that silently serves
    nothing — the exact failure the canonical vocabulary exists to prevent — so it FAILS THE LOAD
    rather than deferring at request time. Runs after `_alias_rails()`, so the old spelling is
    canonical by now. A file with no `rails:` block (a jail run without the file) is not checked:
    the block is the authority, and absent means no constraint."""
    declared = {r for r in (_classes.get("rails") or {}) if not str(r).startswith("_")}
    if not declared:
        return
    for cls, cinfo in (_classes.get("classes") or {}).items():
        if not isinstance(cinfo, dict):
            continue
        for rail in (cinfo.get("rails") or []):
            if rail not in declared:
                raise ValueError(
                    f"model-classes: class {cls} names rail {rail!r}, which the `rails:` block "
                    f"does not declare (declared: {sorted(declared)})")


def rail_facts(rail: str) -> dict:
    """The DECLARED facts for `rail` from model-classes.json's `rails:` block (Goal #1769
    acceptance 2), falling back to RAIL_DEFAULTS for a jail run without the file. Never None for
    a canonical rail."""
    declared = (_classes.get("rails") or {}).get(rail)
    if isinstance(declared, dict):
        return declared
    return RAIL_DEFAULTS.get(rail, {})


def rail_enabled(rail: str) -> bool:
    """The git authority: `rails.<rail>.enabled`. A rail declared `enabled: false` (Zen today) is
    skipped `rail:disabled` and CANNOT be un-parked from env."""
    return bool(rail_facts(rail).get("enabled", True))


def rail_parked_leg(leg: str) -> bool:
    """True while `leg` ("go"/"zen") is parked by OPENCODE_RAIL_DISABLED (FU-213). THE ONE HOME
    for the env parse — openrouter-proxy.py:_rail_disabled delegates here, so the forward-path
    belt and the /route walk cannot disagree about which rail an env value parks."""
    v = os.environ.get("OPENCODE_RAIL_DISABLED", "").strip().lower()
    if v in ("", "0", "false", "no", "off"):
        return False
    if v in ("1", "true", "yes", "on", "all", "both"):
        return True
    return leg in v.replace(",", " ").split()


def rail_parked(rail: str) -> bool:
    """The env authority: a rail parked by OPENCODE_RAIL_DISABLED is skipped `rail:parked`. Only
    the opencode legs have a leg name; every other rail is never parked."""
    leg = RAIL_ENV_LEG.get(rail)
    return bool(leg) and rail_parked_leg(leg)


def rail_skip_reason(rail: str) -> str | None:
    """The rail-level skip reason for `rail`, or None when the rail is rideable. TWO authorities,
    TWO reasons (Goal #1769 acceptance 2): git `enabled: false` → `rail:disabled`; the
    OPENCODE_RAIL_DISABLED env park → `rail:parked`. Git wins — an `enabled: false` rail cannot be
    overridden from env (the precedence documented in model-classes.json's rails._comment)."""
    if not rail_enabled(rail):
        return "rail:disabled"
    if rail_parked(rail):
        return "rail:parked"
    return None


def rail_surfaces(rail: str) -> list[str]:
    """The caller surfaces `rail` serves (Goal #1769 acceptance 2 externalized acceptance 4's
    in-router RAIL_SURFACE into the `rails:` block). The caller-capability predicate reads THIS."""
    return [str(s) for s in (rail_facts(rail).get("surfaces") or [])]


def rail_concurrency(rail: str, default: int | None = None) -> int | None:
    """The rail's declared concurrency bound (Goal #1769 acceptance 2). The Go rail's bound was a
    bare `OPENCODE_MAX_RUNNING` env fact; it is DECLARED here now, with the env as the override
    (openrouter-proxy.py:_go_max_running)."""
    v = rail_facts(rail).get("concurrency")
    return default if v is None else int(v)


def tier_threshold(tier: str | None, default: float,
                   rail: str = model_id.RAIL_SUBSCRIPTION) -> float:
    """FU-109 + Goal #1769 acceptance 3: the per-consumer utilization threshold, read from the
    RAIL's declared `tier_thresholds` (the Anthropic-only top-level table is retired). Unknown/
    absent tier = the global default (bare /anthropic-limit keeps today's behavior exactly)."""
    try:
        return float((rail_facts(rail).get("tier_thresholds") or {})[tier])
    except (KeyError, TypeError, ValueError):
        return default


def _write(sql: str, params: tuple) -> bool:
    """One guarded write. Failure is logged, never raised — the data plane must not die on
    bookkeeping (rule: an absent DB never blocks dispatch)."""
    global _last_sweep
    if _conn is None:
        return False
    now = time.time()
    try:
        with _lock:
            _conn.execute(sql, params)
            if now - _last_sweep > 86400:
                _last_sweep = now
                _conn.execute("DELETE FROM provider_events WHERE ts < ?",
                              (now - RETAIN_EVENTS_D * 86400,))
                _conn.execute("DELETE FROM decisions WHERE ts < ?",
                              (now - RETAIN_EVENTS_D * 86400,))
                _conn.execute("DELETE FROM run_reports WHERE ts < ?",
                              (now - RETAIN_REPORTS_D * 86400,))
                _conn.execute("DELETE FROM strikes WHERE ts < ?",
                              (now - RETAIN_REPORTS_D * 86400,))
                _conn.execute("DELETE FROM generations WHERE ts < ?",
                              (now - RETAIN_REPORTS_D * 86400,))
                _conn.execute("DELETE FROM circuit_events WHERE ts < ?",
                              (now - RETAIN_EVENTS_D * 86400,))
                _conn.execute("DELETE FROM openrouter_keys WHERE last_seen < ?",
                              (now - RETAIN_EVENTS_D * 86400,))
                _conn.execute("DELETE FROM shadow_decisions WHERE ts < ?",
                              (now - RETAIN_EVENTS_D * 86400,))
            _conn.commit()
        return True
    except sqlite3.Error as e:
        _log(f"write failed: {e}")
        return False


def _read(sql: str, params: tuple = ()) -> list[tuple]:
    if _conn is None:
        return []
    try:
        with _lock:
            return _conn.execute(sql, params).fetchall()
    except sqlite3.Error as e:
        _log(f"read failed: {e}")
        return []


def record_report(d: dict, session_ref: str = "") -> tuple[bool, bool, str]:
    """One POST /report body → run_reports (+ a strikes row when it IS a strike: strike-class
    error and no PR came out — mirrors the launcher's AGENT_STRIKE condition; the GitHub comment
    stays the human/audit twin). Returns (stored, striked, provider). Idempotent per session (the launcher
    may retry): INSERT OR REPLACE on the session key.

    FU-201 c: `session_ref` is the proxy-side session key ref (from the /report request's
    Authorization header), used to look up the served provider from provider_events.session.
    The launcher sends the pod name as `d["session"]` — that is stored in strikes.session
    for dedup, while the provider is sourced proxy-side via the correlated key ref.
    provider_events is used instead of generations because _generation_lookup skips
    session-keyed requests (Bearer ref: auth), so generations has no rows for the common
    case. provider_events is recorded for every forwarded response regardless of auth type."""
    now = time.time()
    stored = _write(
        "INSERT OR REPLACE INTO run_reports VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (now, str(d.get("session") or ""), str(d.get("task") or ""), str(d.get("stack") or ""),
         str(d.get("role") or "worker"), int(d.get("round") or 1), str(d.get("model") or ""),
         str(d.get("served_model") or ""), str(d.get("served_provider") or ""),
         float(d.get("cache_hit") or 0.0), float(d.get("cost_usd") or 0.0),
         str(d.get("error_class") or ""), str(d.get("outcome") or ""),
         str(d.get("rail") or "")))
    err = str(d.get("error_class") or "")
    outcome = str(d.get("outcome") or "")
    # ⚠ MATCH EITHER FIELD. The launcher (agent-session.sh /report body) sends the COARSE class in
    # `outcome` (= stats.exit_status when no PR: "harness-death") and a FINER sub-type in
    # `error_class` ("goose-32602-truncation"). Testing only `error_class` meant the commonest
    # infra death never struck: router_strikes_total sat at 1 while three harness deaths landed on
    # 2026-08-06/07. Two of this set's own members (`harness-death`, `no-pr`) are `outcome`
    # vocabulary, so it was never coherent with the single field it was compared against.
    # model-routing-history.md §M1 settles that this is a bug, not a policy: its taxonomy table names
    # "harness-death (goose -32602)" as ONE thing.
    # FU-201 c: the served provider is sourced proxy-side from provider_events via the session
    # key ref (not the pod name — those two id-spaces never intersect). provider_events is
    # recorded for every forwarded response regardless of auth type (unlike generations, which
    # is skipped for session-keyed requests). The most recent provider_event for this session
    # gives us the provider that served the request. Absent a matching row, provider defaults
    # to empty string — the strike still records, just without provider attribution.
    session = str(d.get("session") or "")
    provider = str(d.get("served_provider") or "")
    if not provider and session_ref:
        _prov = _read("SELECT provider FROM provider_events WHERE session=? ORDER BY ts DESC LIMIT 1",
                       (session_ref,))
        provider = str(_prov[0][0]) if _prov else ""
    # Goal #1640 acceptance 1 (reader half, 2026-09-17): the strike row must carry a
    # vocabulary MEMBER, because that is the field every reader tests. Measured on the live
    # store that day: 31 strikes ever, 0 in SERVING_CLASSES, 24 outside STRIKE_CLASSES
    # entirely — while `run_reports` held the conformant half all along
    # (`outcome='auth-storm'` beside `error_class='http-401-storm'`). The decision to strike
    # already matches EITHER field (§M1a, below); only the WRITE dropped the coarse one, so
    # `pair_cooldowns` (error_class IN SERVING_CLASSES) could never match and
    # `/router-status → pair_cooldowns` sat empty by construction, not by luck.
    # Resolution order — member wins, coarse breaks the tie, `unknown` is the floor:
    _klass = err if err in STRIKE_CLASSES else (
        outcome if outcome in STRIKE_CLASSES else "unknown")
    # The fine sub-type is EVIDENCE, never a filter input: it is what tells a reader WHICH
    # auth storm or WHICH harness death this was (the §M1a taxonomy's leaf).
    _subclass = err if err and err != _klass else ""
    striked = False
    if stored and (err in STRIKE_CLASSES or outcome in STRIKE_CLASSES) \
            and not outcome.startswith("pr"):
        # Dedup per (task, model, session): a re-POST must not double-strike.
        _write("DELETE FROM strikes WHERE task=? AND model=? AND session=?",
               (str(d.get("task") or ""), str(d.get("model") or ""), session))
        striked = _write(
            "INSERT INTO strikes VALUES(?,?,?,?,?,?,?,?,?)",
            (now, str(d.get("task") or ""), str(d.get("stack") or ""), str(d.get("model") or ""),
             _klass, int(d.get("round") or 1), session, provider, _subclass))
    if stored:  # M11 leg 3 (shadow): the same feed, folded into the (class, urgency) start tier
        fold = fold_outcome_into_cell(d, striked)
        if fold:
            _log(f"ladder cell {fold['class']}/{fold['urgency']}: {fold['verdict']} at "
                 f"{fold['used_tier']} → start_tier={fold['start_tier']} (shadow)")
    return stored, striked, provider


def _ladder_cfg() -> dict:
    cfg = _classes.get("ladder") or {}
    return {"subscription_model": str(cfg.get("subscription_model") or "claude/haiku"),
            "promote_after": max(1, int(cfg.get("promote_after", 3))),
            "tight_floor_tier": min(len(LADDER) - 1, max(0, int(cfg.get("tight_floor_tier", 1))))}


def ladder_tier(model: str, rail: str, price: float | None) -> int:
    """Which RUNG a candidate sits on. Rail decides the subscription rung (it is the rail that is
    already paid for, whatever the model id); on the OpenRouter rail a $0 price is the free rung
    and everything else is the paid one.

    BOTH subscription rails land on rung 1: `anthropic-subscription` and `opencode-go` are each a
    flat-fee plan whose marginal cost per ride is ~0 (the Go rail's window DRAW is a budget
    meter, not a per-request price — gometer). The rung is named `subscription` in LADDER; the
    RAIL names are the canonical ones (Goal #1769 acceptance 1)."""
    if rail in (model_id.RAIL_SUBSCRIPTION, model_id.RAIL_OPENCODE_GO):
        return 1
    if str(model).endswith(":free") or price == 0.0:
        return 0
    return 2


def resolve_urgency(payload: dict) -> tuple[str, str]:
    """(urgency, source). ADR-094 order: the CALLER's explicit value wins — it is the only input
    that can carry round-state facts a label cannot (this round is a ci-red retry; this child has
    an assembly waiting). Absent that, the git-owned `urgency_map` in model-classes.json is a
    deterministic lookup over the labels/role the dispatch already carries — the same seam and the
    same table the launcher will read when the caller side lands, so the two cannot disagree.
    Nothing here infers anything from the prompt. Missing everywhere ⇒ `tight`, the conservative
    default (a tight cell never gambles a deadline on the free rung)."""
    explicit = str(payload.get("urgency") or "").strip().lower()
    if explicit in URGENCIES:
        return explicit, "caller"
    umap = _classes.get("urgency_map") or {}
    labmap = umap.get("labels") or {}
    hits = [str(labmap[l]).lower() for l in (str(x) for x in (payload.get("labels") or []))
            if l in labmap and str(labmap[l]).lower() in URGENCIES]
    if hits:  # tight wins a tie — the conservative direction
        return ("tight" if "tight" in hits else "elastic"), "label_map"
    role_u = str((umap.get("roles") or {}).get(str(payload.get("role") or "")) or "").lower()
    if role_u in URGENCIES:
        return role_u, "role"
    default = str(umap.get("default") or "tight").lower()
    return (default if default in URGENCIES else "tight"), "default"


def cell_state(cls: str, urgency: str) -> dict:
    """The learned (class, urgency) cell: which rung this cell STARTS on, plus the streaks behind
    it. Absent row = start at rung 0 (free) with no evidence — the optimistic prior M11 asks for,
    which urgency then floors for tight work."""
    rows = _read("SELECT start_tier, clean, degraded FROM cell_start_tier WHERE class=? AND "
                 "urgency=?", (cls, urgency))
    if not rows:
        return {"start_tier": 0, "clean": 0, "degraded": 0, "seen": False}
    return {"start_tier": int(rows[0][0] or 0), "clean": int(rows[0][1] or 0),
            "degraded": int(rows[0][2] or 0), "seen": True}


def _cell_for_session(session: str) -> tuple[str, str] | None:
    """(class, urgency) for a finished run — the join that turns the EXISTING outcomes feed into
    ladder evidence. The shadow row is authoritative (it is the one that recorded the urgency);
    a decision row without one still gives the class, and urgency falls back to the same
    conservative default /route would have used."""
    rows = _read("SELECT class, urgency FROM shadow_decisions WHERE session=? ORDER BY ts DESC "
                 "LIMIT 1", (session,))
    if rows:
        return str(rows[0][0] or ""), str(rows[0][1] or "tight")
    rows = _read("SELECT class FROM decisions WHERE session=? ORDER BY ts DESC LIMIT 1",
                 (session,))
    return (str(rows[0][0] or ""), "tight") if rows and rows[0][0] else None


def fold_outcome_into_cell(d: dict, striked: bool) -> dict | None:
    """M11 leg 3: one run report → the (class, urgency) start-tier table. Reads the SAME feed the
    strike bookkeeping already consumes (no new producer): a banked PR keeps or LOWERS the start
    rung, a strike RAISES it above the rung that just failed. A re-probe one rung down that banks
    clean is adopted immediately — that is the whole point of the re-probe, and waiting
    promote_after runs to believe it would make recovery take days.

    SHADOW: this table is written and logged, and nothing reads it in the served path."""
    session = str(d.get("session") or "")
    cell = _cell_for_session(session) if session else None
    if not cell:
        return None
    cls, urgency = cell
    model = str(d.get("model") or "")
    rail = model_id.parse(model)["rail"]
    used = ladder_tier(model, rail, 0.0 if model.endswith(":free") else None)
    st = cell_state(cls, urgency)
    start, clean, degraded = st["start_tier"], st["clean"], st["degraded"]
    outcome = str(d.get("outcome") or "")
    if striked:
        if used >= start:
            start = min(used + 1, len(LADDER) - 1)
        clean, degraded = 0, degraded + 1
        verdict = "degraded"
    elif outcome.startswith("pr"):
        clean, degraded = clean + 1, 0
        if used < start:
            start, clean = used, 0          # the re-probe proved this rung — adopt it now
        elif clean >= _ladder_cfg()["promote_after"] and start > 0:
            start, clean = start - 1, 0     # banked enough at the start rung to try one cheaper
        verdict = "clean"
    else:
        return None  # a round (changes-requested, ci-red) is neither: §M1, rounds are not strikes
    _write("INSERT OR REPLACE INTO cell_start_tier VALUES(?,?,?,?,?,?)",
           (cls, urgency, start, clean, degraded, time.time()))
    return {"class": cls, "urgency": urgency, "used_tier": LADDER[used],
            "start_tier": LADDER[start], "verdict": verdict}


def record_generation(gen_id: str, requested_model: str, data: dict) -> bool:
    """One /api/v1/generation record → ground-truth cost/attribution (probed 2026-07-27:
    total_cost is the BILLED figure, provider_name/model are what actually SERVED — the M5
    'served model/provider' the ledger wanted — and native_tokens_cached measures the real
    cache hit the h=0.8 pin math assumes). Harvested passively by the data plane per forwarded
    completion; idempotent per generation id — OR IGNORE, so a lookup retry can never
    overwrite a stored record with a thinner one. `latency` is TTFT ONLY (measured 2026-08-02:
    laguna 1.6s TTFT vs ~306s wall) — generation_time is the full decode duration, the only
    field that yields true tokens/sec (homelab#22, the §M8 free-band tie-break input)."""
    return _write(
        "INSERT OR IGNORE INTO generations VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (gen_id, time.time(), requested_model, str(data.get("model") or ""),
         str(data.get("provider_name") or ""), int(data.get("native_tokens_prompt") or 0),
         int(data.get("native_tokens_completion") or 0),
         int(data.get("native_tokens_cached") or 0), float(data.get("total_cost") or 0.0),
         int(data.get("latency") or 0), str(data.get("finish_reason") or ""),
         int(data.get("generation_time") or 0)))


def record_provider_event(model: str, provider: str, status: int,
                          session: str = "") -> None:
    """Passive data-plane observation: one row per forwarded OpenRouter chat/completions
    response. `class` buckets the status for cheap aggregation.
    FU-186 step 1: strip the routing suffix so cooldown/breaker bookkeeping is keyed under the
    bare model id — the same id the /route eligibility loop filters candidates against. The strip
    rule has ONE home, `model_id.strip_routing_suffix` (homelab#1697): it drops only the suffix
    this platform's own router appends, so a `:free` chain id stays whole.

    FU-201 c: `session` is the proxy-side session key ref (from _cb_session()), stored so
    record_report() can look up the served provider for session-keyed requests (generations
    is not harvested for session keys). Defaults to empty string for legacy callers."""
    model = model_id.strip_routing_suffix(model)
    klass = ("2xx" if 200 <= status < 300 else
             "429" if status == 429 else
             "4xx" if 400 <= status < 500 else
             "5xx" if status >= 500 else "other")
    _write("INSERT INTO provider_events VALUES(?,?,?,?,?,?)",
           (time.time(), model, provider or "", status, klass, session))


# ── ADR-107 flip-acceptance 1: the requested≠served model drift belt (homelab#515) ─────────────
# PR#407's class — every claude/haiku worker ride silently running the CLI default
# (opus-5[1m]) for 23 days — was visible in data already collected, and nothing joined the two
# sides. Chainless makes drift MORE likely (per-ride alias remapping: slot maps, failover
# ladders, --pick-rail), so the belt is a flip prerequisite. The router holds BOTH sides for the
# OpenRouter and Go rails: run_reports / the forwarded request's model id (requested) and the
# /generation harvest's served_model + provider (served). The claude-harness/subscription rail's
# served side is the OTLP claude_code_* metrics (an in-cluster collector), which the router does
# not see — that arm lives in github-exporter's prometheusrule.yaml (agent-model-drift group).
_MODEL_FAMILY_SUFFIX_RE = re.compile(r"-(\d{4}|\d{6,8})$")


def model_family(model: str) -> str:
    """The FAMILY of a model id, the level at which requested and served are compared. The raw
    ids legitimately differ across the two sides even when a ride is healthy — date/version
    stamps (deepseek/deepseek-v4-flash-0731, …-20260423), context brackets (claude-opus-5[1m]),
    rail prefixes (opencode-go/, anthropic/, claude/) and claude aliases (haiku →
    claude-haiku). Stripping to the family is what keeps a healthy ride from minting false
    drift; date/version stamps are stripped to their family even when the model does not match
    a vendor/model pattern (e.g. a bare opencode-go/deepseek-v4-flash-0731 after prefix strip),
    so a model's identity is preserved and no unknown id is silently folded."""
    raw = (model or "").strip()
    raw = raw.split(":")[0]                     # drop a :free / :tag suffix
    raw = re.sub(r"\[[^\]]*\]", "", raw)        # drop [1m] / [2m] context brackets
    for prefix in ("opencode-go/", "openrouter/", "opencode/", "claude/", "anthropic/", "openai/"):
        if raw.startswith(prefix):
            raw = raw[len(prefix):]
            break
    if raw in ("haiku", "sonnet", "opus"):      # the claude aliases → the family they serve as
        return f"claude-{raw}"
    cm = re.match(r"^(claude)-([a-z0-9]+)", raw)  # claude-opus-5[1m] → claude-opus
    if cm:
        return f"{cm.group(1)}-{cm.group(2)}"
    m = re.match(r"^([^/]+)/([a-z0-9][a-z0-9._-]*)", raw)  # vendor/model[-stamp] → vendor/model
    if m:
        return f"{m.group(1)}/{_MODEL_FAMILY_SUFFIX_RE.sub('', m.group(2))}"
    return _MODEL_FAMILY_SUFFIX_RE.sub("", raw)


# ── #516: vendor-family (rail-agnostic) for decorrelation ──
# Rail prefixes that are pure TRANSPORT (the vendor follows in `vendor/model`) vs. the ones that
# ARE the vendor. Stripping the latter deletes the segment this function then reads — #797 r4.
_RAIL_ONLY_PREFIXES = ("opencode-go/", "openrouter/", "opencode/")
_VENDOR_PREFIXES = (("claude/", "anthropic"), ("anthropic/", "anthropic"), ("openai/", "openai"))


def vendor_family(model: str) -> str:
    """The VENDOR of a model id, rail-agnostic — the level #516 decorrelation compares at.
    One home, beside model_family(): model_family() answers WHICH model (drift, claude-haiku !=
    claude-opus); this answers WHOSE model (decorrelation, claude/haiku == claude/opus ==
    anthropic/claude-sonnet-5 == anthropic). Both share _MODEL_FAMILY_SUFFIX_RE; neither copies
    the other's prefix list."""
    raw = (model or "").strip().split(":")[0]      # drop a :free / :tag suffix
    raw = re.sub(r"\[[^\]]*\]", "", raw)           # drop [1m] / [2m] context brackets
    for _p in _RAIL_ONLY_PREFIXES:                 # transport only — the vendor is what follows
        if raw.startswith(_p):
            raw = raw[len(_p):]
            break
    for _p, _v in _VENDOR_PREFIXES:                # these prefixes ARE the vendor
        if raw.startswith(_p):
            return _v
    raw = _MODEL_FAMILY_SUFFIX_RE.sub("", raw)
    if raw in ("haiku", "sonnet", "opus") or raw.startswith("claude-"):
        return "anthropic"                         # bare alias / bare claude-* id
    return raw.split("/")[0] if "/" in raw else raw.split("-")[0]


# ── Goal #1769 acceptance 3: the canonical `models` table, keyed by model_family() ─────────────
# `model_tiers` (an id → grade map) retired into `models` (a family → {ids, tier, context_tokens,
# tool_verified, pool_usd} map). The key is model_family()'s OWN output — no new naming scheme —
# so a `modelDeny` of the canonical key binds across every rail serving the model, and the M11
# cross-rail ladder can say "cheapest rail serving X". These three readers are the ONE place the
# table is consulted; every former `model_tiers` reader goes through them.
def _models_table() -> dict:
    return _classes.get("models") or {}


def _model_entry(model: str) -> dict | None:
    """The canonical `models` entry for a model id, keyed by model_family(). None when the id's
    family is not in the table (an unapproved model — the rotation universe's exclusion)."""
    return _models_table().get(model_family(model))


def _model_tier(model: str) -> str | None:
    """The model's tier, read from `models.<key>.tier` (the retired `model_tiers` grade).

    A `:free` id floors to `"free"`. The table is keyed by model_family(), which collapses the
    `:free` suffix onto the paid key, and `ids` is rail → ONE id — so a per-variant grade (master's
    `model_tiers` graded `poolside/laguna-s-2.1:free` `"free"` and `poolside/laguna-s-2.1`
    `"cheap"`) is not expressible in the table and must be resolved by the reader. `:free` is
    already an id-level fact one check up: `never_free` matches the literal suffix (:1925). This is
    the same rule, for `tier_floor`.
    """
    entry = _model_entry(model)
    if not entry:
        return None
    return "free" if str(model).endswith(":free") else entry.get("tier")


def _model_context_tokens(model: str) -> int | None:
    """The model's declared harness context window, read from `models.<key>.context_tokens` —
    the source the shell's CLAUDE_CODE_MAX_CONTEXT_TOKENS constant is deleted against (Goal #1769
    acceptance 3). None when the model declares none (not yet declared, never a guess)."""
    entry = _model_entry(model)
    return entry.get("context_tokens") if entry else None


def _denied(model: str, deny: set) -> bool:
    """True when `model` is denied by the caller's `deny` set. A deny entry matches EITHER the
    exact id (a bare rail id — no regression) OR the model's canonical family (a `models` key, so
    `deny: [claude-sonnet]` excludes `claude/sonnet` AND `anthropic/claude-sonnet-4.6` in the same
    route — Goal #1769 acceptance 3)."""
    return model in deny or model_family(model) in deny


def _assert_models_table(models: dict) -> None:
    """Goal #1769 acceptance 3: the two CI asserts that pin the canonical `models` table to the
    parser. For every entry and every `(rail, id)` under it:

        model_family(id) == key   AND   model_id.parse(id).rail == rail

    The expected values are COMPUTED from the parser, never read back from the table, so a
    mis-keyed row (a wrong family or a wrong rail) trips this instead of silently mis-routing.
    Raises AssertionError naming the offending entry; the self-test drives it over the live table
    AND over a deliberately mis-keyed copy (the negative row — the test must be able to fail)."""
    for key, entry in (models or {}).items():
        if str(key).startswith("_"):
            continue
        ids = entry.get("ids") or {}
        assert ids, f"models.{key} must declare `ids` per rail"
        for rail, mid in ids.items():
            fam = model_family(mid)
            assert fam == key, \
                f"models.{key}.ids.{rail} = {mid!r} parses to family {fam!r}, not {key!r}"
            got_rail = model_id.parse(mid)["rail"]
            assert got_rail == rail, \
                f"models.{key}.ids.{rail} = {mid!r} parses to rail {got_rail!r}, not {rail!r}"
        for fact in ("tier", "context_tokens", "tool_verified", "pool_usd"):
            assert fact in entry, f"models.{key} must declare `{fact}`"


def _repo_from_session(session: str) -> str | None:
    """Recover the repo name from a launcher pod-name session.

    agent-session.sh names worker pods `agent-<PROJECT>-<task>-r<round>` (PROJECT = the repo,
    which may itself contain dashes) or `agent-<PROJECT>-<HHMMSS>` for non-issue launches. The
    task slug is one of `issue-<n>` / `pr-<n>` (optionally followed by `-r<round>`) or a 6-digit
    timestamp. Returns None when the session is not a launcher pod name (router fixtures,
    coordinator/reviewer sessions, anything hand-written)."""
    if not session or not session.startswith("agent-"):
        return None
    rest = session[len("agent-"):]
    for marker in (re.compile(r"-issue-\d+"), re.compile(r"-pr-\d+"), re.compile(r"-\d{6}(?:-r\d+)?$")):
        m = marker.search(rest)
        if m and m.start() > 0:
            return rest[:m.start()]
    return None


def _stack_repos() -> dict[str, str]:
    """repo namespace → owning AgentStack, the reverse of stacks.json's `repos` lists.

    The Go rail's served ledger is keyed by the credential-injection NAMESPACE (`ref:<ns>/<secret>`
    → stack = `<ns>`, the repo name, ADR-087), while run_reports.stack is the AgentStack name the
    launcher resolved (agent-session.sh /report). The join in model_drift_rows() needs this reverse
    map. Two sources, merged (the first seen wins — stacks.json is authoritative where both know a
    repo):

      • `agents/stacks.json` when readable — the committed mirror of the AgentStack claims
        (CI/jail: the deployed proxy pod does NOT mount the repo, so this is absent there).
      • the router's OWN run_reports: `session` encodes the repo (`agent-<repo>-…`) and the
        `stack` column is the AgentStack name — the only source the deployed pod has, complete
        for any stack whose repos have ridden within retention.
    A repo in neither list keeps its identity (the circles repo==stack case, an unstacked
    namespace) — callers fall back to `stack = repo`."""
    m: dict[str, str] = {}
    stacks_path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "agents", "stacks.json")
    if os.path.exists(stacks_path):
        try:
            with open(stacks_path) as fh:
                stacks = json.load(fh).get("stacks") or []
            for st in stacks:
                name = str(st.get("name") or "")
                for r in st.get("repos") or []:
                    m.setdefault(str(r), name)
        except (OSError, ValueError) as e:
            _log(f"stacks.json read failed ({stacks_path}): {e}")
    for session, stack in _read("SELECT session, stack FROM run_reports"):
        repo = _repo_from_session(session)
        if repo and stack:
            m.setdefault(repo, stack)
    return m


def model_drift_rows(window_s: int = 7 * 86400) -> tuple[list, list]:
    """The requested≠served join over the router's OWN tables, per rail (homelab#515).

    Returns (drift, unverifiable) — drift rows are (rail, stack, role, requested, served,
    provider, n) where the SERVED family differs from the REQUESTED family; unverifiable rows
    are (rail, stack, role, requested, n) where a requested run has NO served-side evidence in
    the store. Absence is counted, never matched against nothing — a run whose served side is
    missing (a harvest miss, an OTLP failure, a harness death before export) must not read as
    agreement, the FU-108/FU-125 silent-success class.

    Rail handling is deliberate: the OpenRouter rail's served side is the /generation harvest
    (generations.requested_model → served_model + provider — the M5 'served model' the ledger
    wanted); the Go rail's served side is the self-metered go_usage rows (the proxy strips the
    opencode-go/ prefix and sends the bare id, so a Go ride's requested and served ids are the
    SAME string — the verifiable signal is presence of a ledger row, not a family match); the
    subscription/claude rail's served side is OTLP claude_code_* which the router cannot see,
    so it is excluded here (the github-exporter arm owns it).
    """
    now = time.time()
    since = now - window_s
    # homelab#575: the repo-namespace → AgentStack reverse map, resolved ONCE for the whole join
    # (go_usage rows are keyed by the credential-injection namespace, run_reports by the stack
    # name). Derived from stacks.json where readable (CI/jail) and from run_reports.session in
    # the deployed pod — see _stack_repos().
    stack_repos = _stack_repos()
    # OpenRouter served-side ground truth: requested → served per harvested generation.
    gen = _read(
        "SELECT requested_model, served_model, provider, COUNT(*) FROM generations "
        "WHERE ts > ? GROUP BY requested_model, served_model, provider", (since,))
    by_req_fam: dict[str, list] = {}
    for req, served, provider, n in gen:
        rf = model_family(req)
        if served:
            by_req_fam.setdefault(rf, []).append((model_family(served), served, provider, n))
    drift: list = []
    unver: list = []
    reports = _read(
        "SELECT model, rail, stack, role, COUNT(*) FROM run_reports "
        "WHERE ts > ? AND rail != '' AND outcome != 'failed' GROUP BY model, rail, stack, role", (since,))
    for model, rail, stack, role, n in reports:
        rf = model_family(model)
        if rail == "opencode-go":
            # The Go rail's served side is the self-metered go_usage ledger (bare model ids,
            # prefix stripped at the proxy). A requested family must appear among the stack's
            # served families; absent that, either the stack has NO ledger rows (unverifiable —
            # absence never reads as agreement) or it served a DIFFERENT family (drift, e.g. a
            # slot map redirected the requested flash to kimi-k3).
            #
            # homelab#575: go_usage.stack is the credential-injection NAMESPACE (the repo name),
            # while run_reports.stack is the AgentStack name — for any multi-repo stack whose
            # repos don't equal the stack name (platform, sleep, oracle), the plain `stack = ?`
            # join could never match, so 100% of those rides read as unverifiable. Resolve the
            # stack's repo namespaces (reverse of stacks.json's repos list, derived from
            # run_reports.session in the deployed pod where the file is not mounted) and look
            # there too. The literal stack name stays in the set so legacy/synthetic rows and
            # the circles repo==stack case keep working.
            repos = {r for r, s in stack_repos.items() if s == stack}
            terms = sorted({stack, *repos})
            served = _read(
                f"SELECT DISTINCT model FROM go_usage WHERE ts > ? AND stack IN ({','.join('?' * len(terms))})",
                (since, *terms))
            if not served:
                unver.append(("opencode-go", stack, role, model, n))
            elif not any(model_family(m) == rf for m, in served):
                # A request that rode the Go rail with a different family than requested.
                served_fams = sorted({model_family(m) for m, in served})
                for sf in served_fams:
                    drift.append(("opencode-go", stack, role, model, sf, "", n))
        elif rail == "openrouter":
            fam_rows = by_req_fam.get(rf)
            if not fam_rows:
                unver.append(("openrouter", stack, role, model, n))
            else:
                for sf, served, provider, cnt in sorted(fam_rows):
                    if sf != rf:
                        drift.append(("openrouter", stack, role, model, served, provider, cnt))
    return drift, unver


def record_rotation(source: str, entries: list) -> int:
    """POST /rotation ingest (scout canary verdicts + the curated rotation). Upsert per
    (model, source); returns rows written."""
    n = 0
    now = time.time()
    for e in entries if isinstance(entries, list) else []:
        if not isinstance(e, dict) or not e.get("model"):
            continue
        if _write("INSERT OR REPLACE INTO rotation VALUES(?,?,?,?,?,?)",
                  (str(e.get("class") or e.get("class_hint") or ""), str(e["model"]), source,
                   int(e.get("rank") or 0), str(e.get("canary_verdict") or ""), now)):
            n += 1
    return n


def record_capability(source: str, entries: list) -> int:
    """M8 capability feed (FU-095): AA composite indices per model, pulled weekly by the proxy
    daemon via MCP list-benchmarks (standard account key — probed 2026-08-03). Upsert per
    (model, source); ids arrive date-normalized from the caller."""
    n = 0
    now = time.time()
    for e in entries if isinstance(entries, list) else []:
        if not isinstance(e, dict) or not e.get("model"):
            continue
        if _write("INSERT OR REPLACE INTO capability VALUES(?,?,?,?,?,?)",
                  (str(e["model"]), source, e.get("intelligence"), e.get("coding"),
                   e.get("agentic"), now)):
            n += 1
    return n


def record_task_market(rows: list) -> int:
    """M8 market prior (FU-095): 7-day traffic share per task tag with each tag's top models
    (MCP list-task-classifications). Candidate-ordering DATA for a later leg + the /router-status
    evidence surface; nothing in the decision path reads it yet."""
    n = 0
    now = time.time()
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not r.get("tag") or not r.get("model"):
            continue
        if _write("INSERT OR REPLACE INTO task_market VALUES(?,?,?,?,?,?)",
                  (str(r["tag"]), str(r["model"]), int(r.get("rank") or 0),
                   r.get("usage_share"), r.get("token_share"), now)):
            n += 1
    return n


def capability_floor_block(cls: str, model: str) -> str | None:
    """M8 class floors (FU-095/ADR-096): `class_floors` in model-classes.json is git POLICY
    (per class, axis → minimum AA index); the capability table is proxy-pulled DATA. PERMISSIVE
    by construction — no floors for the class, no row for the model, or a missing axis all
    pass: the floor acts only on present evidence, so a data gap can never brick a chain.
    Returns the failing 'axis=score<min' string, or None when eligible."""
    floors = (_classes.get("class_floors") or {}).get(cls) or {}
    if not floors:
        return None
    base = model.split(":")[0]  # laguna:free scores as its base model
    rows = _read("SELECT source, intelligence, coding, agentic FROM capability "
                 "WHERE model IN (?, ?)", (model, base))
    if not rows:
        return None
    rows.sort(key=lambda r: 0 if r[0] == "artificial-analysis" else 1)
    axes = {"intelligence": rows[0][1], "coding": rows[0][2], "agentic": rows[0][3]}
    for axis, minv in floors.items():
        if str(axis).startswith("_"):
            continue  # _comment keys are docs, not floors
        v = axes.get(str(axis))
        if v is not None and float(v) < float(minv):
            return f"{axis}={v}<{minv}"
    return None


def record_circuit_open(session: str, model: str, klass: str, n_4xx: int) -> bool:
    """ADR-096 addendum 3: the data plane tripped the in-flight 4XX breaker for (session, model)
    — the durable half of the signal (the in-memory half stops forwarding). The retuned FU-021
    watchdog (agent-runtime) reads this class of event as its kill trigger."""
    return _write("INSERT INTO circuit_events VALUES(?,?,?,?,?)",
                  (time.time(), session, model, klass, n_4xx))


def enroll_key_ref(ref: str) -> None:
    """ADR-096 P2: remember every OpenRouter session-key ref the data plane resolves, so the
    headroom daemon can poll GET /api/v1/auth/key per standing project key without any
    cluster-wide secret enumeration (the proxy only ever reads refs traffic already presented)."""
    now = time.time()
    _write("INSERT INTO openrouter_keys VALUES(?,?,?) "
           "ON CONFLICT(ref) DO UPDATE SET last_seen=excluded.last_seen", (ref, now, now))


def key_refs() -> list[str]:
    return [r[0] for r in _read("SELECT ref FROM openrouter_keys ORDER BY last_seen DESC")]


# ── OpenCode Go usage meter (homelab#422 / FU-088 Go-rail) ─────────────────────────────────────
# The Go rail has NO headroom headers and NO usage API — the proxy meters usage itself from
# response bodies. Subscription windows: 5h/$12, 7d/$30, 30d/$60 (usage-value at list prices).
# Stack attribution at request time: `ref:<ns>/<name>` → stack = `<ns>`, else "jail".


def go_usage_add(ts: float, stack: str, model: str, usd: float,
                 usd_draw: float | None = None,
                 tokens_in: int | None = None, tokens_out: int | None = None,
                 cache_read: int | None = None, cache_creation: int | None = None) -> bool:
    """One Go-rail completion → the usage ledger. In-memory degrade = no-op, never a crash.

    `usd` is the BILLED-STYLE estimate (gometer.price — list ×1 with cache discounts, NO badge
    halving, homelab#540); `usd_draw` is the WINDOW-DRAW price (gometer.window_draw — list price
    on raw tokens, badge-halved, the number the window utilization reads). Both are stored so
    they cannot be conflated; tokens are kept for audit/recompute. Rows written without
    `usd_draw` (legacy ingest/shim) store NULL and their draw falls back to `usd`
    (acknowledged under-count, self-corrects as windows roll).

    `cache_read` / `cache_creation` are the cache-split token counts (homelab#540). Absent →
    stored as 0 (old shims / spool rows without the fields); the window-draw recompute only
    improves NEW rows because HISTORICAL rows lack the split."""
    ok = _write("INSERT INTO go_usage VALUES(?,?,?,?,?,?,?,?,?)",
                (ts, stack, model, usd, usd_draw, tokens_in, tokens_out,
                 cache_read, cache_creation))
    # Prune rows older than 45d (30d window + 15d slack) — prevents unbounded growth.
    _write("DELETE FROM go_usage WHERE ts < ?", (ts - 45 * 86400,))
    return ok


def go_usage_chain_open(span_s: float, lookback_s: float = 7 * 86400,
                        now: float | None = None) -> float | None:
    """Recover the CURRENT open window's start epoch for a CHAIN-anchored window (homelab#540).

    The 5h window OPENS at the first request after the previous window expired and resets at
    open + span; idle > span ⇒ the next request opens a fresh window. Over go_usage.ts rows in
    the last `lookback_s` (ascending): open = the earliest ts that is >= the previous open +
    span. After the walk: if now < open + span there IS an open window [open, open+span) and we
    return `open`; otherwise there is NO open window (idle past expiry) and we return None —
    gometer.go_window_bounds then degrades to the grid default for the reset metric.

    `now` is injectable for deterministic tests (defaults to time.time()); the gometer
    chain_fn seam calls it positionally as chain_fn(span_s, lookback_s), so the extra kwarg is
    invisible to the callback contract.

    Returns None on an unreadable ledger (never raises) — the caller logs and degrades, never
    crashes and never silently reports zero usage."""
    if now is None:
        now = time.time()
    rows = _read("SELECT ts FROM go_usage WHERE ts > ? ORDER BY ts ASC",
                 (now - float(lookback_s),))
    open_epoch: float | None = None
    for (ts,) in rows:
        ts = float(ts)
        if open_epoch is None or ts >= open_epoch + float(span_s):
            open_epoch = ts
    if open_epoch is None:
        return None
    if now < open_epoch + float(span_s):
        return open_epoch
    return None


def go_usage_window(seconds: float, since: float | None = None) -> dict:
    """The window snapshot for the trailing/anchored `seconds` window ending now.

    Returns BOTH pricings, deliberately distinct (the 2026-08-17 pricing-defect fix):
      • total_draw_usd / by_stack_draw — the WINDOW DRAW: list price on raw tokens,
        badge-halved (gometer.window_draw). This is what utilization / /opencode-limit use.
      • total_usd / by_stack — the BILLED-STYLE estimate (gometer.price, cache discounts).
    Rows without a stored usd_draw (legacy 4-col writes) fall back to their stored `usd` as
    the draw.

    `seconds` is the nominal span. `since` (epoch, optional) is the ANCHOR floor: when given,
    the effective start is max(now - seconds, since) — an epoch-anchored window (e.g. the 7d
    window resetting Sunday 00:00 UTC, or the 30d window resetting the 13th ~11:30 UTC) counts
    spend since the LAST RESET, not from a pure trailing span. With `since` omitted this is
    exactly the old pure-rolling behaviour. Retention/go_usage_add are untouched: pre-reset
    rows stay in the ledger — they just fall outside the anchored window."""
    now = time.time()
    floor = max(now - seconds, since) if since is not None else (now - seconds)
    # homelab#540: `>=` (not `>`). The anchored-floor convention is "spend since the LAST RESET"
    # — inclusive of the reset/floor epoch — and a CHAIN-anchored window is [open, open+span),
    # where `open` IS the first request that opened the window and must be counted. Existing
    # boundary tests seed rows ±60 from boundaries (never exactly on them) so `>=` vs `>` is
    # invisible there; the chain open-row case is what `>=` fixes.
    rows = _read(
        "SELECT stack, usd, usd_draw FROM go_usage WHERE ts >= ?",
        (floor,))
    total = total_draw = 0.0
    by_stack: dict[str, float] = {}
    by_stack_draw: dict[str, float] = {}
    for stack, usd, usd_draw in rows:
        usd = usd or 0.0
        draw = usd_draw if usd_draw is not None else usd
        total += usd
        total_draw += draw
        if stack:
            by_stack[stack] = by_stack.get(stack, 0.0) + usd
            by_stack_draw[stack] = by_stack_draw.get(stack, 0.0) + draw
    return {"total_usd": total or 0.0, "total_draw_usd": total_draw or 0.0,
            "by_stack": by_stack, "by_stack_draw": by_stack_draw}


# ── homelab#180: reading the openrouter-operator's account-credit gauge ────────────────────────
# The proxy's `credit` capacity leg used to poll OpenRouter's GET /api/v1/credits directly and got
# a 403 on EVERY tick from 2026-08 onwards: that endpoint is scoped to the PROVISIONING key, and
# the proxy holds a project-scoped inference key (openrouterkey.yaml). Operator ruling 2026-08-08:
# the proxy does NOT get the provisioning key — copying a key-mint credential into agent-egress to
# read a balance is the wrong trade. One owner for account-scope facts = the openrouter-operator,
# which holds that key legitimately and exports `openrouter_account_credit_usd` on its own
# /metrics. The proxy reads THAT, in-cluster.
#
# The operator's gauge does NOT share this proxy's honest-absent contract, and the difference is
# the whole reason this parse lives here instead of inline in the proxy's poll:
#   • it is emitted from process start as NaN, before any successful upstream poll; and
#     `float('nan') < OR_MIN_CREDIT` is FALSE, so a naive port of the old comparison would latch
#     never and reproduce exactly the dead leg this function exists to kill.
#   • it HOLDS its last known value across upstream failures — "never 0 unless the account really
#     is empty" — so a present, plausible number can be arbitrarily stale, and a held stale
#     balance is a lie a capacity latch would act on.
# Both are refused HERE, and the function is pure (same reason route() is — so the CI self-test
# can drive it; `devbox run router-self-test`).
ACCOUNT_CREDIT_GAUGE = "openrouter_account_credit_usd"
ACCOUNT_CREDIT_TS_GAUGE = "openrouter_account_credit_updated_timestamp_seconds"


def _prom_sample(text: str, name: str) -> float | None:
    """One UNLABELLED gauge out of a Prometheus text exposition (both series above are
    unlabelled by the operator's contract; a labelled variant is deliberately not matched)."""
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or not line.startswith(name):
            continue
        head, _, rest = line.partition(" ")
        if head != name:
            continue
        try:
            return float(rest.split()[0])
        except (ValueError, IndexError):
            return None
    return None


def parse_account_credit(text: str, now: float,
                         max_age_s: float) -> tuple[float | None, float | None, str]:
    """(balance, operator_updated_at, why) from the operator's /metrics body. `balance` is None
    whenever the number must NOT be trusted, and `why` names which refusal fired so the caller's
    WARN line says something a human can act on."""
    value = _prom_sample(text, ACCOUNT_CREDIT_GAUGE)
    if value is None:
        return None, None, f"{ACCOUNT_CREDIT_GAUGE} absent from the exposition"
    if math.isnan(value):
        return None, None, "gauge is NaN — the operator has never completed an upstream poll"
    if math.isinf(value):
        return None, None, f"gauge is {value} — not a balance"
    updated_at = _prom_sample(text, ACCOUNT_CREDIT_TS_GAUGE)
    if not updated_at:  # absent, or the operator's 0 = "no poll has ever succeeded"
        return None, None, f"{ACCOUNT_CREDIT_TS_GAUGE} is absent/0 — no successful operator poll"
    age = now - updated_at
    if max_age_s and age > max_age_s:
        return None, updated_at, (f"balance is {age:.0f}s old (> {max_age_s:.0f}s) — the operator "
                                  "HOLDS its last value across failures, so this number is stale, "
                                  "not current")
    return round(value, 4), updated_at, f"operator polled {max(0.0, age):.0f}s ago"


def reliability(days: int = 7, min_n: int = 5) -> list[dict]:
    """Addendum 3: observed (model, provider) outcome shares over the window — TIER-AGNOSTIC
    (the ':free' string is never itself a demotion; laguna wore 401 free and 429 paid). Passive
    provider_events is the PRIMARY substrate (it caught the 142 401s /report missed). This is
    the /route ordering + health input in P3; /router-status shows it today."""
    rows = _read(
        "SELECT model, provider, COUNT(*), "
        "SUM(CASE WHEN class='2xx' THEN 1 ELSE 0 END), "
        "SUM(CASE WHEN status IN (401,403) THEN 1 ELSE 0 END), "
        "SUM(CASE WHEN class='429' THEN 1 ELSE 0 END) "
        "FROM provider_events WHERE ts > ? GROUP BY model, provider HAVING COUNT(*) >= ? "
        "ORDER BY 3 DESC", (time.time() - days * 86400, min_n))
    return [{"model": m, "provider": p, "n": n, "ok_rate": round((ok or 0) / n, 3),
             "auth_rate": round((auth or 0) / n, 3), "rate_429": round((r429 or 0) / n, 3)}
            for m, p, n, ok, auth, r429 in rows]


def derive_canary_verdicts(days: int = 7, min_n: int = 20) -> int:
    """Addendum 3: free models stay in-chain deliberately as cheap instability canaries — their
    verdict is FED FROM the passive aggregates, not hand-curated. Per :free model over the
    window: clean ≥95% ok, degraded ≥50%, broken below. Upserts rotation source
    'provider-events'; the scout's own probes stay a separate source."""
    rows = _read(
        "SELECT model, COUNT(*), SUM(CASE WHEN class='2xx' THEN 1 ELSE 0 END) "
        "FROM provider_events WHERE ts > ? AND model LIKE '%:free' "
        "GROUP BY model HAVING COUNT(*) >= ?", (time.time() - days * 86400, min_n))
    entries = []
    for model, n, ok in rows:
        rate = (ok or 0) / n
        entries.append({"model": model,
                        "canary_verdict": "clean" if rate >= 0.95 else
                                          "degraded" if rate >= 0.5 else "broken"})
    return record_rotation("provider-events", entries) if entries else 0


def strikes_for(task: str, stack: str) -> list[tuple[str, str, str]]:
    """(model, provider, error_class) tuples struck for THIS task (FU-201 c: strikes now carry
    the served provider). The /route filter uses this for pair-exclusion on serving-shaped
    strikes and model-level exclusion on infra-shaped ones. /router-status shows it today."""
    return [tuple(r) for r in _read(
        "SELECT DISTINCT model, provider, error_class FROM strikes WHERE task=? AND stack=?",
        (task, stack))]


# ── ADR-096 addendum 4: model cooldowns (the temporary-blacklist / recovery loop) ──────────────
# The end-state resilience the platform wants: a free model 429s under load → it leaves the
# routing pool for a bounded, ESCALATING hold — and when the hold expires it is simply eligible
# again (half-open: cheapest-effective ordering re-picks it, natural traffic is the probe; a 2xx
# clears the streak, a re-trip doubles the hold). Trip/clear both key on OUR passive
# provider_events, never on upstream uptime: measured 2026-08-02, laguna showed 99.9-100%
# uptime_last_5m upstream while our account saw 81% 429 / 53% 401 — OpenRouter's uptime is THEIR
# routing view, blind to per-account/tier limits. (True provider outages are already excluded at
# the PIN layer via uptime_last_30m >= UPTIME_FLOOR.)

def _cooldown_cfg() -> dict:
    cfg = _classes.get("cooldown") or {}
    return {"window_s": int(cfg.get("window_s", 600)),
            "min_events": int(cfg.get("min_events", 6)),
            "bad_share": float(cfg.get("bad_share", 0.5)),
            "base_s": int(cfg.get("base_s", 300)),
            "max_s": int(cfg.get("max_s", 3600))}


def cooldown_note(model: str, status: int, role: str = "worker") -> str | None:
    """Fold one passive provider event into the cooldown state. Returns 'tripped'/'cleared'
    for the data plane's log line, else None. Called AFTER record_provider_event.
    Cooldowns are scoped by (model, role) so probe-class sessions never latch the shared
    router state the fixer lanes read (homelab#1042)."""
    now = time.time()
    if 200 <= status < 300:
        # Verified working for OUR account — clear any hold and reset the escalation streak.
        if _read("SELECT 1 FROM model_cooldowns WHERE model=? AND role=?", (model, role)):
            _write("DELETE FROM model_cooldowns WHERE model=? AND role=?", (model, role))
            return "cleared"
        return None
    if status < 400:
        return None
    cfg = _cooldown_cfg()
    rows = _read(
        "SELECT COUNT(*), SUM(CASE WHEN class='2xx' THEN 0 ELSE 1 END), "
        "SUM(CASE WHEN class='429' THEN 1 ELSE 0 END), "
        "SUM(CASE WHEN status IN (401,403) THEN 1 ELSE 0 END), "
        "SUM(CASE WHEN class='5xx' THEN 1 ELSE 0 END) "
        "FROM provider_events WHERE model=? AND ts > ?", (model, now - cfg["window_s"]))
    if not rows:
        return None
    n, bad, n429, nauth, n5xx = (rows[0][0] or 0), (rows[0][1] or 0), (rows[0][2] or 0), \
        (rows[0][3] or 0), (rows[0][4] or 0)
    if n < cfg["min_events"] or bad / n < cfg["bad_share"]:
        return None
    cur = _read("SELECT until, streak FROM model_cooldowns WHERE model=? AND role=?", (model, role))
    if cur and cur[0][0] > now:
        return None  # already holding — don't extend on every event inside the window
    streak = (cur[0][1] if cur else 0) + 1
    hold = min(cfg["base_s"] * (2 ** (streak - 1)), cfg["max_s"])
    reason = ("429-burst" if n429 >= max(nauth, n5xx) else
              "auth-burst" if nauth >= n5xx else "5xx-burst")
    _write("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
           (model, role, now + hold, streak, reason, now))
    return "tripped"


def active_cooldowns(now: float | None = None, role: str | None = None) -> dict[str, dict]:
    """Return active cooldowns. When role is given, filter to that role's cooldowns only
    (homelab#1042 — probe-class sessions never latch the fixer lanes' router state)."""
    now = now or time.time()
    if role:
        rows = _read(
            "SELECT model, until, streak, reason FROM model_cooldowns WHERE role=? AND until > ?",
            (role, now))
    else:
        rows = _read(
            "SELECT model, until, streak, reason FROM model_cooldowns WHERE until > ?",
            (now,))
    return {m: {"until": u, "remaining_s": round(u - now), "streak": s, "reason": r}
            for m, u, s, r in rows}


# ── Goal #1640 acceptance 5 (router half): the (model, provider) PAIR cooldown ────────────────
# A SEPARATE, coarser mechanism from the transport belt above. `model_cooldowns` is HTTP-fed and
# keyed (model, role); ANY 2xx clears it. This one is keyed (model, provider), tripped by the
# STRIKE evidence (>= pair_min_tasks DISTINCT tasks striking the pair with a SERVING_CLASSES
# class inside pair_window_s), and cleared ONLY by a clean ride — never by a 2xx. The two must
# never be conflated: a 2xx from a provider that is serving a model badly behind HTTP 200 is
# exactly the 2026-09-13 failure this cooldown exists to route around.
#
# STATE IS THE EXISTING `strikes` TABLE — no new table (the Goal's design pin). The hold is a
# DERIVED view: for each pair, the distinct tasks that struck it with a serving class inside the
# window, minus any strike a later clean ride refuted. streak = distinct_tasks - min_tasks + 1,
# hold = base_s doubling per streak up to max_s, until = the pair's newest surviving strike + hold.
# Expiry is HALF-OPEN: the pair is eligible again (one ride is the probe) and a strike during
# half-open raises the distinct-task count, which doubles the hold — the acceptance's third leg.
def _pair_cooldown_cfg() -> dict:
    cfg = _classes.get("cooldown") or {}
    return {"window_s": int(cfg.get("pair_window_s", 86400)),
            "min_tasks": max(2, int(cfg.get("pair_min_tasks", 2))),
            "base_s": int(cfg.get("pair_base_s", 21600)),
            "max_s": int(cfg.get("pair_max_s", 604800))}


def pair_cooldowns(now: float | None = None) -> dict[tuple[str, str], dict]:
    """Active (model, provider) pair cooldowns, derived from the strikes table. Keyed by the
    (model, provider) tuple; each value carries until/remaining_s/streak/reason. A pair whose
    hold has expired is ABSENT (half-open — eligible again). A clean ride (a run_report with
    outcome 'pr' for the same model+served_provider) after the pair's newest strike refutes the
    whole set, so the pair is absent until it is struck afresh."""
    now = now or time.time()
    cfg = _pair_cooldown_cfg()
    since = now - cfg["window_s"]
    # The ONLY clear: a clean ride. Keyed on the same (model, served_provider) the strike uses.
    # Bounded to the window: a clean ride older than `since` is older than every strike the query
    # below can return, so it can refute none of them.
    clean = {(m, p): (ts or 0.0) for m, p, ts in _read(
        "SELECT model, served_provider, MAX(ts) FROM run_reports "
        "WHERE outcome='pr' AND served_provider != '' AND ts > ? "
        "GROUP BY model, served_provider", (since,))}
    _ph = ",".join("?" * len(SERVING_CLASSES))
    rows = _read(
        f"SELECT model, provider, task, MAX(ts) FROM strikes "
        f"WHERE ts > ? AND provider != '' AND error_class IN ({_ph}) "
        f"GROUP BY model, provider, task",
        (since, *sorted(SERVING_CLASSES)))
    agg: dict[tuple[str, str], dict[str, float]] = {}
    for m, p, task, ts in rows:
        if ts <= clean.get((m, p), 0.0):
            continue  # a clean ride after this strike refutes it
        agg.setdefault((m, p), {})[task] = ts
    out: dict[tuple[str, str], dict] = {}
    for (m, p), tasks in agg.items():
        if len(tasks) < cfg["min_tasks"]:
            continue  # one task is a task-local strike, not a provider verdict
        streak = len(tasks) - cfg["min_tasks"] + 1
        hold = min(cfg["base_s"] * (2 ** (streak - 1)), cfg["max_s"])
        until = max(tasks.values()) + hold
        if until <= now:
            continue  # expired → half-open: eligible again, one ride is the probe
        out[(m, p)] = {"model": m, "provider": p, "until": until,
                       "remaining_s": round(until - now), "streak": streak,
                       "reason": "pair-strike"}
    return out


def _rotation_candidates(cinfo: dict) -> list[str]:
    """P5: the class candidate list when the caller passes NO chain — rotation-fed. Universe =
    the canonical `models` table (the human-approved set; graduation stays human), ordered: class
    chain_head first, then daily-rankings rank order, then the git rotation_fallback belt. Models
    whose canary verdict says broken are excluded — on ALL THREE legs, chain_head included
    (homelab#1786). A rotation row is approved when its FAMILY is a `models` key (Goal #1769
    acceptance 3) — the table is keyed canonically, so a `:free`/`:exacto` variant of an approved
    model is approved too.

    The chain_head leg is NOT exempt. A head is a model like any other, and a broken canary is
    exactly the evidence the head ordering should yield to: a head is human-curated POLICY, but
    the canary verdict is the fleet's own serving evidence, and serving a known-broken head ahead
    of everything else is the router's thesis inverted (Goal #1640 acceptance 3). The exclusion
    removes a head from MEMBERSHIP only — the head ORDER is untouched: surviving heads still
    precede the ranked rotation. One rule for every chain_head class, never a per-class knob."""
    models = _models_table()
    rows = _read("SELECT model, source, canary_verdict, rank FROM rotation")
    broken = {m for m, _s, v, _r in rows if v == "broken"}
    ranked = sorted(((r or 0, m) for m, s, _v, r in rows
                     if s == "openrouter-daily-rankings" and model_family(m) in models
                     and m not in broken))
    kind = "reasoning" if cinfo.get("reasoning") else "coding"
    fallback = (_classes.get("rotation_fallback") or {}).get(kind) or []
    out: list[str] = []
    for m in ([m for m in (cinfo.get("chain_head") or []) if m not in broken]
              + [m for _r, m in ranked]
              + [m for m in fallback if m not in broken]):
        if m not in out:
            out.append(m)
    return out


def _as_bool(v, default: bool) -> bool:
    """A JSON field that may arrive as a bool, a number or a shell-ish string. Anything the caller
    did not spell one of the two ways falls back to `default` — a typo must not silently flip an
    experiment's reproducibility knob."""
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    s = str(v).strip().lower()
    if s in ("0", "false", "no", "off"):
        return False
    if s in ("1", "true", "yes", "on"):
        return True
    return default


def draw_slot(cls: str, cinfo: dict, slot) -> dict:
    """ADR-104 §M13: the deterministic draw — (class, slot, pool-version) → exactly one model.

    A pure lookup into the CURATED band (model-classes.json `pools`), never a computation over
    live state, and never a fallback: the ordinary filters (deny/strike/cooldown/floor/rail) then
    apply to the drawn model as they would to a one-entry chain, so a drawn-but-unusable slot
    DEFERS with its usual type instead of substituting the next model down. That is the whole
    point — a relaunched arm must draw what it drew before (idempotent relaunch), and a caller
    that needs another model asks for `slot=N+1` itself, in the open, where the arm table records
    it. Diversity is a curation property, so this function has no notion of it."""
    pools = _classes.get("pools") or {}
    band = str(cinfo.get("pool") or cls)
    entries = [str(m) for m in ((pools.get("bands") or {}).get(band) or [])]
    out = {"pool": band, "pool_version": str(pools.get("version") or ""), "slot": slot}
    try:
        n = int(slot)
    except (TypeError, ValueError):
        n = 0
    if not entries:
        out["draw_reason"] = f"no-pool-for-class:{cls}"
    elif n < 1 or n > len(entries):
        out["draw_reason"] = f"slot-outside-pool:{band}[1..{len(entries)}]"
    else:
        out["model"] = entries[n - 1]
    return out


def _shadow_ladder(payload: dict, cls: str, rails: list, eligible: list, deny: set, struck_models: set,
                   cool: dict, ctx: dict, sub_gate, or_gate, go_gate, jitter: float, pick,
                   excl: dict | None = None, caller_block=None) -> dict:
    """M11 legs 1+2+3, computed ALONGSIDE the served decision and never feeding it.

    The would-be pick if the ladder were authoritative: rungs ordered by true marginal cost
    (free → subscription headroom → paid), entered at the (class, urgency) cell's learned start
    rung, walking UP until a rung has an eligible candidate, cheapest-effective + the usual jitter
    band within the rung.

    ⚠ FU-088 IS THE BOUND, not a preference: the subscription rung is priced ~0 only while
    `subscription_ok` says the 429 latch is clear, both utilization windows are under their
    (tier-composed) thresholds AND the semaphore has a free slot. Otherwise it is priced
    UNPICKABLE — the safety net's slots are not the ladder's to spend, so the ladder can only ever
    consume headroom the reviewer/coordinator lane was already willing to give up."""
    urgency, usrc = resolve_urgency(payload)
    cfg = _ladder_cfg()
    st = cell_state(cls, urgency)
    learned = st["start_tier"]
    # Urgency is the PRIOR, the cell is the correction: elastic takes the learned rung as-is (which
    # begins at free and only climbs on our own evidence — "tier 1 first, always"), tight floors at
    # the subscription rung until the cell has PROVEN the free rung for this class ("skip tier 1
    # unless the cell is proven"). §M11.
    proven = learned == 0 and st["clean"] >= cfg["promote_after"]
    start = max(learned, cfg["tight_floor_tier"]) if (urgency == "tight" and not proven) else learned
    # `pick` comes from route() rather than ctx: with `jitter: false` it is the stable-tie-break
    # picker, and a shadow that jittered while the served decision did not would log a divergence
    # the ladder never had (ADR-104 — experiments do not jitter, on either side of the pane).
    pct = max(0, min(100, int(round(jitter * 100))))
    reprobe = bool(start > 0 and pick([False] * (100 - pct) + [True] * pct))
    if reprobe:
        start -= 1  # the exploration budget that lets a recovered free model be re-discovered

    def _rung(model: str, rail: str) -> dict:
        blocked = None
        price = basis = None
        if rail == model_id.RAIL_SUBSCRIPTION:
            ok, reason, _retry = sub_gate()
            if ok:
                price, basis = 0.0, "subscription"
            else:
                blocked = reason or "subscription-limited"
        elif rail == model_id.RAIL_OPENCODE_GO:
            # Goal #1769 acceptance 1: the Go rung is gated by ITS OWN rail's capacity, never by
            # the OpenRouter key's state — the same rule the served walk applies (go_gate).
            ok, reason, _retry = go_gate()
            if ok:
                price, basis = 0.0, "opencode-go"
            else:
                blocked = f"go:{reason or 'limited'}"
        else:
            ok, reason = or_gate()
            if ok:
                # Same post-exclusion cell price as the served walk (Goal #1640 acceptance 3):
                # the shadow must price a struck-pair model by the provider it lands on after
                # the exclusion, or it would log a divergence the ladder never had.
                price, basis, _prov = ctx["price"](model, (excl or {}).get(model, frozenset()))
            else:
                blocked = reason or "openrouter-unavailable"
        return {"model": model, "rail": rail, "_t": ladder_tier(model, rail, price),
                "price_per_mtok": price, "basis": basis, "blocked": blocked}

    cands = [_rung(m, rail) for m, rail in eligible]
    sub_model = cfg["subscription_model"]
    if (not any(c["rail"] == model_id.RAIL_SUBSCRIPTION for c in cands)
            and model_id.RAIL_SUBSCRIPTION in rails
            and (caller_block is None or caller_block(model_id.RAIL_SUBSCRIPTION) is None)
            and not _denied(sub_model, deny) and sub_model not in struck_models and sub_model not in cool
            and capability_floor_block(cls, sub_model) is None):
        # The rail enters the ordering as a CANDIDATE even when no chain names it — that is leg 1.
        # `subscription` here means the ANTHROPIC safety-net rail (the FU-088 gates' subject, and
        # what the shadow's own `subscription` block reports); a Go candidate is a real chain
        # entry, never a stand-in. Goal #1769 acceptance 4: the stand-in is a CANDIDATE on a rail
        # the CALLER must be able to ride, so a caller that cannot (surface mismatch) does not get
        # a shadow pick it could never serve either.
        cands.append({**_rung(sub_model, model_id.RAIL_SUBSCRIPTION), "synthetic": True})
    for c in cands:
        c["tier"] = LADDER[c["_t"]]
    choice, walk = None, "none"
    # Up from the start rung first; only if nothing at or above it is pickable do we look below
    # (a cell that has climbed past every candidate it actually has must still route somewhere).
    for t in list(range(start, len(LADDER))) + list(range(start - 1, -1, -1)):
        pool = [c for c in cands if c["_t"] == t and c["blocked"] is None]
        if not pool:
            continue
        priced = [c for c in pool if c["price_per_mtok"] is not None]
        if priced:
            floor = min(c["price_per_mtok"] for c in priced)
            band = [c for c in priced if c["price_per_mtok"] <= floor * (1 + jitter) + 1e-12]
        else:
            band = pool[:1]  # unpriced rung: keep caller order, exactly as the served path does
        choice = pick(band)
        walk = "at-or-above-start" if t >= start else "below-start"
        break
    sub = next((c for c in cands if c["rail"] == model_id.RAIL_SUBSCRIPTION), None)
    return {
        "urgency": urgency, "urgency_source": usrc,
        "learned_start_tier": LADDER[learned], "start_tier": LADDER[start], "reprobe": reprobe,
        "cell": {"class": cls, "clean": st["clean"], "degraded": st["degraded"],
                 "seen": st["seen"]},
        "subscription": {"model": (sub or {}).get("model"),
                         "eligible": bool(sub and sub["blocked"] is None),
                         "blocked": (sub or {}).get("blocked")},
        "walk": walk,
        "decision": "dispatch" if choice else "defer",
        "model": (choice or {}).get("model"), "rail": (choice or {}).get("rail"),
        "ladder_tier": (choice or {}).get("tier"),
        "price_per_mtok": (choice or {}).get("price_per_mtok"),
        "candidates": [{k: v for k, v in c.items() if k != "_t"} for c in cands],
    }


def record_shadow_decision(payload: dict, cls: str, served: dict, shadow: dict) -> bool:
    """The soak's evidence surface (M11 acceptance): one row per /route with the served pick and
    the would-be ladder pick side by side, keyed by cell. `agrees` is what the P4 flip reads —
    a shadow log that tracks the served behaviour is a ladder that changes nothing, and a shadow
    log that diverges is exactly the review the operator has to sign off."""
    return _write(
        "INSERT INTO shadow_decisions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (time.time(), str(payload.get("session") or ""), str(payload.get("stack") or ""), cls,
         shadow["urgency"], shadow["urgency_source"],
         str(served.get("rail") or ""), str(served.get("model") or ""),
         str(shadow.get("rail") or ""), str(shadow.get("model") or ""),
         str(shadow.get("ladder_tier") or ""), shadow["start_tier"],
         shadow["learned_start_tier"], 1 if shadow["reprobe"] else 0,
         str(shadow["subscription"].get("blocked") or ""),
         1 if served.get("model") == shadow.get("model") else 0))


def route(payload: dict, ctx: dict) -> dict:
    """The ADR-096 /route decision core — pure given ctx, so the self-test can drive it.

    payload: {stack, task, role, session, labels[], chain[], deny[], class?, tier?, key_ref?,
              surface?, urgency?, slot?, jitter?}
    ctx:     {price: fn(model, exclude_providers=frozenset())
                    ->(usd_per_mtok|None, basis|None, provider|None),
              subscription_ok: fn(tier)->(ok, reason|None, retry_after_s),
              openrouter_ok:  fn(key_ref)->(ok, reason|None),
              opencode_ok:    fn()->(ok, reason|None, retry_after_s)  — the GO rail's OWN
                    capacity (the proxy composes it from /opencode-limit: the observed 429/402
                    latch, the gometer window draw, OPENCODE_MAX_RUNNING and the FU-213 park).
                    Goal #1769 acceptance 1: a Go candidate is gated by THIS, never by the
                    OpenRouter key's state.
              pick: fn(list)->item  (optional; defaults to uniform random — the jitter band.
                    Unused under `jitter: false`, where the tie-break is caller/pool order)}
              `price`'s `exclude_providers` is the task's struck provider slugs (Goal #1640
              acceptance 3): the returned price/provider is the CELL the model lands on AFTER
              those are excluded, so a struck pair is never priced or pinned.

    Walk: resolve class (explicit > label_map > role_defaults) → candidates (a `slot` DRAW on the
    class's curated pool, else the chain, else rotation-fed) → filter deny/strikes/cooldowns/rail
    → per class-rail-order pick the effective-cheapest with a jitter-band uniform pick → capacity-
    gate the rail → dispatch, or a TYPED defer (capacity reasons and cooldowns carry retry_after;
    only chain-exhausted escalates — M1 doctrine).

    CALLER CAPABILITY (Goal #1769 acceptance 4): `surface` (what the caller can EXECUTE) and
    `key_ref` (its OpenRouter credential ref) are caller facts, and each rail's requirement
    (the rail's declared `surfaces`, plus openrouter's `key_ref`) is applied in the ELIGIBILITY
    loop — BEFORE any
    capacity gate — so a candidate whose rail the caller cannot ride is skipped with a typed
    `caller:no-key_ref` / `caller:surface` reason and never consumes a gate probe, and the shadow
    ladder (which reads the same `eligible` set) cannot pick it either. PERMISSIVE BY CONSTRUCTION:
    a body that sends NEITHER fact is filtered by nothing — byte-identical to the walk before this
    change. The filter engages only once a caller has ADOPTED the contract by sending at least one
    of the two; an un-adopted field must never strand a lane, but a caller that HAS declared its
    facts is taken at its word.

    Every RAIL value here is `model_id.parse()`'s (Goal #1769 acceptance 1): a candidate's rail is
    parsed, `classes.<cls>.rails` is written in the same canonical vocabulary, and the decision
    row echoes it. `opencode-go` therefore walks as its own rail — gated by `opencode_ok`, skipped
    with a `go:…` reason — instead of being flattened onto OpenRouter.

    ADR-104 (FU-162) adds the DRAW form on top of that walk rather than beside it: `slot` picks
    one model out of the class's pool (`draw_slot`) and hands it to the same filters as a
    one-entry chain, and `jitter: false` suppresses the exploration band everywhere in the call —
    served pick and shadow ladder both — so ties break stably. Same (class, slot, jitter:false,
    pool-version) ⇒ same model, which is what makes a research mission's roster reproducible and
    a dead arm's relaunch identical. The defer types are unchanged by the draw.

    The M11 cross-rail LADDER rides along in `decision["shadow"]` and changes nothing about the
    walk above: it is computed from the same filtered candidates and the same capacity gates, and
    it is written to the store + the proxy log for the soak review (homelab#159)."""
    now = time.time()
    role = str(payload.get("role") or "worker")
    labels = [str(x) for x in (payload.get("labels") or [])]
    # Goal #1769 acceptance 4: the CALLER's capability facts. `key_ref` rides the body already
    # (the launcher's OpenRouter credential ref, empty on a subscription-rail ride); `surface` is
    # the new one. Read once, here, so the eligibility filter, the OpenRouter gate and the
    # decision row all speak about the same two values.
    caller_surface = str(payload.get("surface") or "").strip()
    caller_key_ref = str(payload.get("key_ref") or "").strip()
    sel = _classes.get("selection") or {}
    # ADR-104: the jitter band is exploration budget for high-volume dispatch and corruption
    # inside a ~13-call experiment. `jitter: false` zeroes the band AND replaces the uniform pick
    # with a stable tie-break (caller/pool order), which is what "ties break stably" has to mean
    # for the draw to be idempotent across relaunches.
    jitter_on = _as_bool(payload.get("jitter"), True)
    jitter = float(sel.get("jitter_band_pct", 15)) / 100.0 if jitter_on else 0.0
    pick_fn = ctx.get("pick", random.choice) if jitter_on else (lambda xs: xs[0])
    cls = str(payload.get("class") or "")
    label_map = _classes.get("label_map") or {}
    # ── #1259: tier_floor/never_free merged across ALL matching labels ──
    # Merge tier constraints across every matching label_map entry rather than taking the
    # first match — a non-budget label (e.g. track/iac) may sort before agent-budget/lg in
    # the issue's label list, and its entry carries no tier keys. Taking the first match
    # would silently drop the budget label's constraints for exactly the multi-label
    # combination the docs call out as normal usage.
    # lg does NOT resolve a class — capability_floor_block reads the separate class_floors
    # table, and label_map is the escalation carrier, not a second floor source. ADR-094
    # holds: the label indirection is the contract; class_floors wins when both speak.
    tier_floor = ""
    never_free = False
    for lab in labels:
        entry = label_map.get(lab) or {}
        if entry:
            if entry.get("class") and not cls:
                cls = str(entry["class"])
            if entry.get("tier_floor") and not tier_floor:
                tier_floor = str(entry["tier_floor"])
            if entry.get("never_free"):
                never_free = True
    if not cls:
        cls = str((_classes.get("role_defaults") or {}).get(role) or "coding")
    cinfo = (_classes.get("classes") or {}).get(cls) or {}
    tier = str(payload.get("tier") or cinfo.get("tier") or "heavy")
    rails = list(cinfo.get("rails") or [model_id.RAIL_OPENROUTER, model_id.RAIL_SUBSCRIPTION])
    chain = [str(m) for m in (payload.get("chain") or [])]
    source = "chain"
    pre_skipped: list[dict] = []
    drawn: dict | None = None
    if payload.get("slot") is not None:
        drawn = draw_slot(cls, cinfo, payload.get("slot"))
        source = "pool"
        if chain:
            # A draw caller names ZERO models (§M13). One that passes both gets the draw, said
            # out loud — silently honouring the chain would put a hand-picked arm in a roster the
            # arm table claims was drawn, which is the exact circles slip ADR-104 answers.
            pre_skipped += [{"model": m, "reason": "chain-ignored:draw"} for m in chain]
        chain = [drawn["model"]] if drawn.get("model") else []
        if drawn.get("draw_reason"):
            pre_skipped.append({"model": "", "reason": drawn["draw_reason"]})
    elif not chain:
        chain = _rotation_candidates(cinfo)
        source = "rotation"
    deny = {str(m) for m in (payload.get("deny") or [])}
    # ── #516: family decorrelation as a /route primitive ──
    # The author's model id → VENDOR family (rail-agnostic), derived via vendor_family() which
    # handles rail-only prefixes, vendor-bearing prefixes, and bare claude aliases in one home.
    # A route with decorrelate_from from either rail excludes all models of that vendor across
    # every rail. An emptied candidate set defers typed rather than degrading to same-family.
    decorrelate_from = str(payload.get("decorrelate_from") or "").strip()
    decorrelate_family = None
    if decorrelate_from:
        decorrelate_family = vendor_family(decorrelate_from)
    # FU-201 c / Goal #1640 acceptance 3: strike rows carry provider + error_class. Serving-shaped
    # strikes (the SERVING_CLASSES subset of the one strike vocabulary) exclude the (model,
    # provider) PAIR — the model stays eligible for re-pick with a different provider, priced by
    # the provider it lands on AFTER the exclusion (the next cheapest CELL). Every other strike
    # class excludes the model entirely. A model with serving-shaped strikes from ≥2 providers is
    # excluded at model level (the #783 rule: model-level verdicts need multi-provider evidence).
    # ENFORCED UNCONDITIONALLY: the 2026-08-23 ruling retired the strike-enforcement knob (see the
    # note above), so the flag and its `if <flag> else []` filter are gone — the task's struck
    # cells are always excluded.
    _strike_rows = strikes_for(str(payload.get("task") or ""),
                               str(payload.get("stack") or ""))
    struck_models: set[str] = set()
    struck_pairs: dict[str, set[str]] = {}
    for _m, _p, _ec in _strike_rows:
        # Goal #1640 acceptance 1 (reader half): the provider test belongs in the CONDITION,
        # not inside the serving branch. Before the write-side normalization every serving
        # failure arrived as a non-member sub-type and fell to the model-level `else`, so the
        # fleet was conservatively over-excluding; with members now stored, a serving strike
        # that carries NO provider would otherwise match the pair branch, find nothing to add,
        # and exclude NOTHING — the fix would have un-excluded live cells. Pair-scope is an
        # upgrade earned by knowing the provider; absent it, model-scope stands.
        if _ec in SERVING_CLASSES and _p:
            struck_pairs.setdefault(_m, set()).add(_p)
        else:
            struck_models.add(_m)
    for _m, _providers in struck_pairs.items():
        if len(_providers) >= 2:
            struck_models.add(_m)
    cool = active_cooldowns(now, role=role)
    # Goal #1640 acceptance 5: the (model, provider) pair cooldowns, derived from the strikes
    # table. A cooled pair joins the exclusion set beside the task's struck pairs, so the model
    # is priced by the provider it lands on AFTER both exclusions — and a cooled pair is never
    # pinned (the proxy unions strike_excluded + cooldown_excluded for the pin).
    cooled = pair_cooldowns(now)
    skipped: list[dict] = list(pre_skipped)
    eligible: list[tuple[str, str]] = []

    # Goal #1769 acceptance 4 (router half): what the CALLER can ride, per rail. Decided HERE, in
    # the eligibility filter, so it precedes every capacity gate by construction — a rail the
    # caller cannot ride never reaches `sub_gate`/`or_gate`/`go_gate` and never costs a probe.
    # Returns the TYPED reason naming the missing fact, or None when the caller can ride the rail.
    def caller_block(rail: str) -> str | None:
        # Neither fact sent ⇒ the caller has not adopted the contract: filter nothing (the
        # permissive default this change deliberately preserves).
        if not (caller_surface or caller_key_ref):
            return None
        # Goal #1769 acceptance 2: the rail's `surfaces` come from the `rails:` block now, not an
        # in-router table. A rail that declares no surfaces (or a caller that sent none) filters
        # nothing on this axis.
        want = rail_surfaces(rail)
        if want and caller_surface and caller_surface not in want:
            return "caller:surface"
        # The OpenRouter rail is bought with the caller's OWN key: a declared fact set with no
        # `key_ref` means the caller cannot ride it (the reviewer, by design). This is the fact
        # the 2026-08-26 gate never asked about.
        if rail == model_id.RAIL_OPENROUTER and not caller_key_ref:
            return "caller:no-key_ref"
        return None
    # model → the providers struck for it (serving-shaped classes). The model stays eligible and
    # is priced by the provider it lands on AFTER these are excluded (the next cheapest CELL).
    _excl: dict[str, frozenset] = {}
    for m in chain:
        # Goal #1769 acceptance 1: the rail is PARSED, never re-derived here. One reader
        # (model_id), one rule, and a third rail value that the walk can act on.
        rail = model_id.parse(m)["rail"]
        # ── #1259: label_map tier_floor/never_free enforcement ──
        # Checked before the main eligibility chain so failing models are skipped early
        # without breaking the elif structure below.
        if never_free and m.endswith(":free"):
            skipped.append({"model": m, "reason": "never-free:label_map"})
            continue
        if tier_floor:
            m_tier = _model_tier(m)
            if m_tier and _TIER_ORDER.get(m_tier, -1) < _TIER_ORDER.get(tier_floor, -1):
                skipped.append({"model": m, "reason": f"tier-floor:{tier_floor}>{m_tier}"})
                continue
        if _denied(m, deny):
            skipped.append({"model": m, "reason": "claim-deny"})
        elif m in struck_models:
            skipped.append({"model": m, "reason": "strike"})
        elif m in cool:
            skipped.append({"model": m, "reason": f"cooldown:{cool[m]['reason']}",
                            "retry_after_s": cool[m]["remaining_s"]})
        elif (floor_fail := capability_floor_block(cls, m)) is not None:
            skipped.append({"model": m, "reason": f"capability-floor:{floor_fail}"})
        elif rail not in rails:
            skipped.append({"model": m, "reason": f"rail-{rail}-not-in-class-{cls}"})
        elif (rail_reason := rail_skip_reason(rail)) is not None:
            # Goal #1769 acceptance 2: TWO authorities, TWO reasons. `rail:disabled` is the git
            # declaration (`rails.<rail>.enabled: false` — Zen today); `rail:parked` is the
            # OPENCODE_RAIL_DISABLED env kill switch (FU-213). Git wins: an `enabled: false` rail
            # cannot be un-parked from env. Checked before caller capability (a rail fact precedes
            # a caller fact) and before capacity, which is never consulted.
            skipped.append({"model": m, "reason": rail_reason})
        elif (caller_reason := caller_block(rail)) is not None:
            # Typed, and a CALLER reason: the rail may be perfectly healthy — this request cannot
            # ride it. Checked after the class's rail list (a class that does not name the rail at
            # all is a class fact, not a caller fact) and before capacity, which is never consulted.
            skipped.append({"model": m, "reason": caller_reason})
        elif decorrelate_family and vendor_family(m) == decorrelate_family:
            skipped.append({"model": m, "reason": f"decorrelate:{decorrelate_family}"})
        else:
            # Serving-shaped strikes exclude the (model, provider) PAIR, not the model: it stays
            # eligible and is priced by the provider it lands on AFTER the exclusion. The struck
            # pair(s) are recorded so the decision row shows WHY the cell was skipped.
            _struck = struck_pairs.get(m, set())
            _cooled = {p for (cm, p) in cooled if cm == m}
            for _p in sorted(_struck):
                skipped.append({"model": m, "provider": _p, "reason": "strike"})
            # Goal #1640 acceptance 5: a cooled pair is excluded under its OWN reason, so a
            # decision row tells a strike exclusion from a cooldown exclusion (the issue's
            # "distinct reason" requirement). A pair that is BOTH struck and cooled is reported
            # once, as a strike — the strike is the sharper, task-local fact.
            for _p in sorted(_cooled - _struck):
                skipped.append({"model": m, "provider": _p, "reason": "cooldown-pair",
                                "retry_after_s": cooled[(m, _p)]["remaining_s"]})
            if _struck or _cooled:
                _excl[m] = frozenset(_struck | _cooled)
            eligible.append((m, rail))
    capacity_block: dict | None = None
    result: dict | None = None
    # Memoized so a route() costs AT MOST ONE read of each capacity gate — the shadow ladder
    # (below) needs the subscription verdict on every call, where the served walk needed it only
    # when a claude/* candidate survived filtering. Same state, same call, just not twice
    # (§M11: read the proxy's own /anthropic-limit state, add no probes).
    _gate_cache: dict = {}

    def sub_gate():
        if "sub" not in _gate_cache:
            _gate_cache["sub"] = ctx["subscription_ok"](tier)
        return _gate_cache["sub"]

    def or_gate():
        if "or" not in _gate_cache:
            _gate_cache["or"] = ctx["openrouter_ok"](caller_key_ref or None)
        return _gate_cache["or"]

    def go_gate():
        """Goal #1769 acceptance 1: the GO rail's own capacity, beside sub_gate/or_gate. Before
        this, an `opencode-go/*` candidate was flattened onto the OpenRouter rail by the walk's
        two-way split and gated by `or_gate` — so a Go model was skipped for the OpenRouter KEY's
        state (budget, a mint that never happened) and a Go outage could never be named as one.
        The verdict is the proxy's `/opencode-limit` composite: the observed 429/402 latch, the
        gometer window draw, OPENCODE_MAX_RUNNING and the FU-213 park. Memoized like the other
        two — one read per route()."""
        if "go" not in _gate_cache:
            _gate_cache["go"] = ctx["opencode_ok"]()
        return _gate_cache["go"]

    for rail in rails:
        pool = [m for m, r in eligible if r == rail]
        if not pool:
            continue
        if rail == model_id.RAIL_SUBSCRIPTION:
            ok, reason, retry = sub_gate()
            if not ok:
                reason = reason or "subscription-limited"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": retry}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            result = {"model": pool[0], "rail": rail, "price_per_mtok": None,
                      "basis": "subscription", "provider": None, "jitter_pool": pool[:1]}
        elif rail == model_id.RAIL_OPENCODE_GO:
            ok, reason, retry = go_gate()
            if not ok:
                # TYPED so a decision row says WHICH rail refused and why: `go:<the /opencode-limit
                # reason>`. A Go candidate is never skipped with an `openrouter:…` reason — that
                # flattening is the defect this acceptance ends.
                reason = f"go:{reason or 'limited'}"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": retry}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            result = {"model": pool[0], "rail": rail, "price_per_mtok": None,
                      "basis": "opencode-go", "provider": None, "jitter_pool": pool[:1]}
        else:
            ok, reason = or_gate()
            if not ok:
                reason = reason or "openrouter-budget-exhausted"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": 900}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            # Price each candidate by the provider it lands on AFTER the task's struck pairs are
            # excluded (Goal #1640 acceptance 3): the next cheapest CELL, not the model's default
            # provider. A model whose every provider is struck drops out of the pool entirely.
            priced = []
            for m in pool:
                _ex = _excl.get(m, frozenset())
                _p, _b, _prov = ctx["price"](m, _ex)
                if _prov is None and _ex:
                    continue  # every provider for this model is struck — the cell is empty
                priced.append((m, _p, _b, _prov))
            if not priced:
                continue
            known = [p for p in priced if p[1] is not None]
            if known:
                floor = min(p[1] for p in known)
                band = [p for p in known if p[1] <= floor * (1 + jitter) + 1e-12]
                pick = pick_fn(band)
            else:
                pick, band = priced[0], priced[:1]  # unpriced chain: keep caller order
            result = {"model": pick[0], "rail": rail, "price_per_mtok": pick[1],
                      "basis": pick[2], "provider": pick[3], "jitter_pool": [p[0] for p in band]}
        break
    # Goal #1640 acceptance 3: the providers excluded for the PICKED model, so the proxy can pin
    # the completion to the same post-exclusion provider the decision priced (never the struck
    # one). Captured before the :exacto suffix is appended (the exclusion keys the bare id).
    _picked_excl = sorted(_excl.get(result["model"], ())) if result else []
    # Split the picked model's exclusions by CAUSE so the proxy can pin against both and a
    # decision row still says which mechanism excluded which provider (Goal #1640 acceptance 5).
    _picked_struck = sorted(struck_pairs.get(result["model"], ())) if result else []
    _picked_cooled = sorted(set(_picked_excl) - set(_picked_struck))
    # FU-186 step 1: class-level provider_policy — append :exacto suffix when the resolved
    # class carries provider_policy: "exacto", so the completion path skips pin injection
    # (the :exacto suffix is already handled at openrouter-proxy.py L3232/L3302).
    # Only a PAID OpenRouter pick carries it (2026-09-13, the flip's self-test catch): a :free
    # model sidesteps M4 already (pin_for returns None — nothing to skip, and ":free:exacto" is
    # a stacked variant upstream never promised), and a subscription-rail pick is not an
    # OpenRouter model id at all (claude/haiku:exacto would reach the claude CLI verbatim;
    # opencode-go/* rides the Go subscription leg — its coarse `rail` reads "openrouter" here;
    # openrouter/<codename> is a cloaked/aggregate id OpenRouter serves itself — one upstream,
    # no provider ordering to delegate).
    # homelab#1693: IDEMPOTENT for an id that ALREADY carries the suffix. The platform claim's
    # `workerModel` is `deepseek/deepseek-v4.1-flash:exacto` (verified 2026-09-14), so a chain
    # entry arriving from the claim gets a SECOND `:exacto` — printed live on the PR#1685 ride's
    # launcher line (`deepseek/deepseek-v4.1-flash:exacto:exacto`). Inert while the claim is
    # `routerMode: shadow` (the doubled id is printed and discarded); Goal #1640 acceptance 6
    # flips the claim to `authoritative`, at which point the doubled id is what OpenRouter
    # receives and it serves no `:exacto:exacto` variant. The rail/`:free`/`opencode-go/`/
    # `openrouter/` exclusions are unchanged.
    if (result and cinfo.get("provider_policy") == "exacto"
            and result.get("rail") == "openrouter"
            and not result["model"].startswith(("opencode-go/", "openrouter/"))
            and not result["model"].endswith(":free")
            and not result["model"].endswith(":exacto")):
        result["model"] += ":exacto"
    if result:
        half_open = bool(_read(
            "SELECT 1 FROM model_cooldowns WHERE model=? AND role=? AND until <= ?",
            (result["model"], role, now)))
        decision = {"decision": "dispatch", "class": cls, "tier": tier, "source": source,
                    "half_open": half_open, "skipped": skipped, "jitter": jitter_on,
                    "strike_excluded": _picked_struck,
                    "cooldown_excluded": _picked_cooled,
                    # Goal #1769 acceptance 3: the served model's declared context window, echoed
                    # so the shell's CLAUDE_CODE_MAX_CONTEXT_TOKENS constant has a source to be
                    # deleted against. None when the model declares none.
                    "context_tokens": _model_context_tokens(result["model"]),
                    "provider_policy": cinfo.get("provider_policy"), **result}
    else:
        if decorrelate_family and not eligible and skipped and \
                all(s["reason"] == f"decorrelate:{decorrelate_family}" for s in skipped):
            reason = f"decorrelate:{decorrelate_family}"
            retry = None
        elif capacity_block:
            reason, retry = capacity_block["reason"], capacity_block.get("retry_after_s") or 900
        elif any(s["reason"].startswith("cooldown") for s in skipped):
            # Both cooldown mechanisms defer as `cooldown` with a retry_after: the transport
            # belt's `cooldown:<reason>` rows and the pair cooldown's `cooldown-pair` rows.
            reason = "cooldown"
            retry = min(s.get("retry_after_s") or 900
                        for s in skipped if s["reason"].startswith("cooldown"))
        else:
            reason = "chain-exhausted"  # deny/strike only — the one defer that escalates
            retry = None
        decision = {"decision": "defer", "reason": reason, "retry_after_s": retry,
                    "class": cls, "tier": tier, "source": source, "skipped": skipped,
                    "jitter": jitter_on}
    # Goal #1769 acceptance 4: the CALLER facts this row was decided ON, carried by BOTH verdicts
    # — a `caller:*` skip in `skipped` is only actionable if the row also says which surface and
    # credential the walk filtered against.
    decision["caller"] = {"surface": caller_surface, "key_ref": caller_key_ref}
    if drawn:
        # The draw's provenance rides BOTH verdicts: a deferred slot has to be recordable in the
        # arm table too ("slot 4 deferred, cooldown" is evidence; a blank is not).
        decision.update({k: v for k, v in drawn.items() if k in ("pool", "pool_version", "slot")})
    # FU-127: the structured carrier — consumers read `.decision.resolved` instead of re-parsing
    # the model string. Present on dispatch, absent on defer (no model to resolve). Goal #1769
    # acceptance 1: `resolved.rail` and `decision.rail` are now the SAME canonical vocabulary
    # (anthropic-subscription, opencode-go, openrouter) — the walk's rail IS the parser's, so
    # there is no second spelling left to translate between.
    if result:
        decision["resolved"] = model_id.parse(result["model"])
    # ── M11 SHADOW (homelab#159) — computed after the served decision, consumed by nobody ──
    shadow = _shadow_ladder(payload, cls, rails, eligible, deny, struck_models, cool, ctx,
                            sub_gate, or_gate, go_gate, jitter, pick_fn, _excl, caller_block)
    # FU-127: the shadow pick carries its own resolved object so the M11 shadow log line
    # describes the SHADOW pick, not the served pick (which may differ — that's the entire
    # point of the shadow line). Present on dispatch, absent on defer.
    if shadow.get("model"):
        shadow["resolved"] = model_id.parse(shadow["model"])
    record_shadow_decision(payload, cls, decision, shadow)
    decision["shadow"] = shadow
    _write("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
           (now, str(payload.get("session") or ""), str(payload.get("stack") or ""), role, cls,
            decision["decision"], decision.get("rail") or "",
            decision.get("model") or "", decision.get("reason") or "",
            json.dumps({"skipped": skipped, "source": source,
                        "jitter_pool": decision.get("jitter_pool"), "shadow": shadow}),
            caller_surface, caller_key_ref))
    return decision


def latch_save(latch: dict) -> None:
    """Persist the FU-088 latch + last windows so a proxy roll can't forget an active 429 hold
    (the in-memory-by-design note in openrouter-proxy.py predates this store)."""
    keep = {k: latch.get(k) for k in ("until", "last_429", "windows", "count_429", "headers_at")}
    _write("INSERT OR REPLACE INTO latch_state VALUES('latch', ?)", (json.dumps(keep),))


def latch_load() -> dict | None:
    rows = _read("SELECT v FROM latch_state WHERE k='latch'")
    if rows:
        try:
            return json.loads(rows[0][0])
        except ValueError:
            pass
    return None


def go_latch_save(latch: dict) -> None:
    """Persist the Go capacity latch so a proxy roll doesn't forget an active 429/402 hold.
    Keeps until, reason, code for the resumed latch; expired latches are not resurrected
    on load."""
    keep = {k: latch.get(k) for k in ("until", "reason", "code")}
    _write("INSERT OR REPLACE INTO latch_state VALUES('go_latch', ?)", (json.dumps(keep),))


def go_latch_load() -> dict | None:
    """Load a persisted Go capacity latch, ignoring it if the hold has expired (until_epoch
    in the past loads as clear)."""
    rows = _read("SELECT v FROM latch_state WHERE k='go_latch'")
    if rows:
        try:
            latch = json.loads(rows[0][0])
            now = time.time()
            # Don't resurrect expired latches — a restart after the hold expired means we're clear
            if latch.get("until", 0.0) > now:
                return latch
        except ValueError:
            pass
    return None


def status_summary() -> dict:
    """GET /router-status — the human/debug view."""
    now = time.time()
    counts = {t: (_read(f"SELECT COUNT(*) FROM {t}") or [(0,)])[0][0]
              for t in ("run_reports", "strikes", "provider_events", "rotation", "decisions",
                        "generations", "circuit_events", "openrouter_keys", "capability",
                        "task_market", "shadow_decisions", "cell_start_tier")}
    gen_24h = _read(
        "SELECT requested_model, provider, COUNT(*), ROUND(SUM(cost_usd), 6), "
        "SUM(tokens_cached), SUM(tokens_prompt) FROM generations WHERE ts > ? "
        "GROUP BY requested_model, provider ORDER BY 4 DESC LIMIT 20", (now - 86400,))
    recent_strikes = _read(
        "SELECT model, error_class, COUNT(*), "
        "  COALESCE(GROUP_CONCAT(DISTINCT NULLIF(error_subclass, '')), '') "
        "FROM strikes WHERE ts > ? "
        "GROUP BY model, error_class ORDER BY 3 DESC LIMIT 20", (now - 7 * 86400,))
    provider_errs = _read(
        "SELECT provider, class, COUNT(*) FROM provider_events "
        "WHERE ts > ? AND class != '2xx' GROUP BY provider, class ORDER BY 3 DESC LIMIT 20",
        (now - 86400,))
    rot = _read("SELECT source, COUNT(*), MAX(updated_ts) FROM rotation GROUP BY source")
    circuit = _read(
        "SELECT session, model, class, n_4xx, ts FROM circuit_events WHERE ts > ? "
        "ORDER BY ts DESC LIMIT 20", (now - 7 * 86400,))
    decisions_24h = _read(
        "SELECT decision, rail, model, reason, surface, key_ref, COUNT(*) FROM decisions "
        "WHERE ts > ? "
        "GROUP BY decision, rail, model, reason, surface, key_ref ORDER BY 7 DESC LIMIT 20",
        (now - 86400,))
    return {
        "cooldowns_active": {
            "worker": active_cooldowns(now, role="worker"),
            "probe": active_cooldowns(now, role="probe"),
        },
        # Goal #1640 acceptance 5: the (model, provider) pair cooldown table, so the seat reads
        # it without the sqlite file. `until` is the epoch the hold expires (half-open); `streak`
        # is the doubling count (2 distinct tasks → 1, 3 → 2, …).
        "pair_cooldowns": [
            {"model": v["model"], "provider": v["provider"], "until": v["until"],
             "remaining_s": v["remaining_s"], "streak": v["streak"]}
            for v in sorted(pair_cooldowns(now).values(),
                            key=lambda x: (x["model"], x["provider"]))],
        "decisions_24h": [
            # Goal #1769 acceptance 4: each row carries the CALLER facts the decision was made on
            # (`surface`/`key_ref`), beside the reason — so a `caller:*` skip is readable from
            # /router-status without the sqlite file. Goal #1769 acceptance 3: the row also echoes
            # the served model's declared `context_tokens` (the shell constant's source).
            {"decision": d, "rail": rl, "model": m, "reason": rs,
             "surface": sf or "", "key_ref": kr or "",
             "context_tokens": _model_context_tokens(m) if m else None, "n": n}
            for d, rl, m, rs, sf, kr, n in decisions_24h],
        "db_persistent": _persistent,
        "rows": counts,
        "strikes_7d": [{"model": m, "error_class": e, "n": n,
                        **({"subclasses": sc} if sc else {})}
                       for m, e, n, sc in recent_strikes],
        "provider_errors_24h": [{"provider": p, "class": c, "n": n} for p, c, n in provider_errs],
        "provider_reliability_7d": reliability()[:20],
        "circuit_opens_7d": [
            {"session": s, "model": m, "class": c, "n_4xx": n, "age_s": round(now - ts)}
            for s, m, c, n, ts in circuit],
        "generations_24h": [
            {"model": m, "provider": p, "n": n, "cost_usd": c,
             "observed_cache_hit": round((tc or 0) / tp, 3) if tp else None}
            for m, p, n, c, tc, tp in gen_24h],
        "rotation": [{"source": s, "entries": n,
                      "age_s": round(now - (ts or now))} for s, n, ts in rot],
        "classes_loaded": bool(_classes),
        # Goal #1640 acceptance 1: the ONE strike vocabulary, served so the finalizer and the
        # fleet-strike reader cite this list instead of keeping a copy that drifts.
        "strike_classes": sorted(STRIKE_CLASSES),
        "serving_classes": sorted(SERVING_CLASSES),
        # Goal #1769 acceptance 2/4: the declared rail set, each rail's state and gate. `enabled`
        # is the git authority, `parked` the env authority (OPENCODE_RAIL_DISABLED) — the two
        # reasons the walk skips a rail with, readable here without the sqlite file.
        "rails": {
            r: {"enabled": rail_enabled(r), "parked": rail_parked(r),
                "gate": rail_facts(r).get("gate"),
                "surfaces": rail_surfaces(r),
                "cost": rail_facts(r).get("cost"),
                "concurrency": rail_facts(r).get("concurrency")}
            for r in RAILS},
        # Goal #1769 acceptance 3: the per-rail FU-109 table (the Anthropic-only top-level table
        # is retired). Kept under the old key for the readers that cite it, now sourced per rail.
        "tier_thresholds": rail_facts(model_id.RAIL_SUBSCRIPTION).get("tier_thresholds") or {},
        # Goal #1769 acceptance 3: the canonical `models` table, echoed whole so the per-model
        # facts (tier, context_tokens, tool_verified, pool_usd) and the per-rail `ids` are
        # expressible from /router-status without the sqlite file or the ConfigMap.
        "models": {
            k: {"tier": v.get("tier"), "context_tokens": v.get("context_tokens"),
                "tool_verified": v.get("tool_verified"), "pool_usd": v.get("pool_usd"),
                "ids": v.get("ids") or {}}
            for k, v in _models_table().items() if not str(k).startswith("_")},
        # M11 shadow (homelab#159) — the soak review reads THESE two: the learned ladder per cell,
        # and where the would-be pick disagreed with what actually got served.
        "ladder_cells": [
            {"class": c, "urgency": u, "start_tier": LADDER[min(int(t or 0), len(LADDER) - 1)],
             "clean": cl, "degraded": dg, "age_s": round(now - (ts or now))}
            for c, u, t, cl, dg, ts in _read(
                "SELECT class, urgency, start_tier, clean, degraded, updated_ts "
                "FROM cell_start_tier ORDER BY class, urgency")],
        "shadow_24h": [
            {"class": c, "urgency": u, "start_tier": st, "shadow": f"{srl}:{sm}",
             "served": f"{vrl}:{vm}", "agrees": bool(ag), "n": n}
            for c, u, st, srl, sm, vrl, vm, ag, n in _read(
                "SELECT class, urgency, start_tier, shadow_rail, shadow_model, served_rail, "
                "served_model, agrees, COUNT(*) FROM shadow_decisions WHERE ts > ? "
                "GROUP BY 1,2,3,4,5,6,7,8 ORDER BY 9 DESC LIMIT 20", (now - 86400,))],
    }


def metrics_lines() -> list[str]:
    """Appended to the proxy's /metrics. Counters are COUNT(*) over the persistent store —
    monotonic across restarts exactly when the PVC is (the point of it)."""
    now = time.time()
    lines = [
        "# TYPE router_db_persistent gauge",
        "# HELP router_db_persistent 1 when the router store rides the PVC; 0 = :memory: degrade (RouterDbEphemeral alert).",
        f"router_db_persistent {1 if _persistent else 0}",
        "# TYPE router_run_reports_total counter",
        f"router_run_reports_total {(_read('SELECT COUNT(*) FROM run_reports') or [(0,)])[0][0]}",
        "# TYPE router_run_reports_by_rail_total counter",
        "# HELP router_run_reports_by_rail_total Run reports broken down by rail (homelab#777 flip acceptance 2, taxonomy #795 — raw values, NOT folded).",
        "# The launcher emits FOUR canonical AGENT_RAIL values (openrouter, subscription,",
        "# opencode-go, subscription-fallback); this metric surfaces them RAW from the",
        "# run_reports table. The folded accounting view (2 buckets: subscription, openrouter)",
        "# is in agents/ledger.py:_model_rail() and the agent_run_{cost_usd,count}_by_rail",
        "# recording rules. See agents/ledger.py §_RAIL_VOCABULARY.",
    ]
    by_rail = _read("SELECT rail, COUNT(*) FROM "
                    "(SELECT COALESCE(NULLIF(rail,''),'unknown') AS rail FROM run_reports) "
                    "GROUP BY rail")
    if by_rail:
        lines += [f'router_run_reports_by_rail_total{{rail="{r}"}} {n}' for r, n in by_rail]
    else:
        lines.append("router_run_reports_by_rail_total 0")
    lines += [
        "# TYPE router_strikes_total counter",
    ]
    strikes = _read("SELECT error_class, COUNT(*) FROM strikes GROUP BY error_class")
    if strikes:
        lines += [f'router_strikes_total{{error_class="{e}"}} {n}' for e, n in strikes]
    else:
        lines.append("router_strikes_total 0")
    lines.append("# TYPE router_provider_events_total counter")
    events = _read("SELECT class, COUNT(*) FROM provider_events GROUP BY class")
    if events:
        lines += [f'router_provider_events_total{{class="{c}"}} {n}' for c, n in events]
    else:
        lines.append("router_provider_events_total 0")
    lines += ["# TYPE router_cooldowns_active gauge",
              "# HELP router_cooldowns_active Models currently held out of the routing pool per role (addendum-4 temporary blacklist)."]
    for _role in ("worker", "probe"):
        lines.append(f'router_cooldowns_active{{role="{_role}"}} {len(active_cooldowns(now, role=_role))}')
    # Goal #1640 acceptance 5: the (model, provider) pair cooldown as a per-cell gauge — the
    # monitoring surface the fleet-strike reader keys on instead of walking issue comments.
    lines += ["# TYPE router_cell_cooldown gauge",
              "# HELP router_cell_cooldown Seconds remaining on a (model, provider) pair cooldown (Goal #1640 acceptance 5); one series per cooled pair, 0 when none is cooled."]
    _pc = pair_cooldowns(now)
    if _pc:
        lines += [f'router_cell_cooldown{{model="{v["model"]}",provider="{v["provider"]}"}} '
                  f'{v["remaining_s"]}' for v in sorted(_pc.values(),
                                                        key=lambda x: (x["model"], x["provider"]))]
    else:
        lines.append("router_cell_cooldown 0")
    lines += ["# TYPE router_decisions_total counter",
              "# HELP router_decisions_total /route outcomes by decision and defer reason."]
    dec = _read("SELECT decision, COALESCE(NULLIF(reason,''),'-'), COUNT(*) FROM decisions "
                "GROUP BY decision, reason")
    if dec:
        lines += [f'router_decisions_total{{decision="{d}",reason="{r}"}} {n}' for d, r, n in dec]
    else:
        lines.append("router_decisions_total 0")
    lines += ["# TYPE router_circuit_open_total counter",
              "# HELP router_circuit_open_total In-flight 4XX circuit-breaker trips per class (ADR-096 addendum 3)."]
    circuit = _read("SELECT class, COUNT(*) FROM circuit_events GROUP BY class")
    if circuit:
        lines += [f'router_circuit_open_total{{class="{c}"}} {n}' for c, n in circuit]
    else:
        lines.append("router_circuit_open_total 0")
    lines += ["# TYPE router_rotation_age_seconds gauge",
              "# HELP router_rotation_age_seconds Age of the newest entry per rotation source (RouterRotationStale alert)."]
    for s, _n, ts in _read("SELECT source, COUNT(*), MAX(updated_ts) FROM rotation GROUP BY source"):
        lines.append(f'router_rotation_age_seconds{{source="{s}"}} {now - (ts or now):.0f}')
    # Ground-truth spend at request granularity (the generation harvest) — the billed figure,
    # labelled by what actually served. Complements the launcher-pushed per-run agent_run_cost_usd.
    lines += ["# TYPE router_generation_cost_usd_total counter",
              "# HELP router_generation_cost_usd_total Billed cost summed from harvested /generation records (ground truth).",
              "# TYPE router_generations_total counter"]
    gen = _read("SELECT requested_model, provider, COUNT(*), SUM(cost_usd) "
                "FROM generations GROUP BY requested_model, provider")
    if gen:
        for m, p, n, c in gen:
            lines.append(f'router_generations_total{{model="{m}",provider="{p}"}} {n}')
            lines.append(f'router_generation_cost_usd_total{{model="{m}",provider="{p}"}} {c or 0:.8f}')
    else:
        lines += ["router_generations_total 0", "router_generation_cost_usd_total 0"]
    lines += ["# TYPE router_observed_cache_hit gauge",
              "# HELP router_observed_cache_hit Measured cached/prompt token ratio per model over 7d — the check on the pin math's CACHE_HIT assumption."]
    for m, tc, tp in _read("SELECT requested_model, SUM(tokens_cached), SUM(tokens_prompt) "
                           "FROM generations WHERE ts > ? GROUP BY requested_model",
                           (now - 7 * 86400,)):
        if tp:
            lines.append(f'router_observed_cache_hit{{model="{m}"}} {(tc or 0) / tp:.3f}')
    # ── ADR-107 flip-acceptance 1 (homelab#515): the requested≠served drift belt ──
    # The join lives in Python (model_family) over the router's own store, so it is deterministic
    # and needs no new collector. `router_run_model_drift_total` is a COUNTER over the 7d window
    # per (rail, stack, role, requested, served, provider) — a run whose served family differs
    # from the requested family. `router_run_model_unverifiable_total` counts runs whose rail had
    # NO served evidence in the window (harvest miss / no ledger row) — absence never reads as
    # agreement. Both reset on a pod roll (computed from the store at scrape time), so an alert
    # needs the max_over_time bridge — the #288/#313 single-replica class.
    drift, unver = model_drift_rows()
    lines += ["# TYPE router_run_model_drift_total counter",
              "# HELP router_run_model_drift_total Runs (7d) whose SERVED model family differs from the REQUESTED one, per rail (ADR-107 flip-acceptance 1)."]
    if drift:
        for rail, stack, role, req, served, provider, n in drift:
            lines.append(f'router_run_model_drift_total{{rail="{rail}",stack="{stack}",role="{role}",'
                         f'requested="{req}",served="{served}",provider="{provider}"}} {n}')
    else:
        lines.append("router_run_model_drift_total 0")
    lines += ["# TYPE router_run_model_unverifiable_total counter",
              "# HELP router_run_model_unverifiable_total Runs (7d) with NO served-side evidence in the store — absence must not read as agreement (homelab#515)."]
    if unver:
        for rail, stack, role, req, n in unver:
            lines.append(f'router_run_model_unverifiable_total{{rail="{rail}",stack="{stack}",'
                         f'role="{role}",requested="{req}"}} {n}')
    else:
        lines.append("router_run_model_unverifiable_total 0")
    # ── M11 shadow (homelab#159): what the cross-rail ladder WOULD have done, per cell ──
    lines += ["# TYPE router_shadow_decisions_total counter",
              "# HELP router_shadow_decisions_total Would-be ladder picks per rung/urgency, and whether they matched the SERVED pick (agrees=0 is the divergence the M11 soak reviews).",
              "# TYPE router_shadow_start_tier gauge",
              "# HELP router_shadow_start_tier Learned start rung per (class, urgency) cell: 0=free 1=subscription 2=paid.",
              "# TYPE router_shadow_subscription_blocked_total counter",
              "# HELP router_shadow_subscription_blocked_total Routes where the subscription rung was priced unpickable, by FU-088 gate reason (the safety net holding the ladder off)."]
    shadow = _read("SELECT COALESCE(NULLIF(shadow_rail,''),'-'), COALESCE(NULLIF(ladder_tier,''),'-'), "
                   "urgency, agrees, COUNT(*) FROM shadow_decisions GROUP BY 1,2,3,4")
    if shadow:
        lines += [f'router_shadow_decisions_total{{rail="{rl}",tier="{t}",urgency="{u}",agrees="{a}"}} {n}'
                  for rl, t, u, a, n in shadow]
    else:
        lines.append("router_shadow_decisions_total 0")
    for c, u, t in _read("SELECT class, urgency, start_tier FROM cell_start_tier"):
        lines.append(f'router_shadow_start_tier{{class="{c}",urgency="{u}"}} {int(t or 0)}')
    blocked = _read("SELECT sub_gate, COUNT(*) FROM shadow_decisions WHERE sub_gate != '' "
                    "GROUP BY sub_gate")
    if blocked:
        lines += [f'router_shadow_subscription_blocked_total{{reason="{r}"}} {n}' for r, n in blocked]
    else:
        lines.append("router_shadow_subscription_blocked_total 0")
    lines += ["# TYPE router_observed_decode_tps gauge",
              "# HELP router_observed_decode_tps Measured completion tokens per second of generation_time over 7d — the §M8 free-band latency tie-break (homelab#22; rows without generation_time excluded)."]
    for m, tok, ms in _read("SELECT requested_model, SUM(tokens_completion), SUM(generation_ms) "
                            "FROM generations WHERE ts > ? AND generation_ms > 0 "
                            "GROUP BY requested_model", (now - 7 * 86400,)):
        if ms:
            lines.append(f'router_observed_decode_tps{{model="{m}"}} {(tok or 0) * 1000.0 / ms:.2f}')
    return lines


def self_test() -> int:
    """In-memory round-trip; the CI gate (`devbox run router-self-test`). Also parses
    model-classes.json when it sits beside this file (the deployed layout)."""
    global _conn, _persistent
    import tempfile
    init(None, os.path.join(os.path.dirname(os.path.abspath(__file__)), "model-classes.json")
         if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                        "model-classes.json")) else None)
    stored, striked, _prov1 = record_report({
        "session": "t-1", "task": "issue-9", "stack": "sleep", "role": "worker", "round": 2,
        "model": "deepseek/deepseek-v4-flash", "cost_usd": 0.12,
        "error_class": "harness-death", "outcome": "no-pr"})
    assert stored and striked, "strike-class report must store + strike"
    stored2, striked2, _prov2 = record_report({
        "session": "t-1", "task": "issue-9", "stack": "sleep",
        "model": "deepseek/deepseek-v4-flash", "error_class": "harness-death",
        "outcome": "no-pr"})
    assert stored2 and striked2, "re-POST must remain idempotent"
    assert (_read("SELECT COUNT(*) FROM strikes") or [(0,)])[0][0] == 1, "no double-strike"
    clean, striked3, _prov3 = record_report({
        "session": "t-2", "task": "issue-9", "stack": "sleep",
        "model": "qwen/qwen3-coder", "cost_usd": 0.31, "error_class": "", "outcome": "pr"})
    assert clean and not striked3, "clean run must not strike"
    # THE REAL PRODUCER SHAPE (agent-session.sh's /report body), added 2026-08-07. The fixtures
    # above put "harness-death" in `error_class` — the taxonomy's own vocabulary, a shape the
    # launcher never sends — so they passed while router_strikes_total sat at 1 through three real
    # harness deaths. This row is what actually arrives: the coarse class in `outcome`, a finer
    # sub-type in `error_class`. Same trap as FU-115b, where the fixture matched the buggy code
    # instead of the caller's output.
    stored4, striked4, _prov4 = record_report({
        "session": "t-3", "task": "issue-19", "stack": "circles", "role": "worker", "round": 1,
        "model": "deepseek/deepseek-v4-flash", "cost_usd": 0.0368, "rail": "subscription-fallback",
        "error_class": "goose-32602-truncation", "outcome": "harness-death"})
    assert stored4 and striked4, "the REAL launcher shape must strike (sub-type in error_class, class in outcome)"
    # homelab#164: …and the rail RIDES that shape. The launcher has sent `rail` since homelab#158
    # (agent-session.sh, the /report body) but run_reports had no column, so record_report dropped
    # it and the only record of a degraded ride was the pod label — gone with the pod, while the
    # store retains 90 days. This asserts the round-trip, not just the write: a positional INSERT
    # that lost its arity would put the rail in the wrong column and still "succeed".
    assert _read("SELECT rail FROM run_reports WHERE session='t-3'") == [("subscription-fallback",)]
    assert _read("SELECT outcome, rail FROM run_reports WHERE session='t-2'") == [("pr", "")], \
        "a report with no rail lands as empty string, not NULL — and does not shift its neighbours"
    # FU-201 c: provider lookup via provider_events.session — the proxy-side seam for
    # session-keyed requests (generations is not harvested for Bearer ref: auth). Record a
    # provider_event with a session key ref, then call record_report with session_ref set,
    # and assert the strike row carries the provider.
    record_provider_event("deepseek/deepseek-v4-flash", "Fireworks", 200,
                          session="test-ns/test-session-secret")
    # Goal #1640 acceptance 3: this fixture's task is deliberately NOT the route tests' `issue-42`
    # — enforcement is now unconditional, so a serving strike recorded here would (correctly)
    # exclude the (deepseek-v4-flash, Fireworks) pair from every `issue-42` route below. The
    # fixture tests provider ATTRIBUTION (session-keyed), not routing, so the task is incidental.
    stored5, striked5, provider5 = record_report({
        "session": "t-provider-1", "task": "issue-42-provider", "stack": "sleep", "role": "worker",
        "round": 1, "model": "deepseek/deepseek-v4-flash", "cost_usd": 0.05,
        "error_class": "provider-5xx", "outcome": "no-pr"},
        session_ref="test-ns/test-session-secret")
    assert stored5 and striked5, "strike with provider must store + strike"
    _p_row = _read("SELECT provider FROM strikes WHERE session='t-provider-1'")
    assert _p_row and _p_row[0][0] == "Fireworks", \
        f"strike provider must be 'Fireworks' from provider_events lookup, got {_p_row}"
    assert provider5 == "Fireworks", \
        f"record_report must RETURN the resolved provider (the /report reply's third value), got {provider5!r}"
    # ── Goal #1640 acceptance 1: the cap-death vocabulary ──
    # A goose ride that dies at the turn cap now reports `turn-cap`; a cap death with zero
    # tool-result progress reports `tool-loop`, which is serving-shaped (the pair exclusion).
    # Each must STRIKE and must store UNDER ITS OWN CLASS: `router_strikes_total{error_class=
    # "tool-loop"}` is the goal's evidence line, so a report that landed as a sub-type or as
    # `unknown` (the rewrite this vocabulary retires) would leave the metric empty — exactly the
    # 2026-09-13 miss. Table-driven so every future vocabulary member is covered the same way.
    # `outcome` is the REAL cap-death shape, `no-output` — deliberately NOT a strike class, so
    # the row can only pass because the CLASS ITSELF is in the vocabulary: with the pre-#1665
    # set this report does not strike at all (the 2026-09-13 miss), which is the pin-vacuity bar.
    for _cls, _task, _serving in (("turn-cap", "issue-70", False),
                                  ("tool-loop", "issue-71", True)):
        _st, _sk, _pv = record_report({
            "session": f"t-{_cls}", "task": _task, "stack": "sleep", "role": "worker",
            "round": 1, "model": "deepseek/deepseek-v4-flash", "cost_usd": 0.02,
            "error_class": _cls, "outcome": "no-output"})
        assert _st and _sk, f"cap-death class {_cls} must store + strike"
        _cls_row = _read("SELECT error_class FROM strikes WHERE session=?", (f"t-{_cls}",))
        assert _cls_row and _cls_row[0][0] == _cls, \
            f"strike must store under its own class, got {_cls_row}"
        assert (_cls in SERVING_CLASSES) is _serving, \
            f"{_cls} serving-shaped={_serving} — the pair-vs-model split is the goal's pin"
    # ONE VOCABULARY: the serving set is a subset VIEW of the strike vocabulary, never a second
    # copy — drift here silently changes which strikes exclude a PAIR vs a whole MODEL.
    assert SERVING_CLASSES <= STRIKE_CLASSES, \
        f"SERVING_CLASSES must be a subset of STRIKE_CLASSES: {SERVING_CLASSES - STRIKE_CLASSES}"
    # …and the home is served, so the finalizer / reader can cite it (the "one home" half).
    _vocab = status_summary()
    assert _vocab["strike_classes"] == sorted(STRIKE_CLASSES) and \
        _vocab["serving_classes"] == sorted(SERVING_CLASSES), \
        "the strike vocabulary must surface on /router-status for the finalizer/reader to cite"
    # THE MIGRATED STORE, on a side connection. Everything above runs against a FRESH database, so
    # it only ever proves the CREATE TABLE path — but the live store is a PVC sqlite that will take
    # this column by ALTER, and the two layouts have to agree for a positional INSERT to be valid.
    # This replays the real sequence (v1 schema → ALTER → today's writer) and reads the columns
    # back BY NAME, which is what catches a rail written into `outcome`'s slot.
    _mig = sqlite3.connect(":memory:")
    _mig.execute("""CREATE TABLE run_reports(
      ts REAL, session TEXT PRIMARY KEY, task TEXT, stack TEXT, role TEXT, round INTEGER,
      model TEXT, served_model TEXT, served_provider TEXT, cache_hit REAL, cost_usd REAL,
      error_class TEXT, outcome TEXT)""")  # the pre-#164 layout, verbatim
    _mig.execute("INSERT INTO run_reports VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 (1.0, "old-1", "issue-1", "sleep", "worker", 1, "m", "", "", 0.0, 0.0, "", "pr"))
    _mig.execute("ALTER TABLE run_reports ADD COLUMN rail TEXT")
    _mig.execute("INSERT OR REPLACE INTO run_reports VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                 (2.0, "new-1", "issue-2", "sleep", "worker", 1, "m", "", "", 0.0, 0.0, "",
                  "harness-death", "subscription-fallback"))
    assert _mig.execute(
        "SELECT outcome, rail FROM run_reports ORDER BY ts").fetchall() == [
        ("pr", None), ("harness-death", "subscription-fallback")], \
        "ALTER'd layout must match the CREATE TABLE one — else the positional write is off by a column"
    _mig.close()
    # Goal #1769 acceptance 4 (router half): the same discipline for decisions.surface/key_ref. The
    # live PVC store takes the two columns by ALTER while the CREATE TABLE path already carries
    # them, and route()'s INSERT is POSITIONAL — so a drift between the layouts would write the
    # caller facts into the wrong slot and still "succeed". Replay the real sequence (pre-#1913
    # schema → ALTER → today's writer) and read the columns back BY NAME.
    _dmig = sqlite3.connect(":memory:")
    _dmig.execute("""CREATE TABLE decisions(
      ts REAL, session TEXT, stack TEXT, role TEXT, class TEXT, decision TEXT, rail TEXT,
      model TEXT, reason TEXT, detail TEXT)""")  # the pre-#1913 layout, verbatim
    _dmig.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?)",
                  (1.0, "old-d", "issue-1", "worker", "coding", "defer", "", "",
                   "chain-exhausted", "{}"))
    for _dcol in ("surface TEXT", "key_ref TEXT"):
        try:
            _dmig.execute(f"ALTER TABLE decisions ADD COLUMN {_dcol}")
        except sqlite3.OperationalError:
            pass  # duplicate column — schema already current
    _dmig.execute("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                  (2.0, "new-d", "issue-2", "reviewer", "review", "dispatch",
                   "anthropic-subscription", "claude/sonnet", "", "{}", "claude-cli",
                   "sleep-agents/sleep-openrouter"))
    assert _dmig.execute(
        "SELECT session, surface, key_ref FROM decisions ORDER BY ts").fetchall() == [
        ("old-d", None, None),
        ("new-d", "claude-cli", "sleep-agents/sleep-openrouter")], \
        "the ALTER'd decisions layout must match the CREATE TABLE one — else the caller facts land in the wrong column"
    _dmig.close()
    # ── homelab#1042: model_cooldowns PVC migration test ──
    # The self-test normally starts from a FRESH schema (:memory: via init(None)), so it never
    # exercises the "table already exists with the old 5-column shape" path that the live PVC
    # store has. This creates an old-schema file DB, calls init() twice (the second call is
    # the one that would silently re-latch or drop the store with the unguarded migration),
    # and asserts the probe row survives both calls. The global connection is saved before
    # and restored after so the rest of the test's in-memory data is not lost.
    _saved_conn, _saved_persistent = _conn, _persistent
    _mig_cool_db = tempfile.mktemp(suffix=".db")
    try:
        # Build the OLD 5-column schema (no role, model-only PK) — exactly what a pre-#1042 PVC
        # store looks like.
        _mig_cool = sqlite3.connect(_mig_cool_db)
        _mig_cool.execute("""CREATE TABLE model_cooldowns(
          model TEXT PRIMARY KEY, until REAL, streak INTEGER, reason TEXT, set_ts REAL)""")
        _mig_cool.execute("INSERT INTO model_cooldowns VALUES(?,?,?,?,?)",
                          ("old-model-a", 99999.0, 2, "429-burst", 10000.0))
        _mig_cool.close()
        # First call: migrates the old schema to the new role-scoped PK.
        init(_mig_cool_db)
        assert _persistent, "init() must report persistent=True for a file DB"
        # Insert a probe row for the same model — this is the case that would collide on PK
        # and drop the store if the migration re-ran.
        _mig_cool = sqlite3.connect(_mig_cool_db)
        _mig_cool.execute("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
                          ("old-model-a", "probe", 88888.0, 1, "429-burst", 20000.0))
        _mig_cool.execute("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
                          ("old-model-a", "worker", 77777.0, 0, "", 30000.0))
        _mig_cool.commit()
        _mig_cool.close()
        # Second call: the guarded migration must NOT re-run, leaving the probe row intact.
        init(_mig_cool_db)
        assert _persistent, "init() must stay persistent after second call (migration must not drop the store)"
        _mig_cool = sqlite3.connect(_mig_cool_db)
        _probe_rows = _mig_cool.execute(
            "SELECT model, role FROM model_cooldowns WHERE role='probe'").fetchall()
        assert len(_probe_rows) == 1 and _probe_rows[0] == ("old-model-a", "probe"), \
            "probe row must survive second init() call — migration must not re-run and relabel it"
        _all_rows = _mig_cool.execute(
            "SELECT model, role FROM model_cooldowns ORDER BY role").fetchall()
        assert len(_all_rows) == 2, \
            "both worker and probe rows for the same model must survive second init() call"
        _mig_cool.close()
    finally:
        if os.path.exists(_mig_cool_db):
            os.unlink(_mig_cool_db)
        _conn, _persistent = _saved_conn, _saved_persistent
    # Goal #1640 acceptance 1 (reader half): the stored class is a vocabulary MEMBER. The
    # fixture above posts `outcome="harness-death"` (a member) beside
    # `error_class="goose-32602-truncation"` (not one) — the real producer shape. Pre-fix the
    # row stored the sub-type, which no reader tests, so the strike counted for nothing.
    assert strikes_for("issue-19", "circles") == [("deepseek/deepseek-v4-flash", "", "harness-death")]
    _sub = _read("SELECT error_class, error_subclass FROM strikes WHERE task=? AND stack=?",
                 ("issue-19", "circles"))
    assert _sub == [("harness-death", "goose-32602-truncation")], \
        f"the fine sub-type survives as evidence beside the member (got {_sub})"
    # A SERVING-shaped class with a known provider scopes to the PAIR; the same class with NO
    # provider must keep MODEL scope. The second row is the trap this change had to avoid: move
    # the provider test into the serving branch and a providerless auth-storm excludes nothing.
    record_provider_event("vendor/pair-model", "providerx", 401, session="t-pairscope")
    record_report({"session": "t-pairscope", "task": "issue-pairscope", "stack": "sleep",
                   "role": "worker", "model": "vendor/pair-model",
                   "outcome": "auth-storm", "error_class": "http-401-storm"},
                  session_ref="t-pairscope")
    _ps = strikes_for("issue-pairscope", "sleep")
    assert _ps and _ps[0][2] == "auth-storm" and _ps[0][1] == "providerx", \
        f"a fine auth sub-type normalizes to the serving member, with its provider (got {_ps})"
    record_report({"session": "t-noprov", "task": "issue-noprov", "stack": "sleep",
                   "role": "worker", "model": "vendor/pair-model",
                   "outcome": "auth-storm", "error_class": "http-401-storm"})
    _np = strikes_for("issue-noprov", "sleep")
    assert _np == [("vendor/pair-model", "", "auth-storm")], f"providerless serving strike (got {_np})"
    _np_models, _np_pairs = set(), {}
    for _m, _p, _ec in _np:
        if _ec in SERVING_CLASSES and _p:
            _np_pairs.setdefault(_m, set()).add(_p)
        else:
            _np_models.add(_m)
    assert _np_models == {"vendor/pair-model"} and not _np_pairs, \
        "a serving strike with no provider keeps MODEL scope — it must never un-exclude the cell"
    # Goal #1640 acceptance 3: enforcement is UNCONDITIONAL — the retired strike-enforcement knob
    # and its `if <flag> else []` filter are gone (the 09-13 checkpoint read it False in
    # production on every routerMode). The route() rows below prove the enforcement.
    assert not hasattr(sys.modules[__name__], "STRIKE_ENFORCE"), \
        "the strike-enforcement flag must be deleted, not merely defaulted off"
    assert strikes_for("issue-9", "sleep") == [("deepseek/deepseek-v4-flash", "", "harness-death")]
    record_provider_event("qwen/qwen3-coder", "deepinfra", 500)
    record_provider_event("qwen/qwen3-coder", "deepinfra", 200)
    assert record_generation("gen-test-1", "deepseek/deepseek-v4-flash", {
        "model": "deepseek/deepseek-v4-flash-20260423", "provider_name": "Fireworks",
        "native_tokens_prompt": 100, "native_tokens_completion": 20,
        "native_tokens_cached": 80, "total_cost": 9.8e-07, "latency": 1022,
        "generation_time": 2000, "finish_reason": "stop"})
    assert record_generation("gen-test-1", "deepseek/deepseek-v4-flash", {
        "total_cost": 9.8e-07}), "generation re-record must stay idempotent (no-op)"
    assert (_read("SELECT generation_ms FROM generations WHERE id='gen-test-1'")
            or [(0,)])[0][0] == 2000, "generation_time must round-trip (homelab#22)"
    assert any("router_observed_decode_tps" in ln and "10.00" in ln
               for ln in metrics_lines()), "decode tok/s gauge (20 tok / 2s = 10.00)"
    # ── ADR-107 flip-acceptance 1 (homelab#515): the requested≠served drift belt ──
    # Family normalisation — the level at which requested and served are compared. These are the
    # shapes the fleet actually produces: date-stamped served ids, [1m] context brackets, the
    # claude aliases, rail prefixes. A raw-equality join would mint false drift on every one.
    assert model_family("deepseek/deepseek-v4-flash") == "deepseek/deepseek-v4-flash"
    assert model_family("deepseek/deepseek-v4-flash-20260423") == "deepseek/deepseek-v4-flash", \
        "a date-stamped served id must collapse to its family"
    assert model_family("deepseek/deepseek-v4-flash-0731") == "deepseek/deepseek-v4-flash", \
        "a 4-digit MMDD-stamped served id must collapse to its family"
    assert model_family("claude-opus-5[1m]") == "claude-opus", \
        "a [1m] context-bracketed id must collapse to its family"
    assert model_family("haiku") == "claude-haiku", "the claude alias must expand to its family"
    assert model_family("claude/haiku") == "claude-haiku", "the claude/ alias must expand too"
    assert model_family("opencode-go/deepseek-v4-flash") == "deepseek-v4-flash", \
        "the opencode-go/ rail prefix must be stripped"
    assert model_family("opencode-go/deepseek-v4-flash-0731") == "deepseek-v4-flash", \
        "a bare id with 4-digit stamp and prefix must still collapse to family"
    assert model_family("moonshotai/kimi-k3") == "moonshotai/kimi-k3", \
        "an already-canonical id must pass through unchanged"
    # The join: a run_report on the openrouter rail whose requested family differs from the
    # harvested generation's served family is drift; a run with NO harvested evidence is
    # unverifiable (absent served side must never read as agreement — the FU-108/FU-125 class).
    record_report({"session": "drift-1", "task": "issue-99", "stack": "sleep", "role": "worker",
                   "model": "deepseek/deepseek-v4-flash", "rail": "openrouter", "outcome": "pr"})
    # total_cost 0.0 on purpose: generations_24h orders by cost DESC and the self-test asserts
    # the FIRST row is gen-test-1 (cache hit 0.8) — a paid drift fixture would sort above it.
    record_generation("gen-drift-1", "deepseek/deepseek-v4-flash", {
        "model": "moonshotai/kimi-k3", "provider_name": "Moonshot",
        "native_tokens_prompt": 1, "native_tokens_completion": 1,
        "native_tokens_cached": 0, "total_cost": 0.0, "latency": 500,
        "generation_time": 1000, "finish_reason": "stop"})
    record_report({"session": "unver-1", "task": "issue-98", "stack": "circles", "role": "worker",
                   "model": "tencent/hy3", "rail": "openrouter", "outcome": "pr"})
    drift, unver = model_drift_rows()
    assert drift == [("openrouter", "sleep", "worker", "deepseek/deepseek-v4-flash",
                      "moonshotai/kimi-k3", "Moonshot", 1)], \
        f"drift must be exactly the requested≠served row: {drift}"
    # gen-test-1's pairing (requested deepseek/deepseek-v4-flash, served
    # deepseek/deepseek-v4-flash-20260423 — same FAMILY) must NOT appear in drift — that is the
    # date-stamp-collapse the family comparison exists for.
    assert all(r[4] != "deepseek/deepseek-v4-flash-20260423" for r in drift), \
        f"a same-family requested/served pair must not be drift: {drift}"
    assert any(r[0] == "openrouter" and r[3] == "tencent/hy3" for r in unver), \
        f"a run with no generation evidence must be unverifiable: {unver}"
    # homelab#748: a FAILED run_report (outcome='failed', e.g. a model-scout canary crash) must
    # NOT appear in the unverifiable set — a harness death with a recorded error_class is already
    # explained and must not masquerade as a coverage gap. The non-failed unver-1 row above proves
    # the belt still fires for genuine blind spots.
    record_report({"session": "failed-unver-1", "task": "issue-748", "stack": "circles",
                   "role": "worker", "model": "anthropic/claude-sonnet-5", "rail": "openrouter",
                   "outcome": "failed", "error_class": "nonzero-exit-1"})
    drift, unver = model_drift_rows()
    assert not any(r[0] == "openrouter" and r[3] == "anthropic/claude-sonnet-5" for r in unver), \
        f"a failed run_report must NOT be unverifiable: {unver}"
    assert any(r[0] == "openrouter" and r[3] == "tencent/hy3" for r in unver), \
        f"the non-failed unverifiable row must still be present after the failed-row fix: {unver}"
    # The Go rail: a requested opencode-go/deepseek-v4-flash ride whose stack served only
    # kimi-k3 (a slot-map redirect) is drift; a Go ride with NO ledger rows for its stack is
    # unverifiable. go_usage rows are written with the BARE model id (prefix stripped at the
    # proxy), so requested and served ids are the same string — the family comparison is what
    # catches a slot map that redirected one model to another.
    _now = time.time()
    record_report({"session": "go-drift-1", "task": "issue-97", "stack": "sleep", "role": "worker",
                   "model": "opencode-go/deepseek-v4-flash", "rail": "opencode-go", "outcome": "pr"})
    # Timestamp ~1h ago (inside the 7d drift window but OUTSIDE the later 5m/300s ledger window
    # tests) so the drift section's synthetic ledger row cannot pollute go_usage_window's sums.
    go_usage_add(_now - 3600, "sleep", "kimi-k3", 0.01)  # the stack served kimi-k3, not flash
    record_report({"session": "go-unver-1", "task": "issue-96", "stack": "circles", "role": "worker",
                   "model": "opencode-go/deepseek-v4-flash", "rail": "opencode-go", "outcome": "pr"})
    drift, unver = model_drift_rows()
    assert any(r[0] == "opencode-go" and r[3] == "opencode-go/deepseek-v4-flash"
               and r[4] == "kimi-k3" for r in drift), \
        f"a Go ride served a different family than requested must be drift: {drift}"
    assert any(r[0] == "opencode-go" and r[3] == "opencode-go/deepseek-v4-flash"
               and r[1] == "circles" for r in unver), \
        f"a Go ride with no ledger rows must be unverifiable: {unver}"
    # homelab#575: the platform-stack shape — go_usage served rows land under the REPO namespace
    # (homelab is one of platform's repos; none of them equals "platform"), so the old `stack = ?`
    # join read every platform Go ride as unverifiable. The join now resolves repo namespaces back
    # to the owning AgentStack via _stack_repos(); a ride served under a repo namespace is
    # verifiable, not unverifiable.
    record_report({"session": "agent-homelab-issue-575-r1", "task": "issue-575",
                   "stack": "platform", "role": "worker",
                   "model": "opencode-go/deepseek-v4-flash", "rail": "opencode-go", "outcome": "pr"})
    go_usage_add(_now - 3600, "homelab", "deepseek-v4-flash", 0.01)  # served under the repo ns
    drift, unver = model_drift_rows()
    assert not any(r[0] == "opencode-go" and r[1] == "platform"
                   and r[3] == "opencode-go/deepseek-v4-flash" for r in unver), \
        f"a platform Go ride served under its repo ns must be VERIFIABLE, not unverifiable: {unver}"
    # homelab#577: the DEPLOYED-POD fallback, exercised directly. The #575 fixture above is
    # MASKED in CI — the committed agents/stacks.json already maps `homelab`→platform, so
    # _stack_repos() satisfies its map before the run_reports loop runs and a broken
    # _repo_from_session regex (the ONLY signal the deployed pod has: it mounts router.py alone
    # via ConfigMap, stacks.json absent by construction) would pass green. Patch os.path.exists
    # to hide stacks.json, seed the launcher's real pod-name shapes, and assert the run_reports
    # loop alone resolves repo → AgentStack.
    record_report({"session": "agent-sleep-iac-issue-42-r1", "task": "issue-42",
                   "stack": "sleep", "role": "worker",
                   "model": "opencode-go/deepseek-v4-flash", "rail": "opencode-go", "outcome": "pr"})
    record_report({"session": "agent-agent-runtime-083012", "task": "adhoc-20260819T083012",
                   "stack": "platform", "role": "worker",
                   "model": "opencode-go/deepseek-v4-flash", "rail": "opencode-go", "outcome": "pr"})
    assert _repo_from_session("agent-homelab-issue-575-r1") == "homelab", "issue shape"
    assert _repo_from_session("agent-sleep-iac-issue-42-r1") == "sleep-iac", \
        "dashed-repo issue shape"
    assert _repo_from_session("agent-agent-runtime-083012") == "agent-runtime", "timestamp shape"
    _sp = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                       "agents", "stacks.json")
    _orig_exists = os.path.exists
    os.path.exists = (lambda p, _orig=_orig_exists, _sp=os.path.abspath(_sp):
                      False if os.path.abspath(p) == _sp else _orig(p))
    try:
        _deployed = _stack_repos()
    finally:
        os.path.exists = _orig_exists
    # With stacks.json hidden, the map is EXACTLY the run_reports.session rows that parsed — a
    # superset here (all of stacks.json's repos) would mean the file leaked back into the branch,
    # a subset/wrong key a broken regex. Both are the regression this branch exists to catch.
    assert set(_deployed) == {"homelab", "sleep-iac", "agent-runtime"}, \
        f"stacks.json must be ABSENT — only run_reports.session rows may resolve: {_deployed}"
    assert _deployed["homelab"] == "platform", f"issue shape (#575 fixture): {_deployed}"
    assert _deployed["sleep-iac"] == "sleep", f"dashed-repo issue shape: {_deployed}"
    assert _deployed["agent-runtime"] == "platform", f"timestamp shape: {_deployed}"
    body = "\n".join(metrics_lines())
    assert 'router_run_model_drift_total{rail="openrouter",stack="sleep",role="worker",' \
           'requested="deepseek/deepseek-v4-flash",served="moonshotai/kimi-k3",provider="Moonshot"} 1' \
           in body, "the drift counter must surface in /metrics"
    assert 'router_run_model_unverifiable_total{rail="openrouter",stack="circles",role="worker",' \
           'requested="tencent/hy3"} 1' in body, "the unverifiable counter must surface in /metrics"
    assert record_rotation("scout-canary",
                           [{"model": "moonshotai/kimi-k3", "canary_verdict": "clean"}]) == 1
    # Addendum 3: reliability aggregate + free-canary derivation + circuit events + key refs
    for _ in range(18):
        record_provider_event("poolside/laguna-s-2.1:free", "poolside", 401)
    for _ in range(2):
        record_provider_event("poolside/laguna-s-2.1:free", "poolside", 200)
    rel = {(r["model"], r["provider"]): r for r in reliability(min_n=2)}
    laguna = rel[("poolside/laguna-s-2.1:free", "poolside")]
    assert laguna["n"] == 20 and laguna["ok_rate"] == 0.1 and laguna["auth_rate"] == 0.9
    assert derive_canary_verdicts(min_n=20) == 1, "20 laguna events must yield one verdict"
    verdicts = dict(_read("SELECT model, canary_verdict FROM rotation WHERE source='provider-events'"))
    assert verdicts == {"poolside/laguna-s-2.1:free": "broken"}, verdicts
    assert record_circuit_open("sleep-agents/or-key", "poolside/laguna-s-2.1:free", "auth", 4)
    assert status_summary()["circuit_opens_7d"][0]["class"] == "auth"
    enroll_key_ref("sleep-agents/sleep-openrouter")
    enroll_key_ref("sleep-agents/sleep-openrouter")  # re-enroll = last_seen bump, not a dup
    assert key_refs() == ["sleep-agents/sleep-openrouter"]
    latch_save({"until": 123.0, "last_429": 100.0, "windows": {"5h": {"utilization": 0.5}},
                "count_429": 2, "headers_at": 99.0})
    assert (latch_load() or {}).get("count_429") == 2, "latch round-trip"
    # ── homelab#422: Go usage ledger round-trip — stack-dimensioned, windowed ──
    now = time.time()
    assert go_usage_add(now - 100, "sleep", "kimi-k3", 0.005)
    assert go_usage_add(now - 50, "sleep", "qwen3.5-plus", 0.002)
    assert go_usage_add(now - 25, "circles", "deepseek-v4-flash", 0.001)
    w5m = go_usage_window(300)  # 5 minutes
    assert abs(w5m["total_usd"] - 0.008) < 1e-9, f"window total={w5m['total_usd']}"
    assert w5m["by_stack"].get("sleep", 0) == 0.007, f"by_stack sleep={w5m['by_stack'].get('sleep')}"
    assert w5m["by_stack"].get("circles", 0) == 0.001, f"by_stack circles={w5m['by_stack'].get('circles')}"
    # Ledger prune — rows older than 45d are deleted
    old_ts = now - 50 * 86400
    assert go_usage_add(old_ts, "old", "kimi-k3", 1.0)  # 50 days old
    assert go_usage_add(now, "fresh", "kimi-k3", 0.01)  # fresh row triggers prune
    w60d = go_usage_window(60 * 86400)  # 60d window
    assert w60d["by_stack"].get("old", 0) == 0, "ledger prune: 50d-old row deleted"
    assert w60d["by_stack"].get("fresh", 0) == 0.01, "ledger prune: fresh row retained"
    # ── gometer WINDOW DRAW pricing (2026-08-17 defect): list price on raw tokens ──────────
    import gometer  # shared home (ADR-108) — the semantics under test
    # Deterministic clocks for the TIME-VARYING DeepSeek rows (2026-09-17 refresh): every
    # price assertion below pins `now`, or it would flip with the wall clock.
    _T_OFF = calendar.timegm((2026, 9, 19, 12, 0, 0, 0, 0, 0))  # Sat 12:00Z → OFF-PEAK
    _T_PEAK = calendar.timegm((2026, 9, 17, 7, 0, 0, 0, 0, 0))  # Thu 07:00Z → PEAK
    assert gometer.is_peak(_T_PEAK) and not gometer.is_peak(_T_OFF), "peak clock fixtures"
    # Console reconciliation (uploads/opencode-go.txt, 2026-08-17): a 5h window of 50.56M in /
    # 0.488M out of deepseek-v4-flash drew DOLLARS at list on RAW tokens, while the old
    # cache-priced meter read $0.145 (~30× low). That invariant is what this pins; the absolute
    # number moved with the 2026-09-17 price refresh (0.14/0.28 + a now-ungrounded 2x badge →
    # 0.15/0.60 off-peak, no badge):
    #   input  50.56M × 0.15 = 7.584
    #   output  0.488M × 0.60 = 0.2928
    #   draw = 7.8768  (NOT the ~$0.15 cents a cache-read interpretation gives)
    _raw_merge = {"input_tokens": 50560000, "output_tokens": 488000}
    _cal = gometer.window_draw("deepseek-v4-flash", _raw_merge, now=_T_OFF)
    assert abs(_cal - 7.8768) < 1e-6, f"window_draw calibration: {_cal} (expected 7.8768 from list prices)"
    assert _cal > 50 * gometer.price("deepseek-v4-flash",
                                     {"input_tokens": 0, "cache_read_input_tokens": 50560000,
                                      "output_tokens": 0}, now=_T_OFF)[0], \
        "the 2026-08-17 invariant: raw-token list draw ≫ the cache-read-priced view"
    # ── homelab#540: price() is BILLED = list ×1 with cache discounts; window_draw() is LIST
    # on raw tokens. deepseek-v4-flash 1M in + 1M out, OFF-PEAK:
    #   billed = 1e6×0.15/1e6 + 1e6×0.60/1e6 = 0.15 + 0.60 = $0.75
    _bill_merge = {"input_tokens": 1000000, "output_tokens": 1000000}
    _bill = gometer.price("deepseek-v4-flash", _bill_merge, now=_T_OFF)[0]
    assert abs(_bill - 0.75) < 1e-9, f"price() off-peak list ×1: {_bill} != 0.75"
    # 2026-09-17: NO row sets half=True any more (the vendor dropped the 2x badge column), so
    # the draw of the same completion is NOT halved — it equals the raw-token list price. This
    # assertion is the regression guard against silently re-introducing an ungrounded halving.
    _draw_same = gometer.window_draw("deepseek-v4-flash", _bill_merge, now=_T_OFF)
    assert abs(_draw_same - 0.75) < 1e-9, f"no badge halving is grounded today: {_draw_same} != 0.75"
    assert not any(r[4] for r in gometer.GO_PRICES.values()), \
        "half=True must stay UNSET until a badge is re-grounded (it makes the latch optimistic)"
    # ── PEAK / OFF-PEAK (2026-09-17): both sides of the boundary, pinned ───────────────────
    # Vendor: peak = Mon-Fri 01:00-04:00 and 06:00-10:00 UTC; everything else off-peak. Peak is
    # exactly 2× off-peak for the four DeepSeek rows.
    _peak_draw = gometer.window_draw("deepseek-v4-flash", _bill_merge, now=_T_PEAK)
    assert abs(_peak_draw - 1.50) < 1e-9, f"peak draw must be 2× off-peak: {_peak_draw} != 1.50"
    #   deepseek-v4-pro peak: 1M×1.32 + 1M×3.96 = $5.28 (off-peak 0.66 + 1.98 = $2.64)
    assert abs(gometer.price("deepseek-v4-pro", _bill_merge, now=_T_PEAK)[0] - 5.28) < 1e-9, \
        "deepseek-v4-pro peak row"
    assert abs(gometer.price("deepseek-v4-pro", _bill_merge, now=_T_OFF)[0] - 2.64) < 1e-9, \
        "deepseek-v4-pro off-peak row"
    # boundary hours: 01:00Z in, 04:00Z out, 06:00Z in, 10:00Z out (half-open [lo, hi)).
    _wed = lambda h, m=0: calendar.timegm((2026, 9, 16, h, m, 0, 0, 0, 0))  # a Wednesday
    assert gometer.is_peak(_wed(1)) and not gometer.is_peak(_wed(0, 59)), "01:00Z opens peak"
    assert gometer.is_peak(_wed(3, 59)) and not gometer.is_peak(_wed(4)), "04:00Z closes peak"
    assert gometer.is_peak(_wed(6)) and not gometer.is_peak(_wed(5, 59)), "06:00Z opens peak"
    assert gometer.is_peak(_wed(9, 59)) and not gometer.is_peak(_wed(10)), "10:00Z closes peak"
    # weekends are off-peak even inside the peak HOURS
    assert not gometer.is_peak(calendar.timegm((2026, 9, 19, 7, 0, 0, 0, 0, 0))), "Sat 07:00Z off-peak"
    assert not gometer.is_peak(calendar.timegm((2026, 9, 20, 7, 0, 0, 0, 0, 0))), "Sun 07:00Z off-peak"
    # a NON-peak model is unaffected by the clock
    assert gometer.window_draw("kimi-k3", _bill_merge, now=_T_PEAK) == \
        gometer.window_draw("kimi-k3", _bill_merge, now=_T_OFF), "clock must not move a flat row"
    # the half MECHANISM is retained for a future GROUNDED badge — prove it still halves
    gometer.GO_PRICES["_synthetic-badged"] = (1.00, 1.00, None, None, True)
    try:
        assert abs(gometer.window_draw("_synthetic-badged", _bill_merge) - 1.00) < 1e-9, \
            "half mechanism must still halve a badged row (2.00 list → 1.00 draw)"
    finally:
        del gometer.GO_PRICES["_synthetic-badged"]
    # qwen3.5-plus is DEAD (400 "Model is unavailable", 3/3, 2026-09-17) and must stay out of
    # the table — /v1/models still lists it, so the model list is not a liveness signal.
    assert "qwen3.5-plus" not in gometer.GO_PRICES, "qwen3.5-plus is dead — keep it deleted"
    # The OLD meter's view — the same physical input reported as cache-read (the "assumes
    # cache-read pricing" bug): 50.56M at the cR rate 0.003/M → cents, not dollars. The billed
    # side is list ×1.
    _old_view = {"input_tokens": 0, "cache_read_input_tokens": 50560000,
                 "output_tokens": 488000}
    _billed_old = gometer.price("deepseek-v4-flash", _old_view, now=_T_OFF)[0]
    assert _billed_old < 0.5, f"the cache-read-meter view must still read cents, got {_billed_old}"
    # ── homelab#540: the cache-split formula (2026-08-18 reconciliation shape, clean numbers) ──
    # kimi-k3 rates in $/M: in 3.00, out 15.00, cR 0.30. A synthetic split row:
    #   in = 41,745  (full price)   → 41745×3.00/1e6 = 0.125235
    #   cache_read = 10,000         → 10000×0.30/1e6 = 0.003
    #   out = 2,653                 → 2653×15.00/1e6 = 0.039795
    #   billed = 0.125235 + 0.003 + 0.039795 = $0.16803  (the 2026-08-18 kimi-k3 shape: 51,745
    #   total input = 41,745 full + 10,000 cache-read; previously the ledger priced all 51,745
    #   at full price = 0.155235 + ... = the over-count the fix removes).
    _kimi = {"input_tokens": 41745, "cache_read_input_tokens": 10000, "output_tokens": 2653}
    _kimi_bill = gometer.price("kimi-k3", _kimi)[0]
    assert abs(_kimi_bill - 0.16803) < 1e-9, f"cache-split billed: {_kimi_bill} != 0.16803"
    # The window-draw of the same split row: cache-read at the cR LIST rate, badge-halved (kimi
    # is not badged, so ×1): 0.125235 + 0.003 + 0.039795 = 0.16803.
    _kimi_draw = gometer.window_draw("kimi-k3", _kimi)
    assert abs(_kimi_draw - 0.16803) < 1e-9, f"cache-split draw: {_kimi_draw} != 0.16803"
    # Tokens WITHOUT a split keep pricing as RAW INPUT (the conservative status quo for
    # historical rows): a row with only cache_read present prices it as raw input at the cR
    # rate only if the split is KNOWN; with no split at all, window_draw prices raw in+out only.
    _kimi_nosplit = {"input_tokens": 1000, "output_tokens": 0}
    assert abs(gometer.window_draw("kimi-k3", _kimi_nosplit) - 0.003) < 1e-9, \
        "window_draw without a split prices raw in only (conservative status quo)"
    # ── gometer window ANCHORS (2026-08-17): epoch-anchored vs pure-rolling floors ──
    # Pure-boundary unit tests with a FIXED now (deterministic — fail if the anchor arithmetic
    # is wrong). fixed_now = 2026-08-17 12:22:16 UTC (a Monday).
    spec7u, spec5u, spec30u = (gometer.GO_WINDOWS[w] for w in ("7d", "5h", "30d"))
    assert spec7u["anchor"] == "weekly" and spec7u["weekday"] == "mon", spec7u
    # homelab#540: the 5h default is now CHAIN-anchored (first-use/expiry-chained — the console's
    # x:01 reset lattice proves the 2026-08-17 grid:217m calibration was the wrong model). The
    # grid offset 217m is retained as the DEGRADE fallback when the ledger is unreadable / no
    # window is open.
    assert spec5u["anchor"] == "chain" and spec5u["grid_offset_min"] == 217, spec5u
    assert spec30u["anchor"] == "monthly" and spec30u["month_day"] == 13, spec30u
    w7u, w7un = gometer.go_window_bounds(spec7u, 1786969336.0)
    # weekly mon 00:00: 2026-08-17T12:22Z IS a Monday, 12h22m past its own boundary →
    # window_start = 08-17T00:00Z (1786924800), resets_at = 08-24T00:00Z (1787529600) — the
    # console cross-check: 12:35Z + 6d11h ≈ 08-24T00:00Z ✓ (a Sunday anchor missed by one day). →
    # last = 2026-08-16 00:00 UTC, next = last + 7d = 2026-08-23 00:00 UTC.
    assert w7u == 1786924800.0 and w7un == 1787529600.0, (w7u, w7un)
    g5u, g5un = gometer.go_window_bounds(spec5u, 1786969336.0)
    # grid 217m: resets daily at midnight + 217min + k*5h → 03:37/08:37/13:37/18:37/23:37 UTC.
    # At 12:22:16 UTC the last is 08:37 (1786955820), the next is 13:37 (1786973820).
    assert g5u == 1786955820.0 and g5un == 1786973820.0, (g5u, g5un)
    m30u, m30un = gometer.go_window_bounds(spec30u, 1786969336.0)
    # monthly 13:11:30: after this month's 13th → last = 2026-08-13 11:30 (1786620600),
    # next = 2026-09-13 11:30 (1789299000).
    assert m30u == 1786620600.0 and m30un == 1789299000.0, (m30u, m30un)
    # and the PRE-13th case: at 2026-08-12 12:00 UTC the last boundary is 2026-07-13 11:30
    # (1783942200), next = 2026-08-13 11:30 (1786620600).
    m30p, m30pn = gometer.go_window_bounds(spec30u, 1786536000.0)
    assert m30p == 1783942200.0 and m30pn == 1786620600.0, (m30p, m30pn)
    # ── homelab#540: CHAIN-anchor (first-use/expiry-chained) window recovery ──
    # The 5h default is `chain`: a new window OPENS at the first request after the previous
    # window expired; reset = open + span; idle > span ⇒ the next request opens a fresh window.
    # The ledger walk (go_usage_chain_open) recovers the CURRENT open window. Cases use a fixed
    # `now` (2027-01-13 00:00:00 UTC) with rows seeded around it; the real-time rows above are
    # cleared first so the walk sees ONLY the synthetic lattice.
    _cnow = 1800000000.0
    _cspan = 500.0
    _c_look = 7 * 86400
    # (a) continuous use → the lattice anchored at the FIRST ts (the degenerate case the
    #     2026-08-17 grid:217m calibration measured — indistinguishable from a fixed grid for
    #     one day). Rows every 100s from _cnow-1000, span 500 → windows open at -1000, -500, 0.
    _write("DELETE FROM go_usage", ())
    go_usage_add(_cnow - 1000, "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 900,  "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 500,  "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 400,  "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 0,    "chain", "kimi-k3", 0.01)
    assert go_usage_chain_open(_cspan, _c_look, now=_cnow) == _cnow, \
        f"chain continuous lattice must open at the first ts + span steps ({_cnow})"
    _ba, _ba_reset = gometer.go_window_bounds(
        {"anchor": "chain", "span_s": _cspan, "chain_lookback_s": _c_look}, _cnow,
        chain_fn=lambda s, lb: go_usage_chain_open(s, lb, now=_cnow))
    assert (_ba, _ba_reset) == (_cnow, _cnow + _cspan), (_ba, _ba_reset)
    # (b) idle gap > span → the fresh window opens at the POST-GAP ts (NOT a fixed-grid lattice
    #     point). Gap from -900 to -300 is 600 > 500, so the -300 row opens a fresh window.
    _write("DELETE FROM go_usage", ())
    go_usage_add(_cnow - 1000, "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 900,  "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 300,  "chain", "kimi-k3", 0.01)   # 600 > 500 after the previous window
    assert go_usage_chain_open(_cspan, _c_look, now=_cnow) == _cnow - 300, \
        "chain idle-gap must open the fresh window at the post-gap ts (not a grid lattice point)"
    # (c) now past open+span → NO open window (idle past expiry) → chain_fn returns None, and
    #     go_window_bounds DEGRADES to this window's GRID default (loud log, never a crash,
    #     never a silent zero).
    _write("DELETE FROM go_usage", ())
    go_usage_add(_cnow - 1000, "chain", "kimi-k3", 0.01)
    go_usage_add(_cnow - 500,  "chain", "kimi-k3", 0.01)
    assert go_usage_chain_open(_cspan, _c_look, now=_cnow) is None, \
        "chain: now >= open+span must mean NO open window"
    _gspec = {"anchor": "chain", "span_s": 5 * 3600, "grid_offset_min": 217,
              "chain_lookback_s": _c_look}
    _g_spec = {"anchor": "grid", "span_s": 5 * 3600, "grid_offset_min": 217}
    _deg, _deg_reset = gometer.go_window_bounds(_gspec, _cnow, chain_fn=lambda s, lb: None)
    _gx, _gx_reset = gometer.go_window_bounds(_g_spec, _cnow)
    assert (_deg, _deg_reset) == (_gx, _gx_reset), \
        f"chain None-fallback must equal the grid default: {(_deg, _deg_reset)} != {(_gx, _gx_reset)}"
    _deg2, _deg2_reset = gometer.go_window_bounds(_gspec, _cnow)  # no chain_fn wired
    assert (_deg2, _deg2_reset) == (_gx, _gx_reset), \
        "chain without chain_fn must degrade to the grid default"
    # Restore the ledger — the chain cases above leave synthetic 2027 rows that would otherwise
    # pollute the real-time (2026) LEDGER integration windows below.
    _write("DELETE FROM go_usage", ())
    # LEDGER integration — the 7d anchored window (boundary Sunday 00:00 UTC, ALWAYS within
    # [now−7d, now], so the anchored floor is exactly the boundary): seed PRE-reset rows ($24 —
    # the false-latch sum that pushed platform Go-flash dispatches back to claude/haiku) and
    # POST-reset rows ($0.15). go_usage_window(7d, since=w7_start) must report ONLY $0.15.
    aw = time.time()
    w7_start, w7_next = gometer.go_window_bounds(spec7u, aw)
    assert w7_start <= aw < w7_next, (w7_start, aw, w7_next)
    go_usage_add(w7_start - 100, "pre7", "kimi-k3", 24.00)   # before the Sunday boundary
    go_usage_add(w7_start + 100, "post7", "kimi-k3", 0.15)   # after it
    w7 = go_usage_window(spec7u["span_s"], since=w7_start)
    # Expected from the anchor arithmetic: floor = max(now − 7d, w7_start) = w7_start, so only
    # rows with ts > w7_start count. pre7 (w7_start−100) is excluded; post7 (w7_start+100) is
    # included. 24.00 + 0.15 = 24.15 would be the WRONG pure-rolling answer; 0.15 is anchored.
    assert w7["by_stack"].get("pre7", 0) == 0, \
        f"anchored 7d must EXCLUDE pre-reset rows: {w7['by_stack']}"
    assert abs(w7["by_stack"].get("post7", 0) - 0.15) < 1e-9, \
        f"anchored 7d must count the post-reset row: {w7['by_stack']}"
    assert abs(w7["by_stack_draw"].get("post7", 0) - 0.15) < 1e-9, \
        f"anchored 7d draw must match (no usd_draw stored → falls back to usd): {w7['by_stack_draw']}"
    # The 30d window stays ROLLING when no anchor is applied (the conservative fallback): a pure
    # trailing 30d span covers both rows → 24.00 + 0.15 = 24.15.
    w30 = go_usage_window(30 * 86400)
    assert abs(w30["by_stack"].get("pre7", 0) - 24.00) < 1e-9, w30["by_stack"]
    assert abs(w30["by_stack"].get("post7", 0) - 0.15) < 1e-9, w30["by_stack"]
    # 30d DEFAULT is now MONTHLY-anchored. The monthly period can exceed the 30d span, so the
    # anchored floor is max(now−30d, m30_start) — place the rows either side of THAT floor
    # (deterministic for any point in the month), not around m30_start alone.
    m30_start, m30_next = gometer.go_window_bounds(spec30u, aw)
    assert m30_start <= aw < m30_next, (m30_start, aw, m30_next)
    m_floor = max(aw - spec30u["span_s"], m30_start)
    go_usage_add(m_floor - 60, "pre30", "kimi-k3", 24.00)
    go_usage_add(m_floor + 60, "post30", "kimi-k3", 0.15)
    w30a = go_usage_window(spec30u["span_s"], since=m30_start)
    assert w30a["by_stack"].get("pre30", 0) == 0, \
        f"monthly-anchored 30d must EXCLUDE pre-floor rows: {w30a['by_stack']}"
    assert abs(w30a["by_stack"].get("post30", 0) - 0.15) < 1e-9, \
        f"monthly-anchored 30d must count the post-floor row: {w30a['by_stack']}"
    # 5h DEFAULT is grid-anchored (daily 03:37/08:37/13:37/18:37/23:37 UTC, offset 217m). The
    # grid boundary is always within [now−5h, now], so the floor is exactly the boundary.
    g5_start, g5_next = gometer.go_window_bounds(spec5u, aw)
    assert g5_start <= aw < g5_next, (g5_start, aw, g5_next)
    go_usage_add(g5_start - 60, "pre5", "kimi-k3", 24.00)     # before the current 5h slot
    go_usage_add(g5_start + 60, "post5", "kimi-k3", 0.15)     # after it
    w5a = go_usage_window(spec5u["span_s"], since=g5_start)
    assert w5a["by_stack"].get("pre5", 0) == 0, \
        f"grid-anchored 5h must EXCLUDE pre-slot rows: {w5a['by_stack']}"
    assert abs(w5a["by_stack"].get("post5", 0) - 0.15) < 1e-9, \
        f"grid-anchored 5h must count the post-slot row: {w5a['by_stack']}"
    # Deterministic `since`-floor proof (the assertion that FAILS against the pre-anchor code,
    # which had no `since` param — and would read 3.00 if `since` were silently ignored):
    go_usage_add(aw - 100, "floor-pre", "kimi-k3", 1.00)
    go_usage_add(aw - 50, "floor-post", "kimi-k3", 2.00)
    wf = go_usage_window(300, since=aw - 60)   # floor = max(now−300, aw−60) = aw−60
    assert wf["by_stack"].get("floor-pre", 0) == 0, "since floor must exclude rows older than it"
    assert abs(wf["by_stack"].get("floor-post", 0) - 2.00) < 1e-9, wf["by_stack"]
    wr = go_usage_window(300)                  # rolling: both rows within 300s
    assert abs(wr["by_stack"].get("floor-pre", 0) - 1.00) < 1e-9, wr["by_stack"]
    assert abs(wr["by_stack"].get("floor-post", 0) - 2.00) < 1e-9, wr["by_stack"]
    # A garbage GO_WINDOW_ANCHORS falls back LOUDLY to that window's default — never a crash,
    # never a partial/guessed spec (one gometer stderr log line per unparseable chunk).
    _gd = gometer.apply_anchor_overrides
    ok = _gd("5h=grid:999m,7d=weekly:mon:09:30,30d=monthly:05:06:07")
    assert ok["5h"]["grid_offset_min"] == 999 and ok["5h"]["anchor"] == "grid", ok["5h"]
    assert ok["7d"]["weekday"] == "mon" and ok["7d"]["hour"] == 9 and ok["7d"]["minute"] == 30, ok["7d"]
    assert ok["30d"]["month_day"] == 5 and ok["30d"]["hour"] == 6 and ok["30d"]["minute"] == 7, ok["30d"]
    g2 = _gd("5h=boom,7d=weekly:nope,30d=")     # every spec unparseable → defaults
    assert g2 == gometer._GO_WINDOW_DEFAULTS, (g2, gometer._GO_WINDOW_DEFAULTS)
    # ── addendum 4: the 429→cooldown→recovery loop + route() scenarios ──
    # Goal #1640 acceptance 3: the price callback now takes the providers to EXCLUDE and returns
    # the provider the model lands on (the CELL), so /route can price post-exclusion. The base
    # fixture has no provider dimension (provider=None) — the strike rows below supply one.
    _BASE_PRICES = {"tencent/hy3": (0.041, "market"),
                    "deepseek/deepseek-v4-flash": (0.033, "market")}
    CTX = {
        "price": lambda m, exclude=frozenset(): (0.0, "free", None) if m.endswith(":free")
                 else (*_BASE_PRICES.get(m, (None, None)), None),
        "subscription_ok": lambda tier: (True, None, 0),
        "openrouter_ok": lambda ref: (True, None),
        # Goal #1769 acceptance 1: the Go rail's own gate, beside the other two. Open by default
        # here; the rows below close it and assert the Go reason.
        "opencode_ok": lambda: (True, None, 0),
        "pick": lambda band: band[0],  # deterministic for the test
    }
    CHAIN = ["inclusionai/ling-3.0-flash:free", "deepseek/deepseek-v4-flash", "tencent/hy3",
             "claude/haiku"]
    base = {"stack": "sleep", "task": "issue-42", "role": "worker", "session": "t-route",
            "chain": CHAIN}
    # The LIVE model-classes.json carries provider_policy: exacto on coding (2026-09-13 flip).
    # The routing-mechanics rows below assert bare model ids; the policy rows ((a)/(b)/(c) under
    # "FU-186 step 1") set the policy explicitly on a copy — so the baseline here is policy-free.
    _classes["classes"]["coding"].pop("provider_policy", None)
    d = route(dict(base), CTX)
    assert d["decision"] == "dispatch" and d["model"] == "inclusionai/ling-3.0-flash:free", d
    assert d["rail"] == "openrouter" and d["class"] == "coding", d
    # FU-127: the structured carrier — shape AND string↔structured parity for each rail prefix.
    # openrouter rail, bare vendor/model (the common case)
    assert d.get("resolved") == {"rail": "openrouter", "harness": "", "model": "inclusionai/ling-3.0-flash:free"}, \
        f"resolved shape (openrouter bare): {d.get('resolved')}"
    # subscription rail: claude/ prefix → anthropic-subscription, harness claude
    _sub = route(dict(base, chain=["claude/haiku"]), CTX)
    assert _sub["decision"] == "dispatch" and _sub["rail"] == "anthropic-subscription", _sub
    assert _sub.get("resolved") == {"rail": "anthropic-subscription", "harness": "claude", "model": "haiku"}, \
        f"resolved shape (subscription): {_sub.get('resolved')}"
    # opencode-go rail: the walk parses a THIRD rail value now (Goal #1769 acceptance 1). A class
    # whose `rails` does not name it skips the candidate BY RAIL — typed and visible, never
    # silently flattened onto OpenRouter (which is what the two-way split did, and why a Go
    # candidate used to be gated by the OpenRouter KEY's state).
    _go_noclass = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), CTX)
    assert _go_noclass["decision"] == "defer" and _go_noclass["reason"] == "chain-exhausted", \
        _go_noclass
    assert {"model": "opencode-go/deepseek-v4-flash",
            "reason": "rail-opencode-go-not-in-class-coding"} in _go_noclass["skipped"], \
        _go_noclass["skipped"]
    # ── Goal #1769 acceptance 1: THREE-WAY RAIL, from model_id.parse(), at the walk ──
    # The walk derived the rail with a two-way split before this
    # (`"subscription" if m.startswith("claude/") else "openrouter"`), so `opencode-go/*`
    # classified as OpenRouter and was gated by the OpenRouter key's state instead of the Go
    # rail's own capacity. Every rail value below is one model_id.parse() produced, and a decision
    # row echoes the CANONICAL name — the same vocabulary `resolved.rail` uses.
    _saved_rails = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["opencode-go", "openrouter"]
    _go = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), CTX)
    assert _go["decision"] == "dispatch" and _go["rail"] == "opencode-go", _go
    assert _go["model"] == "opencode-go/deepseek-v4-flash" and _go["basis"] == "opencode-go", _go
    assert _go["price_per_mtok"] is None, "a subscription-rail pick carries no per-token price"
    assert _go.get("resolved") == {"rail": "opencode-go", "harness": "claude",
                                   "model": "opencode-go/deepseek-v4-flash"}, \
        f"resolved shape (opencode-go): {_go.get('resolved')}"
    assert _go["rail"] == _go["resolved"]["rail"], \
        "decision.rail and resolved.rail are ONE vocabulary now (acceptance 1)"
    # Go gate CLOSED ⇒ the Go candidate is skipped with a GO reason, and an OpenRouter sibling
    # still serves: a Go outage is never an OpenRouter-key verdict, and it never takes the
    # OpenRouter rail down with it.
    _go_closed = {**CTX, "opencode_ok": lambda: (False, "observed-429", 900)}
    _go_lim = route(dict(base, chain=["opencode-go/deepseek-v4-flash", "tencent/hy3"]),
                    _go_closed)
    assert _go_lim["decision"] == "dispatch" and _go_lim["rail"] == "openrouter", _go_lim
    assert _go_lim["model"] == "tencent/hy3", _go_lim
    assert {"model": "opencode-go/deepseek-v4-flash", "reason": "go:observed-429"} \
        in _go_lim["skipped"], _go_lim["skipped"]
    assert not any(str(s.get("reason", "")).startswith("openrouter") for s in _go_lim["skipped"]), \
        f"a Go candidate must never be skipped for an OpenRouter reason: {_go_lim['skipped']}"
    # …and with ONLY the Go candidate the defer is typed with the Go reason AND its retry_after
    # (the capacity-class defer shape: retryable, not the escalating chain-exhausted).
    _go_def = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), _go_closed)
    assert _go_def["decision"] == "defer" and _go_def["reason"] == "go:observed-429", _go_def
    assert _go_def["retry_after_s"] == 900, _go_def
    assert _go_def.get("resolved") is None, "defer carries no resolved model"
    # …and the SHADOW ladder reads the same gate: the Go rung is blocked with the Go reason,
    # never priced as if the rail were open (the two halves of the walk cannot disagree about
    # whether the Go rail is up).
    _go_shadow = next(c for c in _go_def["shadow"]["candidates"] if c["rail"] == "opencode-go")
    assert _go_shadow["blocked"] == "go:observed-429", _go_shadow
    # …and the OpenRouter KEY's state is NOT consulted for a Go candidate: an exhausted
    # OpenRouter budget leaves the Go rail serving (the inverse of the pre-fix behaviour, where
    # exactly this input decided the Go candidate's fate).
    _or_closed = {**CTX, "openrouter_ok": lambda ref: (False, "openrouter-budget-exhausted")}
    _go_or = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), _or_closed)
    assert _go_or["decision"] == "dispatch" and _go_or["rail"] == "opencode-go", _go_or
    # the walk's OWN vocabulary is the parser's: every rail a class may name is one the parser
    # produces (or the one declared member no parse rule produces yet — the parked Zen leg)
    assert _classes["classes"]["coding"]["rails"] == ["opencode-go", "openrouter"]
    _classes["classes"]["coding"]["rails"] = _saved_rails
    # the THREE-WAY parse itself, per candidate class — the rule this block reads, not re-states
    for _mid, _want in (("claude/haiku", "anthropic-subscription"),
                        ("opencode-go/deepseek-v4-flash", "opencode-go"),
                        ("deepseek/deepseek-v4-flash", "openrouter"),
                        ("openrouter/owl-alpha", "openrouter")):
        assert model_id.parse(_mid)["rail"] == _want, (_mid, model_id.parse(_mid))
    # ── the ONE-RELEASE alias (acceptance 1): the OLD rail name still loads ──
    # `subscription` meant the Anthropic rail before the canonical vocabulary; a class file still
    # spelling it must resolve to the canonical name (and the decision row must echo the CANONICAL
    # one), not to an empty pool that silently never serves.
    assert _alias_rails() == 0, \
        "the shipped model-classes.json is already canonical — the alias must be a no-op there"
    _classes["classes"]["coding"]["rails"] = ["subscription"]
    assert _alias_rails() == 1, "the old `subscription` rail name must alias, once"
    assert _classes["classes"]["coding"]["rails"] == ["anthropic-subscription"], \
        _classes["classes"]["coding"]["rails"]
    _alias_route = route(dict(base, chain=["claude/haiku"]), CTX)
    assert _alias_route["decision"] == "dispatch" \
        and _alias_route["rail"] == "anthropic-subscription", _alias_route
    # idempotent: a second load of the same file changes nothing and logs nothing
    assert _alias_rails() == 0, "the alias is idempotent — a canonical list is left alone"
    _classes["classes"]["coding"]["rails"] = _saved_rails
    # cloaked openrouter/<codename>: prefix KEPT, model is the full id
    _cloak = route(dict(base, chain=["openrouter/owl-alpha"]), CTX)
    assert _cloak["decision"] == "dispatch" and _cloak["rail"] == "openrouter", _cloak
    assert _cloak.get("resolved") == {"rail": "openrouter", "harness": "", "model": "openrouter/owl-alpha"}, \
        f"resolved shape (cloaked): {_cloak.get('resolved')}"
    # defer decision has NO resolved field
    _def = route(dict(base, chain=["deepseek/deepseek-v4-flash"],
                      deny=["deepseek/deepseek-v4-flash"]), CTX)
    assert _def["decision"] == "defer" and _def.get("resolved") is None, \
        f"defer must not carry resolved: {_def.get('resolved')}"
    # ── FU-186 step 1: provider_policy knob — exacto skips pin injection ──
    # (a) A class WITHOUT provider_policy (audit — role "retro" in role_defaults; "audit" is a
    #     class name, not a role, and an unknown role defaults to coding, which made this row
    #     vacuous until the coding flip exposed it) serving openrouter/fusion is pin-preserving
    #     (no :exacto suffix, no provider_policy key).
    _audit = route(dict(base, role="retro", chain=["openrouter/fusion"]), CTX)
    assert _audit["class"] == "audit", f"retro role must resolve the audit class: {_audit}"
    assert _audit["decision"] == "dispatch" and _audit["model"] == "openrouter/fusion", \
        f"audit route must serve openrouter/fusion without :exacto: {_audit}"
    assert _audit.get("provider_policy") is None, \
        f"audit class has no provider_policy: {_audit}"
    # (b) A class that DOES carry provider_policy: "exacto" appends :exacto to a PAID OpenRouter
    #     pick and echoes the policy — and leaves a :free pick and a subscription pick BARE
    #     (a :free model has no pin to skip; claude/* is not an OpenRouter id). Live since the
    #     coding class carries the policy (2026-09-13).
    _saved_classes = copy.deepcopy(_classes)
    _classes["classes"]["coding"]["provider_policy"] = "exacto"
    _exacto = route(dict(base, chain=["deepseek/deepseek-v4-flash"]), CTX)  # role=worker → coding
    assert _exacto["decision"] == "dispatch" and _exacto["model"] == "deepseek/deepseek-v4-flash:exacto", \
        f"coding with provider_policy=exacto must append :exacto to a paid pick: {_exacto}"
    assert _exacto.get("provider_policy") == "exacto", \
        f"decision must echo provider_policy: {_exacto}"
    _exacto_free = route(dict(base), CTX)  # chain head is the :free model
    assert _exacto_free["model"] == "inclusionai/ling-3.0-flash:free", \
        f":free pick must stay bare under exacto (no pin to skip): {_exacto_free}"
    _exacto_sub = route(dict(base, chain=["claude/haiku"]), CTX)
    assert _exacto_sub["decision"] == "dispatch" and _exacto_sub["model"] == "claude/haiku", \
        f"subscription pick must stay bare under exacto: {_exacto_sub}"
    # (b2) homelab#1693: the append is IDEMPOTENT. The platform claim's `workerModel` is
    #      `deepseek/deepseek-v4.1-flash:exacto` (verified 2026-09-14), so a chain entry that
    #      ALREADY carries the suffix must route to a SINGLE-suffixed id — never
    #      `…:exacto:exacto` (the doubled id observed live on the PR#1685 ride's launcher line,
    #      inert only while the claim is `routerMode: shadow`; Goal #1640 acceptance 6 flips it
    #      to `authoritative`, where the doubled id reaches OpenRouter). Non-vacuous: without the
    #      guard this row reads `deepseek/deepseek-v4.1-flash:exacto:exacto` and goes RED.
    _pre = route(dict(base, chain=["deepseek/deepseek-v4.1-flash:exacto"]), CTX)
    assert _pre["decision"] == "dispatch" and \
        _pre["model"] == "deepseek/deepseek-v4.1-flash:exacto", \
        f"a pre-suffixed chain entry must stay single-suffixed under exacto: {_pre}"
    # …and the bookkeeping path keys it under the BARE id: record_provider_event strips ONE
    # :exacto (router.py:521), which lands on the bare id only because the guard above kept the
    # id single-suffixed. A doubled id would key cooldowns under `…flash:exacto`.
    for _ in range(8):
        record_provider_event(_pre["model"], "novita", 429)
    assert cooldown_note("deepseek/deepseek-v4.1-flash", 429, role="worker") == "tripped", \
        "a pre-suffixed entry's cooldown must key under the bare id"
    assert "deepseek/deepseek-v4.1-flash" in active_cooldowns(role="worker"), \
        "bare id must be in active_cooldowns for a pre-suffixed entry"
    assert "deepseek/deepseek-v4.1-flash:exacto" not in active_cooldowns(role="worker"), \
        "the single-suffixed id must NOT be a cooldown key"
    for _ in range(8):
        record_provider_event("deepseek/deepseek-v4.1-flash", "novita", 200)
    assert cooldown_note("deepseek/deepseek-v4.1-flash", 200, role="worker") == "cleared", \
        "cooldown must clear for the bare id"
    _classes.clear()
    _classes.update(copy.deepcopy(_saved_classes))
    # (c) NON-VACUOUS: cooldown/breaker bookkeeping under the BARE id, not the :exacto-suffixed id.
    #     This assertion goes RED against the pre-fix source (where or_model kept the suffix) and
    #     GREEN after the fix (openrouter-proxy.py strips :exacto from the bookkeeping key).
    _classes["classes"]["coding"]["provider_policy"] = "exacto"
    _exacto2 = route(dict(base, chain=["deepseek/deepseek-v4-flash"]), CTX)
    _exacto_model = _exacto2["model"]  # "deepseek/deepseek-v4-flash:exacto"
    # The expectation is a LITERAL, not a re-derivation through the production strip: the point of
    # this assertion is that the bookkeeping key is the bare chain id, and computing it with the
    # same function under test would make the pin vacuous (homelab#1697).
    _bare_model = "deepseek/deepseek-v4-flash"
    assert _bare_model != _exacto_model, f"paid pick must carry :exacto here: {_exacto2}"
    # Trip a cooldown using the model as it arrives on the completion path (suffixed).
    for _ in range(8):
        record_provider_event(_exacto_model, "novita", 429)
    # The cooldown must be keyed under the BARE id — the same id the /route eligibility loop
    # filters candidates against. The suffixed id must NOT appear in active_cooldowns.
    assert cooldown_note(_bare_model, 429, role="worker") == "tripped", \
        f"cooldown must be keyed under bare id {_bare_model}, not suffixed {_exacto_model}"
    assert _bare_model in active_cooldowns(role="worker"), \
        f"bare model {_bare_model} must be in active_cooldowns"
    assert _exacto_model not in active_cooldowns(role="worker"), \
        f"suffixed model {_exacto_model} must NOT be in active_cooldowns"
    # Clear the cooldown so it doesn't pollute subsequent tests.
    for _ in range(8):
        record_provider_event(_bare_model, "novita", 200)
    assert cooldown_note(_bare_model, 200, role="worker") == "cleared", \
        f"cooldown must clear for {_bare_model}"
    _classes.clear()
    _classes.update(copy.deepcopy(_saved_classes))
    # free model starts 429ing: burst past min_events/bad_share trips a cooldown
    for _ in range(8):
        record_provider_event("inclusionai/ling-3.0-flash:free", "novita", 429)
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 429, role="worker") == "tripped"
    assert "inclusionai/ling-3.0-flash:free" in active_cooldowns(role="worker")
    d2 = route(dict(base), CTX)
    assert d2["decision"] == "dispatch" and d2["model"] == "deepseek/deepseek-v4-flash", d2
    assert any(s["reason"] == "cooldown:429-burst" for s in d2["skipped"]), d2["skipped"]
    # the hold expires ("the model comes back online") → half-open: cheapest wins again
    assert _write("UPDATE model_cooldowns SET until=? WHERE model=? AND role='worker'",
                  (time.time() - 1, "inclusionai/ling-3.0-flash:free"))
    d3 = route(dict(base), CTX)
    assert d3["decision"] == "dispatch" and d3["model"] == "inclusionai/ling-3.0-flash:free", d3
    assert d3["half_open"], "an expired-cooldown pick must be flagged half-open"
    # a 2xx clears the row + streak; a re-trip would have doubled the hold before that
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 200, role="worker") == "cleared"
    # ── homelab#1042: role-scoped cooldowns — probe-class sessions never latch the fixer lanes' state ──
    # Trip a cooldown with role="probe" — a worker route() must NOT see it.
    for _ in range(8):
        record_provider_event("inclusionai/ling-3.0-flash:free", "novita", 429)
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 429, role="probe") == "tripped"
    assert "inclusionai/ling-3.0-flash:free" in active_cooldowns(role="probe"), \
        "probe-scoped cooldown must be visible to probe role"
    assert "inclusionai/ling-3.0-flash:free" not in active_cooldowns(role="worker"), \
        "probe-scoped cooldown must NOT be visible to worker role"
    # A worker route() must still see the model as available (no worker-scoped cooldown)
    d_probe_cool = route(dict(base), CTX)
    assert d_probe_cool["decision"] == "dispatch" and d_probe_cool["model"] == "inclusionai/ling-3.0-flash:free", \
        f"worker route must dispatch the free model despite probe cooldown: {d_probe_cool}"
    # A probe route() must see the model as unavailable (probe-scoped cooldown active)
    d_probe_route = route(dict(base, role="probe"), CTX)
    assert d_probe_route["decision"] == "dispatch" and d_probe_route["model"] == "deepseek/deepseek-v4-flash", \
        f"probe route must skip the free model due to probe-scoped cooldown: {d_probe_route}"
    assert any(s["reason"] == "cooldown:429-burst" for s in d_probe_route["skipped"]), \
        f"probe route must cite cooldown in skipped: {d_probe_route['skipped']}"
    # Clean up: clear the probe-scoped cooldown
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 200, role="probe") == "cleared"
    assert "inclusionai/ling-3.0-flash:free" not in active_cooldowns(role="probe"), \
        "probe-scoped cooldown must be cleared by 2xx"
    assert not _read("SELECT 1 FROM model_cooldowns WHERE model='inclusionai/ling-3.0-flash:free'")
    # claim deny + strike filtering → chain-exhausted escalates; cooldown-only defer retries
    dd = route(dict(base, chain=["deepseek/deepseek-v4-flash"],
                    deny=["deepseek/deepseek-v4-flash"]), CTX)
    assert dd["decision"] == "defer" and dd["reason"] == "chain-exhausted", dd
    # ── Goal #1640 acceptance 3: strikes enforced per task, cell pricing post-exclusion ──
    # A serving-shaped strike excludes the (model, provider) PAIR, not the model: the model is
    # re-priced by the provider it lands on AFTER the exclusion. Here deepseek-v4-flash's default
    # provider (open-inference) is struck; at its next provider (deepinfra) it costs $0.05/M,
    # MORE than tencent/hy3 at novita ($0.03/M) — so the next-cheapest CELL is hy3, and the row
    # shows the struck pair skipped and hy3 picked with the price that won. This is the issue's
    # "the same model at another provider may cost more than another model" case.
    _CELLS = {
        "deepseek/deepseek-v4-flash": [("open-inference", 0.01), ("deepinfra", 0.05)],
        "tencent/hy3": [("novita", 0.03)],
    }

    def _cell_price(m, exclude=frozenset()):
        for _prov, _price in _CELLS.get(m, []):
            if _prov not in exclude:
                return _price, "market", _prov
        return None, None, None

    _CELL_CTX = {**CTX, "price": _cell_price}
    _PAIR_CHAIN = ["deepseek/deepseek-v4-flash", "tencent/hy3"]
    # (1) serving-shaped strike on the PAIR (deepseek-v4-flash, open-inference): the model is NOT
    #     excluded — it is re-priced at deepinfra ($0.05) and LOSES to hy3 ($0.03). The row shows
    #     the struck pair skipped and the next-cheapest CELL picked.
    record_report({"session": "t-strike-pair-1", "task": "issue-80", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "provider-5xx",
                   "outcome": "no-output"})
    _sp = route({"stack": "sleep", "task": "issue-80", "role": "worker",
                 "session": "t-strike-pair-1", "chain": _PAIR_CHAIN}, _CELL_CTX)
    assert _sp["decision"] == "dispatch" and _sp["model"] == "tencent/hy3", _sp
    assert _sp["provider"] == "novita" and _sp["price_per_mtok"] == 0.03, _sp
    assert {"model": "deepseek/deepseek-v4-flash", "provider": "open-inference",
            "reason": "strike"} in _sp["skipped"], _sp["skipped"]
    assert not any(s["reason"] == "strike" and s.get("provider") is None
                   for s in _sp["skipped"]), \
        f"a single-provider serving strike must NOT exclude the model: {_sp['skipped']}"
    # …and the SHADOW ladder prices the same post-exclusion CELL (it must not log a divergence
    # the served walk never had): deepseek-v4-flash's shadow candidate is $0.05 at deepinfra.
    _sp_shadow_ds = next(c for c in _sp["shadow"]["candidates"]
                         if c["model"] == "deepseek/deepseek-v4-flash")
    assert _sp_shadow_ds["price_per_mtok"] == 0.05, _sp_shadow_ds
    # (2) the SAME model is re-priced by the provider it lands on AFTER the exclusion: strike
    #     deepseek-v4-flash's default (open-inference) and it is picked at deepinfra — the row's
    #     price is the CELL's ($0.05), not the model's default ($0.01 at the struck provider).
    record_report({"session": "t-strike-pair-2", "task": "issue-81", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "timeout",
                   "outcome": "no-output"})
    _sp2 = route({"stack": "sleep", "task": "issue-81", "role": "worker",
                  "session": "t-strike-pair-2", "chain": ["deepseek/deepseek-v4-flash"]}, _CELL_CTX)
    assert _sp2["decision"] == "dispatch" and _sp2["model"] == "deepseek/deepseek-v4-flash", _sp2
    assert _sp2["provider"] == "deepinfra" and _sp2["price_per_mtok"] == 0.05, _sp2
    assert {"model": "deepseek/deepseek-v4-flash", "provider": "open-inference",
            "reason": "strike"} in _sp2["skipped"], _sp2["skipped"]
    # (3) a model struck at TWO providers is excluded at MODEL level (the #783 rule): the skipped
    #     row carries no provider, and the model is not a candidate at all.
    record_report({"session": "t-strike-pair-3a", "task": "issue-82", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "provider-5xx",
                   "outcome": "no-output"})
    record_report({"session": "t-strike-pair-3b", "task": "issue-82", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "deepinfra", "error_class": "provider-5xx",
                   "outcome": "no-output"})
    _sp3 = route({"stack": "sleep", "task": "issue-82", "role": "worker",
                  "session": "t-strike-pair-3", "chain": _PAIR_CHAIN}, _CELL_CTX)
    assert _sp3["decision"] == "dispatch" and _sp3["model"] == "tencent/hy3", _sp3
    assert {"model": "deepseek/deepseek-v4-flash", "reason": "strike"} in _sp3["skipped"], \
        _sp3["skipped"]
    # (4) a NON-serving class excludes the model on ONE strike (no pair dimension)
    record_report({"session": "t-strike-model-1", "task": "issue-83", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "no-pr",
                   "outcome": "no-output"})
    _sm = route({"stack": "sleep", "task": "issue-83", "role": "worker",
                 "session": "t-strike-model-1", "chain": _PAIR_CHAIN}, _CELL_CTX)
    assert _sm["decision"] == "dispatch" and _sm["model"] == "tencent/hy3", _sm
    assert {"model": "deepseek/deepseek-v4-flash", "reason": "strike"} in _sm["skipped"], \
        _sm["skipped"]
    # Goal #1640 acceptance 5: fixtures (1)-(3) struck (deepseek-v4-flash, open-inference) from
    # three distinct tasks with serving classes, which trips the PAIR cooldown. The tests between
    # here and fixture (5) are about OTHER mechanisms (capability floors, rotation), so refute the
    # cooldown with a clean ride — the same explicit-cleanup pattern the fixtures above use. The
    # pair cooldown's own assertions live after fixture (7), where the fixtures re-trip it.
    record_report({"session": "t-pc-clean-early", "task": "issue-91", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "outcome": "pr"})
    assert ("deepseek/deepseek-v4-flash", "open-inference") not in pair_cooldowns()
    # subscription-limited defers with retry_after when only claude/* remains
    lim = {**CTX, "subscription_ok": lambda tier: (False, "utilization-5h", 1200)}
    ds = route(dict(base, chain=["claude/haiku"]), lim)
    assert ds == {**ds, "decision": "defer", "reason": "utilization-5h"} and \
        ds["retry_after_s"] == 1200, ds
    # label-driven class override: task/research → research class (reasoning tier, openrouter rail)
    dr = route(dict(base, labels=["track/iac"], chain=CHAIN), CTX)
    assert dr["class"] == "coding", dr
    # rotation-fed candidates when NO chain is passed (P5): universe ∩ rankings, broken excluded
    record_rotation("openrouter-daily-rankings",
                    [{"model": "tencent/hy3", "rank": 1},
                     {"model": "not-in-tiers/mystery", "rank": 2}])
    record_rotation("provider-events",
                    [{"model": "poolside/laguna-s-2.1:free", "canary_verdict": "broken"}])
    dv = route(dict(base, chain=[]), {**CTX, "price": lambda m, exclude=frozenset(): (0.05, "market", None)})
    assert dv["decision"] == "dispatch" and dv["source"] == "rotation", dv
    # homelab#1783: `coding` now carries a chain_head (v4-flash → v4.1-flash), and
    # _rotation_candidates puts the head AHEAD of the ranked rotation — that IS the class's
    # ordering policy on a chainless stack, so the old `tencent/hy3` (rank 1) expectation is
    # deliberately repinned. The ranked rotation still FEEDS (hy3 is in the pool) and both the
    # broken canary and the ungraded model are still excluded, which is what this fixture is for.
    assert dv["model"] == "deepseek/deepseek-v4-flash", dv
    assert dv["jitter_pool"] == ["deepseek/deepseek-v4-flash",
                                 "deepseek/deepseek-v4.1-flash", "tencent/hy3"], dv
    # homelab#1786: the broken-canary exclusion applies to the chain_head leg too — a head is a
    # model like any other, and a broken canary is exactly the evidence the head ordering yields
    # to (Goal #1640 acceptance 3: the exclusion surface). Mark the coding head's FIRST entry
    # broken and the head leg must skip it, falling to the NEXT head — membership only, the head
    # ORDER is untouched (v4.1-flash still precedes the ranked rotation). This is the fixture the
    # pre-fix source fails: it fed only the ranked and fallback legs, so the head leg's missing
    # exclusion stayed green.
    record_rotation("provider-events",
                    [{"model": "deepseek/deepseek-v4-flash", "canary_verdict": "broken"}])
    db = route(dict(base, chain=[]),
               {**CTX, "price": lambda m, exclude=frozenset(): (0.05, "market", None)})
    assert db["decision"] == "dispatch" and db["source"] == "rotation", db
    assert db["model"] == "deepseek/deepseek-v4.1-flash", db
    assert db["jitter_pool"] == ["deepseek/deepseek-v4.1-flash", "tencent/hy3"], db
    # …and it is ONE rule for every chain_head class, not a per-class knob: the same broken verdict
    # removes a head from the review class (claude/sonnet) too.
    record_rotation("provider-events",
                    [{"model": "claude/sonnet", "canary_verdict": "broken"}])
    _rc = _rotation_candidates({"chain_head": ["claude/sonnet"], "reasoning": True})
    assert "claude/sonnet" not in _rc, _rc
    # cleanup: clear both broken verdicts so later fixtures see the unbroken rotation
    record_rotation("provider-events",
                    [{"model": "deepseek/deepseek-v4-flash", "canary_verdict": ""},
                     {"model": "claude/sonnet", "canary_verdict": ""}])
    # ── Goal #1769 acceptance 4 (router half): CALLER CAPABILITY in the rail walk ──
    # The 2026-08-26 world, REPLAYED (docs/incidents/2026-08-26-reviewer-404-loop.md). The
    # reviewer sends NO chain — candidates come from the class's chain_head + the rotation, which
    # is OpenRouter-ids-only (`tencent/hy3` here, exactly the shape that served dead) — and NO
    # OpenRouter `key_ref`, by design. `review`'s second rail entry then served a dead OpenRouter
    # pick with the account perfectly healthy: the gate asked "can the ACCOUNT buy", never "can
    # the CALLER ride". With the caller's `surface` now declared, the openrouter candidates are
    # skipped for the missing credential and the subscription candidate serves.
    _review_caller = {"stack": "oracle", "task": "issue-188", "role": "reviewer",
                      "session": "t-caller-review", "class": "review", "chain": [],
                      "surface": "claude-cli"}
    _cr = route(dict(_review_caller), CTX)      # OpenRouter account HEALTHY: CTX's or_gate is open
    assert _cr["decision"] == "dispatch", _cr
    assert _cr["rail"] == "anthropic-subscription" and _cr["model"] == "claude/sonnet", _cr
    assert {"model": "tencent/hy3", "reason": "caller:no-key_ref"} in _cr["skipped"], \
        f"the openrouter candidate must be skipped for the missing credential: {_cr['skipped']}"
    assert not any(s.get("model") == "claude/sonnet" and str(s.get("reason", "")).startswith("caller:")
                   for s in _cr["skipped"]), \
        f"the subscription candidate rides a claude-cli caller: {_cr['skipped']}"
    # …and the CALLER facts ride the decision row itself (acceptance 4's status half).
    assert _cr["caller"] == {"surface": "claude-cli", "key_ref": ""}, _cr.get("caller")
    assert _read("SELECT surface, key_ref FROM decisions WHERE session='t-caller-review'") \
        == [("claude-cli", "")], "the caller facts must land on the stored decision row"
    # THE SHADOW LADDER READS THE SAME ELIGIBLE SET: the unrideable rail is absent from it, so a
    # defer can never be handed an openrouter model as its shadow pick (the FU-188 shape).
    assert _cr["shadow"]["decision"] == "dispatch", _cr["shadow"]
    assert all(model_id.parse(c["model"])["rail"] != "openrouter"
               for c in _cr["shadow"]["candidates"]), \
        f"an unrideable rail must be absent from the shadow ladder too: {_cr['shadow']['candidates']}"
    # …and the openrouter rail is not even PROBED: the capability skip precedes the capacity gate,
    # so a healthy account's gate is never consulted for a caller that cannot ride the rail.
    _rev_probes: list = []
    _rev_ctx = {**CTX, "openrouter_ok": lambda ref: (_rev_probes.append(ref), (True, None))[1]}
    _cr_p = route(dict(_review_caller, session="t-caller-review-probe"), _rev_ctx)
    assert _cr_p["rail"] == "anthropic-subscription" and not _rev_probes, \
        f"a caller-unrideable rail must not consume a probe (calls={_rev_probes})"
    # The SAME body WITH a credential ⇒ the openrouter rail is rideable again (no caller skip).
    _cr2 = route(dict(_review_caller, session="t-caller-review-key",
                      key_ref="sleep-agents/sleep-openrouter"), CTX)
    assert not any(str(s.get("reason", "")).startswith("caller:") for s in _cr2["skipped"]), \
        f"a caller that sends the credential must not be capability-skipped: {_cr2['skipped']}"
    # NO REGRESSION for a caller that has not adopted the field: `key_ref` alone (no `surface`)
    # walks the openrouter rail exactly as the fact-less body does — byte-identical pick and rail.
    _with_key = route(dict(base, key_ref="sleep-agents/sleep-openrouter"), CTX)
    assert _with_key["model"] == d["model"] and _with_key["rail"] == d["rail"], \
        f"a key_ref-only body must walk as before this change: {_with_key} vs {d}"
    assert not any(str(s.get("reason", "")).startswith("caller:")
                   for s in _with_key["skipped"]), _with_key["skipped"]
    # The SURFACE mismatch: a caller that can only execute the OpenAI-compatible API can ride
    # NEITHER CLI rail — every claude/* and Go candidate is skipped `caller:surface` (and, with no
    # credential, the openrouter rail for its own missing fact).
    _saved_rails2 = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["opencode-go", "anthropic-subscription", "openrouter"]
    _api = route(dict(base, session="t-caller-surface",
                      chain=["claude/haiku", "opencode-go/deepseek-v4-flash"],
                      surface="openai-api"), CTX)
    for _mid in ("claude/haiku", "opencode-go/deepseek-v4-flash"):
        assert {"model": _mid, "reason": "caller:surface"} in _api["skipped"], \
            f"{_mid} must be skipped on the surface mismatch: {_api['skipped']}"
    assert _api["decision"] == "defer", _api
    _classes["classes"]["coding"]["rails"] = _saved_rails2
    # …and with ONLY an openrouter candidate, the capability skip still precedes the gate: the
    # walk defers WITHOUT the OpenRouter gate having been consulted.
    _or_calls: list = []
    _nc = route(dict(base, session="t-caller-nogate", chain=["deepseek/deepseek-v4-flash"],
                     surface="openai-api"),
                {**CTX, "openrouter_ok": lambda ref: (_or_calls.append(ref), (True, None))[1]})
    assert {"model": "deepseek/deepseek-v4-flash", "reason": "caller:no-key_ref"} \
        in _nc["skipped"], _nc["skipped"]
    assert _nc["decision"] == "defer" and not _or_calls, \
        f"capability is decided BEFORE capacity (OpenRouter gate calls={_or_calls})"
    # The requirement table is per-rail and complete: every canonical rail declares its surfaces
    # in the `rails:` block (acceptance 2 externalized RAIL_SURFACE), and openrouter's requirement
    # is the CREDENTIAL (its own key_ref test), never a surface — so its declared surfaces cover
    # every caller surface.
    for _r in RAILS:
        assert rail_surfaces(_r), f"rail {_r} must declare surfaces in the `rails:` block"
    assert set(rail_surfaces(model_id.RAIL_OPENROUTER)) >= {"claude-cli", "opencode-cli",
                                                             "openai-api"}, \
        rail_surfaces(model_id.RAIL_OPENROUTER)
    # …and /router-status carries the caller facts on its decision rows.
    assert any(r.get("surface") == "claude-cli" and r["rail"] == "anthropic-subscription"
               for r in status_summary()["decisions_24h"]), \
        "decision rows must carry the caller facts the route was decided on"
    # ── Goal #1769 acceptance 2: the `rails:` block is READ ──
    # (a) a rail declared `enabled: false` (Zen) is skipped `rail:disabled` — the GIT authority.
    # No parse rule produces the Zen rail yet (the `opencode/` prefix is the leg, homelab#445), so
    # the test injects a candidate at the PARSER seam; the walk itself is unmodified.
    _saved_rails_zen = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["opencode-zen", "openrouter"]
    _orig_parse = model_id.parse
    model_id.parse = lambda m: ({"rail": RAIL_OPENCODE_ZEN, "harness": "opencode", "model": m}
                                if m == "opencode/zen-probe" else _orig_parse(m))
    try:
        _zen = route(dict(base, session="t-zen-disabled", chain=["opencode/zen-probe"]), CTX)
    finally:
        model_id.parse = _orig_parse
    assert _zen["decision"] == "defer", _zen
    assert {"model": "opencode/zen-probe", "reason": "rail:disabled"} in _zen["skipped"], \
        _zen["skipped"]
    _classes["classes"]["coding"]["rails"] = _saved_rails_zen
    # (b) a rail parked by OPENCODE_RAIL_DISABLED is skipped `rail:parked` — the ENV authority —
    # and SERVED with it unset. The env is read at call time, so the toggle is the test's.
    _saved_rails_go2 = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["opencode-go", "openrouter"]
    _old_park = os.environ.get("OPENCODE_RAIL_DISABLED")
    try:
        os.environ["OPENCODE_RAIL_DISABLED"] = "go"
        _parked = route(dict(base, session="t-go-parked",
                             chain=["opencode-go/deepseek-v4-flash"]), CTX)
        assert _parked["decision"] == "defer", _parked
        assert {"model": "opencode-go/deepseek-v4-flash", "reason": "rail:parked"} \
            in _parked["skipped"], _parked["skipped"]
        os.environ.pop("OPENCODE_RAIL_DISABLED", None)
        _unparked = route(dict(base, session="t-go-unparked",
                               chain=["opencode-go/deepseek-v4-flash"]), CTX)
        assert _unparked["decision"] == "dispatch" and _unparked["rail"] == "opencode-go", _unparked
    finally:
        if _old_park is None:
            os.environ.pop("OPENCODE_RAIL_DISABLED", None)
        else:
            os.environ["OPENCODE_RAIL_DISABLED"] = _old_park
    _classes["classes"]["coding"]["rails"] = _saved_rails_go2
    # (c) a class naming a rail the block does not declare FAILS THE LOAD (acceptance 5).
    _saved_rails_bad = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["bogus-rail"]
    try:
        _assert_declared_rails()
        raise AssertionError("a class naming an undeclared rail must fail the load")
    except ValueError:
        pass
    finally:
        _classes["classes"]["coding"]["rails"] = _saved_rails_bad
    # (d) tier_thresholds is read PER RAIL (acceptance 3): the Anthropic-only top-level table is
    # retired; the subscription rail's declared table is the home.
    assert tier_threshold("dispatch", 0.0) == 0.9 and tier_threshold("heavy", 0.0) == 0.8, \
        (tier_threshold("dispatch", 0.0), tier_threshold("heavy", 0.0))
    assert tier_threshold("nope", 0.42) == 0.42, "an unknown tier falls to the default"
    # (e) /router-status echoes the rail set with each rail's enabled/parked state and gate.
    _rs = status_summary()
    assert set(_rs["rails"]) == set(RAILS), _rs["rails"]
    assert _rs["rails"][RAIL_OPENCODE_ZEN]["enabled"] is False, _rs["rails"][RAIL_OPENCODE_ZEN]
    assert _rs["rails"][model_id.RAIL_OPENCODE_GO]["gate"] == "go", _rs["rails"]
    assert _rs["rails"][model_id.RAIL_OPENCODE_GO]["parked"] is False, _rs["rails"]
    # (f) the one-release migration (acceptance 3): a stale file's Anthropic-only top-level
    # `tier_thresholds` is folded into the subscription rail ONCE and the old key dropped.
    _sub_tt_saved = dict(rail_facts(model_id.RAIL_SUBSCRIPTION).get("tier_thresholds") or {})
    _classes["rails"][model_id.RAIL_SUBSCRIPTION]["tier_thresholds"] = {}
    _classes["tier_thresholds"] = {"dispatch": 0.7, "heavy": 0.6, "_comment": "stale"}
    assert _migrate_tier_thresholds() == 1, "a stale top-level table must migrate once"
    assert "tier_thresholds" not in _classes, "the old key must be dropped after migration"
    assert rail_facts(model_id.RAIL_SUBSCRIPTION)["tier_thresholds"] == {"dispatch": 0.7,
                                                                        "heavy": 0.6}, \
        rail_facts(model_id.RAIL_SUBSCRIPTION)["tier_thresholds"]
    _classes["rails"][model_id.RAIL_SUBSCRIPTION]["tier_thresholds"] = _sub_tt_saved
    # (g) the rails-LESS stale file (a partial revert of just model-classes.json): a top-level
    # `tier_thresholds` with NO `rails:` block at all must still SURVIVE — the fold seeds the
    # WHOLE canonical block from RAIL_DEFAULTS (so `_assert_declared_rails()` stays satisfied)
    # and the file's declared value WINS over the hardcoded default, rather than being silently
    # popped and reverting to RAIL_DEFAULTS. This is the reviewer's own repro, pinned.
    _saved_classes_all = dict(_classes)
    _classes.clear()
    _classes.update({"tier_thresholds": {"dispatch": 0.7}, "classes": {}})
    assert _migrate_tier_thresholds() == 1, "a rails-less stale table must still migrate once"
    assert "tier_thresholds" not in _classes, "the old key must be dropped after migration"
    assert set(_classes["rails"]) == set(RAILS), \
        f"the seed must be the WHOLE canonical block: {sorted(_classes['rails'])}"
    _assert_declared_rails()  # the seeded block keeps every class's rail declared
    assert tier_threshold("dispatch", 0.42) == 0.7, \
        f"a rails-less stale table must survive, not revert to RAIL_DEFAULTS: " \
        f"{tier_threshold('dispatch', 0.42)}"
    _classes.clear()
    _classes.update(_saved_classes_all)
    # ── Goal #1769 acceptance 3: the canonical `models` table ──
    # (h) the two table asserts over the LIVE table: every entry's every (rail, id) must parse to
    # the entry's key (model_family) and its rail (model_id.parse). The expected values are
    # COMPUTED from the parser, never read back from the table — so a mis-keyed row trips this.
    _assert_models_table(_models_table())
    # (i) the negative row: a deliberately mis-keyed entry MUST trip the assert (the test can
    # fail). Two drifts, one per half of the assert: a wrong family and a wrong rail.
    _bad_family = {"claude-sonnet": {"ids": {"openrouter": "anthropic/claude-opus-4.6"},
                                     "tier": "large", "context_tokens": None,
                                     "tool_verified": None, "pool_usd": None}}
    _bad_rail = {"claude-sonnet": {"ids": {"opencode-go": "claude/sonnet"},
                                   "tier": "large", "context_tokens": None,
                                   "tool_verified": None, "pool_usd": None}}
    for _bad, _want in ((_bad_family, "family"), (_bad_rail, "rail")):
        try:
            _assert_models_table(_bad)
        except AssertionError as _e:
            assert _want in str(_e), f"the {_want} drift must be named: {_e}"
        else:
            raise AssertionError(f"a mis-keyed models entry must trip the assert ({_want})")
    # (j) the one-release `model_tiers` alias: a stale id→grade table folds into `models` ONCE,
    # keyed by model_family() and railed by model_id.parse(), and the old key is dropped.
    _models_saved = copy.deepcopy(_classes.get("models"))
    _classes["model_tiers"] = {"claude/haiku": "cheap", "opencode-go/deepseek-v4-flash": "cheap"}
    assert _migrate_model_tiers() == 2, "a stale model_tiers table must migrate once"
    assert "model_tiers" not in _classes, "the old key must be dropped after migration"
    assert _classes["models"]["claude-haiku"]["tier"] == "cheap", _classes["models"]["claude-haiku"]
    assert _classes["models"]["deepseek-v4-flash"]["ids"] == \
        {"opencode-go": "opencode-go/deepseek-v4-flash"}, _classes["models"]["deepseek-v4-flash"]
    _assert_models_table(_classes["models"])  # the seeded table still satisfies the two asserts
    _classes["models"] = _models_saved
    # (j2) the `:free` suffix-floor: the table is keyed by model_family(), which collapses the
    # `:free` suffix onto the paid key, and `ids` is rail → ONE id — so master's two grades for
    # `poolside/laguna-s-2.1` (`cheap`) and `poolside/laguna-s-2.1:free` (`free`) are not
    # expressible in the table and are resolved per-id by the reader. Both grades must survive.
    assert _model_tier("poolside/laguna-s-2.1") == "cheap", \
        _model_tier("poolside/laguna-s-2.1")
    assert _model_tier("poolside/laguna-s-2.1:free") == "free", \
        _model_tier("poolside/laguna-s-2.1:free")
    # (j3) the alias path: a stale `model_tiers` holding BOTH laguna ids folds into the canonical
    # table, and the reader still resolves the two grades per-id — in EITHER key order (the
    # migration's setdefault keeps only the first-seen grade, so the reader, not the table, is
    # what restores the variant's floor).
    for _order in ({"poolside/laguna-s-2.1": "cheap", "poolside/laguna-s-2.1:free": "free"},
                   {"poolside/laguna-s-2.1:free": "free", "poolside/laguna-s-2.1": "cheap"}):
        _classes["model_tiers"] = dict(_order)
        assert _migrate_model_tiers() == 2, "both laguna ids must migrate"
        assert _model_tier("poolside/laguna-s-2.1") == "cheap", \
            f"paid laguna must stay cheap (order {list(_order)}): " \
            f"{_model_tier('poolside/laguna-s-2.1')}"
        assert _model_tier("poolside/laguna-s-2.1:free") == "free", \
            f":free laguna must floor to free (order {list(_order)}): " \
            f"{_model_tier('poolside/laguna-s-2.1:free')}"
        _classes["models"] = copy.deepcopy(_models_saved)
    # (k) /router-status echoes the canonical table (the per-model facts + per-rail ids).
    _rs_models = status_summary()["models"]
    assert _rs_models["deepseek-v4-flash"]["context_tokens"] == 1000000, \
        _rs_models.get("deepseek-v4-flash")
    assert _rs_models["claude-sonnet"]["ids"]["openrouter"] == "anthropic/claude-sonnet-4.6", \
        _rs_models.get("claude-sonnet")
    # (l) the cross-rail deny (acceptance 3): a deny of the CANONICAL key excludes every rail's id
    # for that model in the same route; a deny of a bare rail id excludes just that id.
    _deny_chain = ["claude/sonnet", "anthropic/claude-sonnet-4.6", "tencent/hy3"]
    _dd = route(dict(base, chain=_deny_chain, deny=["claude-sonnet"]), CTX)
    assert _dd["decision"] == "dispatch" and _dd["model"] == "tencent/hy3", _dd
    assert {"model": "claude/sonnet", "reason": "claim-deny"} in _dd["skipped"], _dd["skipped"]
    assert {"model": "anthropic/claude-sonnet-4.6", "reason": "claim-deny"} in _dd["skipped"], \
        _dd["skipped"]
    _dd2 = route(dict(base, chain=["claude/sonnet", "anthropic/claude-sonnet-4.6"],
                      deny=["claude/sonnet"]), CTX)
    assert _dd2["decision"] == "dispatch" and _dd2["model"] == "anthropic/claude-sonnet-4.6", _dd2
    assert {"model": "claude/sonnet", "reason": "claim-deny"} in _dd2["skipped"], _dd2["skipped"]
    assert not any(s.get("model") == "anthropic/claude-sonnet-4.6" for s in _dd2["skipped"]), \
        _dd2["skipped"]
    # (m) /route echoes the served model's declared context_tokens (acceptance 3): the Go flash's
    # 1M window is the shell constant being retired, so it must be expressible from the decision.
    _saved_rails_ctx = list(_classes["classes"]["coding"]["rails"])
    _classes["classes"]["coding"]["rails"] = ["opencode-go", "openrouter"]
    _ctx_go = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), CTX)
    assert _ctx_go["decision"] == "dispatch" and _ctx_go["context_tokens"] == 1000000, _ctx_go
    _classes["classes"]["coding"]["rails"] = _saved_rails_ctx
    # ── M8 capability floors (FU-095): evidence blocks, absence passes ──
    assert record_capability("artificial-analysis", [
        {"model": "lowcap/model", "intelligence": 12.0, "coding": 9.0, "agentic": 5.0},
        {"model": "tencent/hy3", "intelligence": 55.0, "coding": 52.0, "agentic": 41.0}]) == 2
    _classes.setdefault("class_floors", {})["coding"] = {"coding": 30}
    df = route(dict(base, chain=["lowcap/model", "deepseek/deepseek-v4-flash", "tencent/hy3"]),
               CTX)
    assert df["decision"] == "dispatch" and df["model"] == "deepseek/deepseek-v4-flash", df
    assert any(s["reason"].startswith("capability-floor:coding=9.0<30")
               for s in df["skipped"]), df["skipped"]
    # no capability row (deepseek in this fixture) = permissive pass; a :free variant scores
    # as its base model
    assert capability_floor_block("coding", "deepseek/deepseek-v4-flash") is None
    assert capability_floor_block("coding", "lowcap/model:free") == "coding=9.0<30"
    assert record_task_market([{"tag": "code:devops_config", "model": "xiaomi/mimo-v2.5",
                                "rank": 1, "usage_share": 0.182, "token_share": 0.183}]) == 1
    # ── Goal #1640 acceptance 3: pair strike + active cooldown / capability-floor edge cases ──
    # (5) pair strike + active cooldown: cooldown takes precedence in the filter order. The
    #     struck pair is recorded in skipped before the model is excluded by cooldown.
    record_report({"session": "t-strike-cool-1", "task": "issue-84", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "provider-5xx",
                   "outcome": "no-output"})
    for _ in range(8):
        record_provider_event("deepseek/deepseek-v4-flash", "deepinfra", 429)
    assert cooldown_note("deepseek/deepseek-v4-flash", 429, role="worker") == "tripped"
    _sc = route({"stack": "sleep", "task": "issue-84", "role": "worker",
                 "session": "t-strike-cool-1", "chain": _PAIR_CHAIN}, _CELL_CTX)
    assert _sc["decision"] == "dispatch" and _sc["model"] == "tencent/hy3", _sc
    # Cooldown is the filter that stops it from being eligible
    assert any(s["reason"].startswith("cooldown:") for s in _sc["skipped"]), \
        f"cooldown must block the pair-struck model: {_sc['skipped']}"
    # Clear the cooldown for subsequent tests
    assert cooldown_note("deepseek/deepseek-v4-flash", 200, role="worker") == "cleared"
    # (6) pair strike + capability-floor fail: capability-floor takes precedence. The struck
    #     pair is recorded in skipped before the model is excluded by capability-floor.
    record_report({"session": "t-strike-floor-1", "task": "issue-85", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "timeout",
                   "outcome": "no-output"})
    # Set up a capability record for deepseek that fails the existing coding floor
    record_capability("artificial-analysis", [
        {"model": "deepseek/deepseek-v4-flash", "intelligence": 25.0, "coding": 9.0, "agentic": 5.0}])
    _sf = route({"stack": "sleep", "task": "issue-85", "role": "worker",
                 "session": "t-strike-floor-1", "chain": _PAIR_CHAIN}, _CELL_CTX)
    assert _sf["decision"] == "dispatch" and _sf["model"] == "tencent/hy3", _sf
    # Capability-floor is the filter that stops it from being eligible
    assert any(s["reason"].startswith("capability-floor:") for s in _sf["skipped"]), \
        f"capability-floor must block the pair-struck model: {_sf['skipped']}"
    # Clean up: remove the deepseek capability record so it doesn't affect subsequent tests
    _write("DELETE FROM capability WHERE model=? AND source=?",
           ("deepseek/deepseek-v4-flash", "artificial-analysis"))
    # (7) pair strike + decorrelate_from set to an unrelated family: the struck provider must be
    #     excluded even when the model is not in the decorrelated family. The decision carries
    #     skipped with the strike row, and the model is priced/pinned at the post-exclusion cell.
    record_report({"session": "t-strike-decor-1", "task": "issue-86", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "error_class": "provider-5xx",
                   "outcome": "no-output"})
    _sdc = route({"stack": "sleep", "task": "issue-86", "role": "worker",
                  "session": "t-strike-decor-1", "chain": ["deepseek/deepseek-v4-flash"],
                  "decorrelate_from": "moonshotai/kimi-k3"}, _CELL_CTX)
    assert _sdc["decision"] == "dispatch" and _sdc["model"] == "deepseek/deepseek-v4-flash", _sdc
    assert _sdc["provider"] == "deepinfra" and _sdc["price_per_mtok"] == 0.05, _sdc
    assert {"model": "deepseek/deepseek-v4-flash", "provider": "open-inference",
            "reason": "strike"} in _sdc["skipped"], _sdc["skipped"]
    assert _sdc.get("strike_excluded") == ["open-inference"], \
        f"strike_excluded must record the struck provider: {_sdc.get('strike_excluded')}"
    # ── Goal #1640 acceptance 5: the (model, provider) PAIR cooldown ──
    # Fixtures (5)-(7) struck (deepseek-v4-flash, open-inference) from three distinct tasks with
    # serving classes — exactly the trip condition (>= pair_min_tasks DISTINCT tasks inside
    # pair_window_s). The pair is cooled, and /route excludes it under its OWN reason, distinct
    # from a task-local strike.
    _pc_fix = pair_cooldowns()
    assert ("deepseek/deepseek-v4-flash", "open-inference") in _pc_fix, _pc_fix
    assert _pc_fix[("deepseek/deepseek-v4-flash", "open-inference")]["streak"] == 2, _pc_fix
    # …and /route excludes it as a COOLDOWN, not a strike: the route's task (issue-92) has no
    # strike of its own, so strike_excluded is empty and cooldown_excluded names the cooled
    # provider — the issue's "distinct reason so a decision row tells the two apart".
    _pcr = route({"stack": "sleep", "task": "issue-92", "role": "worker",
                  "session": "t-pc-route", "chain": ["deepseek/deepseek-v4-flash"]}, _CELL_CTX)
    assert _pcr["decision"] == "dispatch" and _pcr["model"] == "deepseek/deepseek-v4-flash", _pcr
    assert _pcr["provider"] == "deepinfra" and _pcr["price_per_mtok"] == 0.05, _pcr
    assert any(s.get("model") == "deepseek/deepseek-v4-flash"
               and s.get("provider") == "open-inference" and s.get("reason") == "cooldown-pair"
               for s in _pcr["skipped"]), _pcr["skipped"]
    assert _pcr["cooldown_excluded"] == ["open-inference"], _pcr
    assert _pcr["strike_excluded"] == [], \
        "a cooldown exclusion must NOT be reported as a strike exclusion"
    # /router-status exposes the table (pair, until, streak) so the seat reads it without sqlite.
    _pc_status = status_summary()["pair_cooldowns"]
    assert any(e["model"] == "deepseek/deepseek-v4-flash" and e["provider"] == "open-inference"
               and e["streak"] == 2 and e["until"] > time.time() for e in _pc_status), _pc_status
    # …and the per-cell gauge is scraped from /metrics (the fleet-strike reader's surface).
    assert 'router_cell_cooldown{model="deepseek/deepseek-v4-flash",provider="open-inference"}' \
        in "\n".join(metrics_lines()), "the pair cooldown must surface as a per-cell gauge"
    # ── the three acceptance behaviours, on a DEDICATED pair so they are controlled ──
    # A synthetic model id, so this pair cannot collide with any other fixture's model.
    _PM, _PP = "cooldown/model-a", "prov-x"
    _PC_CELLS = {"cooldown/model-a": [("prov-x", 0.02), ("prov-y", 0.05)]}

    def _pc_price(m, exclude=frozenset()):
        for _prov, _price in _PC_CELLS.get(m, []):
            if _prov not in exclude:
                return _price, "market", _prov
        return None, None, None

    _PC_CTX = {**CTX, "price": _pc_price}
    # (a) two strikes on one pair inside the window → the pair is excluded from /route.
    for _t in ("issue-93", "issue-94"):
        record_report({"session": f"t-pc-{_t}", "task": _t, "stack": "sleep", "role": "worker",
                       "round": 1, "model": _PM, "served_provider": _PP,
                       "error_class": "provider-5xx", "outcome": "no-output"})
    _pc1 = pair_cooldowns()
    assert (_PM, _PP) in _pc1 and _pc1[(_PM, _PP)]["streak"] == 1, _pc1
    # a SECOND strike on the SAME task must not raise the streak — the trip is per DISTINCT task
    record_report({"session": "t-pc-issue-93b", "task": "issue-93", "stack": "sleep",
                   "role": "worker", "round": 2, "model": _PM, "served_provider": _PP,
                   "error_class": "timeout", "outcome": "no-output"})
    assert pair_cooldowns()[(_PM, _PP)]["streak"] == 1, \
        "the trip counts DISTINCT tasks, not strikes"
    # the pair is excluded from /route, priced at the provider it lands on AFTER the exclusion
    _pcr2 = route({"stack": "sleep", "task": "issue-98", "role": "worker",
                   "session": "t-pc-route-2", "chain": [_PM]}, _PC_CTX)
    assert _pcr2["decision"] == "dispatch" and _pcr2["provider"] == "prov-y", _pcr2
    assert _pcr2["price_per_mtok"] == 0.05, _pcr2
    assert any(s.get("model") == _PM and s.get("provider") == _PP
               and s.get("reason") == "cooldown-pair" for s in _pcr2["skipped"]), _pcr2["skipped"]
    # (b) expiry → half-open: the pair is eligible again (absent from the table)
    _pc_until = pair_cooldowns()[(_PM, _PP)]["until"]
    assert (_PM, _PP) not in pair_cooldowns(now=_pc_until + 1), \
        "an expired hold is half-open — the pair is eligible again"
    # (c) a strike DURING half-open doubles the hold (streak 2 → 12 h)
    record_report({"session": "t-pc-issue-95", "task": "issue-95", "stack": "sleep",
                   "role": "worker", "round": 1, "model": _PM, "served_provider": _PP,
                   "error_class": "provider-5xx", "outcome": "no-output"})
    _pc2 = pair_cooldowns()
    assert _pc2[(_PM, _PP)]["streak"] == 2, _pc2
    assert _pc2[(_PM, _PP)]["remaining_s"] > 11 * 3600, \
        f"a strike during half-open must double the hold to 12 h: {_pc2[(_PM, _PP)]}"
    # (d) a 2xx does NOT clear it — the transport belt's rule does not apply to a pair cooldown
    for _ in range(8):
        record_provider_event(_PM, _PP, 200)
    assert (_PM, _PP) in pair_cooldowns(), "a 2xx must NOT clear a pair cooldown"
    # …only a CLEAN RIDE does
    record_report({"session": "t-pc-clean", "task": "issue-96", "stack": "sleep",
                   "role": "worker", "round": 1, "model": _PM, "served_provider": _PP,
                   "outcome": "pr"})
    assert (_PM, _PP) not in pair_cooldowns(), "a clean ride clears the pair cooldown"
    # Clean up the fixtures' cooldown so the downstream tests (which are about other mechanisms)
    # are not polluted — the same pattern the capability/cooldown fixtures above use.
    record_report({"session": "t-pc-clean-ds", "task": "issue-97", "stack": "sleep",
                   "role": "worker", "round": 1, "model": "deepseek/deepseek-v4-flash",
                   "served_provider": "open-inference", "outcome": "pr"})
    assert ("deepseek/deepseek-v4-flash", "open-inference") not in pair_cooldowns()
    # ── M11 shadow ladder (homelab#159): free → subscription-headroom → paid, per (class, urgency) ──
    # Every assertion here is about the SHADOW block. The served pick is asserted unchanged beside
    # each one — that is the acceptance criterion of this leg, not a nicety.
    assert resolve_urgency({"urgency": "elastic"}) == ("elastic", "caller")
    assert resolve_urgency({"urgency": "ELASTIC "}) == ("elastic", "caller"), "normalized"
    assert resolve_urgency({"urgency": "yesterday"}) == ("tight", "default"), "garbage ⇒ default"
    assert resolve_urgency({}) == ("tight", "default"), "missing ⇒ tight (conservative)"
    if _classes.get("urgency_map"):
        assert resolve_urgency({"labels": ["task/research"]}) == ("elastic", "label_map")
        assert resolve_urgency({"labels": ["task/research", "task/goal"]})[0] == "tight", \
            "tight wins a label tie — the conservative direction"
        assert resolve_urgency({"role": "retro"}) == ("elastic", "role")
        assert resolve_urgency({"urgency": "tight", "labels": ["task/research"]})[1] == "caller", \
            "the caller's round-state knowledge outranks the label table (ADR-094)"
    # tight (the default) floors at the subscription rung while the cell is unproven; the SERVED
    # pick stays the cheapest-effective OpenRouter model exactly as before.
    dsh = route(dict(base, session="t-shadow-1"), CTX)
    assert dsh["model"] == "inclusionai/ling-3.0-flash:free", "served pick UNCHANGED by the shadow"
    sh = dsh["shadow"]
    assert (sh["urgency"], sh["urgency_source"]) == ("tight", "default"), sh
    assert sh["start_tier"] == "subscription" and sh["learned_start_tier"] == "free", sh
    # Goal #1769 acceptance 1: the shadow's RAIL is canonical too (the rung it sits on keeps the
    # ladder's own name — rungs and rails are two vocabularies, and only the rail moved).
    assert (sh["model"], sh["rail"], sh["ladder_tier"]) == ("claude/haiku", "anthropic-subscription",
                                                            "subscription"), sh
    assert sh["subscription"]["eligible"] and sh["price_per_mtok"] == 0.0, sh
    # elastic takes the learned rung as-is — rung 0, the free model, "tier 1 first"
    de = route(dict(base, session="t-shadow-2", urgency="elastic"), CTX)
    assert de["model"] == "inclusionai/ling-3.0-flash:free"
    assert de["shadow"]["ladder_tier"] == "free" and de["shadow"]["urgency_source"] == "caller"
    # ⚠ THE FU-088 BOUND. Semaphore full / utilization past threshold ⇒ the subscription rung is
    # priced UNPICKABLE and the ladder climbs past it to paid. The safety net's slots are not the
    # ladder's to spend, and this is the assertion that says so.
    lim2 = {**CTX, "subscription_ok": lambda tier: (False, "subscription-limited:semaphore", 300)}
    dlim = route(dict(base, session="t-shadow-3"), lim2)
    assert dlim["model"] == "inclusionai/ling-3.0-flash:free", "served pick still unchanged"
    shl = dlim["shadow"]
    assert shl["rail"] == "openrouter" and shl["ladder_tier"] == "paid", shl
    assert shl["model"] == "deepseek/deepseek-v4-flash", shl
    assert not shl["subscription"]["eligible"], shl
    assert shl["subscription"]["blocked"] == "subscription-limited:semaphore", shl
    # leg 1: the rail is a CANDIDATE even when the chain names no claude/* entry
    dsyn = route(dict(base, session="t-shadow-4", chain=["deepseek/deepseek-v4-flash"]), CTX)
    assert dsyn["model"] == "deepseek/deepseek-v4-flash", "served pick unchanged"
    assert any(c.get("synthetic") and c["model"] == "claude/haiku"
               for c in dsyn["shadow"]["candidates"]), dsyn["shadow"]["candidates"]
    assert dsyn["shadow"]["model"] == "claude/haiku", dsyn["shadow"]
    # the jitter band re-probes ONE rung down (pick the last band member instead of the first)
    dj = route(dict(base, session="t-shadow-5"), {**CTX, "pick": lambda b: b[-1]})
    assert dj["shadow"]["reprobe"] and dj["shadow"]["start_tier"] == "free", dj["shadow"]
    # a class whose rails exclude the subscription never grows the candidate (research pins
    # openrouter — coordination must not be routed onto the safety net by the ladder)
    if (_classes.get("classes") or {}).get("research"):
        dres = route(dict(base, session="t-shadow-6", **{"class": "research"}), CTX)
        assert all(c["rail"] == "openrouter" for c in dres["shadow"]["candidates"]), dres["shadow"]
    # ── leg 3: the cell LEARNS from the existing outcomes feed (no new producer) ──
    for sess, model, outcome, err in (
            ("t-cell-1", "claude/haiku", "harness-death", "goose-32602-truncation"),
            ("t-cell-2", "inclusionai/ling-3.0-flash:free", "pr", ""),
            ("t-cell-3", "inclusionai/ling-3.0-flash:free", "pr", ""),
            ("t-cell-4", "inclusionai/ling-3.0-flash:free", "pr", ""),
            ("t-cell-5", "inclusionai/ling-3.0-flash:free", "pr", "")):
        route(dict(base, session=sess), CTX)
        # Goal #1640 acceptance 3: the strike fixture's task is NOT the route tests' `issue-42`
        # — enforcement is unconditional now, so t-cell-1's harness-death strike would (correctly)
        # exclude claude/haiku from every `issue-42` route below. The cell fold keys on the
        # SESSION, so the task is incidental to what this leg proves.
        record_report({"session": sess, "task": "issue-42-cell", "stack": "sleep", "role": "worker",
                       "model": model, "outcome": outcome, "error_class": err})
        if sess == "t-cell-1":  # a strike at the subscription rung climbs the cell above it
            assert cell_state("coding", "tight")["start_tier"] == 2, cell_state("coding", "tight")
        if sess == "t-cell-2":  # a re-probe one rung down that BANKS is adopted immediately
            assert cell_state("coding", "tight")["start_tier"] == 0, cell_state("coding", "tight")
    proven = cell_state("coding", "tight")
    assert proven["start_tier"] == 0 and proven["clean"] >= 3, proven
    dp = route(dict(base, session="t-shadow-7"), CTX)
    assert dp["shadow"]["start_tier"] == "free" and dp["shadow"]["ladder_tier"] == "free", \
        "a PROVEN cell lets even tight work start on the free rung (§M11)"
    assert dp["model"] == "inclusionai/ling-3.0-flash:free", "…and the served pick never moved"
    assert status_summary()["ladder_cells"] and status_summary()["shadow_24h"], "soak surfaces"
    # ── ADR-104 / FU-162: the DRAW verb — class + slot + jitter:false on the curated pools ──
    # Two properties carry the research lane and neither is visible in a single call: the same
    # inputs must draw the same model on a relaunch, and an unusable slot must DEFER rather than
    # quietly hand back the next model down (a substituted arm is a corrupted experiment, and the
    # circles run-1 slip is what happens when nothing pins that).
    _bands = ((_classes.get("pools") or {}).get("bands") or {})
    if _bands:
        _pv = str(_classes["pools"]["version"])
        d1 = route(dict(base, session="t-draw-1", slot=2, jitter=False,
                        **{"class": "regular"}), CTX)
        assert d1["decision"] == "dispatch" and d1["source"] == "pool", d1
        assert d1["model"] == _bands["regular"][1], d1
        assert (d1["pool"], d1["pool_version"], d1["slot"]) == ("regular", _pv, 2), d1
        assert d1["jitter"] is False and d1["rail"] == "openrouter", d1
        # `base` carries a chain; a draw caller names zero models, so the chain is dropped LOUDLY
        assert [s for s in d1["skipped"] if s["reason"] == "chain-ignored:draw"], d1["skipped"]
        # IDEMPOTENCE: different session, different jitter picker, same (class, slot, version)
        d1b = route(dict(base, session="t-draw-1b", chain=[], slot=2, jitter=False,
                         **{"class": "regular"}), {**CTX, "pick": lambda b: b[-1]})
        assert (d1b["model"], d1b["pool_version"]) == (d1["model"], _pv), (d1, d1b)
        # a slot past the end of the band is the ESCALATING defer, not a wrap-around or a walk
        _n = len(_bands["regular"])
        dz = route(dict(base, session="t-draw-z", chain=[], slot=_n + 1, jitter=False,
                        **{"class": "regular"}), CTX)
        assert dz["decision"] == "defer" and dz["reason"] == "chain-exhausted", dz
        assert any(s["reason"].startswith("slot-outside-pool:regular") for s in dz["skipped"]), dz
        assert dz["slot"] == _n + 1 and dz["pool_version"] == _pv, dz
        # a drawn model the claim denies DEFERS — it never slides to slot+1 behind the caller
        dd2 = route(dict(base, session="t-draw-deny", chain=[], slot=1, jitter=False,
                         deny=[_bands["regular"][0]], **{"class": "regular"}), CTX)
        assert dd2["decision"] == "defer" and dd2["reason"] == "chain-exhausted", dd2
        assert dd2.get("model") is None and dd2["pool"] == "regular", dd2
        # the instrument is one fixed model, and NOT an arm — the run-1 "proxy graded its own arm"
        di = route(dict(base, session="t-draw-i", chain=[], slot=1, jitter=False,
                        **{"class": "instrument"}), CTX)
        assert di["decision"] == "dispatch" and di["model"] == _bands["instrument"][0], di
        assert di["model"] not in _bands["regular"], "instrument ∉ regular (ADR-104 disjointness)"
        # the ultra band rides the subscription rail, and the class rails let it
        du = route(dict(base, session="t-draw-u", chain=[], slot=1, jitter=False,
                        **{"class": "ultra"}), CTX)
        assert du["decision"] == "dispatch" and du["rail"] == "anthropic-subscription", du
        assert du["model"] == _bands["ultra"][0], du
    # JITTER SUPPRESSED, on the ordinary chain path too: three equally-priced candidates put the
    # tie-break in the open. With the band live, the ctx picker roams it; with `jitter: false` the
    # pick is the first in caller order and the shadow ladder stops re-probing a rung down.
    # (class `review`, whose ladder cell is still unproven here — the `coding` cell was promoted
    # to the free rung by the leg-3 fixtures above, and a proven cell never re-probes.)
    EQ = {**CTX, "price": lambda m, exclude=frozenset(): (0.05, "market", None),
          "pick": lambda b: b[-1]}
    _eqbase = dict(base, chain=CHAIN[:3], **{"class": "review"})
    dj_on = route(dict(_eqbase, session="t-jitter-on"), EQ)
    dj_off = route(dict(_eqbase, session="t-jitter-off", jitter=False), EQ)
    assert dj_on["model"] == "tencent/hy3" and dj_on["jitter"] is True, dj_on
    assert dj_off["model"] == "inclusionai/ling-3.0-flash:free", dj_off
    assert dj_off["model"] == dj_off["jitter_pool"][0], "ties break stably, in caller order"
    assert dj_on["shadow"]["reprobe"] and not dj_off["shadow"]["reprobe"], \
        "the shadow ladder must not jitter either when the caller asked for none"
    # ── #516: family decorrelation as a /route primitive, plus the shadow/served divergence ──
    # Same-family exclusion: decorrelate_from blocks models sharing the author's family across rails.
    _dcbase = dict(base, chain=["deepseek/deepseek-v4-flash", "tencent/hy3", "claude/haiku"])
    _dc = route(dict(_dcbase, decorrelate_from="opencode-go/deepseek-v4-flash"), CTX)
    assert _dc["decision"] == "dispatch" and _dc["model"] == "tencent/hy3", \
        f"decorrelate_from must skip the deepseek family: {_dc}"
    assert any(s["reason"] == "decorrelate:deepseek" for s in _dc["skipped"]), \
        f"deepseek model must be skipped with decorrelate reason: {_dc['skipped']}"
    # Cross-family: a different family from the author passes through unaffected (tencent is
    # moonshotai/kimi-k3, not tencent/hy3 — decorrelate_from=tencent/hy3 blocks the hy3 family).
    _dc2 = route(dict(_dcbase, decorrelate_from="moonshotai/kimi-k3"), CTX)
    assert _dc2["decision"] == "dispatch" and _dc2["model"] == "deepseek/deepseek-v4-flash", \
        f"unrelated decorrelate_from must not block deepseek: {_dc2}"
    # Entire chain from the same family → typed defer (decorrelate:<family>), not chain-exhausted.
    _dc3 = route(dict(base, chain=["deepseek/deepseek-v4-flash"],
                      decorrelate_from="opencode-go/deepseek-v4-flash"), CTX)
    assert _dc3["decision"] == "defer" and _dc3["reason"] == "decorrelate:deepseek", \
        f"all-same-family must defer with decorrelate reason: {_dc3}"
    assert _dc3.get("retry_after_s") is None, "decorrelate defer must not carry retry_after"
    # The shadow ladder also sees the decorrelation — the same-family model is absent from its
    # candidates so it cannot pick it either.
    assert _dc["shadow"]["decision"] == "dispatch", \
        "shadow must dispatch when the served path dispatches"
    assert all("deepseek" not in c["model"] for c in _dc["shadow"]["candidates"]), \
        "the decorrelated family must be absent from shadow candidates"
    # Shadow/served divergence: a chain where the shadow ladder would pick the subscription rung
    # (a proven cell that floors at free would pick the subscription stand-in) while the served
    # path dispatches the free model — assert the divergence IS recorded and the served decision
    # is unaffected. The review class (subscription-first rails) with proven free cell means the
    # shadow ladder at tight urgency floors to subscription.
    _shadow_div = route(dict(base, session="t-shadow-div-1", **{"class": "review"}),
                        {**CTX, "pick": lambda b: b[-1]})
    # The review class has subscription-first rails. At tight urgency with the cell unproven,
    # the shadow ladder floors to subscription, while the served path dispatches the free model.
    assert _shadow_div["decision"] == "dispatch", \
        f"served decision must dispatch regardless of shadow: {_shadow_div}"
    # Verify divergence by checking the shadow decision was recorded in the store
    _sd_rows = _read("SELECT served_model, shadow_model, agrees FROM shadow_decisions "
                     "WHERE session='t-shadow-div-1'")
    assert len(_sd_rows) == 1, f"exactly one shadow decision row for t-shadow-div-1: {_sd_rows}"
    assert _sd_rows[0][0] == _shadow_div["model"], \
        "served model in shadow record must match the served decision"
    # If the served and shadow models differ, agrees=0; since review class has different rail
    # ordering, the shadow picks the subscription model while served picks the free model.
    if _sd_rows[0][0] != _sd_rows[0][1]:
        assert _sd_rows[0][2] == 0, \
            f"divergent shadow/served must record agrees=0: {_sd_rows}"
    # Sibling decorrelation guard: a denied model + decorrelate_from must still defer
    # chain-exhausted (preventing the guard from being relabelled decorrelate:<family>).
    _dc4 = route(dict(base, chain=["deepseek/deepseek-v4-flash"],
                      deny=["deepseek/deepseek-v4-flash"],
                      decorrelate_from="tencent/hy3"), CTX)
    assert _dc4["decision"] == "defer" and _dc4["reason"] == "chain-exhausted", \
        f"denied + decorrelate_from must defer chain-exhausted: {_dc4}"
    # Cooldown + decorrelate_from: a model on cooldown with decorrelate_from set to an unrelated
    # family must retain its retry_after_s (not lose it to the decorrelate: branch).
    cooldown_note("inclusionai/ling-3.0-flash:free", 429, role="worker")
    _now = time.time()
    _write("UPDATE model_cooldowns SET until=? WHERE model=? AND role='worker'",
           (_now + 99999, "inclusionai/ling-3.0-flash:free"))
    _dc5 = route(dict(base, chain=["inclusionai/ling-3.0-flash:free"],
                      decorrelate_from="tencent/hy3"), CTX)
    assert _dc5["decision"] == "defer" and _dc5["reason"] == "cooldown", \
        f"cooldown + decorrelate_from must defer cooldown: {_dc5}"
    assert _dc5.get("retry_after_s") is not None, \
        "cooldown + decorrelate_from must carry retry_after_s"
    _write("UPDATE model_cooldowns SET until=? WHERE model=? AND role='worker'",
           (_now - 1, "inclusionai/ling-3.0-flash:free"))
    cooldown_note("inclusionai/ling-3.0-flash:free", 200, role="worker")
    # Mixed decorrelate + deny: two models, one decorrelated (vendor deepseek), one denied.
    # With the all() guard, this must defer chain-exhausted (not relabel decorrelate:deepseek).
    _dc6 = route(dict(base, chain=["deepseek/deepseek-v4-flash", "moonshotai/kimi-k3"],
                      deny=["moonshotai/kimi-k3"],
                      decorrelate_from="opencode-go/deepseek-v4-flash"), CTX)
    assert _dc6["decision"] == "defer" and _dc6["reason"] == "chain-exhausted", \
        f"mixed decorrelate+deny must defer chain-exhausted: {_dc6}"
    # Mixed decorrelate + cooldown: two models, one decorrelated (vendor deepseek), one on
    # cooldown (moonshotai/kimi-k3). Must defer cooldown (not decorrelate) and carry retry_after_s.
    _now2 = time.time()
    _write("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
           ("moonshotai/kimi-k3", "worker", _now2 + 99999, 1, "429-burst", _now2))
    _dc7 = route(dict(base, chain=["deepseek/deepseek-v4-flash", "moonshotai/kimi-k3"],
                      decorrelate_from="opencode-go/deepseek-v4-flash"), CTX)
    assert _dc7["decision"] == "defer" and _dc7["reason"] == "cooldown", \
        f"mixed decorrelate+cooldown must defer cooldown: {_dc7}"
    assert _dc7.get("retry_after_s") is not None, \
        "mixed decorrelate+cooldown must carry retry_after_s"
    _write("DELETE FROM model_cooldowns WHERE model=? AND role='worker'", ("moonshotai/kimi-k3",))
    # ── vendor_family() direct assertions ──
    assert vendor_family("opencode-go/deepseek-v4-flash") == "deepseek", \
        f"rail-prefixed deepseek → deepseek: {vendor_family('opencode-go/deepseek-v4-flash')}"
    assert vendor_family("deepseek/deepseek-v4-flash-0731") == "deepseek", \
        f"bare deepseek-stamped → deepseek: {vendor_family('deepseek/deepseek-v4-flash-0731')}"
    assert vendor_family("claude/haiku") == "anthropic", \
        f"claude/haiku → anthropic: {vendor_family('claude/haiku')}"
    assert vendor_family("claude/sonnet") == "anthropic", \
        f"claude/sonnet → anthropic: {vendor_family('claude/sonnet')}"
    assert vendor_family("claude/opus") == "anthropic", \
        f"claude/opus → anthropic: {vendor_family('claude/opus')}"
    assert vendor_family("anthropic/claude-sonnet-5") == "anthropic", \
        f"anthropic/claude-sonnet-5 → anthropic: {vendor_family('anthropic/claude-sonnet-5')}"
    assert vendor_family("openai/gpt-5") == "openai", \
        f"openai/gpt-5 → openai: {vendor_family('openai/gpt-5')}"
    assert vendor_family("moonshotai/kimi-k3") == "moonshotai", \
        f"moonshotai/kimi-k3 → moonshotai: {vendor_family('moonshotai/kimi-k3')}"
    # Same-vendor Claude decorrelation: decorrelate_from=claude/opus must exclude claude/haiku
    _dc8base = dict(base, chain=["claude/haiku", "tencent/hy3"])
    _dc8 = route(dict(_dc8base, decorrelate_from="claude/opus"), CTX)
    assert _dc8["decision"] == "dispatch" and _dc8["model"] == "tencent/hy3", \
        f"claude/opus decorrelate_from must skip claude/haiku: {_dc8}"
    assert any(s["reason"] == "decorrelate:anthropic" for s in _dc8["skipped"]), \
        f"claude/haiku must be skipped with decorrelate:anthropic: {_dc8['skipped']}"
    # Cross-rail anthropic equivalence: anthropic/claude-sonnet-5 must also exclude claude/haiku
    _dc9 = route(dict(_dc8base, decorrelate_from="anthropic/claude-sonnet-5"), CTX)
    assert _dc9["decision"] == "dispatch" and _dc9["model"] == "tencent/hy3", \
        f"anthropic/claude-sonnet-5 decorrelate_from must skip claude/haiku: {_dc9}"
    assert any(s["reason"] == "decorrelate:anthropic" for s in _dc9["skipped"]), \
        f"claude/haiku must be skipped with decorrelate:anthropic: {_dc9['skipped']}"
    # homelab#180: the operator-gauge parse behind the latch's `credit` leg. The proxy half is one
    # HTTP GET; every way this leg can go quietly dead is decided HERE, so it is pinned HERE.
    _OP_TS = 1786237718.460958
    fresh = (f"# HELP {ACCOUNT_CREDIT_GAUGE} account credit\n"
             f"# TYPE {ACCOUNT_CREDIT_GAUGE} gauge\n"
             f"{ACCOUNT_CREDIT_GAUGE} 20.167155\n"
             f"{ACCOUNT_CREDIT_TS_GAUGE} {_OP_TS}\n"
             "openrouter_account_credit_poll_failures_total 0\n")
    bal, at, why = parse_account_credit(fresh, _OP_TS + 60, 1800)
    assert bal == 20.1672 and at == _OP_TS, (bal, at, why)
    # The NaN trap, stated as the comparison the caller actually makes: a naive port would leave
    # the leg silently never latching (`nan < floor` is False), which IS the bug #180 is about.
    nan_body = fresh.replace("20.167155", "NaN")
    bal, _, why = parse_account_credit(nan_body, _OP_TS + 60, 1800)
    assert bal is None and "NaN" in why, why
    assert not (float("nan") < 0.25), "the trap this refusal exists for"
    # A HELD stale value must be refused, not trusted — the operator keeps its last number across
    # upstream failures, so 'present and plausible' is not 'current'.
    bal, at, why = parse_account_credit(fresh, _OP_TS + 4000, 1800)
    assert bal is None and at == _OP_TS and "stale" in why, why
    assert parse_account_credit(fresh, _OP_TS + 4000, 0)[0] == 20.1672, \
        "max_age_s=0 disables the staleness refusal"
    # Never-polled operator: gauge present, timestamp 0.
    never = fresh.replace(str(_OP_TS), "0")
    assert parse_account_credit(never, _OP_TS, 1800)[0] is None, "ts 0 = no poll has succeeded"
    # Operator unreachable / wrong endpoint / gauge renamed — an empty-ish body is no value.
    assert parse_account_credit("# nothing here\n", _OP_TS, 1800)[0] is None
    assert parse_account_credit("", _OP_TS, 1800)[0] is None
    # The proxy's OWN same-named-prefix series must never be mistaken for the operator's gauge.
    assert _prom_sample(f"{ACCOUNT_CREDIT_GAUGE}_bogus 1.0\n", ACCOUNT_CREDIT_GAUGE) is None
    # ── homelab#618: Go capacity latch persistence — survives restarts ──
    # Round-trip: latch → save → load → check it's still there
    now = time.time()
    go_latch_save({"until": now + 1000.0, "reason": "observed-429", "code": 429})
    loaded = go_latch_load()
    assert loaded is not None and loaded["code"] == 429, "go latch round-trip"
    assert loaded["until"] > now, "go latch until_epoch is in the future"
    # Expired latch is not resurrected (until_epoch in the past loads as clear)
    expired_latch = {"until": now - 100.0, "reason": "observed-402", "code": 402}
    go_latch_save(expired_latch)
    expired_loaded = go_latch_load()
    assert expired_loaded is None, "expired go latch must not be resurrected"
    # Active latch clears persisted state (early-clear path)
    go_latch_save({"until": now + 1000.0, "reason": "observed-429", "code": 429})
    go_latch_save({"until": 0.0, "reason": "", "code": 0})  # simulate early clear
    cleared_loaded = go_latch_load()
    assert cleared_loaded is None, "cleared go latch must not persist"
    # Seed a TRUE NULL-rail row (bypassing record_report, which always writes str(None or "") = "")
    # alongside the record_report-written rows whose rail is '' — the migrated-store fixture
    # above is in a throwaway :memory: connection and does NOT populate _conn, so without this
    # row the assertion below would pass even with the buggy raw-GROUP-BY form.
    _conn.execute(
        "INSERT OR REPLACE INTO run_reports(ts,session,task,stack,role,round,model,"
        "served_model,served_provider,cache_hit,cost_usd,error_class,outcome,rail) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (1.0, "null-rail-1", "issue-0", "none", "worker", 1, "m", "", "", 0.0, 0.0, "", "pr", None))
    body = "\n".join(metrics_lines())
    # The store now contains BOTH a genuine NULL-rail row (null-rail-1) and record_report-written
    # rows whose rail is '' (e.g. t-2). The by_rail query must coalesce both to 'unknown' and
    # GROUP BY the coalesced value, producing exactly ONE line — not two with the same label set.
    unknown_lines = [ln for ln in body.split("\n")
                     if 'router_run_reports_by_rail_total{rail="unknown"}' in ln]
    assert len(unknown_lines) == 1, \
        f"expected exactly 1 by_rail unknown line, got {len(unknown_lines)}: {unknown_lines}"
    assert "router_db_persistent 0" in body, "self-test store is ephemeral by construction"
    # Goal #1640 acceptance 1 (reader half): THREE harness-deaths now, where the pre-fix store
    # counted one — issue-19's row moved from the non-member sub-type onto its member, and the
    # metric is the surface where that silence was visible all along (24 of 31 live strikes sat
    # outside the vocabulary on 2026-09-17 and no series said so).
    assert 'router_strikes_total{error_class="harness-death"} 3' in body, \
        [ln for ln in body.split("\n") if "router_strikes_total" in ln]
    assert 'router_strikes_total{error_class="auth-storm"} 2' in body, \
        "the two normalized auth strikes count on the SERVING member, not on http-401-storm"
    assert not any('error_class="http-401-storm"' in ln or 'error_class="goose-32602-truncation"' in ln
                   for ln in body.split("\n")), \
        "no strike series may carry a non-vocabulary class — that is the defect this pins"
    assert 'router_circuit_open_total{class="auth"} 1' in body
    assert 'router_decisions_total{decision="dispatch"' in body
    assert status_summary()["decisions_24h"], "decisions must surface in status"
    assert (_read("SELECT COUNT(*) FROM generations") or [(0,)])[0][0] == 2  # gen-test-1 + gen-drift-1
    assert 'router_generations_total{model="deepseek/deepseek-v4-flash",provider="Fireworks"} 1' in body
    summary_gen = status_summary()["generations_24h"]
    assert summary_gen and summary_gen[0]["observed_cache_hit"] == 0.8, \
        "first full record wins; measured cache hit = 80/100"
    assert 'router_shadow_start_tier{class="coding",urgency="tight"} 0' in body, \
        "the learned cell must surface as a gauge for the M11 soak"
    assert 'router_shadow_decisions_total{rail="anthropic-subscription"' in body, body
    assert 'router_shadow_subscription_blocked_total{reason="subscription-limited:semaphore"} 1' \
        in body, "the FU-088 gate holding the ladder off must be countable"
    summary = status_summary()
    # 10 run_reports (t-1 is INSERT OR REPLACE'd, + t-2 clean, + t-3 the real producer shape,
    # + the 5 M11 ladder-cell fixtures, + the 2 homelab#577 deployed-pod pod-name shapes,
    # + null-rail-1) and 3 strikes (issue-9/sleep from the vocabulary fixture,
    # issue-19/circles from the real one, issue-42/sleep from the ladder's degradation step).
    # homelab#1665 MOVES both counts by the two cap-death fixtures (t-turn-cap, t-tool-loop):
    # each is a run_report AND a strike, so 18→20 and 4→6. The assertion is kept, not dropped.
    # Goal #1640 acceptance 3 MOVES them again by the five strike fixtures (t-strike-pair-1/2,
    # t-strike-pair-3a/3b, t-strike-model-1): each is a run_report AND a strike, so 20→25 and
    # 6→11. Round 3 adds t-strike-cool-1, t-strike-floor-1, t-strike-decor-1: 25→28 and 11→14.
    # Goal #1640 acceptance 5 MOVES them by the pair-cooldown fixtures: four strikes
    # (t-pc-issue-93/94/93b/95) and three clean rides (t-pc-clean-early, t-pc-clean,
    # t-pc-clean-ds) — seven run_reports, four strikes: 28→35 and 14→18.
    assert summary["rows"]["run_reports"] == 37 and summary["rows"]["strikes"] == 20  # + t-pairscope + t-noprov (Goal #1640 acceptance 1 reader half) + + drift-1 + unver-1 + go-drift-1 + go-unver-1 + platform-575 + sleep-iac-577 + agent-runtime-577 + failed-unver-1 + null-rail-1 + t-provider-1 + t-turn-cap + t-tool-loop + t-strike-pair-1 + t-strike-pair-2 + t-strike-pair-3a + t-strike-pair-3b + t-strike-model-1 + t-strike-cool-1 + t-strike-floor-1 + t-strike-decor-1 + t-pc-clean-early + t-pc-issue-93 + t-pc-issue-94 + t-pc-issue-93b + t-pc-issue-95 + t-pc-clean + t-pc-clean-ds
    if _classes:
        # Goal #1769 acceptance 3: tier_thresholds is read PER RAIL now — the Anthropic-only
        # top-level table is retired into `rails.anthropic-subscription.tier_thresholds`.
        _sub_tt = rail_facts(model_id.RAIL_SUBSCRIPTION).get("tier_thresholds") or {}
        assert _sub_tt, "the subscription rail must declare tier_thresholds (FU-109)"
        for tier, thr in _sub_tt.items():
            if tier.startswith("_"):  # _comment keys are docs, not tiers
                continue
            assert 0.0 < float(thr) <= 1.0, f"tier {tier} threshold out of range"
        # …and the `rails:` block declares every canonical rail with the required fields.
        _declared = {r for r in (_classes.get("rails") or {}) if not str(r).startswith("_")}
        assert _declared == set(RAILS), \
            f"the `rails:` block must declare every canonical rail: {_declared} vs {set(RAILS)}"
        for _r in RAILS:
            _f = rail_facts(_r)
            for _k in ("gate", "surfaces", "cost", "windows", "tier_thresholds",
                       "concurrency", "enabled"):
                assert _k in _f, f"rail {_r} must declare `{_k}` in the `rails:` block"
        assert rail_facts(RAIL_OPENCODE_ZEN).get("enabled") is False, \
            "Zen must be declared enabled: false (a rail we chose not to use is DECLARED, not omitted)"
        # Goal #1769 acceptance 1: `classes.<cls>.rails` is written in the CANONICAL rail
        # vocabulary — every entry is a rail this walk can actually produce (or the declared,
        # parse-less Zen leg). A typo or a pre-Goal-#1769 spelling that reached the walk would be
        # an empty pool: a class that silently serves nothing. The alias above covers the old
        # names at load; this is what makes a NEW wrong name a CI failure instead of a silence.
        for _c, _ci in (_classes.get("classes") or {}).items():
            for _r in (_ci.get("rails") or []):
                assert _r in RAILS, \
                    f"class {_c} lists rail {_r!r}, which is not in the canonical vocabulary {RAILS}"
        # M11 policy sanity (homelab#159): the two git-owned halves of the ladder.
        umap = _classes.get("urgency_map") or {}
        assert umap, "model-classes.json must carry urgency_map — it is the table BOTH sides read"
        assert str(umap.get("default", "tight")) in URGENCIES, "urgency_map default must be tight/elastic"
        for scope in ("labels", "roles"):
            for k, v in (umap.get(scope) or {}).items():
                assert str(v) in URGENCIES, f"urgency_map.{scope}[{k}] = {v!r} is not tight/elastic"
        lad = _ladder_cfg()
        assert model_family(lad["subscription_model"]) in _models_table(), \
            "the ladder's subscription candidate must be a graded model (models.<key>.tier)"
        assert 0 <= lad["tight_floor_tier"] < len(LADDER)
        # ADR-104 POOL CURATION invariants (FU-162). The router deliberately does not enforce
        # these at request time — research is an operator-driven lane where visibility is the
        # guard (ADR-104 (3)) — so the enforcement point is HERE, where a hand-seeded edit meets
        # CI. Everything asserted is a property of the TABLE, not of any request.
        pools = _classes.get("pools") or {}
        if pools:
            assert str(pools.get("version") or ""), \
                "pools.version is missing — /route echoes it, and an arm table without it cannot be re-drawn"
            all_classes = _classes.get("classes") or {}
            models = _models_table()
            band_of: dict[str, str] = {}
            for bname, entries in (pools.get("bands") or {}).items():
                assert entries, f"pool {bname} is empty — a band with no depth is not a band"
                selectors = [c for c, ci in all_classes.items()
                             if str(ci.get("pool") or c) == bname]
                assert selectors, f"pool {bname} has no class selecting it (/route's `class` is the selector)"
                fams: set[str] = set()
                for m in entries:
                    assert model_family(m) in models, \
                        f"pool {bname}: {m} is not in the models table — pools draw from the human-approved universe only"
                    assert m not in band_of, \
                        f"bands must be DISJOINT: {m} is in both {band_of[m]} and {bname} (the run-1 self-grading arm)"
                    band_of[m] = bname
                    fam = m.split("/")[0]
                    assert fam not in fams, f"pool {bname}: family {fam} twice — pools are family-deduped"
                    fams.add(fam)
                    # Same rail rule the walk above applies, so a pool cannot hold a model its
                    # own class would skip as rail-not-in-class on every single draw. The rule is
                    # the PARSER's (Goal #1769 acceptance 1) — never a second copy of it.
                    rail = model_id.parse(m)["rail"]
                    for c in selectors:
                        assert rail in (all_classes[c].get("rails") or []), \
                            f"pool {bname}: {m} rides {rail}, absent from class {c} rails"
        cb = _classes.get("circuit_breaker") or {}
        assert int(cb.get("auth_threshold", 4)) < int(cb.get("generic_threshold", 10)), \
            "auth breaker must trip before the generic one (auth never self-heals)"
        # Chain ⊆ models parity (the invariant this file's _comment has CLAIMED since P3 but
        # nothing enforced — found 2026-08-03 when mimo graduated into sleep's chain and its tier
        # entry became a human to-do item instead of a CI failure). The `models` table is the
        # rotation path's human-approved universe (P5): a chain model whose FAMILY is missing from
        # it silently loses rotation visibility. Jail/CI-only: in-pod runs have no stacks.json and
        # skip.
        stacks_path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "agents", "stacks.json")
        if os.path.exists(stacks_path):
            with open(stacks_path) as fh:
                stacks = json.load(fh).get("stacks") or []
            models = _models_table()
            chain_models = set()
            for st in stacks:
                if st.get("workerModel"):
                    chain_models.add(st["workerModel"])
                chain_models.update(st.get("workerModelFallbacks") or [])
            missing = sorted(m for m in chain_models if model_family(m) not in models)
            if missing:
                reg_path = os.path.join(os.path.dirname(stacks_path), ".openrouter-registry.json")
                prices = {}
                if os.path.exists(reg_path):
                    with open(reg_path) as fh:
                        prices = {k: v.get("prompt") for k, v in json.load(fh).get("models", {}).items()}
                for m in missing:
                    p = prices.get(m)
                    tier = ("free" if (m.endswith(":free") or p == 0) else
                            "cheap" if p is not None and p < 0.5 else
                            "large" if p is not None and p < 3 else
                            "premium" if p is not None else "cheap?")
                    print(f'  models MISSING chain entry — add: "{model_family(m)}": '
                          f'{{"ids": {{"{model_id.parse(m)["rail"]}": "{m}"}}, "tier": "{tier}", '
                          f'"context_tokens": null, "tool_verified": null, "pool_usd": null}}'
                          f'{f"  (${p}/M prompt)" if p is not None else "  (not in registry — verify price)"}')
                raise AssertionError(
                    f"the models table must cover every stacks.json chain entry; missing: {missing}")
    # ── homelab#1117: active_cooldowns() role filter on status/metrics call sites ──
    # A model with BOTH a worker-scoped and a probe-scoped cooldown must not collapse into one
    # entry. The status payload must show both roles; the metrics gauge must carry a role label.
    _write("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
           ("dual-role-model", "worker", time.time() + 86400, 1, "429-burst", time.time()))
    _write("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?,?)",
           ("dual-role-model", "probe", time.time() + 86400, 2, "429-burst", time.time()))
    _now_1117 = time.time()
    _all_cool = active_cooldowns(_now_1117)  # no role filter — the OLD shape (collapses)
    # The unfiltered call returns a dict keyed by model, so two rows for the same model
    # collapse into one (last row wins). This is the bug the issue exists to fix — the
    # role-filtered calls below prove the data is not lost, just invisible without a role.
    assert "dual-role-model" in _all_cool, \
        "dual-role-model must appear in unfiltered active_cooldowns() (collapsed but present)"
    _worker_cool = active_cooldowns(_now_1117, role="worker")
    _probe_cool = active_cooldowns(_now_1117, role="probe")
    assert "dual-role-model" in _worker_cool, \
        "dual-role-model must appear in worker-scoped active_cooldowns()"
    assert "dual-role-model" in _probe_cool, \
        "dual-role-model must appear in probe-scoped active_cooldowns()"
    assert len(_worker_cool) + len(_probe_cool) == 2, \
        f"worker+probe cooldowns must not collapse: worker={len(_worker_cool)} probe={len(_probe_cool)}"
    _status = status_summary()
    assert "worker" in _status["cooldowns_active"], \
        "status_summary() cooldowns_active must have a 'worker' key"
    assert "probe" in _status["cooldowns_active"], \
        "status_summary() cooldowns_active must have a 'probe' key"
    assert "dual-role-model" in _status["cooldowns_active"]["worker"], \
        "dual-role-model must appear in status worker cooldowns"
    assert "dual-role-model" in _status["cooldowns_active"]["probe"], \
        "dual-role-model must appear in status probe cooldowns"
    _metrics_body = "\n".join(metrics_lines())
    assert 'router_cooldowns_active{role="worker"}' in _metrics_body, \
        "metrics must have a role=worker gauge line"
    assert 'router_cooldowns_active{role="probe"}' in _metrics_body, \
        "metrics must have a role=probe gauge line"
    # ── #1259: label_map tier_floor/never_free enforcement ──
    # agent-budget/lg: tier_floor="large", never_free=true
    # Use a chain with a :free model, a cheap model, and a large model to prove both filters bind.
    _lg_chain = ["inclusionai/ling-3.0-flash:free", "deepseek/deepseek-v4-flash",
                  "moonshotai/kimi-k3"]
    _lg = route(dict(base, chain=_lg_chain, labels=["agent-budget/lg"]), CTX)
    assert _lg["decision"] == "dispatch", f"lg must dispatch with a large candidate: {_lg}"
    assert _lg["model"] == "moonshotai/kimi-k3", \
        f"lg must pick the large-tier model, got {_lg['model']}"
    _lg_tier = _model_tier(_lg["model"])
    assert _lg_tier and _TIER_ORDER.get(_lg_tier, -1) >= _TIER_ORDER.get("large", -1), \
        f"lg must pick at/above large tier, got {_lg['model']} (tier={_lg_tier})"
    assert not _lg["model"].endswith(":free"), \
        f"lg must never pick a :free model, got {_lg['model']}"
    assert any(s["reason"] == "never-free:label_map" for s in _lg["skipped"]), \
        f"lg must skip :free models: {_lg['skipped']}"
    assert any(s["reason"].startswith("tier-floor:") for s in _lg["skipped"]), \
        f"lg must skip below-floor models: {_lg['skipped']}"
    # agent-budget/md: tier_floor="cheap" — free models excluded, cheap+ passes
    _md = route(dict(base, labels=["agent-budget/md"]), CTX)
    assert _md["decision"] == "dispatch", f"md must dispatch: {_md}"
    assert _md["model"] == "deepseek/deepseek-v4-flash", \
        f"md must pick the first cheap+ model, got {_md['model']}"
    _md_tier = _model_tier(_md["model"])
    assert _md_tier and _TIER_ORDER.get(_md_tier, -1) >= _TIER_ORDER.get("cheap", -1), \
        f"md must pick at/above cheap tier, got {_md['model']} (tier={_md_tier})"
    assert any(s["reason"].startswith("tier-floor:") for s in _md["skipped"]), \
        f"md must skip free models: {_md['skipped']}"
    # The `:free` suffix-floor under a tier_floor:cheap route (the migration's own job — master
    # graded `poolside/laguna-s-2.1:free` "free" and the paid id "cheap"). Offered both, the
    # :free variant is skipped with the typed reason and the paid id is served.
    _laguna_chain = ["poolside/laguna-s-2.1:free", "poolside/laguna-s-2.1"]
    _laguna = route(dict(base, chain=_laguna_chain, labels=["agent-budget/md"]), CTX)
    assert _laguna["decision"] == "dispatch", f"laguna md must dispatch: {_laguna}"
    assert _laguna["model"] == "poolside/laguna-s-2.1", \
        f"md must serve the paid laguna, got {_laguna['model']}"
    assert any(s["model"] == "poolside/laguna-s-2.1:free"
               and s["reason"] == "tier-floor:cheap>free" for s in _laguna["skipped"]), \
        f"the :free laguna must skip with tier-floor:cheap>free: {_laguna['skipped']}"
    # No size label: byte-identical to today's pick (no drift for the untouched majority)
    _no_label = route(dict(base), CTX)
    assert _no_label["decision"] == "dispatch" and _no_label["model"] == "inclusionai/ling-3.0-flash:free", \
        f"no-label must match base pick (no drift): {_no_label}"
    assert not any(s["reason"].startswith("never-free:") or s["reason"].startswith("tier-floor:")
                   for s in _no_label["skipped"]), \
        "no-label must not trigger tier_floor/never_free skips"
    # Multi-label: track/iac + agent-budget/lg — the non-budget label sorts first in GitHub's
    # label list, so this row proves the merge-across-all-labels fix (the first-match capture
    # would silently drop tier_floor/never_free from the budget label).
    _multi = route(dict(base, chain=_lg_chain, labels=["track/iac", "agent-budget/lg"]), CTX)
    assert _multi["decision"] == "dispatch", \
        f"multi-label (track/iac + lg) must dispatch: {_multi}"
    assert _multi["model"] == "moonshotai/kimi-k3", \
        f"multi-label must pick the large-tier model, got {_multi['model']}"
    _multi_tier = _model_tier(_multi["model"])
    assert _multi_tier and _TIER_ORDER.get(_multi_tier, -1) >= _TIER_ORDER.get("large", -1), \
        f"multi-label must pick at/above large tier, got {_multi['model']} (tier={_multi_tier})"
    assert not _multi["model"].endswith(":free"), \
        f"multi-label must never pick a :free model, got {_multi['model']}"
    assert any(s["reason"] == "never-free:label_map" for s in _multi["skipped"]), \
        f"multi-label must skip :free models: {_multi['skipped']}"
    assert any(s["reason"].startswith("tier-floor:") for s in _multi["skipped"]), \
        f"multi-label must skip below-floor models: {_multi['skipped']}"
    # Clean up the test rows so they don't pollute later assertions
    _write("DELETE FROM model_cooldowns WHERE model='dual-role-model'", ())
    print("router self-test: OK "
          f"(classes {'loaded' if _classes else 'absent — jail run without the file is fine'})")
    return 0


if __name__ == "__main__":  # the only CLI mode is the self-test (CI + jail probes)
    sys.exit(self_test())
