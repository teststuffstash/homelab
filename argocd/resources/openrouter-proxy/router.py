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

import json
import os
import random
import sqlite3
import sys
import threading
import time

# Strike taxonomy (model-routing.md §M1): these error classes are INFRA failures — they blacklist
# the (task, model) pair without consuming a round. Kept in step with agent-session.sh's
# classifier and agent-finalize (the authoritative signature copy).
STRIKE_CLASSES = {"harness-death", "auth-storm", "timeout", "provider-5xx", "no-pr", "unknown"}

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
  ts REAL, task TEXT, stack TEXT, model TEXT, error_class TEXT, round INTEGER, session TEXT);
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
  model TEXT PRIMARY KEY, until REAL, streak INTEGER, reason TEXT, set_ts REAL);
CREATE TABLE IF NOT EXISTS capability(
  model TEXT, source TEXT, intelligence REAL, coding REAL, agentic REAL, updated_ts REAL,
  PRIMARY KEY(model, source));
CREATE TABLE IF NOT EXISTS task_market(
  tag TEXT, model TEXT, rank INTEGER, usage_share REAL, token_share REAL, updated_ts REAL,
  PRIMARY KEY(tag, model));
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
    striked = False
    if stored and (err in STRIKE_CLASSES or outcome in STRIKE_CLASSES) \
            and not outcome.startswith("pr"):
        # Dedup per (task, model, session): a re-POST must not double-strike.
        _write("DELETE FROM strikes WHERE task=? AND model=? AND session=?",
               (str(d.get("task") or ""), str(d.get("model") or ""), str(d.get("session") or "")))
        striked = _write(
            "INSERT INTO strikes VALUES(?,?,?,?,?,?,?)",
            (now, str(d.get("task") or ""), str(d.get("stack") or ""), str(d.get("model") or ""),
             err, int(d.get("round") or 1), str(d.get("session") or "")))
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
    response. `class` buckets the status for cheap aggregation."""
    klass = ("2xx" if 200 <= status < 300 else
             "429" if status == 429 else
             "4xx" if 400 <= status < 500 else
             "5xx" if status >= 500 else "other")
    _write("INSERT INTO provider_events VALUES(?,?,?,?,?)",
           (time.time(), model, provider or "", status, klass))


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


def strikes_for(task: str, stack: str) -> list[str]:
    """Models struck for THIS task (M1: blacklists are task-scoped) — the /route filter in P3;
    /router-status shows it today."""
    return [r[0] for r in _read(
        "SELECT DISTINCT model FROM strikes WHERE task=? AND stack=?", (task, stack))]


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


def cooldown_note(model: str, status: int) -> str | None:
    """Fold one passive provider event into the cooldown state. Returns 'tripped'/'cleared'
    for the data plane's log line, else None. Called AFTER record_provider_event."""
    now = time.time()
    if 200 <= status < 300:
        # Verified working for OUR account — clear any hold and reset the escalation streak.
        if _read("SELECT 1 FROM model_cooldowns WHERE model=?", (model,)):
            _write("DELETE FROM model_cooldowns WHERE model=?", (model,))
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
    cur = _read("SELECT until, streak FROM model_cooldowns WHERE model=?", (model,))
    if cur and cur[0][0] > now:
        return None  # already holding — don't extend on every event inside the window
    streak = (cur[0][1] if cur else 0) + 1
    hold = min(cfg["base_s"] * (2 ** (streak - 1)), cfg["max_s"])
    reason = ("429-burst" if n429 >= max(nauth, n5xx) else
              "auth-burst" if nauth >= n5xx else "5xx-burst")
    _write("INSERT OR REPLACE INTO model_cooldowns VALUES(?,?,?,?,?)",
           (model, now + hold, streak, reason, now))
    return "tripped"


def active_cooldowns(now: float | None = None) -> dict[str, dict]:
    now = now or time.time()
    return {m: {"until": u, "remaining_s": round(u - now), "streak": s, "reason": r}
            for m, u, s, r in _read(
                "SELECT model, until, streak, reason FROM model_cooldowns WHERE until > ?",
                (now,))}


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


