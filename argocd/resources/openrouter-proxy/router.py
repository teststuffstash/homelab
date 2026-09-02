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

# Strike taxonomy (model-routing.md §M1): these error classes are INFRA failures — they blacklist
# the (task, model) pair without consuming a round. Kept in step with agent-session.sh's
# classifier and agent-finalize (the authoritative signature copy).
STRIKE_CLASSES = {"harness-death", "auth-storm", "timeout", "provider-5xx", "no-pr", "unknown"}

# FU-201 c: serving-shaped strike classes — provider-side failures that exclude the (model,
# provider) PAIR rather than the model entirely. A model-level blacklist needs ≥2-provider
# evidence (the #783 rule). These classes are the ADR-115 evidence set: provider 4xx/5xx
# responses and tool-call malformation that the serving provider caused.
SERVING_CLASSES = {"provider-5xx", "timeout", "auth-storm"}

# ⚑ ENFORCEMENT IS OFF BY DEFAULT — operator ruling 2026-08-07, and it makes an ACCIDENT explicit.
# Strikes were never being recorded (the drift below), so `route()` has always filtered against an
# empty table. That accident turned out to be *better* than the design: circles#19 died on
# deepseek-v4-flash at r1 and the SAME model completed the SAME task at r2 — a strike would have
# pushed it to a pricier chain entry for nothing. Tally so far is 3 deaths vs 3 clean runs on lg
# work, i.e. "N strikes and you're out" is not supported by the evidence; "retry, or fan out N
# parallel and keep the survivor" may well be cheaper than the next model in the chain.
# So: RECORD the strikes (we need the data to decide), do NOT act on them yet. Flip this on only
# with a policy decision behind it — see docs/agents/model-routing.md §M1a.
STRIKE_ENFORCE = os.environ.get("ROUTER_STRIKE_ENFORCE", "0").strip().lower() not in ("", "0", "false", "no", "off")
# Retention (days): the FU-057 ledger (pushgateway + transcripts) is the long-horizon store;
# this DB answers "recent enough to route on".
RETAIN_EVENTS_D = 30   # provider_events, decisions
RETAIN_REPORTS_D = 90  # run_reports, strikes

