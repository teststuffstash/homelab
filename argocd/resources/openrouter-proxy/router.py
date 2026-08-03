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
  error_class TEXT, outcome TEXT);
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
CREATE INDEX IF NOT EXISTS ix_pe_model_ts ON provider_events(model, ts);
"""

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
        "INSERT OR REPLACE INTO run_reports VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (now, str(d.get("session") or ""), str(d.get("task") or ""), str(d.get("stack") or ""),
         str(d.get("role") or "worker"), int(d.get("round") or 1), str(d.get("model") or ""),
         str(d.get("served_model") or ""), str(d.get("served_provider") or ""),
         float(d.get("cache_hit") or 0.0), float(d.get("cost_usd") or 0.0),
         str(d.get("error_class") or ""), str(d.get("outcome") or "")))
    err = str(d.get("error_class") or "")
    striked = False
    if stored and err in STRIKE_CLASSES and not str(d.get("outcome") or "").startswith("pr"):
        # Dedup per (task, model, session): a re-POST must not double-strike.
        _write("DELETE FROM strikes WHERE task=? AND model=? AND session=?",
               (str(d.get("task") or ""), str(d.get("model") or ""), str(d.get("session") or "")))
        striked = _write(
            "INSERT INTO strikes VALUES(?,?,?,?,?,?,?)",
            (now, str(d.get("task") or ""), str(d.get("stack") or ""), str(d.get("model") or ""),
             err, int(d.get("round") or 1), str(d.get("session") or "")))
    return stored, striked


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


def route(payload: dict, ctx: dict) -> dict:
    """The ADR-096 /route decision core — pure given ctx, so the self-test can drive it.

    payload: {stack, task, role, session, labels[], chain[], deny[], class?, tier?, key_ref?}
    ctx:     {price: fn(model)->(usd_per_mtok|None, basis|None),
              subscription_ok: fn(tier)->(ok, reason|None, retry_after_s),
              openrouter_ok:  fn(key_ref)->(ok, reason|None),
              pick: fn(list)->item  (optional; defaults to uniform random — the jitter band)}

    Walk: resolve class (explicit > label_map > role_defaults) → candidates (chain, else
    rotation-fed) → filter deny/strikes/cooldowns/rail → per class-rail-order pick the
    effective-cheapest with a jitter-band uniform pick → capacity-gate the rail → dispatch,
    or a TYPED defer (capacity reasons and cooldowns carry retry_after; only chain-exhausted
    escalates — M1 doctrine)."""
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
    struck = set(strikes_for(str(payload.get("task") or ""), str(payload.get("stack") or "")))
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
        elif rail not in rails:
            skipped.append({"model": m, "reason": f"rail-{rail}-not-in-class-{cls}"})
        else:
            eligible.append((m, rail))
    capacity_block: dict | None = None
    result: dict | None = None
    for rail in rails:
        pool = [m for m, r in eligible if r == rail]
        if not pool:
            continue
        if rail == "subscription":
            ok, reason, retry = ctx["subscription_ok"](tier)
            if not ok:
                reason = reason or "subscription-limited"
                capacity_block = capacity_block or {"reason": reason, "retry_after_s": retry}
                skipped += [{"model": m, "reason": reason} for m in pool]
                continue
            result = {"model": pool[0], "rail": rail, "price_per_mtok": None,
                      "basis": "subscription", "jitter_pool": pool[:1]}
        else:
            ok, reason = ctx["openrouter_ok"](payload.get("key_ref"))
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
    _write("INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?)",
           (now, str(payload.get("session") or ""), str(payload.get("stack") or ""), role, cls,
            decision["decision"], decision.get("rail") or "",
            decision.get("model") or "", decision.get("reason") or "",
            json.dumps({"skipped": skipped, "source": source,
                        "jitter_pool": decision.get("jitter_pool")})))
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
                        "generations", "circuit_events", "openrouter_keys")}
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
                    [{"model": "qwen/qwen3-coder", "rank": 1},
                     {"model": "not-in-tiers/mystery", "rank": 2}])
    record_rotation("provider-events",
                    [{"model": "poolside/laguna-s-2.1:free", "canary_verdict": "broken"}])
    dv = route(dict(base, chain=[]), {**CTX, "price": lambda m: (0.05, "market")})
    assert dv["decision"] == "dispatch" and dv["source"] == "rotation", dv
    assert dv["model"] == "qwen/qwen3-coder", dv
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
    summary = status_summary()
    assert summary["rows"]["run_reports"] == 2 and summary["rows"]["strikes"] == 1
    if _classes:
        assert "tier_thresholds" in _classes, "model-classes.json must carry tier_thresholds"
        for tier, thr in _classes["tier_thresholds"].items():
            if tier.startswith("_"):  # _comment keys are docs, not tiers
                continue
            assert 0.0 < float(thr) <= 1.0, f"tier {tier} threshold out of range"
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