def _shadow_ladder(payload: dict, cls: str, rails: list, eligible: list, deny: set, struck: set,
                   cool: dict, ctx: dict, sub_gate, or_gate, jitter: float) -> dict:
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
    pick = ctx.get("pick", random.choice)
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
            and sub_model not in deny and sub_model not in struck and sub_model not in cool
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
              urgency?}
    ctx:     {price: fn(model)->(usd_per_mtok|None, basis|None),
              subscription_ok: fn(tier)->(ok, reason|None, retry_after_s),
              openrouter_ok:  fn(key_ref)->(ok, reason|None),
              pick: fn(list)->item  (optional; defaults to uniform random — the jitter band)}

    Walk: resolve class (explicit > label_map > role_defaults) → candidates (chain, else
    rotation-fed) → filter deny/strikes/cooldowns/rail → per class-rail-order pick the
    effective-cheapest with a jitter-band uniform pick → capacity-gate the rail → dispatch,
    or a TYPED defer (capacity reasons and cooldowns carry retry_after; only chain-exhausted
    escalates — M1 doctrine).

    The M11 cross-rail LADDER rides along in `decision["shadow"]` and changes nothing about the
    walk above: it is computed from the same filtered candidates and the same capacity gates, and
    it is written to the store + the proxy log for the soak review (homelab#159)."""
    now = time.time()
    role = str(payload.get("role") or "worker")
    labels = [str(x) for x in (payload.get("labels") or [])]
    sel = _classes.get("selection") or {}
    jitter = float(sel.get("jitter_band_pct", 15)) / 100.0
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
    if not chain:
        chain = _rotation_candidates(cinfo)
        source = "rotation"
    deny = {str(m) for m in (payload.get("deny") or [])}
    # Recorded always, ACTED ON only when STRIKE_ENFORCE (see the constant's note): today this is
    # an empty set, which is exactly the behaviour the loop has had all along — now on purpose.
    struck = set(strikes_for(str(payload.get("task") or ""), str(payload.get("stack") or ""))) \
        if STRIKE_ENFORCE else set()
    cool = active_cooldowns(now)
    skipped: list[dict] = []
    eligible: list[tuple[str, str]] = []
    for m in chain:
        rail = "subscription" if m.startswith("claude/") else "openrouter"
        if m in deny:
            skipped.append({"model": m, "reason": "claim-deny"})
        elif m in struck:
            skipped.append({"model": m, "reason": "strike"})
        elif m in cool:
            skipped.append({"model": m, "reason": f"cooldown:{cool[m]['reason']}",
                            "retry_after_s": cool[m]["remaining_s"]})
        elif (floor_fail := capability_floor_block(cls, m)) is not None:
            skipped.append({"model": m, "reason": f"capability-floor:{floor_fail}"})
        elif rail not in rails:
            skipped.append({"model": m, "reason": f"rail-{rail}-not-in-class-{cls}"})
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
                pick = ctx.get("pick", random.choice)(band)
            else:
                pick, band = priced[0], priced[:1]  # unpriced chain: keep caller order
            result = {"model": pick[0], "rail": rail, "price_per_mtok": pick[1],
                      "basis": pick[2], "jitter_pool": [p[0] for p in band]}
        break
    if result:
        half_open = bool(_read(
            "SELECT 1 FROM model_cooldowns WHERE model=? AND until <= ?", (result["model"], now)))
        decision = {"decision": "dispatch", "class": cls, "tier": tier, "source": source,
                    "half_open": half_open, "skipped": skipped, **result}
    else:
        if capacity_block:
            reason, retry = capacity_block["reason"], capacity_block.get("retry_after_s") or 900
        elif any(s["reason"].startswith("cooldown:") for s in skipped):
            reason = "cooldown"
            retry = min(s.get("retry_after_s") or 900
                        for s in skipped if s["reason"].startswith("cooldown:"))
        else:
            reason = "chain-exhausted"  # deny/strike only — the one defer that escalates
            retry = None
        decision = {"decision": "defer", "reason": reason, "retry_after_s": retry,
                    "class": cls, "tier": tier, "source": source, "skipped": skipped}
    # ── M11 SHADOW (homelab#159) — computed after the served decision, consumed by nobody ──
    shadow = _shadow_ladder(payload, cls, rails, eligible, deny, struck, cool, ctx,
                            sub_gate, or_gate, jitter)
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
        "cooldowns_active": active_cooldowns(now),
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
              "# HELP router_cooldowns_active Models currently held out of the routing pool (addendum-4 temporary blacklist).",
              f"router_cooldowns_active {len(active_cooldowns(now))}",
              "# TYPE router_decisions_total counter",
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
    assert strikes_for("issue-19", "circles") == ["deepseek/deepseek-v4-flash"]
    # Recording is not acting: enforcement stays OFF until a policy decision (see STRIKE_ENFORCE).
    assert STRIKE_ENFORCE is False, "strike enforcement must default OFF — routing is unchanged by design"
    assert strikes_for("issue-9", "sleep") == ["deepseek/deepseek-v4-flash"]
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
    # free model starts 429ing: burst past min_events/bad_share trips a cooldown
    for _ in range(8):
        record_provider_event("inclusionai/ling-3.0-flash:free", "novita", 429)
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 429) == "tripped"
    assert "inclusionai/ling-3.0-flash:free" in active_cooldowns()
    d2 = route(dict(base), CTX)
    assert d2["decision"] == "dispatch" and d2["model"] == "deepseek/deepseek-v4-flash", d2
    assert any(s["reason"] == "cooldown:429-burst" for s in d2["skipped"]), d2["skipped"]
    # the hold expires ("the model comes back online") → half-open: cheapest wins again
    assert _write("UPDATE model_cooldowns SET until=? WHERE model=?",
                  (time.time() - 1, "inclusionai/ling-3.0-flash:free"))
    d3 = route(dict(base), CTX)
    assert d3["decision"] == "dispatch" and d3["model"] == "inclusionai/ling-3.0-flash:free", d3
    assert d3["half_open"], "an expired-cooldown pick must be flagged half-open"
    # a 2xx clears the row + streak; a re-trip would have doubled the hold before that
    assert cooldown_note("inclusionai/ling-3.0-flash:free", 200) == "cleared"
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
    body = "\n".join(metrics_lines())
    assert "router_db_persistent 0" in body, "self-test store is ephemeral by construction"
    assert 'router_strikes_total{error_class="harness-death"} 1' in body
    assert 'router_circuit_open_total{class="auth"} 1' in body
    assert 'router_decisions_total{decision="dispatch"' in body
    assert status_summary()["decisions_24h"], "decisions must surface in status"
    assert (_read("SELECT COUNT(*) FROM generations") or [(0,)])[0][0] == 1
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
    # 8 run_reports (t-1 is INSERT OR REPLACE'd, + t-2 clean, + t-3 the real producer shape,
    # + the 5 M11 ladder-cell fixtures) and 3 strikes (issue-9/sleep from the vocabulary fixture,
    # issue-19/circles from the real one, issue-42/sleep from the ladder's degradation step).
    assert summary["rows"]["run_reports"] == 8 and summary["rows"]["strikes"] == 3
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
    print("router self-test: OK "
          f"(classes {'loaded' if _classes else 'absent — jail run without the file is fine'})")
    return 0


if __name__ == "__main__":  # the only CLI mode is the self-test (CI + jail probes)
    sys.exit(self_test())