_SCHEMA = """
CREATE TABLE IF NOT EXISTS strikes(
  ts REAL, task TEXT, stack TEXT, model TEXT, error_class TEXT, round INTEGER, session TEXT,
  provider TEXT);
CREATE INDEX IF NOT EXISTS ix_strikes ON strikes(stack, task, model);
CREATE TABLE IF NOT EXISTS provider_events(
  ts REAL, model TEXT, provider TEXT, status INTEGER, class TEXT);
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
  model TEXT, reason TEXT, detail TEXT);
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
# resort. See docs/agents/model-routing.md §M11.
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
                # proxy-side from generations in record_report(). Same LAST-column discipline.
                try:
                    conn.execute("ALTER TABLE strikes ADD COLUMN provider TEXT")
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
    _log(f"store={'persistent' if _persistent else 'ephemeral'} "
         f"classes={'loaded' if _classes else 'defaults'}")
    return _persistent


def classes() -> dict:
    return _classes


def tier_threshold(tier: str | None, default: float) -> float:
    """FU-109: the per-consumer utilization threshold. Unknown/absent tier = the global default
    (bare /anthropic-limit keeps today's behavior exactly)."""
    try:
        return float((_classes.get("tier_thresholds") or {})[tier])
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


def record_report(d: dict) -> tuple[bool, bool]:
    """One POST /report body → run_reports (+ a strikes row when it IS a strike: strike-class
    error and no PR came out — mirrors the launcher's AGENT_STRIKE condition; the GitHub comment
    stays the human/audit twin). Returns (stored, striked). Idempotent per session (the launcher
    may retry): INSERT OR REPLACE on the session key."""
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
    # model-routing.md §M1 settles that this is a bug, not a policy: its taxonomy table names
    # "harness-death (goose -32602)" as ONE thing.
    # FU-201 c: the served provider is sourced proxy-side from the generations table (the
    # launcher's /report body does not carry it). The generation harvest runs alongside the
    # data plane, so by the time record_report() is called the generation row for this session
    # already exists. Absent a generation row, provider defaults to empty string — the strike
    # still records, just without provider attribution.
    session = str(d.get("session") or "")
    provider = str(d.get("served_provider") or "")
    if not provider:
        _prov = _read("SELECT provider FROM generations WHERE id=?",
                       (session,))
        provider = str(_prov[0][0]) if _prov else ""
    striked = False
    if stored and (err in STRIKE_CLASSES or outcome in STRIKE_CLASSES) \
            and not outcome.startswith("pr"):
        # Dedup per (task, model, session): a re-POST must not double-strike.
        _write("DELETE FROM strikes WHERE task=? AND model=? AND session=?",
               (str(d.get("task") or ""), str(d.get("model") or ""), session))
        striked = _write(
            "INSERT INTO strikes VALUES(?,?,?,?,?,?,?,?)",
            (now, str(d.get("task") or ""), str(d.get("stack") or ""), str(d.get("model") or ""),
             err, int(d.get("round") or 1), session, provider))
    if stored:  # M11 leg 3 (shadow): the same feed, folded into the (class, urgency) start tier
        fold = fold_outcome_into_cell(d, striked)
        if fold:
            _log(f"ladder cell {fold['class']}/{fold['urgency']}: {fold['verdict']} at "
                 f"{fold['used_tier']} → start_tier={fold['start_tier']} (shadow)")
    return stored, striked


def _ladder_cfg() -> dict:
    cfg = _classes.get("ladder") or {}
    return {"subscription_model": str(cfg.get("subscription_model") or "claude/haiku"),
            "promote_after": max(1, int(cfg.get("promote_after", 3))),
            "tight_floor_tier": min(len(LADDER) - 1, max(0, int(cfg.get("tight_floor_tier", 1))))}


def ladder_tier(model: str, rail: str, price: float | None) -> int:
    """Which RUNG a candidate sits on. Rail decides the subscription rung (it is the rail that is
    already paid for, whatever the model id); on the OpenRouter rail a $0 price is the free rung
    and everything else is the paid one."""
    if rail == "subscription":
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
    rail = "subscription" if model.startswith("claude/") else "openrouter"
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


def record_provider_event(model: str, provider: str, status: int) -> None:
    """Passive data-plane observation: one row per forwarded OpenRouter chat/completions
    response. `class` buckets the status for cheap aggregation.
    FU-186 step 1: strip :exacto suffix so cooldown/breaker bookkeeping is keyed under the
    bare model id — the same id the /route eligibility loop filters candidates against."""
    model = model.removesuffix(":exacto")
    klass = ("2xx" if 200 <= status < 300 else
             "429" if status == 429 else
             "4xx" if 400 <= status < 500 else
             "5xx" if status >= 500 else "other")
    _write("INSERT INTO provider_events VALUES(?,?,?,?,?)",
           (time.time(), model, provider or "", status, klass))


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


def _rotation_candidates(cinfo: dict) -> list[str]:
    """P5: the class candidate list when the caller passes NO chain — rotation-fed. Universe =
    model_tiers keys (the human-approved set; graduation stays human), ordered: class chain_head
    first, then daily-rankings rank order, then the git rotation_fallback belt. Models whose
    canary verdict says broken are excluded."""
    tiers = _classes.get("model_tiers") or {}
    rows = _read("SELECT model, source, canary_verdict, rank FROM rotation")
    broken = {m for m, _s, v, _r in rows if v == "broken"}
    ranked = sorted(((r or 0, m) for m, s, _v, r in rows
                     if s == "openrouter-daily-rankings" and m in tiers and m not in broken))
    kind = "reasoning" if cinfo.get("reasoning") else "coding"
    fallback = (_classes.get("rotation_fallback") or {}).get(kind) or []
    out: list[str] = []
    for m in (list(cinfo.get("chain_head") or []) + [m for _r, m in ranked]
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
                   cool: dict, ctx: dict, sub_gate, or_gate, jitter: float, pick) -> dict:
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
        if rail == "subscription":
            ok, reason, _retry = sub_gate()
            if ok:
                price, basis = 0.0, "subscription"
            else:
                blocked = reason or "subscription-limited"
        else:
            ok, reason = or_gate()
            if ok:
                price, basis = ctx["price"](model)
            else:
                blocked = reason or "openrouter-unavailable"
        return {"model": model, "rail": rail, "_t": ladder_tier(model, rail, price),
                "price_per_mtok": price, "basis": basis, "blocked": blocked}

    cands = [_rung(m, rail) for m, rail in eligible]
    sub_model = cfg["subscription_model"]
    if (not any(c["rail"] == "subscription" for c in cands) and "subscription" in rails
            and sub_model not in deny and sub_model not in struck_models and sub_model not in cool
            and capability_floor_block(cls, sub_model) is None):
        # The rail enters the ordering as a CANDIDATE even when no chain names it — that is leg 1.
        cands.append({**_rung(sub_model, "subscription"), "synthetic": True})
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
    sub = next((c for c in cands if c["rail"] == "subscription"), None)
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
              urgency?, slot?, jitter?}
    ctx:     {price: fn(model)->(usd_per_mtok|None, basis|None),
              subscription_ok: fn(tier)->(ok, reason|None, retry_after_s),
              openrouter_ok:  fn(key_ref)->(ok, reason|None),
              pick: fn(list)->item  (optional; defaults to uniform random — the jitter band.
                    Unused under `jitter: false`, where the tie-break is caller/pool order)}

    Walk: resolve class (explicit > label_map > role_defaults) → candidates (a `slot` DRAW on the
    class's curated pool, else the chain, else rotation-fed) → filter deny/strikes/cooldowns/rail
    → per class-rail-order pick the effective-cheapest with a jitter-band uniform pick → capacity-
    gate the rail → dispatch, or a TYPED defer (capacity reasons and cooldowns carry retry_after;
    only chain-exhausted escalates — M1 doctrine).

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
    for lab in labels:
        entry = label_map.get(lab) or {}
        if entry.get("class") and not cls:
            cls = str(entry["class"])
    if not cls:
        cls = str((_classes.get("role_defaults") or {}).get(role) or "coding")
    cinfo = (_classes.get("classes") or {}).get(cls) or {}
    tier = str(payload.get("tier") or cinfo.get("tier") or "heavy")
    rails = list(cinfo.get("rails") or ["openrouter", "subscription"])
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
    # FU-201 c: strike rows carry provider + error_class. Serving-shaped strikes (provider-5xx,
    # timeout, auth-storm) exclude the (model, provider) PAIR — the model stays eligible for
    # re-pick with a different provider. Infra-shaped strikes (harness-death, no-pr, unknown)
    # exclude the model entirely. A model with serving-shaped strikes from ≥2 providers is
    # excluded at model level (the #783 rule: model-level verdicts need multi-provider evidence).
    # Recorded always, ACTED ON only when STRIKE_ENFORCE (see the constant's note): today this is
    # an empty set, which is exactly the behaviour the loop has had all along — now on purpose.
    _strike_rows = strikes_for(str(payload.get("task") or ""),
                               str(payload.get("stack") or "")) if STRIKE_ENFORCE else []
    struck_models: set[str] = set()
    _serving_providers: dict[str, set[str]] = {}
    for _m, _p, _ec in _strike_rows:
        if _ec in SERVING_CLASSES:
            if _p:
                _serving_providers.setdefault(_m, set()).add(_p)
        else:
            struck_models.add(_m)
    for _m, _providers in _serving_providers.items():
        if len(_providers) >= 2:
            struck_models.add(_m)
    cool = active_cooldowns(now, role=role)
    skipped: list[dict] = list(pre_skipped)
    eligible: list[tuple[str, str]] = []
    for m in chain:
        rail = "subscription" if m.startswith("claude/") else "openrouter"
        if m in deny:
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
        elif decorrelate_family:
            if vendor_family(m) == decorrelate_family:
                skipped.append({"model": m, "reason": f"decorrelate:{decorrelate_family}"})
            else:
                eligible.append((m, rail))
        else:
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
            _gate_cache["or"] = ctx["openrouter_ok"](payload.get("key_ref"))
        return _gate_cache["or"]

    for rail in rails:
        pool = [m for m, r in eligible if r == rail]
        if not pool:
            continue
        if rail == "subscription":
            ok, reason, retry = sub_gate()
            if not ok:
                reason = reason or "subscription-limited"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": retry}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            result = {"model": pool[0], "rail": rail, "price_per_mtok": None,
                      "basis": "subscription", "jitter_pool": pool[:1]}
        else:
            ok, reason = or_gate()
            if not ok:
                reason = reason or "openrouter-budget-exhausted"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": 900}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            priced = [(m, *ctx["price"](m)) for m in pool]
            known = [p for p in priced if p[1] is not None]
            if known:
                floor = min(p[1] for p in known)
                band = [p for p in known if p[1] <= floor * (1 + jitter) + 1e-12]
                pick = pick_fn(band)
            else:
                pick, band = priced[0], priced[:1]  # unpriced chain: keep caller order
            result = {"model": pick[0], "rail": rail, "price_per_mtok": pick[1],
                      "basis": pick[2], "jitter_pool": [p[0] for p in band]}
        break
    # FU-186 step 1: class-level provider_policy — append :exacto suffix when the resolved
    # class carries provider_policy: "exacto", so the completion path skips pin injection
    # (the :exacto suffix is already handled at openrouter-proxy.py L3232/L3302).
    if result and cinfo.get("provider_policy") == "exacto":
        result["model"] += ":exacto"
    if result:
        half_open = bool(_read(
            "SELECT 1 FROM model_cooldowns WHERE model=? AND role=? AND until <= ?",
            (result["model"], role, now)))
        decision = {"decision": "dispatch", "class": cls, "tier": tier, "source": source,
                    "half_open": half_open, "skipped": skipped, "jitter": jitter_on,
                    "provider_policy": cinfo.get("provider_policy"), **result}
    else:
        if decorrelate_family and not eligible and skipped and \
                all(s["reason"] == f"decorrelate:{decorrelate_family}" for s in skipped):
            reason = f"decorrelate:{decorrelate_family}"
            retry = None
        elif capacity_block:
            reason, retry = capacity_block["reason"], capacity_block.get("retry_after_s") or 900
        elif any(s["reason"].startswith("cooldown:") for s in skipped):
            reason = "cooldown"
            retry = min(s.get("retry_after_s") or 900
                        for s in skipped if s["reason"].startswith("cooldown:"))
        else:
            reason = "chain-exhausted"  # deny/strike only — the one defer that escalates
            retry = None
        decision = {"decision": "defer", "reason": reason, "retry_after_s": retry,
                    "class": cls, "tier": tier, "source": source, "skipped": skipped,
                    "jitter": jitter_on}
    if drawn:
        # The draw's provenance rides BOTH verdicts: a deferred slot has to be recordable in the
        # arm table too ("slot 4 deferred, cooldown" is evidence; a blank is not).
        decision.update({k: v for k, v in drawn.items() if k in ("pool", "pool_version", "slot")})
    # FU-127: the structured carrier — consumers read `.decision.resolved` instead of re-parsing
    # the model string. Present on dispatch, absent on defer (no model to resolve). The rail in
    # resolved uses the canonical vocabulary (anthropic-subscription, openrouter, opencode-go)
    # while decision.rail uses the route's internal vocabulary (subscription, openrouter).
    if result:
        decision["resolved"] = model_id.parse(result["model"])
    # ── M11 SHADOW (homelab#159) — computed after the served decision, consumed by nobody ──
    shadow = _shadow_ladder(payload, cls, rails, eligible, deny, struck_models, cool, ctx,
                            sub_gate, or_gate, jitter, pick_fn)
    # FU-127: the shadow pick carries its own resolved object so the M11 shadow log line
    # describes the SHADOW pick, not the served pick (which may differ — that's the entire
    # point of the shadow line). Present on dispatch, absent on defer.
    if shadow.get("model"):
        shadow["resolved"] = model_id.parse(shadow["model"])
    record_shadow_decision(payload, cls, decision, shadow)
    decision["shadow"] = shadow
    _write("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?)",
           (now, str(payload.get("session") or ""), str(payload.get("stack") or ""), role, cls,
            decision["decision"], decision.get("rail") or "",
            decision.get("model") or "", decision.get("reason") or "",
            json.dumps({"skipped": skipped, "source": source,
                        "jitter_pool": decision.get("jitter_pool"), "shadow": shadow})))
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
        "SELECT model, error_class, COUNT(*) FROM strikes WHERE ts > ? "
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
        "SELECT decision, rail, model, reason, COUNT(*) FROM decisions WHERE ts > ? "
        "GROUP BY decision, rail, model, reason ORDER BY 5 DESC LIMIT 20", (now - 86400,))
    return {
        "cooldowns_active": {
            "worker": active_cooldowns(now, role="worker"),
            "probe": active_cooldowns(now, role="probe"),
        },
        "decisions_24h": [
            {"decision": d, "rail": rl, "model": m, "reason": rs, "n": n}
            for d, rl, m, rs, n in decisions_24h],
        "db_persistent": _persistent,
        "rows": counts,
        "strikes_7d": [{"model": m, "error_class": e, "n": n} for m, e, n in recent_strikes],
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
        "tier_thresholds": _classes.get("tier_thresholds") or {},
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
    stored, striked = record_report({
        "session": "t-1", "task": "issue-9", "stack": "sleep", "role": "worker", "round": 2,
        "model": "deepseek/deepseek-v4-flash", "cost_usd": 0.12,
        "error_class": "harness-death", "outcome": "no-pr"})
    assert stored and striked, "strike-class report must store + strike"
    stored2, striked2 = record_report({
        "session": "t-1", "task": "issue-9", "stack": "sleep",
        "model": "deepseek/deepseek-v4-flash", "error_class": "harness-death",
        "outcome": "no-pr"})
    assert stored2 and striked2, "re-POST must remain idempotent"
    assert (_read("SELECT COUNT(*) FROM strikes") or [(0,)])[0][0] == 1, "no double-strike"
    clean, striked3 = record_report({
        "session": "t-2", "task": "issue-9", "stack": "sleep",
        "model": "qwen/qwen3-coder", "cost_usd": 0.31, "error_class": "", "outcome": "pr"})
    assert clean and not striked3, "clean run must not strike"
    # THE REAL PRODUCER SHAPE (agent-session.sh's /report body), added 2026-08-07. The fixtures
    # above put "harness-death" in `error_class` — the taxonomy's own vocabulary, a shape the
    # launcher never sends — so they passed while router_strikes_total sat at 1 through three real
    # harness deaths. This row is what actually arrives: the coarse class in `outcome`, a finer
    # sub-type in `error_class`. Same trap as FU-115b, where the fixture matched the buggy code
    # instead of the caller's output.
    stored4, striked4 = record_report({
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
    assert strikes_for("issue-19", "circles") == [("deepseek/deepseek-v4-flash", "", "goose-32602-truncation")]
    # Recording is not acting: enforcement stays OFF until a policy decision (see STRIKE_ENFORCE).
    assert STRIKE_ENFORCE is False, "strike enforcement must default OFF — routing is unchanged by design"
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
    # ── gometer WINDOW DRAW pricing (2026-08-17 defect): list price on raw tokens, badged ──
    import gometer  # shared home (ADR-108) — the semantics under test
    # Console reconciliation (uploads/opencode-go.txt): a 5h window of 50.56M in / 0.488M out of
    # badged deepseek-v4-flash drew ≈ $4.32 (console) while the old cache-priced meter read
    # $0.145 (~30× low). LIST prices: flash in $0.14/M, out $0.28/M, half=True.
    #   input  50.56M × 0.14 = 7.0784  → ÷2 = 3.5392
    #   output  0.488M × 0.28 = 0.13664 → ÷2 = 0.06832
    #   draw = 3.60752  (NOT the ~$0.14 cents a cache-read interpretation gives)
    _raw_merge = {"input_tokens": 50560000, "output_tokens": 488000}
    _cal = gometer.window_draw("deepseek-v4-flash", _raw_merge)
    assert 3.5 <= _cal <= 3.75, f"window_draw calibration: {_cal} (expected ≈3.61 from list prices)"
    # ── homelab#540: price() is BILLED = list ×1, badge models included, NO halving ──
    # The matrix's console-verified ruling (docs/spikes/opencode-model-matrix.md): billed Cost =
    # list ×1 for EVERY model, badged included; the badge halving is the WINDOW-DRAW
    # (limit-side) effect only. deepseek-v4-flash (half=True) 1M in + 1M out:
    #   billed = 1e6×0.14/1e6 + 1e6×0.28/1e6 = 0.14 + 0.28 = $0.42  (NOT $0.21)
    _bill_merge = {"input_tokens": 1000000, "output_tokens": 1000000}
    _bill = gometer.price("deepseek-v4-flash", _bill_merge)[0]
    assert abs(_bill - 0.42) < 1e-9, f"price() must bill badge models at list ×1: {_bill} != 0.42"
    # and the DRAW of the SAME physical completion IS badge-halved: 0.42 × 0.5 = $0.21.
    _draw_same = gometer.window_draw("deepseek-v4-flash", _bill_merge)
    assert abs(_draw_same - 0.21) < 1e-9, f"window_draw must badge-halve the same completion: {_draw_same}"
    # The OLD meter's view — the same physical input reported as cache-read (the "assumes
    # cache-read pricing" bug): 50.56M at the cR rate 0.0028/M → cents, not dollars. The billed
    # side is now list ×1, so the cache-read view prices at the cR rate ×1 (no halving).
    _old_view = {"input_tokens": 0, "cache_read_input_tokens": 50560000,
                 "output_tokens": 488000}
    _billed_old = gometer.price("deepseek-v4-flash", _old_view)[0]
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
    CTX = {
        "price": lambda m: (0.0, "free") if m.endswith(":free") else
                           ({"tencent/hy3": (0.041, "market"),
                             "deepseek/deepseek-v4-flash": (0.033, "market")}.get(m, (None, None))),
        "subscription_ok": lambda tier: (True, None, 0),
        "openrouter_ok": lambda ref: (True, None),
        "pick": lambda band: band[0],  # deterministic for the test
    }
    CHAIN = ["inclusionai/ling-3.0-flash:free", "deepseek/deepseek-v4-flash", "tencent/hy3",
             "claude/haiku"]
    base = {"stack": "sleep", "task": "issue-42", "role": "worker", "session": "t-route",
            "chain": CHAIN}
    d = route(dict(base), CTX)
    assert d["decision"] == "dispatch" and d["model"] == "inclusionai/ling-3.0-flash:free", d
    assert d["rail"] == "openrouter" and d["class"] == "coding", d
    # FU-127: the structured carrier — shape AND string↔structured parity for each rail prefix.
    # openrouter rail, bare vendor/model (the common case)
    assert d.get("resolved") == {"rail": "openrouter", "harness": "", "model": "inclusionai/ling-3.0-flash:free"}, \
        f"resolved shape (openrouter bare): {d.get('resolved')}"
    # subscription rail: claude/ prefix → anthropic-subscription, harness claude
    _sub = route(dict(base, chain=["claude/haiku"]), CTX)
    assert _sub["decision"] == "dispatch" and _sub["rail"] == "subscription", _sub
    assert _sub.get("resolved") == {"rail": "anthropic-subscription", "harness": "claude", "model": "haiku"}, \
        f"resolved shape (subscription): {_sub.get('resolved')}"
    # opencode-go rail: prefix kept, harness claude
    _go = route(dict(base, chain=["opencode-go/deepseek-v4-flash"]), CTX)
    assert _go["decision"] == "dispatch" and _go["rail"] == "openrouter", _go
    assert _go.get("resolved") == {"rail": "opencode-go", "harness": "claude", "model": "opencode-go/deepseek-v4-flash"}, \
        f"resolved shape (opencode-go): {_go.get('resolved')}"
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
    # (a) With no class carrying provider_policy, an audit/research route serving
    #     openrouter/fusion is pin-preserving (no :exacto suffix, no provider_policy key).
    _audit = route(dict(base, role="audit", chain=["openrouter/fusion"]), CTX)
    assert _audit["decision"] == "dispatch" and _audit["model"] == "openrouter/fusion", \
        f"audit route must serve openrouter/fusion without :exacto: {_audit}"
    assert _audit.get("provider_policy") is None, \
        f"audit class has no provider_policy: {_audit}"
    # (b) A class that DOES carry provider_policy: "exacto" appends :exacto and echoes the policy.
    _saved_classes = copy.deepcopy(_classes)
    _classes["classes"]["coding"]["provider_policy"] = "exacto"
    _exacto = route(dict(base), CTX)  # role=worker → class coding
    assert _exacto["decision"] == "dispatch" and _exacto["model"] == "inclusionai/ling-3.0-flash:free:exacto", \
        f"coding with provider_policy=exacto must append :exacto: {_exacto}"
    assert _exacto.get("provider_policy") == "exacto", \
        f"decision must echo provider_policy: {_exacto}"
    _classes.clear()
    _classes.update(copy.deepcopy(_saved_classes))
    # (c) NON-VACUOUS: cooldown/breaker bookkeeping under the BARE id, not the :exacto-suffixed id.
    #     This assertion goes RED against the pre-fix source (where or_model kept the suffix) and
    #     GREEN after the fix (openrouter-proxy.py strips :exacto from the bookkeeping key).
    _classes["classes"]["coding"]["provider_policy"] = "exacto"
    _exacto2 = route(dict(base), CTX)
    _exacto_model = _exacto2["model"]  # e.g. "inclusionai/ling-3.0-flash:free:exacto"
    _bare_model = _exacto_model.removesuffix(":exacto")  # e.g. "inclusionai/ling-3.0-flash:free"
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
    dv = route(dict(base, chain=[]), {**CTX, "price": lambda m: (0.05, "market")})
    assert dv["decision"] == "dispatch" and dv["source"] == "rotation", dv
    assert dv["model"] == "tencent/hy3", dv
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
    assert (sh["model"], sh["rail"], sh["ladder_tier"]) == ("claude/haiku", "subscription",
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
        record_report({"session": sess, "task": "issue-42", "stack": "sleep", "role": "worker",
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
        assert du["decision"] == "dispatch" and du["rail"] == "subscription", du
        assert du["model"] == _bands["ultra"][0], du
    # JITTER SUPPRESSED, on the ordinary chain path too: three equally-priced candidates put the
    # tie-break in the open. With the band live, the ctx picker roams it; with `jitter: false` the
    # pick is the first in caller order and the shadow ladder stops re-probing a rung down.
    # (class `review`, whose ladder cell is still unproven here — the `coding` cell was promoted
    # to the free rung by the leg-3 fixtures above, and a proven cell never re-probes.)
    EQ = {**CTX, "price": lambda m: (0.05, "market"), "pick": lambda b: b[-1]}
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
    assert 'router_strikes_total{error_class="harness-death"} 1' in body
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
    assert 'router_shadow_decisions_total{rail="subscription"' in body, body
    assert 'router_shadow_subscription_blocked_total{reason="subscription-limited:semaphore"} 1' \
        in body, "the FU-088 gate holding the ladder off must be countable"
    summary = status_summary()
    # 10 run_reports (t-1 is INSERT OR REPLACE'd, + t-2 clean, + t-3 the real producer shape,
    # + the 5 M11 ladder-cell fixtures, + the 2 homelab#577 deployed-pod pod-name shapes,
    # + null-rail-1) and 3 strikes (issue-9/sleep from the vocabulary fixture,
    # issue-19/circles from the real one, issue-42/sleep from the ladder's degradation step).
    assert summary["rows"]["run_reports"] == 17 and summary["rows"]["strikes"] == 3  # + drift-1 + unver-1 + go-drift-1 + go-unver-1 + platform-575 + sleep-iac-577 + agent-runtime-577 + failed-unver-1 + null-rail-1
    if _classes:
        assert "tier_thresholds" in _classes, "model-classes.json must carry tier_thresholds"
        for tier, thr in _classes["tier_thresholds"].items():
            if tier.startswith("_"):  # _comment keys are docs, not tiers
                continue
            assert 0.0 < float(thr) <= 1.0, f"tier {tier} threshold out of range"
        # M11 policy sanity (homelab#159): the two git-owned halves of the ladder.
        umap = _classes.get("urgency_map") or {}
        assert umap, "model-classes.json must carry urgency_map — it is the table BOTH sides read"
        assert str(umap.get("default", "tight")) in URGENCIES, "urgency_map default must be tight/elastic"
        for scope in ("labels", "roles"):
            for k, v in (umap.get(scope) or {}).items():
                assert str(v) in URGENCIES, f"urgency_map.{scope}[{k}] = {v!r} is not tight/elastic"
        lad = _ladder_cfg()
        assert lad["subscription_model"] in (_classes.get("model_tiers") or {}), \
            "the ladder's subscription candidate must be a graded model (model_tiers)"
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
            tiers = _classes.get("model_tiers") or {}
            band_of: dict[str, str] = {}
            for bname, entries in (pools.get("bands") or {}).items():
                assert entries, f"pool {bname} is empty — a band with no depth is not a band"
                selectors = [c for c, ci in all_classes.items()
                             if str(ci.get("pool") or c) == bname]
                assert selectors, f"pool {bname} has no class selecting it (/route's `class` is the selector)"
                fams: set[str] = set()
                for m in entries:
                    assert m in tiers, \
                        f"pool {bname}: {m} is not in model_tiers — pools draw from the human-approved universe only"
                    assert m not in band_of, \
                        f"bands must be DISJOINT: {m} is in both {band_of[m]} and {bname} (the run-1 self-grading arm)"
                    band_of[m] = bname
                    fam = m.split("/")[0]
                    assert fam not in fams, f"pool {bname}: family {fam} twice — pools are family-deduped"
                    fams.add(fam)
                    # Same rail rule the walk above applies, so a pool cannot hold a model its
                    # own class would skip as rail-not-in-class on every single draw.
                    rail = "subscription" if m.startswith("claude/") else "openrouter"
                    for c in selectors:
                        assert rail in (all_classes[c].get("rails") or []), \
                            f"pool {bname}: {m} rides {rail}, absent from class {c} rails"
        cb = _classes.get("circuit_breaker") or {}
        assert int(cb.get("auth_threshold", 4)) < int(cb.get("generic_threshold", 10)), \
            "auth breaker must trip before the generic one (auth never self-heals)"
        # Chain ⊆ model_tiers parity (the invariant this file's _comment has CLAIMED since P3 but
        # nothing enforced — found 2026-08-03 when mimo graduated into sleep's chain and its tier
        # entry became a human to-do item instead of a CI failure). model_tiers is the rotation
        # path's human-approved universe (P5): a chain model missing from it silently loses
        # rotation visibility. Jail/CI-only: in-pod runs have no stacks.json and skip.
        stacks_path = os.path.join(os.path.dirname(__file__), "..", "..", "..", "agents", "stacks.json")
        if os.path.exists(stacks_path):
            with open(stacks_path) as fh:
                stacks = json.load(fh).get("stacks") or []
            tiers = _classes.get("model_tiers") or {}
            chain_models = set()
            for st in stacks:
                if st.get("workerModel"):
                    chain_models.add(st["workerModel"])
                chain_models.update(st.get("workerModelFallbacks") or [])
            missing = sorted(m for m in chain_models if m not in tiers)
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
                    print(f'  model_tiers MISSING chain entry — add: "{m}": "{tier}"'
                          f'{f"  (${p}/M prompt)" if p is not None else "  (not in registry — verify price)"}')
                raise AssertionError(
                    f"model_tiers must cover every stacks.json chain entry; missing: {missing}")
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
    # Clean up the test rows so they don't pollute later assertions
    _write("DELETE FROM model_cooldowns WHERE model='dual-role-model'", ())
    print("router self-test: OK "
          f"(classes {'loaded' if _classes else 'absent — jail run without the file is fine'})")
    return 0


if __name__ == "__main__":  # the only CLI mode is the self-test (CI + jail probes)
    sys.exit(self_test())
