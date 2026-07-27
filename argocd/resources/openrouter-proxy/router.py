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
  cost_usd REAL, latency_ms INTEGER, finish TEXT);
CREATE TABLE IF NOT EXISTS decisions(
  ts REAL, session TEXT, stack TEXT, role TEXT, class TEXT, decision TEXT, rail TEXT,
  model TEXT, reason TEXT, detail TEXT);
CREATE TABLE IF NOT EXISTS latch_state(k TEXT PRIMARY KEY, v TEXT);
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
    overwrite a stored record with a thinner one."""
    return _write(
        "INSERT OR IGNORE INTO generations VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (gen_id, time.time(), requested_model, str(data.get("model") or ""),
         str(data.get("provider_name") or ""), int(data.get("native_tokens_prompt") or 0),
         int(data.get("native_tokens_completion") or 0),
         int(data.get("native_tokens_cached") or 0), float(data.get("total_cost") or 0.0),
         int(data.get("latency") or 0), str(data.get("finish_reason") or "")))


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


def strikes_for(task: str, stack: str) -> list[str]:
    """Models struck for THIS task (M1: blacklists are task-scoped) — the /route filter in P3;
    /router-status shows it today."""
    return [r[0] for r in _read(
        "SELECT DISTINCT model FROM strikes WHERE task=? AND stack=?", (task, stack))]


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
                        "generations")}
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
    return {
        "db_persistent": _persistent,
        "rows": counts,
        "strikes_7d": [{"model": m, "error_class": e, "n": n} for m, e, n in recent_strikes],
        "provider_errors_24h": [{"provider": p, "class": c, "n": n} for p, c, n in provider_errs],
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
        "finish_reason": "stop"})
    assert record_generation("gen-test-1", "deepseek/deepseek-v4-flash", {
        "total_cost": 9.8e-07}), "generation re-record must stay idempotent (no-op)"
    assert record_rotation("scout-canary",
                           [{"model": "moonshotai/kimi-k3", "canary_verdict": "clean"}]) == 1
    latch_save({"until": 123.0, "last_429": 100.0, "windows": {"5h": {"utilization": 0.5}},
                "count_429": 2, "headers_at": 99.0})
    assert (latch_load() or {}).get("count_429") == 2, "latch round-trip"
    body = "\n".join(metrics_lines())
    assert "router_db_persistent 0" in body, "self-test store is ephemeral by construction"
    assert 'router_strikes_total{error_class="harness-death"} 1' in body
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
            assert 0.0 < float(thr) <= 1.0, f"tier {tier} threshold out of range"
    print("router self-test: OK "
          f"(classes {'loaded' if _classes else 'absent — jail run without the file is fine'})")
    return 0


if __name__ == "__main__":  # the only CLI mode is the self-test (CI + jail probes)
    sys.exit(self_test())
